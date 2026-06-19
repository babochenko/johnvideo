// johnvideo — shared editor contract between the views and the coordinator.
#import <Cocoa/Cocoa.h>
#include "timeline.h"

// Timeline drawing geometry, shared by TimelineView and hit-testing.
static const CGFloat kTrackHeight = 48.0;
static const CGFloat kTrackGap    = 4.0;
static const CGFloat kHeaderWidth = 96.0;
static const CGFloat kRulerHeight = 18.0;

// Implemented by AppDelegate; views call back into it to mutate the model.
@protocol EditorHost <NSObject>
- (jv_timeline *)timeline;
- (double)pixelsPerSecond;
- (double)playhead;

- (void)refreshAll;                                   // redraw preview + timeline
- (void)seekTo:(double)t;
- (void)setPixelsPerSecond:(double)pps;               // timeline zoom

- (void)addTrackOfKind:(jv_track_kind)kind;
- (void)removeTrackAtIndex:(size_t)index;

// Drop/paste an image (provide either encoded bytes or a file path) onto the
// first visual track at time t.
- (void)addImageData:(NSData *)data path:(NSString *)path atTime:(double)t;

// Import a video or audio file (chosen by extension/probing) at time t.
- (void)importMediaPath:(NSString *)path atTime:(double)t;

// Create an editable text clip; canvas position is normalized 0..1.
- (void)addTextAtCanvasX:(float)cx y:(float)cy time:(double)t;

// Selection (a clip is identified by its track + clip pointer).
- (void)selectTrack:(jv_track *)t clip:(jv_clip *)c;
- (jv_clip *)selectedClip;
@end
