// johnvideo — preview pane implementation (Objective-C++)
#import "PreviewView.h"
#import "Media.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "decoder.h"

typedef enum { PV_NONE, PV_MOVE, PV_RESIZE, PV_ROTATE } pv_mode;

static CGFloat pt_dist(NSPoint a, NSPoint b);   // defined below

@implementation PreviewView {
    NSRect           _videoRect;   // where the composited frame is drawn (letterboxed)
    jv_clip         *_dragClip;    // visual clip being dragged on the canvas
    NSPoint          _grab;        // pointer offset from the clip center at grab time
    pv_mode          _mode;
    BOOL             _editing;     // typing into a text clip in place
    jv_clip         *_editClip;    // text clip being edited
    NSMutableString *_editText;    // working copy of the edited string
    BOOL             _editSelAll;  // whole-string selection (cmd+a)
    NSUInteger       _editCaret;   // caret index into _editText

    // Crop (trim) mode: a dashed frame over the image selecting the visible
    // sub-region. The clip renders full while cropping; commit writes the frame.
    BOOL             _cropping;
    jv_clip         *_cropClip;
    float            _cropX, _cropY, _cropW, _cropH;   // working crop, normalized 0..1
    int              _cropDrag;    // 0 none, 1 move, 2 corner-drag
    int              _cropCorner;  // which corner (0=TL,1=TR,2=BR,3=BL) when resizing
}

- (BOOL)becomeFirstResponder { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF,
                                         NSPasteboardTypeFileURL, NSPasteboardTypeString ]];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }   // standard y-up: NSImage draws our top-down buffer upright
- (BOOL)acceptsFirstResponder { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in [self.trackingAreas copy]) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
          owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSCursor *cur = [NSCursor arrowCursor];
    jv_clip *sel = [self.host selectedClip];
    if (sel && [self clipIsVisual:sel]) {
        if (pt_dist(p, [self rotateHandleForClip:sel]) < 12)      cur = [NSCursor openHandCursor];
        else if (pt_dist(p, [self resizeHandleForClip:sel]) < 12) cur = [NSCursor crosshairCursor];
    }
    [cur set];
}

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

// ---- Crop (trim) geometry ----
// A clip's stored crop, normalized; zero/invalid means full (the whole image).
static void clipCrop(jv_clip *c, float *x, float *y, float *w, float *h) {
    jv_image *im = &c->u.image;
    if (im->crop_w <= 0 || im->crop_h <= 0) { *x = 0; *y = 0; *w = 1; *h = 1; }
    else { *x = im->crop_x; *y = im->crop_y; *w = im->crop_w; *h = im->crop_h; }
}
// Screen rect of a normalized crop within the (full-image) display rect. The
// image is top-down (crop_y measured from the top); the view is y-up.
- (NSRect)screenRectForCropX:(float)cx y:(float)cy w:(float)cw h:(float)ch ofClip:(jv_clip *)c {
    NSRect dr = [self displayRectForClip:c];
    return NSMakeRect(dr.origin.x + cx * dr.size.width,
                      NSMaxY(dr) - (cy + ch) * dr.size.height,
                      cw * dr.size.width, ch * dr.size.height);
}
// The visible region of a clip on screen (display rect reduced by its crop).
- (NSRect)visibleRectForClip:(jv_clip *)c {
    float x, y, w, h; clipCrop(c, &x, &y, &w, &h);
    return [self screenRectForCropX:x y:y w:w h:h ofClip:c];
}
// The crop toggle button: a small square at the top-right of the visible image.
- (NSRect)cropButtonForClip:(jv_clip *)c {
    NSRect v = _cropping && c == _cropClip
        ? [self screenRectForCropX:_cropX y:_cropY w:_cropW h:_cropH ofClip:c]
        : [self visibleRectForClip:c];
    const CGFloat sz = 22;
    return NSMakeRect(NSMaxX(v) - sz, NSMaxY(v) - sz, sz, sz);   // top-right corner
}
// Convert a screen frame back to a normalized crop of the clip's full image.
- (void)setWorkingCropFromScreenRect:(NSRect)f clip:(jv_clip *)c {
    NSRect dr = [self displayRectForClip:c];
    if (dr.size.width <= 0 || dr.size.height <= 0) return;
    float x = (f.origin.x - dr.origin.x) / dr.size.width;
    float w = f.size.width / dr.size.width;
    float h = f.size.height / dr.size.height;
    float y = (NSMaxY(dr) - NSMaxY(f)) / dr.size.height;
    // Clamp to the image and enforce a minimum size.
    if (w < 0.05f) w = 0.05f; if (h < 0.05f) h = 0.05f;
    if (x < 0) x = 0; if (y < 0) y = 0;
    if (x + w > 1) x = 1 - w; if (y + h > 1) y = 1 - h;
    _cropX = x; _cropY = y; _cropW = w; _cropH = h;
}

