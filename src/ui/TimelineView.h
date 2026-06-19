// johnvideo — timeline pane.
//
// Draws a time ruler, track lanes with clips, and the playhead. Handles
// scrubbing, clip select/move/trim, right-click (add text / delete), and
// accepts image / media drops.
#import <Cocoa/Cocoa.h>
#import "Editor.h"

@interface TimelineView : NSView
@property(nonatomic, weak) id<EditorHost> host;
@end
