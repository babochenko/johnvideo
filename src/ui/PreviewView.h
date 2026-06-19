// johnvideo — preview pane.
//
// Renders the composited frame at the playhead (jv_render_frame -> CGImage),
// adds text on right-click, and accepts image paste / drag-and-drop.
#import <Cocoa/Cocoa.h>
#import "Editor.h"

@interface PreviewView : NSView
@property(nonatomic, weak) id<EditorHost> host;
- (void)beginEditingTextClip:(jv_clip *)c;
@end
