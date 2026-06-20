// johnvideo — timeline pane implementation (Objective-C++)
#import "TimelineView.h"
#import "Media.h"

typedef enum { DRAG_NONE, DRAG_SCRUB, DRAG_MOVE, DRAG_TRIM, DRAG_TRIM_LEFT, DRAG_TRACK, DRAG_MARK } drag_mode;

@implementation TimelineView {
    drag_mode  _drag;
    jv_track  *_dragTrack;
    jv_clip   *_dragClip;
    double     _grabOffset;   // seconds between clip start and grab point
    size_t     _trackDragIdx; // track being reordered
    size_t     _markIdx;      // marker being dragged
    BOOL       _didDrag;      // a move drag actually happened (vs a bare click)
    double     _clickSeek;    // playhead time to apply on a bare clip click
}
// Scroll is stored on the timeline model (so it persists with the project).
- (double)sx { return [self.host timeline]->scroll_x; }
- (double)sy { return [self.host timeline]->scroll_y; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF,
                                         NSPasteboardTypeFileURL, NSPasteboardTypeString ]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
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
    if (p.y < kRulerHeight) {
        jv_timeline *tl = [self.host timeline];
        for (size_t i = 0; i < tl->marker_count; i++)
            if (fabs([self xForTime:tl->markers[i]] - p.x) < 6) { cur = [NSCursor resizeLeftRightCursor]; break; }
        [cur set];
        return;
    }
    if (p.y >= kRulerHeight && p.x >= kHeaderWidth) {
        jv_track *t = NULL; size_t idx = 0;
        jv_clip *c = [self clipAtPoint:p track:&t index:&idx];
        if (c && [self.host bladeActive]) {
            cur = [NSCursor crosshairCursor];   // blade: slice
        } else if (c) {
            NSRect r = [self rectForClip:c onTrack:idx];
            if (p.x > NSMaxX(r) - 8 || p.x < NSMinX(r) + 8) cur = [NSCursor resizeLeftRightCursor];
        }
    }
    [cur set];
}

// ---- Geometry ----
- (double)pps { return [self.host pixelsPerSecond]; }
- (CGFloat)xForTime:(double)t { return kHeaderWidth + (t - self.sx) * self.pps; }
- (double)timeForX:(CGFloat)x {
    double t = self.sx + (x - kHeaderWidth) / self.pps;
    return t < 0 ? 0 : t;
}
- (CGFloat)yForTrack:(size_t)i { return kRulerHeight + i * (kTrackHeight + kTrackGap) + kTrackGap - self.sy; }

- (NSRect)rectForClip:(jv_clip *)c onTrack:(size_t)i {
    CGFloat x = [self xForTime:c->start_time];
    CGFloat w = c->duration * self.pps;
    return NSMakeRect(x, [self yForTrack:i], w < 2 ? 2 : w, kTrackHeight);
}

// Snap a scrub time to the nearest clip start/end (or 0) within ~8px.
- (double)snapTime:(double)t {
    jv_timeline *tl = [self.host timeline];
    double best = t, bestDist = 8.0 / self.pps;   // threshold in seconds
    double zero = 0.0;
    if (fabs(zero - t) < bestDist) { bestDist = fabs(zero - t); best = zero; }
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *trk = &tl->tracks[i];
        for (size_t j = 0; j < trk->clip_count; j++) {
            double edges[2] = { trk->clips[j].start_time,
                                trk->clips[j].start_time + trk->clips[j].duration };
            for (int k = 0; k < 2; k++) {
                double d = fabs(edges[k] - t);
                if (d < bestDist) { bestDist = d; best = edges[k]; }
            }
        }
    }
    return best;
}

+ (NSString *)formatTime:(double)t {
    if (t < 0) t = 0;
    int minutes = (int)(t / 60.0);
    double secs = t - minutes * 60.0;
    return [NSString stringWithFormat:@"%d:%06.3f", minutes, secs];
}

// Locate the track index for a y coordinate; SIZE_MAX if none.
- (size_t)trackIndexForY:(CGFloat)y {
    jv_timeline *tl = [self.host timeline];
    for (size_t i = 0; i < tl->track_count; i++) {
        CGFloat ty = [self yForTrack:i];
        if (y >= ty && y < ty + kTrackHeight) return i;
    }
    return SIZE_MAX;
}

