// johnvideo — audio playback + voiceover recording (Objective-C++)
#import "AudioController.h"
#import <AVFoundation/AVFoundation.h>

static const double kSR = 48000.0;

@implementation AudioController {
    AVAudioEngine     *_playEngine;
    AVAudioSourceNode *_source;
    volatile int64_t   _playSample;   // frames elapsed since playFrom:
    double             _playSR;        // playback engine sample rate (hardware)
    double             _startTime;     // timeline seconds at play start
    BOOL               _playing;

    AVAudioEngine     *_recEngine;
    float             *_recBuf;        // interleaved stereo float
    size_t             _recFrames;
    size_t             _recCap;
    int                _recSR;
    BOOL               _recording;
}

- (BOOL)isPlaying   { return _playing; }
- (BOOL)isRecording { return _recording; }

- (double)currentTime {
    if (_playing)   return _startTime + (double)_playSample / _playSR;
    if (_recording) return _startTime + (double)_recFrames / (_recSR > 0 ? _recSR : kSR);
    return _startTime;
}

// ---- Playback ----
- (void)playFrom:(double)t {
    [self stop];
    _startTime = t;
    _playSample = 0;

    _playEngine = [[AVAudioEngine alloc] init];

    // Match the output hardware's sample rate; connecting with a mismatched
    // rate is what throws the NSException that aborts the process. The mixer
    // resamples by time, so any rate is fine to feed it.
    double sr = [_playEngine.outputNode outputFormatForBus:0].sampleRate;
    if (sr <= 0) sr = kSR;
    _playSR = sr;

    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:sr
                                                            channels:2
                                                         interleaved:YES];
    __weak AudioController *weakSelf = self;
    _source = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:
        ^OSStatus(BOOL *silence, const AudioTimeStamp *ts,
                  AVAudioFrameCount count, AudioBufferList *abl) {
            AudioController *s = weakSelf;
            float *out = (float *)abl->mBuffers[0].mData;
            if (!s || !s->_timeline) { memset(out, 0, count * 2 * sizeof(float)); *silence = YES; return noErr; }
            double now = s->_startTime + (double)s->_playSample / s->_playSR;
            jv_mix_audio(s->_timeline, now, (int)s->_playSR, (int)count, out);
            s->_playSample += count;
            *silence = NO;   // without this CoreAudio may discard the buffer as silence
            return noErr;
        }];

    @try {
        AVAudioMixerNode *mixer = _playEngine.mainMixerNode;   // also lazily creates outputNode
        AVAudioOutputNode *output = _playEngine.outputNode;
        [_playEngine attachNode:_source];
        [_playEngine connect:_source to:mixer format:fmt];
        // Explicitly wire mixer -> output at the hardware format so there is a
        // guaranteed path to the speakers.
        [_playEngine connect:mixer to:output format:[output inputFormatForBus:0]];
        mixer.outputVolume = 1.0;
        [_playEngine prepare];
        NSError *err = nil;
        if (![_playEngine startAndReturnError:&err]) {
            NSLog(@"johnvideo: play engine failed: %@", err);
            _playEngine = nil; _source = nil; return;
        }
    } @catch (NSException *ex) {
        NSLog(@"johnvideo: play engine exception: %@", ex);
        _playEngine = nil; _source = nil; return;
    }
    _playing = YES;
}

- (void)stop {
    if (_playEngine) {
        [_playEngine stop];
        _playEngine = nil;
        _source = nil;
    }
    if (_playing) _startTime = [self currentTime];
    _playing = NO;
}

// ---- Recording ----
- (void)appendStereoFrom:(AVAudioPCMBuffer *)buf {
    AVAudioFrameCount n = buf.frameLength;
    if (n == 0) return;
    if (_recFrames + n > _recCap) {
        _recCap = (_recFrames + n) * 2 + 4096;
        _recBuf = (float *)realloc(_recBuf, _recCap * 2 * sizeof(float));
    }
    float *const *ch = buf.floatChannelData;
    int channels = (int)buf.format.channelCount;
    for (AVAudioFrameCount i = 0; i < n; i++) {
        float l = ch[0][i];
        float r = channels > 1 ? ch[1][i] : l;
        _recBuf[(_recFrames + i) * 2 + 0] = l;
        _recBuf[(_recFrames + i) * 2 + 1] = r;
    }
    _recFrames += n;
}

// Caller is responsible for having obtained microphone permission first.
- (void)startRecordingFrom:(double)t {
    if (_recording) return;
    free(_recBuf);
    _recBuf = NULL; _recFrames = 0; _recCap = 0;

    _recEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = _recEngine.inputNode;
    AVAudioFormat *inFmt = [input inputFormatForBus:0];
    if (inFmt.sampleRate <= 0 || inFmt.channelCount == 0) {
        NSLog(@"johnvideo: no microphone input available");
        _recEngine = nil; return;
    }
    _recSR = (int)inFmt.sampleRate;

    __weak AudioController *weakSelf = self;
    @try {
        [input installTapOnBus:0 bufferSize:1024 format:inFmt
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
            [weakSelf appendStereoFrom:buf];
        }];
        NSError *err = nil;
        if (![_recEngine startAndReturnError:&err]) {
            NSLog(@"johnvideo: record engine failed: %@", err);
            _recEngine = nil; return;
        }
    } @catch (NSException *ex) {
        NSLog(@"johnvideo: record engine exception: %@", ex);
        _recEngine = nil; return;
    }
    // The playhead advances from the capture clock (see currentTime); we don't
    // run a second output engine here, which would contend for the device.
    _startTime = t;
    _recording = YES;
}

- (float *)stopRecordingFrames:(size_t *)outFrames sampleRate:(int *)outSR {
    if (!_recording) { if (outFrames) *outFrames = 0; return NULL; }
    [_recEngine.inputNode removeTapOnBus:0];
    [_recEngine stop];
    _recEngine = nil;
    _recording = NO;
    [self stop];

    float *buf = _recBuf;
    if (outFrames) *outFrames = _recFrames;
    if (outSR) *outSR = _recSR > 0 ? _recSR : (int)kSR;
    _recBuf = NULL; _recFrames = 0; _recCap = 0;
    return buf;
}

@end
