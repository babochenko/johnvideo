// johnvideo — preview pane implementation (Objective-C++)
#import "PreviewView.h"
#import "Media.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "decoder.h"

typedef enum { PV_NONE, PV_MOVE, PV_RESIZE, PV_ROTATE } pv_mode;

@interface PreviewView () <NSTextFieldDelegate>
@end

@implementation PreviewView {
    NSRect       _videoRect;   // where the composited frame is drawn (letterboxed)
    jv_clip     *_dragClip;    // visual clip being dragged on the canvas
    NSPoint      _grab;        // pointer offset from the clip center at grab time
    pv_mode      _mode;
    NSTextField *_editField;   // in-place text editor overlay
    jv_clip     *_editClip;    // text clip currently being edited
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF,
                                         NSPasteboardTypeFileURL, NSPasteboardTypeString ]];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }   // standard y-up: NSImage draws our top-down buffer upright
- (BOOL)acceptsFirstResponder { return YES; }

// Compute the largest rect with the timeline's aspect ratio that fits bounds.
- (NSRect)fitRect {
    jv_timeline *tl = [self.host timeline];
    CGFloat aspect = (tl && tl->height) ? (CGFloat)tl->width / tl->height : 16.0 / 9.0;
    NSRect b = self.bounds;
    CGFloat w = b.size.width, h = w / aspect;
    if (h > b.size.height) { h = b.size.height; w = h * aspect; }
    return NSMakeRect((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
}

// ---- Clip geometry on the canvas (matches the engine compositor) ----
// Fill normalized center and source pixel size for a visual clip; returns the
// height fraction it occupies, or 0 if it has no on-canvas geometry.
- (float)clip:(jv_clip *)c center:(NSPoint *)ctr srcW:(float *)sw srcH:(float *)sh {
    jv_timeline *tl = [self.host timeline];
    switch (c->type) {
        case JV_CLIP_IMAGE:
            *ctr = NSMakePoint(c->u.image.cx, c->u.image.cy);
            *sw = c->u.image.width; *sh = c->u.image.height;
            return c->u.image.scale;
        case JV_CLIP_TEXT:
            *ctr = NSMakePoint(c->u.text.cx, c->u.text.cy);
            *sw = c->u.text.width; *sh = c->u.text.height;
            return (float)c->u.text.height / (tl->height > 0 ? tl->height : 1);
        case JV_CLIP_VIDEO: {
            *ctr = NSMakePoint(c->u.video.cx, c->u.video.cy);
            int vw = c->u.video.decoder ? jv_decoder_width((jv_decoder *)c->u.video.decoder) : 16;
            int vh = c->u.video.decoder ? jv_decoder_height((jv_decoder *)c->u.video.decoder) : 9;
            *sw = vw > 0 ? vw : 16; *sh = vh > 0 ? vh : 9;
            return c->u.video.scale;
        }
        default: return 0;
    }
}

// Normalized canvas coords (top-down: cy=0 at the top) for a view point.
- (NSPoint)normFromPoint:(NSPoint)p {
    return NSMakePoint((p.x - _videoRect.origin.x) / _videoRect.size.width,
                       (NSMaxY(_videoRect) - p.y) / _videoRect.size.height);
}

// Snap a clip's normalized center so its edges/center stick to canvas guides.
- (NSPoint)snapCenter:(NSPoint)n forClip:(jv_clip *)c {
    NSRect r = [self displayRectForClip:c];
    float halfWn = (float)(r.size.width / 2) / _videoRect.size.width;
    float halfHn = (float)(r.size.height / 2) / _videoRect.size.height;
    float thx = 8.0f / _videoRect.size.width;
    float thy = 8.0f / _videoRect.size.height;
    float xs[3] = { halfWn, 1 - halfWn, 0.5f };   // left edge, right edge, center
    float ys[3] = { halfHn, 1 - halfHn, 0.5f };   // top edge, bottom edge, center
    for (int k = 0; k < 3; k++) if (fabsf(n.x - xs[k]) < thx) { n.x = xs[k]; break; }
    for (int k = 0; k < 3; k++) if (fabsf(n.y - ys[k]) < thy) { n.y = ys[k]; break; }
    return n;
}

// Screen center of a clip (cy is top-down, view is y-up).
- (NSPoint)centerForClip:(jv_clip *)c {
    NSPoint ctr; float sw = 0, sh = 0;
    [self clip:c center:&ctr srcW:&sw srcH:&sh];
    return NSMakePoint(_videoRect.origin.x + ctr.x * _videoRect.size.width,
                       NSMaxY(_videoRect) - ctr.y * _videoRect.size.height);
}

// On-screen (unrotated) rect of a visual clip within _videoRect.
- (NSRect)displayRectForClip:(jv_clip *)c {
    NSPoint ctr; float sw = 0, sh = 0;
    float scale = [self clip:c center:&ctr srcW:&sw srcH:&sh];
    if (scale <= 0 || sw <= 0 || sh <= 0) return NSZeroRect;
    CGFloat h = scale * _videoRect.size.height;
    CGFloat w = h * sw / sh;
    NSPoint mid = [self centerForClip:c];
    return NSMakeRect(mid.x - w / 2, mid.y - h / 2, w, h);
}

- (float)rotationForClip:(jv_clip *)c {
    switch (c->type) {
        case JV_CLIP_IMAGE: return c->u.image.rotation;
        case JV_CLIP_TEXT:  return c->u.text.rotation;
        case JV_CLIP_VIDEO: return c->u.video.rotation;
        default: return 0;
    }
}
- (void)setRotation:(float)r forClip:(jv_clip *)c {
    switch (c->type) {
        case JV_CLIP_IMAGE: c->u.image.rotation = r; break;
        case JV_CLIP_TEXT:  c->u.text.rotation = r; break;
        case JV_CLIP_VIDEO: c->u.video.rotation = r; break;
        default: break;
    }
}
- (void)setScale:(float)s forClip:(jv_clip *)c {
    if (s < 0.02f) s = 0.02f;
    if (s > 3.0f) s = 3.0f;
    switch (c->type) {
        case JV_CLIP_IMAGE: c->u.image.scale = s; break;
        case JV_CLIP_TEXT:  c->u.text.scale = s; break;
        case JV_CLIP_VIDEO: c->u.video.scale = s; break;
        default: break;
    }
}

// Handle anchor points (screen coords) for the selected clip.
- (NSPoint)resizeHandleForClip:(jv_clip *)c { NSRect r = [self displayRectForClip:c]; return NSMakePoint(NSMaxX(r), NSMinY(r)); }
- (NSPoint)rotateHandleForClip:(jv_clip *)c { NSRect r = [self displayRectForClip:c]; return NSMakePoint(NSMidX(r), NSMaxY(r) + 22); }

// Topmost visual clip active at the playhead whose rect contains p.
- (jv_clip *)visualClipAtPoint:(NSPoint)p {
    jv_timeline *tl = [self.host timeline];
    if (!tl) return NULL;
    double t = [self.host playhead];
    // Topmost z = first visual track (matches the compositor).
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *trk = &tl->tracks[i];
        if (trk->kind != JV_TRACK_VISUAL) continue;
        for (size_t j = trk->clip_count; j-- > 0;) {
            jv_clip *c = &trk->clips[j];
            if (t < c->start_time || t >= c->start_time + c->duration) continue;
            if (NSPointInRect(p, [self displayRectForClip:c])) return c;
        }
    }
    return NULL;
}

- (void)setClip:(jv_clip *)c centerX:(float)cx y:(float)cy {
    if (cx < 0) cx = 0; if (cx > 1) cx = 1;
    if (cy < 0) cy = 0; if (cy > 1) cy = 1;
    switch (c->type) {
        case JV_CLIP_IMAGE: c->u.image.cx = cx; c->u.image.cy = cy; break;
        case JV_CLIP_TEXT:  c->u.text.cx = cx;  c->u.text.cy = cy;  break;
        case JV_CLIP_VIDEO: c->u.video.cx = cx; c->u.video.cy = cy; break;
        default: break;
    }
}

static CGFloat pt_dist(NSPoint a, NSPoint b) { return hypot(a.x - b.x, a.y - b.y); }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];

    // Double-click: edit a text clip in place, or create one and edit it.
    if (e.clickCount == 2) {
        jv_clip *hit = [self visualClipAtPoint:p];
        if (hit && hit->type == JV_CLIP_TEXT) {
            [self.host selectTrack:NULL clip:hit];
            [self beginEditingTextClip:hit];
        } else {
            NSPoint n = [self normFromPoint:p];
            [self.host addTextAtCanvasX:n.x y:n.y time:[self.host playhead]];
            jv_clip *c = [self.host selectedClip];
            if (c && c->type == JV_CLIP_TEXT) [self beginEditingTextClip:c];
        }
        return;
    }

    [self.window makeFirstResponder:self];

    // If a clip is selected, check its resize/rotate handles first.
    jv_clip *sel = [self.host selectedClip];
    if (sel && [self clipIsVisual:sel]) {
        if (pt_dist(p, [self rotateHandleForClip:sel]) < 12) { _dragClip = sel; _mode = PV_ROTATE; return; }
        if (pt_dist(p, [self resizeHandleForClip:sel]) < 12) { _dragClip = sel; _mode = PV_RESIZE; return; }
    }

    _dragClip = [self visualClipAtPoint:p];
    if (_dragClip) {
        [self.host selectTrack:NULL clip:_dragClip];
        NSPoint mid = [self centerForClip:_dragClip];
        _grab = NSMakePoint(p.x - mid.x, p.y - mid.y);
        _mode = PV_MOVE;
        [self.host refreshAll];
    } else {
        _mode = PV_NONE;
    }
}