- (void)enterCropForClip:(jv_clip *)c {
    [self.host recordUndo];
    _cropping = YES; _cropClip = c;
    clipCrop(c, &_cropX, &_cropY, &_cropW, &_cropH);   // start from the existing crop
    // Show the whole image while cropping so the frame can be expanded again.
    c->u.image.crop_x = 0; c->u.image.crop_y = 0; c->u.image.crop_w = 1; c->u.image.crop_h = 1;
    [self.host refreshAll];
}
- (void)commitCrop {
    if (!_cropping) return;
    if (_cropClip) {
        _cropClip->u.image.crop_x = _cropX; _cropClip->u.image.crop_y = _cropY;
        _cropClip->u.image.crop_w = _cropW; _cropClip->u.image.crop_h = _cropH;
    }
    _cropping = NO; _cropClip = NULL; _cropDrag = 0;
    [self.host refreshAll];
}

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

    if (_editing) [self commitTextEditing];   // clicking elsewhere commits the edit

    // Double-click: edit a text clip in place, or create one and edit it.
    if (e.clickCount == 2) {
        jv_clip *hit = [self visualClipAtPoint:p];
        if (hit && hit->type == JV_CLIP_TEXT) {
            [self.host recordUndo];
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

    jv_clip *sel = [self.host selectedClip];

    // Crop button: toggle trim mode for the selected image (top-right of it).
    if (sel && sel->type == JV_CLIP_IMAGE && [self clipActive:sel] &&
        NSPointInRect(p, [self cropButtonForClip:sel])) {
        if (_cropping) [self commitCrop]; else [self enterCropForClip:sel];
        return;
    }
    // While cropping: drag the dashed frame (corner = resize, interior = move).
    if (_cropping && _cropClip) {
        NSRect f = [self screenRectForCropX:_cropX y:_cropY w:_cropW h:_cropH ofClip:_cropClip];
        NSPoint corner[4] = { {NSMinX(f), NSMaxY(f)}, {NSMaxX(f), NSMaxY(f)},
                              {NSMaxX(f), NSMinY(f)}, {NSMinX(f), NSMinY(f)} };   // TL,TR,BR,BL
        for (int i = 0; i < 4; i++)
            if (pt_dist(p, corner[i]) < 14) { _cropDrag = 2; _cropCorner = i; return; }
        if (NSPointInRect(p, f)) { _cropDrag = 1; _grab = NSMakePoint(p.x - f.origin.x, p.y - f.origin.y); return; }
        return;   // clicks elsewhere are ignored while cropping
    }

    // If a clip is selected, check its resize/rotate handles first.
    if (sel && [self clipIsVisual:sel] && [self clipActive:sel]) {
        if (pt_dist(p, [self rotateHandleForClip:sel]) < 12) { [self.host recordUndo]; _dragClip = sel; _mode = PV_ROTATE; return; }
        if (pt_dist(p, [self resizeHandleForClip:sel]) < 12) { [self.host recordUndo]; _dragClip = sel; _mode = PV_RESIZE; return; }
    }

    _dragClip = [self visualClipAtPoint:p];
    if (_dragClip) {
        [self.host recordUndo];
        [self.host selectTrack:NULL clip:_dragClip];
        NSPoint mid = [self centerForClip:_dragClip];
        _grab = NSMakePoint(p.x - mid.x, p.y - mid.y);
        _mode = PV_MOVE;
        [self.host refreshAll];
    } else {
        [self.host selectTrack:NULL clip:NULL];   // clicking empty canvas deselects
        _mode = PV_NONE;
        [self.host refreshAll];
    }
}

- (BOOL)clipIsVisual:(jv_clip *)c {
    return c->type == JV_CLIP_IMAGE || c->type == JV_CLIP_TEXT || c->type == JV_CLIP_VIDEO;
}

// Is the clip on screen at the current playhead?
- (BOOL)clipActive:(jv_clip *)c {
    double t = [self.host playhead];
    return c && t >= c->start_time && t < c->start_time + c->duration;
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];

    // Crop frame drag (move / resize) — operates in the full-image display rect.
    if (_cropping && _cropClip && _cropDrag) {
        NSRect dr = [self displayRectForClip:_cropClip];
        NSRect f = [self screenRectForCropX:_cropX y:_cropY w:_cropW h:_cropH ofClip:_cropClip];
        if (_cropDrag == 1) {                       // move, clamped inside the image
            f.origin = NSMakePoint(p.x - _grab.x, p.y - _grab.y);
            if (f.origin.x < dr.origin.x) f.origin.x = dr.origin.x;
            if (f.origin.y < dr.origin.y) f.origin.y = dr.origin.y;
            if (NSMaxX(f) > NSMaxX(dr)) f.origin.x = NSMaxX(dr) - f.size.width;
            if (NSMaxY(f) > NSMaxY(dr)) f.origin.y = NSMaxY(dr) - f.size.height;
        } else {                                    // resize: drag a corner, opposite stays put
            CGFloat px = fmin(fmax(p.x, NSMinX(dr)), NSMaxX(dr));
            CGFloat py = fmin(fmax(p.y, NSMinY(dr)), NSMaxY(dr));
            CGFloat ox, oy;                          // opposite (fixed) corner
            switch (_cropCorner) {
                case 0: ox = NSMaxX(f); oy = NSMinY(f); break;   // TL -> BR fixed
                case 1: ox = NSMinX(f); oy = NSMinY(f); break;   // TR -> BL
                case 2: ox = NSMinX(f); oy = NSMaxY(f); break;   // BR -> TL
                default: ox = NSMaxX(f); oy = NSMaxY(f); break;  // BL -> TR
            }
            f = NSMakeRect(fmin(px, ox), fmin(py, oy), fabs(px - ox), fabs(py - oy));
        }
        [self setWorkingCropFromScreenRect:f clip:_cropClip];
        [self.host refreshAll];
        return;
    }

    if (!_dragClip || _mode == PV_NONE) return;
    NSPoint mid = [self centerForClip:_dragClip];

    if (_mode == PV_MOVE) {
        [[NSCursor closedHandCursor] set];
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

- (void)mouseUp:(NSEvent *)e { _dragClip = NULL; _mode = PV_NONE; _cropDrag = 0; [[NSCursor arrowCursor] set]; }

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

    // Selection outline + resize/rotate handles — only when the clip is visible now.
    jv_clip *sel = [self.host selectedClip];
    if (sel && [self clipIsVisual:sel] && [self clipActive:sel]) {
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

    // Crop (trim) overlay: dashed frame + dimmed exterior, plus the toggle button
    // on the selected image. Drawn unrotated (crop is authored in image space).
    if (sel && sel->type == JV_CLIP_IMAGE && [self clipActive:sel]) {
        if (_cropping && _cropClip == sel) {
            NSRect dr = [self displayRectForClip:sel];
            NSRect f  = [self screenRectForCropX:_cropX y:_cropY w:_cropW h:_cropH ofClip:sel];
            // Dim everything outside the frame within the image footprint.
            [[NSColor colorWithWhite:0 alpha:0.45] setFill];
            NSRectFill(NSMakeRect(dr.origin.x, dr.origin.y, dr.size.width, NSMinY(f) - dr.origin.y));         // below
            NSRectFill(NSMakeRect(dr.origin.x, NSMaxY(f), dr.size.width, NSMaxY(dr) - NSMaxY(f)));            // above
            NSRectFill(NSMakeRect(dr.origin.x, NSMinY(f), NSMinX(f) - dr.origin.x, f.size.height));           // left
            NSRectFill(NSMakeRect(NSMaxX(f), NSMinY(f), NSMaxX(dr) - NSMaxX(f), f.size.height));              // right
            NSBezierPath *dash = [NSBezierPath bezierPathWithRect:f];
            CGFloat pat[2] = {6, 4}; [dash setLineDash:pat count:2 phase:0];
            dash.lineWidth = 1.5; [[NSColor whiteColor] setStroke]; [dash stroke];
            for (int i = 0; i < 4; i++) {   // corner knobs
                NSPoint cpt[4] = { {NSMinX(f),NSMaxY(f)}, {NSMaxX(f),NSMaxY(f)}, {NSMaxX(f),NSMinY(f)}, {NSMinX(f),NSMinY(f)} };
                [[NSColor whiteColor] setFill];
                [[NSBezierPath bezierPathWithRect:NSMakeRect(cpt[i].x - 4, cpt[i].y - 4, 8, 8)] fill];
            }
        }
        // Toggle button (top-right of the visible image): a small crop glyph.
        NSRect brect = [self cropButtonForClip:sel];
        [[NSColor colorWithWhite:0 alpha:0.6] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:brect xRadius:4 yRadius:4] fill];
        [(_cropping ? [NSColor systemYellowColor] : [NSColor whiteColor]) setStroke];
        NSBezierPath *g = [NSBezierPath bezierPath]; g.lineWidth = 1.5;
        NSRect gi = NSInsetRect(brect, 6, 6);
        [g moveToPoint:NSMakePoint(NSMinX(gi), NSMaxY(gi))];   // ⌐ + ¬ crop marks
        [g lineToPoint:NSMakePoint(NSMinX(gi), NSMinY(gi))];
        [g lineToPoint:NSMakePoint(NSMaxX(gi), NSMinY(gi))];
        [g moveToPoint:NSMakePoint(NSMaxX(gi), NSMinY(gi))];
        [g lineToPoint:NSMakePoint(NSMaxX(gi), NSMaxY(gi))];
        [g lineToPoint:NSMakePoint(NSMinX(gi), NSMaxY(gi))];
        [g stroke];
    }

    // Text-edit caret (+ select-all highlight) on the edited clip.
    if (_editing && _editClip && [self clipActive:_editClip]) {
        NSRect r = [self displayRectForClip:_editClip];
        if (_editSelAll) {
            [[NSColor colorWithSRGBRed:0.3 green:0.5 blue:1 alpha:0.35] setFill];
            NSRectFill(NSInsetRect(r, -2, -2));
        }
        // Locate the caret: line index + the current line's prefix width.
        NSString *upto = [_editText substringToIndex:(_editCaret <= _editText.length ? _editCaret : _editText.length)];
        NSArray<NSString *> *uptoLines = [upto componentsSeparatedByString:@"\n"];
        NSUInteger line = uptoLines.count - 1;
        NSUInteger nLines = [[_editText componentsSeparatedByString:@"\n"] count];
        NSDictionary *fa = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:_editClip->u.text.font_size] };
        CGFloat prefixW = [uptoLines.lastObject sizeWithAttributes:fa].width;
        CGFloat bmpW = _editClip->u.text.width > 0 ? _editClip->u.text.width : 1;
        CGFloat caretX = r.origin.x + ((4 + prefixW) / bmpW) * r.size.width;
        CGFloat top    = NSMaxY(r) - ((CGFloat)line / nLines) * r.size.height;
        CGFloat bottom = NSMaxY(r) - ((CGFloat)(line + 1) / nLines) * r.size.height;
        [[NSColor whiteColor] setFill];
        NSRectFill(NSMakeRect(caretX, bottom, 2, top - bottom));
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

// We edit text by capturing keystrokes directly (the preview is the first
// responder), instead of overlaying an NSTextField — far more reliable.
- (void)beginEditingTextClip:(jv_clip *)c {
    [self commitTextEditing];
    _editClip = c;
    _editing = YES;
    _editSelAll = YES;   // start with the whole string selected (type to replace)
    _editText = [NSMutableString stringWithUTF8String:(c->u.text.string ? c->u.text.string : "")];
    _editCaret = _editText.length;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self];
    [self.host refreshAll];
}