- (jv_track *)trackOfClip:(jv_clip *)c {
    jv_timeline *tl = [self.host timeline];
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *t = &tl->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) if (&t->clips[j] == c) return t;
    }
    return NULL;
}

- (jv_clip *)clipAtPoint:(NSPoint)p track:(jv_track **)outTrack index:(size_t *)outIdx {
    jv_timeline *tl = [self.host timeline];
    size_t ti = [self trackIndexForY:p.y];
    if (ti == SIZE_MAX) return NULL;
    jv_track *t = &tl->tracks[ti];
    for (size_t j = 0; j < t->clip_count; j++) {
        if (NSPointInRect(p, [self rectForClip:&t->clips[j] onTrack:ti])) {
            if (outTrack) *outTrack = t;
            if (outIdx) *outIdx = ti;
            return &t->clips[j];
        }
    }
    return NULL;
}

// Draw a peak-based waveform of an audio clip's PCM within rect.
- (void)drawWaveformForClip:(jv_clip *)c inRect:(NSRect)rect {
    jv_audio *a = &c->u.audio;
    if (!a->pcm || a->frames == 0 || rect.size.width < 2) return;
    int cols = (int)rect.size.width;
    CGFloat midY = NSMidY(rect), halfH = rect.size.height / 2 - 2;
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.55] setStroke];
    NSBezierPath *wf = [NSBezierPath bezierPath];
    wf.lineWidth = 1.0;
    size_t per = a->frames / (size_t)cols; if (per == 0) per = 1;
    for (int x = 0; x < cols; x++) {
        size_t start = (size_t)x * per;
        float peak = 0;
        for (size_t k = 0; k < per && start + k < a->frames; k += 1) {
            float l = a->pcm[(start + k) * 2];
            float v = l < 0 ? -l : l;
            if (v > peak) peak = v;
        }
        if (peak > 1) peak = 1;
        CGFloat px = rect.origin.x + x;
        [wf moveToPoint:NSMakePoint(px, midY - peak * halfH)];
        [wf lineToPoint:NSMakePoint(px, midY + peak * halfH)];
    }
    [wf stroke];
}

