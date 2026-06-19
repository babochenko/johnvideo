// Orientation probe: make a PNG that is red on TOP, blue on BOTTOM, decode it
// through the paste path (jv_rgba_from_bytes), and report the top-left pixel.
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Media.h"
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        int W = 4, H = 4;
        // Top-down buffer: rows 0-1 red, rows 2-3 blue.
        unsigned char src[4*4*4];
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                unsigned char *p = &src[(y*W+x)*4];
                if (y < H/2) { p[0]=255; p[1]=0; p[2]=0; p[3]=255; }   // red top
                else         { p[0]=0; p[1]=0; p[2]=255; p[3]=255; }   // blue bottom
            }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(src, W, H, 8, W*4, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGImageRef img = CGBitmapContextCreateImage(ctx);  // top-down CGImage
        // Encode to PNG in memory.
        NSMutableData *png = [NSMutableData data];
        CGImageDestinationRef dst = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)png, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);

        int w=0,h=0;
        unsigned char *out = jv_rgba_from_bytes(png.bytes, png.length, &w, &h);
        if (!out) { printf("decode failed\n"); return 1; }
        unsigned char *top = &out[0];
        unsigned char *bot = &out[(h-1)*w*4];
        printf("top-left  RGBA = %d,%d,%d,%d  (expect red 255,0,0)\n", top[0],top[1],top[2],top[3]);
        printf("bot-left  RGBA = %d,%d,%d,%d  (expect blue 0,0,255)\n", bot[0],bot[1],bot[2],bot[3]);
        printf("%s\n", top[0]>200 ? "BUFFER IS TOP-DOWN (correct)" : "BUFFER IS FLIPPED (bug)");
        free(out);
        CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    }
    return 0;
}