// Insert / delete operate at the caret (clearing a select-all first).
- (void)insertEditString:(NSString *)s {
    if (_editSelAll) { [_editText setString:s]; _editSelAll = NO; _editCaret = s.length; }
    else { if (_editCaret > _editText.length) _editCaret = _editText.length;
           [_editText insertString:s atIndex:_editCaret]; _editCaret += s.length; }
    [self applyEditedText];
}
- (void)deleteEditBackward {
    if (_editSelAll) { [_editText setString:@""]; _editSelAll = NO; _editCaret = 0; }
    else if (_editCaret > 0) { [_editText deleteCharactersInRange:NSMakeRange(_editCaret - 1, 1)]; _editCaret--; }
    [self applyEditedText];
}
// Delete from `from` up to the caret (used by Option/Cmd + Backspace).
- (void)deleteEditFrom:(NSUInteger)from {
    if (_editSelAll) { [self deleteEditBackward]; return; }
    if (from >= _editCaret) return;
    [_editText deleteCharactersInRange:NSMakeRange(from, _editCaret - from)];
    _editCaret = from;
    [self applyEditedText];
}

// Move the caret up/down a line, keeping the column where possible.
- (void)moveCaretLine:(int)dir {
    _editSelAll = NO;
    NSArray<NSString *> *lines = [_editText componentsSeparatedByString:@"\n"];
    NSUInteger pos = 0, line = 0, col = 0;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSUInteger len = lines[i].length;
        if (_editCaret <= pos + len) { line = i; col = _editCaret - pos; break; }
        pos += len + 1;
    }
    NSInteger target = (NSInteger)line + dir;
    if (target < 0 || target >= (NSInteger)lines.count) { [self.host refreshAll]; return; }
    NSUInteger tlen = [lines[(NSUInteger)target] length];
    NSUInteger ncol = col < tlen ? col : tlen;
    NSUInteger newCaret = 0;
    for (NSInteger i = 0; i < target; i++) newCaret += [lines[(NSUInteger)i] length] + 1;
    _editCaret = newCaret + ncol;
    [self.host refreshAll];
}

