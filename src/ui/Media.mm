// johnvideo — platform media helpers (Objective-C++)
#import "Media.h"
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>

// Draw a CGImage into a fresh RGBA8 buffer of the same pixel size.
static unsigned char *rgba_from_cgimage(CGImageRef img, int *w, int *h) {
    if (!img) return NULL;
    int width = (int)CGImageGetWidth(img);
    int height = (int)CGImageGetHeight(img);
    if (width <= 0 || height <= 0) return NULL;

    unsigned char *buf = (unsigned char *)calloc((size_t)width * height * 4, 1);
    if (!buf) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        buf, width, height, 8, width * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }

    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), img);
    CGContextRelease(ctx);
    *w = width; *h = height;
    return buf;
}

unsigned char *jv_rgba_from_file(const char *path, int *w, int *h) {
    if (!path) return NULL;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    unsigned char *buf = rgba_from_cgimage(img, w, h);
    if (img) CGImageRelease(img);
    CFRelease(src);
    return buf;
}

unsigned char *jv_rgba_from_bytes(const void *bytes, size_t len, int *w, int *h) {
    if (!bytes || !len) return NULL;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    unsigned char *buf = rgba_from_cgimage(img, w, h);
    if (img) CGImageRelease(img);
    CFRelease(src);
    return buf;
}

unsigned char *jv_rasterize_text(const char *utf8, double font_size,
                                 unsigned int color, int *w, int *h) {
    if (!utf8) return NULL;
    NSString *s = [NSString stringWithUTF8String:utf8];
    if (s.length == 0) s = @" ";

    CGFloat r = ((color >> 24) & 0xFF) / 255.0;
    CGFloat g = ((color >> 16) & 0xFF) / 255.0;
    CGFloat b = ((color >> 8) & 0xFF) / 255.0;
    CGFloat a = (color & 0xFF) / 255.0;

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:font_size],
        NSForegroundColorAttributeName:
            [NSColor colorWithSRGBRed:r green:g blue:b alpha:a],
    };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attrs];

    // Measure, with a little padding so glyphs aren't clipped.
    NSSize sz = [as size];
    int width = (int)ceil(sz.width) + 8;
    int height = (int)ceil(sz.height) + 6;
    if (width <= 0 || height <= 0) return NULL;

    unsigned char *buf = (unsigned char *)calloc((size_t)width * height * 4, 1);
    if (!buf) return NULL;
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        buf, width, height, 8, width * 4, cspace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cspace);
    if (!ctx) { free(buf); return NULL; }

    // Draw in the same bottom-left-origin CG context the image path uses (no
    // extra flip) so the text bitmap has the identical top-down layout.
    NSGraphicsContext *prev = [NSGraphicsContext currentContext];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext setCurrentContext:gc];
    [as drawAtPoint:NSMakePoint(4, 3)];
    [gc flushGraphics];
    [NSGraphicsContext setCurrentContext:prev];
    CGContextRelease(ctx);

    *w = width; *h = height;
    return buf;
}

CGImageRef jv_cgimage_from_rgba(const unsigned char *rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return NULL;
    CFDataRef data = CFDataCreate(NULL, rgba, (CFIndex)w * h * 4);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(
        w, h, 8, 32, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return img;
}