// ---- Drawing ----
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
    NSRectFill(self.bounds);
    jv_timeline *tl = [self.host timeline];
    if (!tl) return;

    // Ruler with an adaptive tick step (so labels never crowd when zoomed out).
    [[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, kRulerHeight));
    NSDictionary *tick = @{ NSFontAttributeName: [NSFont systemFontOfSize:9],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.85 alpha:1.0] };
    double span = (self.bounds.size.width - kHeaderWidth) / self.pps;
    const double steps[] = { 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600 };
    double step = steps[(sizeof steps / sizeof steps[0]) - 1];
    for (size_t i = 0; i < sizeof steps / sizeof steps[0]; i++)
        if (steps[i] * self.pps >= 56) { step = steps[i]; break; }   // ~56px min spacing
    double t0 = floor(self.sx / step) * step;
    for (double tt = t0; tt <= self.sx + span; tt += step) {
        CGFloat x = [self xForTime:tt];
        if (x < kHeaderWidth) continue;
        [[NSColor colorWithCalibratedWhite:0.4 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(x, 0, 1, kRulerHeight));
        int sec = (int)(tt + 0.5);
        NSString *lbl = sec < 60 ? [NSString stringWithFormat:@"%ds", sec]
                                 : [NSString stringWithFormat:@"%d:%02d", sec / 60, sec % 60];
        [lbl drawAtPoint:NSMakePoint(x + 2, 3) withAttributes:tick];
    }

    // Current playhead time (m:ss.mmm), right-aligned in the ruler — bright.
    NSString *timeStr = [TimelineView formatTime:[self.host playhead]];
    NSDictionary *timeAttrs = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: [NSColor whiteColor] };
    NSSize tsz = [timeStr sizeWithAttributes:timeAttrs];
    [timeStr drawAtPoint:NSMakePoint(self.bounds.size.width - tsz.width - 8, 2) withAttributes:timeAttrs];

    NSDictionary *labelAttrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
                                  NSForegroundColorAttributeName: [NSColor whiteColor] };

    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *t = &tl->tracks[i];
        CGFloat ty = [self yForTrack:i];
        BOOL audio = (t->kind == JV_TRACK_AUDIO);

        // Lane + header.
        NSColor *lane = audio ? [NSColor colorWithCalibratedRed:0.14 green:0.18 blue:0.14 alpha:1]
                              : [NSColor colorWithCalibratedRed:0.14 green:0.16 blue:0.20 alpha:1];
        [lane setFill];
        NSRectFill(NSMakeRect(kHeaderWidth, ty, self.bounds.size.width - kHeaderWidth, kTrackHeight));
        [[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(0, ty, kHeaderWidth, kTrackHeight));
        NSString *name = t->name ? [NSString stringWithUTF8String:t->name] : @"track";
        [name drawAtPoint:NSMakePoint(8, ty + (kTrackHeight - 14) / 2) withAttributes:labelAttrs];

        // Clips.
        for (size_t j = 0; j < t->clip_count; j++) {
            jv_clip *c = &t->clips[j];
            NSRect r = [self rectForClip:c onTrack:i];
            NSColor *fill;
            switch (c->type) {
                case JV_CLIP_IMAGE: fill = [NSColor systemTealColor]; break;
                case JV_CLIP_TEXT:  fill = [NSColor systemPurpleColor]; break;
                case JV_CLIP_VIDEO: fill = [NSColor systemBlueColor]; break;
                default:            fill = [NSColor systemGreenColor]; break;
            }
            [[fill colorWithAlphaComponent:0.85] setFill];
            NSRect inner = NSInsetRect(r, 1, 3);
            NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:inner xRadius:4 yRadius:4];
            [bp fill];
            if (c->type == JV_CLIP_AUDIO && c->u.audio.pcm)
                [self drawWaveformForClip:c inRect:inner];
            if ([self.host isClipSelected:c]) {
                [[NSColor whiteColor] setStroke];
                [bp setLineWidth:2];
                [bp stroke];
            }
            NSString *cl = nil;
            if (c->type == JV_CLIP_TEXT && c->u.text.string)
                cl = [NSString stringWithUTF8String:c->u.text.string];
            else if (c->u.image.path)  // path lives at the same union offset for image/video/audio
                cl = [[NSString stringWithUTF8String:c->u.image.path] lastPathComponent];
            if (cl) [cl drawAtPoint:NSMakePoint(r.origin.x + 6, ty + 6) withAttributes:tick];
        }
    }

    // Markers (yellow lines + a flag in the ruler).
    for (size_t i = 0; i < tl->marker_count; i++) {
        CGFloat mx = [self xForTime:tl->markers[i]];
        if (mx < kHeaderWidth) continue;
        [[NSColor systemYellowColor] setFill];
        NSRectFill(NSMakeRect(mx, 0, 1, self.bounds.size.height));
        NSBezierPath *flag = [NSBezierPath bezierPath];
        [flag moveToPoint:NSMakePoint(mx, 0)];
        [flag lineToPoint:NSMakePoint(mx + 8, 5)];
        [flag lineToPoint:NSMakePoint(mx, 10)];
        [flag closePath];
        [flag fill];
    }

    // Playhead.
    CGFloat px = [self xForTime:[self.host playhead]];
    [[NSColor systemRedColor] setFill];
    NSRectFill(NSMakeRect(px, 0, 1.5, self.bounds.size.height));
}

