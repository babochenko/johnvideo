// johnvideo — audio playback + voiceover recording (Objective-C++).
//
// Playback: an AVAudioSourceNode whose render block pulls jv_mix_audio at the
// running playhead. Recording: an input tap accumulating stereo float PCM.
#import <Cocoa/Cocoa.h>
#include "timeline.h"

@interface AudioController : NSObject
@property(nonatomic, assign) jv_timeline *timeline;   // borrowed

- (void)playFrom:(double)t;
- (void)stop;
- (BOOL)isPlaying;
- (double)currentTime;          // playhead while playing, in seconds

// Records mic input while the timeline plays for monitoring.
- (void)startRecordingFrom:(double)t;
// Stops; returns malloc'd interleaved stereo float PCM (caller frees), with
// the captured frame count and sample rate. Returns NULL if nothing recorded.
- (float *)stopRecordingFrames:(size_t *)outFrames sampleRate:(int *)outSR;
- (BOOL)isRecording;
@end
