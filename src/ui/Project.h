// johnvideo — project file (de)serialization.
//
// The .jvp file is a plain-text, line-based, diff-friendly format (git-track
// friendly). Media that has a source file is referenced by path; media without
// one (pasted images, recorded voiceovers) is written to a sibling
// "<file>.assets" folder as PNG/WAV and referenced relatively.
#import <Cocoa/Cocoa.h>
#include "timeline.h"

#ifdef __cplusplus
extern "C" {
#endif

BOOL         jv_project_save(jv_timeline *tl, NSString *path);
jv_timeline *jv_project_load(NSString *path);

#ifdef __cplusplus
}
#endif