- (BOOL)clipIsVisual:(jv_clip *)c {
    return c->type == JV_CLIP_IMAGE || c->type == JV_CLIP_TEXT || c->type == JV_CLIP_VIDEO;
}

- (void)mouseDragged:(NSEvent *)e {
    if (!_dragClip || _mode == PV_NONE) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint mid = [self centerForClip:_dragClip];

    if (_mode == PV_MOVE) {
        NSPoint adj = NSMakePoint(p.x - _grab.x, p.y - _grab.y);
        NSPoint n = [self normFromPoint:adj];
        n = [self snapCenter:n forClip:_dragClip];   // sticky to canvas edges/center
        [self setClip:_dragClip centerX:n.x y:n.y];
    } else if (_mode == PV_RESIZE) {
        // Scale so the clip half-height follows the pointer's vertical distance.
        CGFloat halfH = fabs(p.y - mid.y);
        [self setScale:(float)(2 * halfH / _videoRect.size.height) forClip:_dragClip];
    } else if (_mode == PV_ROTATE) {
        // Clockwise bearing from straight-up = 0, sticky to multiples of 90°.
        float ang = (float)atan2(p.x - mid.x, p.y - mid.y);
        float step = (float)M_PI_2;
        float nearest = roundf(ang / step) * step;
        if (fabsf(ang - nearest) < 0.12f) ang = nearest;   // ~7° snap zone
        [self setRotation:ang forClip:_dragClip];
    }
    [self.host refreshAll];
}

