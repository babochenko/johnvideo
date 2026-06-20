// johnvideo — test-only introspection into the in-place text editor.
#import "PreviewView.h"

@interface PreviewView (Test)
- (BOOL)isEditing;
- (NSString *)editText;      // current working string
- (NSUInteger)editCaret;     // caret index into editText
- (BOOL)editSelAll;          // whole-string selection active
- (void)layoutForTest;       // compute _videoRect without a draw cycle (canvas hit-testing)
@end
