// johnvideo — test-only hooks into the coordinator.
//
// Lets headless UI tests boot a real AppDelegate (real EditorHost) with real
// TimelineView/PreviewView wired up in an offscreen window, then synthesize
// events and assert on the resulting model/transport state. NOT used in the app.
#import "AppDelegate.h"
#import "Editor.h"
#import "TimelineView.h"
#import "PreviewView.h"

@interface AppDelegate (Test)
// Build the model + both views inside an offscreen window of the given size.
// The timeline pane fills the window so timeline hit-testing uses full height.
- (void)bootForTestWithSize:(NSSize)size;
- (TimelineView *)tlView;
- (PreviewView *)pvView;
- (BOOL)isPlaying;
- (void)forcePlay;     // start the transport without relying on a run loop / audio
- (double)pps;

// The EditorHost selectors tests read/drive (the app implements these privately).
- (jv_timeline *)timeline;
- (double)playhead;
- (void)seekTo:(double)t;
- (jv_clip *)selectedClip;
- (BOOL)isClipSelected:(jv_clip *)c;
- (BOOL)bladeActive;

// Project persistence (normally private to the coordinator).
- (BOOL)loadProjectAtPath:(NSString *)path;
- (void)saveToPath:(NSString *)path;
- (BOOL)reopenLastProject;
- (NSString *)projectPath;
@end