- (void)mouseUp:(NSEvent *)e { _dragClip = NULL; _mode = PV_NONE; }

- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    jv_timeline *tl = [self.host timeline];
    if (!tl) return;

    _videoRect = [self fitRect];
    int pw = (int)_videoRect.size.width;
    int ph = (int)_videoRect.size.height;
    if (pw <= 0 || ph <= 0) return;

    unsigned char *rgba = (unsigned char *)malloc((size_t)pw * ph * 4);
    jv_render_frame(tl, [self.host playhead], rgba, pw, ph);
    CGImageRef img = jv_cgimage_from_rgba(rgba, pw, ph);
    if (img) {
        // NSImage draws our top-down buffer upright regardless of view flip.
        NSImage *ns = [[NSImage alloc] initWithCGImage:img size:NSMakeSize(pw, ph)];
        [ns drawInRect:_videoRect];
        CGImageRelease(img);
    }
    free(rgba);

    // Selection outline + resize/rotate handles.
    jv_clip *sel = [self.host selectedClip];
    if (sel && [self clipIsVisual:sel]) {
        NSRect r = [self displayRectForClip:sel];
        NSPoint mid = NSMakePoint(NSMidX(r), NSMidY(r));
        NSGraphicsContext *gctx = [NSGraphicsContext currentContext];
        [gctx saveGraphicsState];
        // Rotate the selection chrome around the clip center to match the clip.
        NSAffineTransform *tf = [NSAffineTransform transform];
        [tf translateXBy:mid.x yBy:mid.y];
        [tf rotateByRadians:-[self rotationForClip:sel]];   // screen is y-up; clip rot is clockwise
        [tf translateXBy:-mid.x yBy:-mid.y];
        [tf concat];

        [[NSColor whiteColor] setStroke];
        NSBezierPath *box = [NSBezierPath bezierPathWithRect:r];
        box.lineWidth = 1.5;
        [box stroke];
        // Rotate handle stem + knob.
        NSPoint rot = NSMakePoint(NSMidX(r), NSMaxY(r) + 22);
        NSBezierPath *stem = [NSBezierPath bezierPath];
        [stem moveToPoint:NSMakePoint(NSMidX(r), NSMaxY(r))];
        [stem lineToPoint:rot];
        [stem stroke];
        [[NSColor systemGreenColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(rot.x - 5, rot.y - 5, 10, 10)] fill];
        // Resize handle (bottom-right).
        [[NSColor systemBlueColor] setFill];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(NSMaxX(r) - 5, NSMinY(r) - 5, 10, 10)] fill];
        [gctx restoreGraphicsState];
    }
}

// ---- Right-click: add text ----
- (void)rightMouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (!NSPointInRect(p, _videoRect)) return;
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *it = [menu addItemWithTitle:@"Add Text Here"
                                     action:@selector(addTextFromMenu:)
                              keyEquivalent:@""];
    it.target = self;
    it.representedObject = [NSValue valueWithPoint:p];
    [NSMenu popUpContextMenu:menu withEvent:e forView:self];
}