// ---- Mouse: scrub / select / move / trim ----
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];

    // Double-click a text clip on the timeline -> edit it in place on the preview.
    if (e.clickCount == 2) {
        jv_track *t = NULL; size_t idx = 0;
        jv_clip *c = [self clipAtPoint:p track:&t index:&idx];
        if (c && c->type == JV_CLIP_TEXT) { [self.host selectTrack:t clip:c]; [self.host beginEditingClip:c]; return; }
    }

    if (p.y < kRulerHeight) {
        jv_timeline *tl = [self.host timeline];
        for (size_t i = 0; i < tl->marker_count; i++) {
            if (fabs([self xForTime:tl->markers[i]] - p.x) < 6) {
                [self.host recordUndo]; _drag = DRAG_MARK; _markIdx = i; return;   // drag a marker
            }
        }
        _drag = DRAG_SCRUB; [self.host seekTo:[self snapTime:[self timeForX:p.x]]]; return;
    }

    // Header column: start a track reorder drag.
    if (p.x < kHeaderWidth) {
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX) { [self.host recordUndo]; _drag = DRAG_TRACK; _trackDragIdx = ti; return; }
    }

    jv_track *t = NULL; size_t idx = 0;
    jv_clip *c = [self clipAtPoint:p track:&t index:&idx];
    if (c && [self.host bladeActive]) { [self.host bladeCutClip:c atTime:[self timeForX:p.x]]; _drag = DRAG_NONE; return; }   // blade: slice where clicked
    if (c) {
        if (e.modifierFlags & NSEventModifierFlagCommand) { [self.host toggleSelectClip:c]; _drag = DRAG_NONE; return; }
        if (e.modifierFlags & NSEventModifierFlagShift)   { [self.host extendSelectionTo:c]; _drag = DRAG_NONE; return; }
        [self.host recordUndo];
        if (![self.host isClipSelected:c]) [self.host selectTrack:t clip:c];   // keep multi-selection if part of it
        NSRect r = [self rectForClip:c onTrack:idx];
        if (p.x > NSMaxX(r) - 8) {            // right edge => trim end
            _drag = DRAG_TRIM;
        } else if (p.x < NSMinX(r) + 8) {     // left edge => trim start
            _drag = DRAG_TRIM_LEFT;
        } else {
            _drag = DRAG_MOVE;
            _grabOffset = [self timeForX:p.x] - c->start_time;
            _didDrag = NO;
            _clickSeek = [self timeForX:p.x];   // applied on mouseUp only if it stays a click (a drag cancels it)
        }
        _dragTrack = t; _dragClip = c;
        [self setNeedsDisplay:YES];
    } else {
        [self.host selectTrack:NULL clip:NULL];   // clicking empty space deselects
        _drag = DRAG_SCRUB;
        [self.host seekTo:[self snapTime:[self timeForX:p.x]]];
    }
}

// Snap a time to the playhead, 0, or any clip edge (excluding `ex`), within 8px.
- (double)snapBoundary:(double)tval excluding:(jv_clip *)ex {
    jv_timeline *tl = [self.host timeline];
    double best = tval, bestDist = 8.0 / self.pps;
    double cands0[2] = { 0.0, [self.host playhead] };
    for (int k = 0; k < 2; k++) {
        double d = fabs(cands0[k] - tval);
        if (d < bestDist) { bestDist = d; best = cands0[k]; }
    }
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *trk = &tl->tracks[i];
        for (size_t j = 0; j < trk->clip_count; j++) {
            jv_clip *c = &trk->clips[j];
            if (c == ex) continue;
            double edges[2] = { c->start_time, c->start_time + c->duration };
            for (int k = 0; k < 2; k++) {
                double d = fabs(edges[k] - tval);
                if (d < bestDist) { bestDist = d; best = edges[k]; }
            }
        }
    }
    return best;
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    jv_timeline *tl = [self.host timeline];
    double t = [self timeForX:p.x];
    // Drag cursor feedback.
    if (_drag == DRAG_MOVE || _drag == DRAG_TRACK || _drag == DRAG_MARK) [[NSCursor closedHandCursor] set];
    else if (_drag == DRAG_TRIM || _drag == DRAG_TRIM_LEFT) [[NSCursor resizeLeftRightCursor] set];
    if (_drag == DRAG_TRACK) {
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX && ti != _trackDragIdx) {
            jv_timeline_move_track(tl, _trackDragIdx, ti);
            _trackDragIdx = ti;
            [self.host refreshAll];
        }
        return;
    }
    if (_drag == DRAG_MARK) {
        if (_markIdx < tl->marker_count) {
            double nt = [self snapTime:[self timeForX:p.x]];
            tl->markers[_markIdx] = nt < 0 ? 0 : nt;
            [self.host refreshAll];
        }
        return;
    }
    if (_drag == DRAG_SCRUB) {
        [self.host seekTo:[self snapTime:t]];
    } else if (_drag == DRAG_MOVE && _dragClip) {
        _didDrag = YES;   // a real move -> don't seek the redline on mouseUp
        // Move all selected clips together to the track under the pointer.
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX) {
            NSInteger curTi = _dragTrack - tl->tracks;
            if ((NSInteger)ti != curTi && tl->tracks[ti].kind == _dragTrack->kind) {
                [self.host shiftSelectionTracksBy:(int)((NSInteger)ti - curTi)];
                _dragClip = [self.host selectedClip];
                if (_dragClip) _dragTrack = [self trackOfClip:_dragClip];
                if (!_dragClip || !_dragTrack) return;
            }
        }
        double ns = t - _grabOffset, dur = _dragClip->duration;
        // Sticky: snap whichever edge (start/end) is closer to a boundary.
        double sStart = [self snapBoundary:ns excluding:_dragClip];
        double sEnd   = [self snapBoundary:ns + dur excluding:_dragClip];
        if (fabs(sStart - ns) <= fabs(sEnd - (ns + dur))) ns = sStart; else ns = sEnd - dur;
        if (ns < 0) ns = 0;
        double oldStart = _dragClip->start_time;
        _dragClip->start_time = ns;
        [self.host shiftSelectionExcept:_dragClip by:ns - oldStart];   // move-together
        [self.host refreshAll];
    } else if (_drag == DRAG_TRIM && _dragClip) {
        double end = [self snapBoundary:t excluding:_dragClip];
        double nd = end - _dragClip->start_time;
        _dragClip->duration = nd < 0.1 ? 0.1 : nd;
        [self.host refreshAll];
    } else if (_drag == DRAG_TRIM_LEFT && _dragClip) {
        // Drag the left edge; keep the right edge fixed and trim into the source.
        double rightEdge = _dragClip->start_time + _dragClip->duration;
        double newStart = [self snapBoundary:t excluding:_dragClip];
        if (newStart < 0) newStart = 0;
        if (newStart > rightEdge - 0.1) newStart = rightEdge - 0.1;
        _dragClip->in_offset += newStart - _dragClip->start_time;
        if (_dragClip->in_offset < 0) _dragClip->in_offset = 0;
        _dragClip->start_time = newStart;
        _dragClip->duration = rightEdge - newStart;
        [self.host refreshAll];
    }
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