// Caret-navigation helpers (notes-app semantics). Lines are \n-separated.
- (NSUInteger)lineStartFor:(NSUInteger)pos {
    while (pos > 0 && [_editText characterAtIndex:pos - 1] != '\n') pos--;
    return pos;
}
- (NSUInteger)lineEndFor:(NSUInteger)pos {
    NSUInteger n = _editText.length;
    while (pos < n && [_editText characterAtIndex:pos] != '\n') pos++;
    return pos;
}
- (NSUInteger)wordLeftFrom:(NSUInteger)pos {
    NSCharacterSet *w = [NSCharacterSet alphanumericCharacterSet];
    while (pos > 0 && ![w characterIsMember:[_editText characterAtIndex:pos - 1]]) pos--;   // skip separators
    while (pos > 0 && [w characterIsMember:[_editText characterAtIndex:pos - 1]]) pos--;     // skip the word
    return pos;
}
- (NSUInteger)wordRightFrom:(NSUInteger)pos {
    NSUInteger n = _editText.length;
    NSCharacterSet *w = [NSCharacterSet alphanumericCharacterSet];
    while (pos < n && ![w characterIsMember:[_editText characterAtIndex:pos]]) pos++;
    while (pos < n && [w characterIsMember:[_editText characterAtIndex:pos]]) pos++;
    return pos;
}