- (void)addTextFromMenu:(NSMenuItem *)item {
    NSPoint p = [[item representedObject] pointValue];
    NSPoint n = [self normFromPoint:p];
    [self.host addTextAtCanvasX:n.x y:n.y time:[self.host playhead]];
    jv_clip *c = [self.host selectedClip];
    if (c && c->type == JV_CLIP_TEXT) [self beginEditingTextClip:c];
}

// ---- In-place text editing ----
- (void)rerasterizeText:(jv_clip *)c {
    free(c->u.text.rgba);
    const char *s = c->u.text.string && c->u.text.string[0] ? c->u.text.string : " ";
    int w = 0, h = 0;
    c->u.text.rgba = jv_rasterize_text(s, c->u.text.font_size, c->u.text.color, &w, &h);
    c->u.text.width = w; c->u.text.height = h;
}

- (void)beginEditingTextClip:(jv_clip *)c {
    [self commitTextEditing];
    _editClip = c;
    jv_timeline *tl = [self.host timeline];
    CGFloat sc = _videoRect.size.height / (tl && tl->height > 0 ? tl->height : 1080);

    NSRect r = [self displayRectForClip:c];
    CGFloat w = fmax(r.size.width + 24, 80), h = fmax(r.size.height + 12, 28);
    NSRect fr = NSMakeRect([self centerForClip:c].x - w / 2, [self centerForClip:c].y - h / 2, w, h);
    _editField = [[NSTextField alloc] initWithFrame:fr];
    _editField.stringValue = c->u.text.string ? @(c->u.text.string) : @"";
    _editField.bordered = NO;
    _editField.drawsBackground = YES;
    _editField.backgroundColor = [NSColor colorWithWhite:0 alpha:0.4];
    _editField.textColor = [NSColor whiteColor];
    _editField.focusRingType = NSFocusRingTypeNone;
    _editField.alignment = NSTextAlignmentCenter;
    _editField.font = [NSFont boldSystemFontOfSize:fmax(10, c->u.text.font_size * sc)];
    _editField.delegate = self;
    [self addSubview:_editField];
    [self.window makeFirstResponder:_editField];
    [_editField selectText:nil];
}

- (void)controlTextDidChange:(NSNotification *)note {
    if (!_editClip) return;
    NSString *s = _editField.stringValue;
    free(_editClip->u.text.string);
    _editClip->u.text.string = strdup(s.UTF8String);
    [self rerasterizeText:_editClip];     // live: updates canvas bitmap + timeline label
    [self.host refreshAll];
}

- (void)controlTextDidEndEditing:(NSNotification *)note { [self commitTextEditing]; }

- (void)commitTextEditing {
    if (!_editField) return;
    if (_editClip) {
        NSString *s = _editField.stringValue;
        free(_editClip->u.text.string);
        _editClip->u.text.string = strdup(s.length ? s.UTF8String : "Text");
        [self rerasterizeText:_editClip];
    }
    [_editField removeFromSuperview];
    _editField = nil;
    _editClip = NULL;
    [self.host refreshAll];
}

// ---- Paste (Cmd+V) ----
- (void)keyDown:(NSEvent *)e {
    if ((e.modifierFlags & NSEventModifierFlagCommand) && [e.charactersIgnoringModifiers isEqualToString:@"v"]) {
        [self paste:nil];
    } else {
        [super keyDown:e];
    }
}

- (void)paste:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [self ingestPasteboard:pb atTime:[self.host playhead]];
}

// ---- Drag and drop (including from a browser) ----
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    return [self ingestPasteboard:sender.draggingPasteboard atTime:[self.host playhead]];
}

// Shared handler for both paste and drop. Tries, in order: raw image data,
// a file URL (local file or browser image drag), then a text URL to fetch.
- (BOOL)ingestPasteboard:(NSPasteboard *)pb atTime:(double)t {
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    NSData *tiff = png ?: [pb dataForType:NSPasteboardTypeTIFF];
    if (tiff) { [self.host addImageData:tiff path:nil atTime:t]; return YES; }

    NSURL *fileURL = [NSURL URLFromPasteboard:pb];
    if (fileURL.isFileURL) {
        [self.host importMediaPath:fileURL.path atTime:t];
        return YES;
    }

    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (str.length) {
        NSURL *url = [NSURL URLWithString:[str stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        if (url && (url.isFileURL || [url.scheme hasPrefix:@"http"])) {
            [self fetchURL:url atTime:t];
            return YES;
        }
    }
    return NO;
}

// Browser drops often give only a URL; fetch the bytes asynchronously.
- (void)fetchURL:(NSURL *)url atTime:(double)t {
    if (url.isFileURL) { [self.host importMediaPath:url.path atTime:t]; return; }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.host addImageData:data path:nil atTime:t];
        });
    }];
    [task resume];
}

@end