- (void)mouseUp:(NSEvent *)e {
    if (_drag == DRAG_TRACK) {
        jv_timeline_order_tracks([self.host timeline]);   // keep video above audio
        [self.host refreshAll];
    } else if (_drag == DRAG_MARK) {
        jv_timeline *tl = [self.host timeline];
        qsort(tl->markers, tl->marker_count, sizeof(double), cmp_double);   // keep sorted
        [self.host refreshAll];
    } else if (_drag == DRAG_MOVE && !_didDrag) {
        [self.host seekTo:_clickSeek];   // a bare click (no drag) moves the redline to the click point
    }
    _drag = DRAG_NONE; _dragClip = NULL; _dragTrack = NULL;
    [[NSCursor arrowCursor] set];
}

// ---- Zoom (see more/less time) ----
- (void)magnifyWithEvent:(NSEvent *)e {
    [self.host setPixelsPerSecond:[self.host pixelsPerSecond] * (1.0 + e.magnification)];
    [self setNeedsDisplay:YES];
}
- (void)scrollWheel:(NSEvent *)e {
    if (e.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
        [self.host setPixelsPerSecond:[self.host pixelsPerSecond] * (1.0 + e.scrollingDeltaY * 0.01)];
        [self setNeedsDisplay:YES];
        return;
    }
    // Horizontal scroll pans time; vertical scroll moves down the track list.
    jv_timeline *tl = [self.host timeline];
    double nx = tl->scroll_x - e.scrollingDeltaX / self.pps;
    tl->scroll_x = nx < 0 ? 0 : nx;
    double ny = tl->scroll_y - e.scrollingDeltaY;
    CGFloat maxY = [self contentHeight] - self.bounds.size.height;
    if (ny > maxY) ny = maxY > 0 ? maxY : 0;
    if (ny < 0) ny = 0;
    tl->scroll_y = ny;
    [self setNeedsDisplay:YES];
}

// Keep the playhead within the visible time window; pages when it runs off an
// edge so playback can scroll past the original viewport.
- (void)followPlayhead {
    jv_timeline *tl = [self.host timeline];
    if (!tl) return;
    double span = (self.bounds.size.width - kHeaderWidth) / self.pps;
    if (span <= 0) return;
    double ph = [self.host playhead];
    if (ph >= tl->scroll_x + span) {          // off the right edge -> page so it's at the left
        tl->scroll_x = ph;
    } else if (ph < tl->scroll_x) {           // off the left edge -> bring it back into view
        tl->scroll_x = ph;
    }
    if (tl->scroll_x < 0) tl->scroll_x = 0;
}

- (CGFloat)contentHeight {
    jv_timeline *tl = [self.host timeline];
    return kRulerHeight + tl->track_count * (kTrackHeight + kTrackGap) + kTrackGap;
}