- (void)applyEditedText {
    if (!_editClip) return;
    free(_editClip->u.text.string);
    _editClip->u.text.string = strdup(_editText.UTF8String);
    [self rerasterizeText:_editClip];   // live: canvas bitmap + timeline label
    [self.host refreshAll];
}

- (void)clearSelectionIfAny {
    if (_editSelAll) { [_editText setString:@""]; _editSelAll = NO; }
}

// Handle a key while editing; returns YES if consumed.
- (BOOL)handleEditingKey:(NSEvent *)e {
    if (!_editing) return NO;
    NSEventModifierFlags m = e.modifierFlags;
    NSString *ig = e.charactersIgnoringModifiers;
    unichar k = ig.length ? [ig characterAtIndex:0] : 0;
    unichar lk = (k >= 'A' && k <= 'Z') ? k + 32 : k;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    // Arrow keys move the caret (never insert; they live in the function-key range).
    // Modifiers follow notes-app semantics: Cmd = line/document ends, Option = word/paragraph.
    BOOL isArrow = (k == NSLeftArrowFunctionKey || k == NSRightArrowFunctionKey ||
                    k == NSUpArrowFunctionKey   || k == NSDownArrowFunctionKey);
    if (isArrow) {
        _editSelAll = NO;
        BOOL cmd = (m & NSEventModifierFlagCommand) != 0;
        BOOL opt = (m & NSEventModifierFlagOption)  != 0;
        if (k == NSLeftArrowFunctionKey) {
            if (cmd)      _editCaret = [self lineStartFor:_editCaret];
            else if (opt) _editCaret = [self wordLeftFrom:_editCaret];
            else if (_editCaret > 0) _editCaret--;
        } else if (k == NSRightArrowFunctionKey) {
            if (cmd)      _editCaret = [self lineEndFor:_editCaret];
            else if (opt) _editCaret = [self wordRightFrom:_editCaret];
            else if (_editCaret < _editText.length) _editCaret++;
        } else if (k == NSUpArrowFunctionKey) {
            if (cmd)      _editCaret = 0;                                  // document start
            else if (opt) { NSUInteger s = [self lineStartFor:_editCaret]; // paragraph start (then previous)
                            _editCaret = (s == _editCaret && s > 0) ? [self lineStartFor:s - 1] : s; }
            else { [self moveCaretLine:-1]; return YES; }
        } else { // down
            if (cmd)      _editCaret = _editText.length;                   // document end
            else if (opt) { NSUInteger en = [self lineEndFor:_editCaret];  // paragraph end (then next)
                            _editCaret = (en == _editCaret && en < _editText.length) ? [self lineEndFor:en + 1] : en; }
            else { [self moveCaretLine:1]; return YES; }
        }
        [self.host refreshAll];
        return YES;
    }
    // Modified backspace (notes-app): Option = delete previous word, Cmd = delete
    // to the start of the line. Handled before the Cmd/Ctrl swallow below.
    if ((k == NSDeleteCharacter || k == 0x08) && (m & (NSEventModifierFlagCommand | NSEventModifierFlagOption))) {
        if (_editSelAll) { [self deleteEditBackward]; return YES; }
        NSUInteger from = (m & NSEventModifierFlagCommand) ? [self lineStartFor:_editCaret]
                                                           : [self wordLeftFrom:_editCaret];
        [self deleteEditFrom:from];
        return YES;
    }
    if (m & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) {
        if (lk == 'a') { _editSelAll = YES; [self.host refreshAll]; return YES; }       // select all
        if (lk == 'c') { [pb clearContents]; [pb setString:_editText forType:NSPasteboardTypeString]; return YES; }
        if (lk == 'x') { [pb clearContents]; [pb setString:_editText forType:NSPasteboardTypeString];
                         [_editText setString:@""]; _editSelAll = NO; _editCaret = 0; [self applyEditedText]; return YES; }
        if (lk == 'v') { NSString *s = [pb stringForType:NSPasteboardTypeString]; if (s.length) [self insertEditString:s]; return YES; }
        return YES;   // swallow other modified keys while editing
    }
    if (k >= 0xF700 && k <= 0xF8FF) return YES;   // ignore other function keys (F-keys, etc.)
    if (k == 0x1B) { [self commitTextEditing]; return YES; }                            // esc commits
    if (k == 0x0D || k == 0x03) { [self insertEditString:@"\n"]; return YES; }          // return = newline
    if (k == NSDeleteCharacter || k == 0x08) { [self deleteEditBackward]; return YES; }  // backspace
    NSString *ins = e.characters;
    if (ins.length && [ins characterAtIndex:0] >= 0x20) { [self insertEditString:ins]; return YES; }
    return YES;   // swallow other keys while editing
}

