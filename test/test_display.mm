// Display probe: take a top-down CGImage (red top / blue bottom), draw it with
// NSImage drawInRect into a FLIPPED graphics context (like PreviewView), and
// read back the top pixel to see how it ends up oriented.
#import <Cocoa/Cocoa.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        int W=4,H=4;
        unsigned char src[4*4*4];
        for (int y=0;y<H;y++) for (int x=0;x<W;x++){
            unsigned char *p=&src[(y*W+x)*4];
            if (y<H/2){p[0]=255;p[1]=0;p[2]=0;p[3]=255;} else {p[0]=0;p[1]=0;p[2]=255;p[3]=255;}
        }
        CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
        CGContextRef bc=CGBitmapContextCreate(src,W,H,8,W*4,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGImageRef img=CGBitmapContextCreateImage(bc);  // top-down: red on top
        NSImage *ns=[[NSImage alloc] initWithCGImage:img size:NSMakeSize(W,H)];

        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
        NSGraphicsContext *gc=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        // Mimic a flipped NSView.
        gc=[NSGraphicsContext graphicsContextWithCGContext:gc.CGContext flipped:YES];
        [NSGraphicsContext setCurrentContext:gc];
        [ns drawInRect:NSMakeRect(0,0,W,H)];
        [gc flushGraphics];

        NSColor *topc=[rep colorAtX:0 y:0];        // y=0 is top in NSBitmapImageRep
        printf("rendered top pixel R=%.0f G=%.0f B=%.0f\n", topc.redComponent*255, topc.greenComponent*255, topc.blueComponent*255);
        printf("%s\n", topc.redComponent>0.7 ? "TOP-DOWN BUFFER DISPLAYS UPRIGHT" : "TOP-DOWN BUFFER DISPLAYS UPSIDE DOWN");
        CGImageRelease(img); CGContextRelease(bc); CGColorSpaceRelease(cs);
    }
    return 0;
}