// ---- Right-click menu ----
- (void)rightMouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSMenu *menu = [[NSMenu alloc] init];

    // Ruler: marker add/delete.
    if (p.y < kRulerHeight) {
        NSNumber *t = @([self timeForX:p.x]);
        NSMenuItem *add = [menu addItemWithTitle:@"Add Marker Here" action:@selector(addMarkerHere:) keyEquivalent:@""];
        add.target = self; add.representedObject = t;
        NSMenuItem *del = [menu addItemWithTitle:@"Delete Marker" action:@selector(deleteMarkerHere:) keyEquivalent:@""];
        del.target = self; del.representedObject = t;
        [NSMenu popUpContextMenu:menu withEvent:e forView:self];
        return;
    }

    // Track header: track-management menu.
    if (p.x < kHeaderWidth) {
        size_t ti = [self trackIndexForY:p.y];
        NSMenuItem *av = [menu addItemWithTitle:@"Add Video Track" action:@selector(addVideoTrack) keyEquivalent:@""];
        NSMenuItem *aa = [menu addItemWithTitle:@"Add Audio Track" action:@selector(addAudioTrack) keyEquivalent:@""];
        av.target = self; aa.target = self;
        if (ti != SIZE_MAX) {
            [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *ren = [menu addItemWithTitle:@"Rename Track…" action:@selector(renameTrackFromMenu:) keyEquivalent:@""];
            ren.target = self; ren.representedObject = @(ti);
            NSMenuItem *del = [menu addItemWithTitle:@"Delete This Track" action:@selector(deleteTrackFromMenu:) keyEquivalent:@""];
            del.target = self;
            del.representedObject = @(ti);
        }
        [NSMenu popUpContextMenu:menu withEvent:e forView:self];
        return;
    }

    jv_track *t = NULL; size_t idx = 0;
    jv_clip *c = [self clipAtPoint:p track:&t index:&idx];
    if (c) {
        [self.host selectTrack:t clip:c];
        [self setNeedsDisplay:YES];
        NSMenuItem *del = [menu addItemWithTitle:@"Delete Clip" action:@selector(deleteSelected) keyEquivalent:@""];
        del.target = self;
    } else {
        NSMenuItem *it = [menu addItemWithTitle:@"Add Text Here" action:@selector(addTextFromMenu:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = [NSValue valueWithPoint:p];
    }
    [NSMenu popUpContextMenu:menu withEvent:e forView:self];
}

- (void)addVideoTrack { [self.host addTrackOfKind:JV_TRACK_VISUAL]; }
- (void)addAudioTrack { [self.host addTrackOfKind:JV_TRACK_AUDIO]; }

- (void)renameTrackFromMenu:(NSMenuItem *)item {
    size_t ti = [[item representedObject] unsignedLongValue];
    jv_timeline *tl = [self.host timeline];
    if (ti >= tl->track_count) return;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Rename Track";
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    tf.stringValue = tl->tracks[ti].name ? @(tl->tracks[ti].name) : @"";
    a.accessoryView = tf;
    [a addButtonWithTitle:@"Rename"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] == NSAlertFirstButtonReturn) [self.host renameTrackAtIndex:ti to:tf.stringValue];
}
- (void)deleteTrackFromMenu:(NSMenuItem *)item {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Delete this track?";
    a.informativeText = @"All clips on this track will be removed. Any media they reference (images, video, recordings) disappears from the project.";
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"Delete"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] == NSAlertFirstButtonReturn)
        [self.host removeTrackAtIndex:[[item representedObject] unsignedLongValue]];
}

- (void)addTextFromMenu:(NSMenuItem *)item {
    NSPoint p = [[item representedObject] pointValue];
    [self.host addTextAtCanvasX:0.5f y:0.5f time:[self timeForX:p.x]];
}

- (void)addMarkerHere:(NSMenuItem *)item {
    [self.host seekTo:[[item representedObject] doubleValue]];
    [self.host addMarkerAtPlayhead];
}
- (void)deleteMarkerHere:(NSMenuItem *)item {
    [self.host seekTo:[[item representedObject] doubleValue]];
    [self.host deleteMarkerNearPlayhead];
}

