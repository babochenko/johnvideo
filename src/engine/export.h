// johnvideo — timeline export (pure C, FFmpeg).
#ifndef JV_EXPORT_H
#define JV_EXPORT_H

#include "timeline.h"

#ifdef __cplusplus
extern "C" {
#endif

// Optional progress callback: fraction in [0,1]. Return 0 to cancel.
typedef int (*jv_export_progress)(double fraction, void *user);

// Renders the whole timeline to an H.264 + AAC MP4 at out_path.
// Returns 0 on success, negative on error.
int jv_export_mp4(jv_timeline *tl, const char *out_path,
                  jv_export_progress cb, void *user);

#ifdef __cplusplus
}
#endif

#endif // JV_EXPORT_H
