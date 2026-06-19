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
- (void)renameTrackAtIndex:(size_t)index to:(NSString *)name;

// Drop/paste an image (provide either encoded bytes or a file path) onto the
// first visual track at time t.
- (void)addImageData:(NSData *)data path:(NSString *)path atTime:(double)t;

// Import a video or audio file (chosen by extension/probing) at time t.
- (void)importMediaPath:(NSString *)path atTime:(double)t;

// Create an editable text clip; canvas position is normalized 0..1.
- (void)addTextAtCanvasX:(float)cx y:(float)cy time:(double)t;

// Selection (a clip is identified by its track + clip pointer).
- (void)selectTrack:(jv_track *)t clip:(jv_clip *)c;   // single-select
- (jv_clip *)selectedClip;                              // primary selection
- (void)toggleSelectClip:(jv_clip *)c;                  // cmd+click multi-select
- (void)extendSelectionTo:(jv_clip *)c;                 // shift+click range select
- (BOOL)isClipSelected:(jv_clip *)c;
- (void)shiftSelectionExcept:(jv_clip *)c by:(double)delta;  // horizontal move-together
- (void)shiftSelectionTracksBy:(int)delta;                   // vertical move-together

// Move the selected object(s) along the timeline (cmd+h/l).
- (void)nudgeSelectedBy:(double)seconds;
// Jump the playhead through {0, markers..., end} (cmd + arrows).
- (void)jumpStartMarksEnd:(int)dir;

// Transport / navigation (keyboard).
- (void)transportToggle;                 // space
- (void)nudgePlayheadBy:(double)seconds;  // arrows / h / l
- (void)zoomBy:(double)factor;            // ctrl +/-
- (void)addTextAtPlayhead;                // t

// Editing / history.
- (void)recordUndo;                       // snapshot before a mutation
- (void)copySelectedClip;
- (BOOL)pasteClipAtPlayhead;              // YES if a clip was pasted
- (void)deleteSelectedClip;
- (void)performUndo;
- (void)performRedo;

// Markers.
- (void)addMarkerAtPlayhead;              // m
- (BOOL)deleteMarkerNearPlayhead;         // YES if one was removed
- (void)jumpToMarker:(int)dir;            // ctrl + arrows / h / l

// Clip / track navigation (vim-style).
- (void)selectAdjacentClip:(int)dir;      // h / l  (by start time)
- (void)focusTrack:(int)dir;              // j / k

// Edit a text clip in place on the preview (timeline double-click).
- (void)beginEditingClip:(jv_clip *)c;

// Blade tool (modal): toggle, query, and cut a clip at the playhead.
- (void)toggleBlade;
- (BOOL)bladeActive;
- (void)bladeCutClip:(jv_clip *)c atTime:(double)t;
@end