- (void)keyDown:(NSEvent *)e {
    NSString *chars = e.charactersIgnoringModifiers;
    unichar k = chars.length ? [chars characterAtIndex:0] : 0;
    unichar lk = (k >= 'A' && k <= 'Z') ? k + 32 : k;
    NSEventModifierFlags m = e.modifierFlags;
    if (m & NSEventModifierFlagCommand) {            // Cmd-based shortcuts
        if (lk == 'a') { [self.host selectAllClips]; return; }        // select all clips
        if (lk == 'h') { [self.host nudgeSelectedBy:-0.5]; return; }   // move object
        if (lk == 'l') { [self.host nudgeSelectedBy:0.5];  return; }
        if (k == NSLeftArrowFunctionKey)  { [self.host jumpStartMarksEnd:-1]; return; }
        if (k == NSRightArrowFunctionKey) { [self.host jumpStartMarksEnd:1];  return; }
        return;
    }
    if (m & NSEventModifierFlagControl) {            // Ctrl-based shortcuts
        if (lk == 'z') { if (m & NSEventModifierFlagShift) [self.host performRedo]; else [self.host performUndo]; return; }
        if (lk == 'c') { [self.host copySelectedClip]; return; }
        if (lk == 'v') { [self paste:nil]; return; }
        if (lk == 'h' || k == NSLeftArrowFunctionKey)  { [self.host jumpToMarker:-1]; return; }
        if (lk == 'l' || k == NSRightArrowFunctionKey) { [self.host jumpToMarker:1];  return; }
        if (k == '=' || k == '+') { [self.host zoomBy:1.25]; [self setNeedsDisplay:YES]; return; }
        if (k == '-' || k == '_') { [self.host zoomBy:0.8];  [self setNeedsDisplay:YES]; return; }
        return;
    }
    if (k == ' ') { [self.host transportToggle]; return; }
    if (k == NSLeftArrowFunctionKey)  { [self.host nudgePlayheadBy:-0.5]; return; }   // arrows move time
    if (k == NSRightArrowFunctionKey) { [self.host nudgePlayheadBy:0.5];  return; }
    if (lk == 'h') { [self.host selectAdjacentClip:-1]; return; }   // h/l move between objects
    if (lk == 'l') { [self.host selectAdjacentClip:1];  return; }
    if (lk == 'j') { [self.host focusTrack:1];  return; }            // j/k jump tracks (j down, k up)
    if (lk == 'k') { [self.host focusTrack:-1]; return; }
    if (lk == 't') { [self.host addTextAtPlayhead]; return; }
    if (lk == 'm') { [self.host addMarkerAtPlayhead]; return; }
    if (lk == 'b') { [self.host toggleBlade]; return; }
    if (k == NSDeleteCharacter || k == NSBackspaceCharacter || k == NSDeleteFunctionKey) {
        if ([self.host deleteMarkerNearPlayhead]) return;   // a marker at the playhead, else the clip
        [self.host deleteSelectedClip];
        return;
    }
    [super keyDown:e];
}

- (void)deleteSelected { [self.host deleteSelectedClip]; }

// ---- Paste (Cmd+V via the Edit menu) ----
- (void)paste:(id)sender {
    if ([self.host pasteClipAtPlayhead]) return;   // internal clip clipboard first
    [self ingestPasteboard:[NSPasteboard generalPasteboard] atTime:[self.host playhead]];
}
- (void)copy:(id)sender { [self.host copySelectedClip]; }
- (void)undo:(id)sender { [self.host performUndo]; }
- (void)redo:(id)sender { [self.host performRedo]; }

// Shared by paste: and performDragOperation:. Image bytes, then file URL, then
// an http(s) URL to fetch.
- (BOOL)ingestPasteboard:(NSPasteboard *)pb atTime:(double)t {
    NSURL *fileURL = [NSURL URLFromPasteboard:pb];
    if (fileURL.isFileURL) { [self.host importMediaPath:fileURL.path atTime:t]; return YES; }

    NSData *tiff = [pb dataForType:NSPasteboardTypePNG] ?: [pb dataForType:NSPasteboardTypeTIFF];
    if (tiff) { [self.host addImageData:tiff path:nil atTime:t]; return YES; }

    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (str.length) {
        NSURL *url = [NSURL URLWithString:[str stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        if ([url.scheme hasPrefix:@"http"]) {
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                completionHandler:^(NSData *data, NSURLResponse *r, NSError *err) {
                    if (data && !err) dispatch_async(dispatch_get_main_queue(), ^{
                        [self.host addImageData:data path:nil atTime:t];
                    });
                }];
            [task resume];
            return YES;
        }
    }
    return NO;
}

// ---- Drops ----
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPoint p = [self convertPoint:sender.draggingLocation fromView:nil];
    return [self ingestPasteboard:sender.draggingPasteboard atTime:[self timeForX:p.x]];
}

@end
