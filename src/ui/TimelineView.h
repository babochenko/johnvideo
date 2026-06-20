// johnvideo — timeline pane.
//
// Draws a time ruler, track lanes with clips, and the playhead. Handles
// scrubbing, clip select/move/trim, right-click (add text / delete), and
// accepts image / media drops.
#import <Cocoa/Cocoa.h>
#import "Editor.h"

@interface TimelineView : NSView
@property(nonatomic, weak) id<EditorHost> host;
// Pan the view to keep the playhead on screen (used during playback).
- (void)followPlayhead;
// Zoom keeping the time under `anchorX` pinned (mouse-anchored zoom).
- (void)zoomToPps:(double)target anchorX:(CGFloat)anchorX;
// Keyboard zoom, anchored at the playhead.
- (void)zoomAroundPlayheadBy:(double)factor;
@end
