// johnvideo — platform media helpers (Objective-C++ bridge to C engine).
//
// Produce RGBA8 (top-down, premultiplied-by-alpha-aware) buffers the engine
// compositor understands. All returned buffers are malloc'd; free with free().
#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
extern "C" {
#endif

// Decode an image file (any ImageIO-supported format) to RGBA. NULL on failure.
unsigned char *jv_rgba_from_file(const char *path, int *w, int *h);

// Decode encoded image bytes (e.g. clipboard PNG / dragged image data) to RGBA.
unsigned char *jv_rgba_from_bytes(const void *bytes, size_t len, int *w, int *h);

// Rasterize UTF-8 text with Core Text to a tightly-fit RGBA bitmap.
// color is 0xRRGGBBAA.
unsigned char *jv_rasterize_text(const char *utf8, double font_size,
                                 unsigned int color, int *w, int *h);

// Wrap an RGBA buffer in a CGImage for on-screen drawing. Copies the bytes,
// so the caller keeps ownership of `rgba`. Release with CGImageRelease.
CGImageRef jv_cgimage_from_rgba(const unsigned char *rgba, int w, int h);

#ifdef __cplusplus
}
#endif
