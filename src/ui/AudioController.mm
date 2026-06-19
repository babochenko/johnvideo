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
    float             *_mixbuf;        // preallocated interleaved scratch for the render block

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
    AVAudioMixerNode *mixer = _playEngine.mainMixerNode;   // lazily creates+connects outputNode
    AVAudioOutputNode *output = _playEngine.outputNode;

    // Build the source format from the OUTPUT format (same sample rate and
    // interleaved-ness) — feeding the graph a mismatched layout is what made it
    // silent. Hardware float is typically non-interleaved (planar).
    AVAudioFormat *outFmt = [output inputFormatForBus:0];
    double sr = outFmt.sampleRate > 0 ? outFmt.sampleRate : kSR;
    _playSR = sr;
    BOOL interleaved = outFmt.isInterleaved;
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:sr
                                                            channels:2
                                                         interleaved:interleaved];
    if (!_mixbuf) _mixbuf = (float *)malloc(sizeof(float) * 16384 * 2);

    __weak AudioController *weakSelf = self;
    _source = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:
        ^OSStatus(BOOL *silence, const AudioTimeStamp *ts,
                  AVAudioFrameCount count, AudioBufferList *abl) {
            AudioController *s = weakSelf;
            if (!s || !s->_timeline || count > 16384) {
                for (UInt32 b = 0; b < abl->mNumberBuffers; b++)
                    memset(abl->mBuffers[b].mData, 0, abl->mBuffers[b].mDataByteSize);
                *silence = YES; return noErr;
            }
            double now = s->_startTime + (double)s->_playSample / s->_playSR;
            jv_mix_audio(s->_timeline, now, (int)s->_playSR, (int)count, s->_mixbuf);
            if (abl->mNumberBuffers >= 2) {                 // non-interleaved: split L/R
                float *L = (float *)abl->mBuffers[0].mData;
                float *R = (float *)abl->mBuffers[1].mData;
                for (AVAudioFrameCount i = 0; i < count; i++) { L[i] = s->_mixbuf[i*2]; R[i] = s->_mixbuf[i*2+1]; }
            } else {                                        // interleaved
                memcpy(abl->mBuffers[0].mData, s->_mixbuf, count * 2 * sizeof(float));
            }
            s->_playSample += count;
            *silence = NO;
            return noErr;
        }];

    @try {
        [_playEngine attachNode:_source];
        [_playEngine connect:_source to:mixer format:fmt];
        [_playEngine connect:mixer to:output format:outFmt];
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
// Live access for the timeline to draw the take as it is captured.
- (const float *)recordingPCM { return _recBuf; }
- (size_t)recordingFrames { return _recFrames; }
- (int)recordingSampleRate { return _recSR > 0 ? _recSR : (int)kSR; }

- (void)appendStereoFrom:(AVAudioPCMBuffer *)buf {
    AVAudioFrameCount n = buf.frameLength;
    if (n == 0 || !_recBuf) return;
    if (_recFrames + n > _recCap) n = (AVAudioFrameCount)(_recCap - _recFrames);   // capped, no realloc
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

    // Fixed-capacity buffer (10 min) so the pointer is stable while a live clip
    // references it during recording (no realloc to invalidate it).
    _recCap = (size_t)_recSR * 60 * 10;
    _recBuf = (float *)malloc(_recCap * 2 * sizeof(float));
    if (!_recBuf) { _recEngine = nil; return; }

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