- (void)commitTextEditing {
    if (!_editing) return;
    if (_editClip) {
        if (_editText.length == 0) [_editText setString:@"Text"];
        [self applyEditedText];
    }
    _editing = NO;
    _editClip = NULL;
    _editText = nil;
    [self.host refreshAll];
}

// ---- Paste (Cmd+V) ----
- (void)keyDown:(NSEvent *)e {
    if (_editing) { [self handleEditingKey:e]; return; }   // typing into a text clip
    NSString *chars = e.charactersIgnoringModifiers;
    unichar k = chars.length ? [chars characterAtIndex:0] : 0;
    unichar lk = (k >= 'A' && k <= 'Z') ? k + 32 : k;
    NSEventModifierFlags m = e.modifierFlags;
    if (_cropping && k == 0x1B) { [self commitCrop]; return; }   // Esc approves the crop
    if (m & NSEventModifierFlagCommand) {
        if (lk == 'a') { [self.host selectAllClips]; return; }        // select all clips
        if (k == NSLeftArrowFunctionKey)  { [self.host jumpStartMarksEnd:-1]; return; }
        if (k == NSRightArrowFunctionKey) { [self.host jumpStartMarksEnd:1];  return; }
        return;   // Cmd+H/Cmd+Opt+H are the system Hide items (handled by the menu)
    }
    if (m & NSEventModifierFlagOption) {             // Option + arrows = move the selected object(s)
        if (k == NSLeftArrowFunctionKey)  { [self.host nudgeSelectedBy:-0.5]; return; }
        if (k == NSRightArrowFunctionKey) { [self.host nudgeSelectedBy:0.5];  return; }
    }
    if (m & NSEventModifierFlagControl) {
        if (lk == 'z') { if (m & NSEventModifierFlagShift) [self.host performRedo]; else [self.host performUndo]; return; }
        if (lk == 'c') { [self.host copySelectedClip]; return; }
        if (lk == 'v') { [self paste:nil]; return; }
        if (lk == 'h' || k == NSLeftArrowFunctionKey)  { [self.host jumpToMarker:-1]; return; }
        if (lk == 'l' || k == NSRightArrowFunctionKey) { [self.host jumpToMarker:1];  return; }
        if (k == '=' || k == '+') { [self.host zoomBy:1.25]; return; }
        if (k == '-' || k == '_') { [self.host zoomBy:0.8];  return; }
        return;
    }
    if (k == ' ') { [self.host transportToggle]; return; }
    if (k == NSLeftArrowFunctionKey)  { [self.host nudgePlayheadBy:-0.5]; return; }
    if (k == NSRightArrowFunctionKey) { [self.host nudgePlayheadBy:0.5];  return; }
    if (lk == 'h') { [self.host selectAdjacentClip:-1]; return; }
    if (lk == 'l') { [self.host selectAdjacentClip:1];  return; }
    if (lk == 'j') { [self.host focusTrack:1];  return; }
    if (lk == 'k') { [self.host focusTrack:-1]; return; }
    if (lk == 't') { [self.host addTextAtPlayhead]; return; }
    if (lk == 'm') { [self.host addMarkerAtPlayhead]; return; }
    if (lk == 'b') { [self.host toggleBlade]; return; }
    if (k == NSDeleteCharacter || k == NSBackspaceCharacter || k == NSDeleteFunctionKey) {
        [self.host deleteSelectedClip]; return;   // backspace deletes the selected object
    }
    [super keyDown:e];
}

- (void)paste:(id)sender {
    if (_editing) {                                   // paste text into the edited clip at the caret
        NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (s.length) [self insertEditString:s];
        return;
    }
    if ([self.host pasteClipAtPlayhead]) return;
    [self ingestPasteboard:[NSPasteboard generalPasteboard] atTime:[self.host playhead]];
}
- (void)copy:(id)sender {
    if (_editing) {                                   // copy the edited text
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents]; [pb setString:(_editText ?: @"") forType:NSPasteboardTypeString];
        return;
    }
    [self.host copySelectedClip];
}
- (void)undo:(id)sender { [self.host performUndo]; }
- (void)redo:(id)sender { [self.host performRedo]; }

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

// ---- Test-only introspection (see PreviewView+Test.h) ----
#import "PreviewView+Test.h"

@implementation PreviewView (Test)
- (BOOL)isEditing { return _editing; }
- (NSString *)editText { return _editText; }
- (NSUInteger)editCaret { return _editCaret; }
- (BOOL)editSelAll { return _editSelAll; }
- (void)layoutForTest { _videoRect = [self fitRect]; }
- (BOOL)isCropping { return _cropping; }
@end
