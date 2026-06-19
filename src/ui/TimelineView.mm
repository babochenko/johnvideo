// johnvideo — timeline pane implementation (Objective-C++)
#import "TimelineView.h"
#import "Media.h"

typedef enum { DRAG_NONE, DRAG_SCRUB, DRAG_MOVE, DRAG_TRIM, DRAG_TRIM_LEFT, DRAG_TRACK } drag_mode;

@implementation TimelineView {
    drag_mode  _drag;
    jv_track  *_dragTrack;
    jv_clip   *_dragClip;
    double     _grabOffset;   // seconds between clip start and grab point
    size_t     _trackDragIdx; // track being reordered
    double     _scrollX;      // pan offset in seconds (time at the left edge)
    CGFloat    _scrollY;      // pan offset in pixels down the track list
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF,
                                         NSPasteboardTypeFileURL, NSPasteboardTypeString ]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

// ---- Geometry ----
- (double)pps { return [self.host pixelsPerSecond]; }
- (CGFloat)xForTime:(double)t { return kHeaderWidth + (t - _scrollX) * self.pps; }
- (double)timeForX:(CGFloat)x {
    double t = _scrollX + (x - kHeaderWidth) / self.pps;
    return t < 0 ? 0 : t;
}
- (CGFloat)yForTrack:(size_t)i { return kRulerHeight + i * (kTrackHeight + kTrackGap) + kTrackGap - _scrollY; }

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

    // Ruler: a tick every second.
    [[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, kRulerHeight));
    NSDictionary *tick = @{ NSFontAttributeName: [NSFont systemFontOfSize:9],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.85 alpha:1.0] };
    double span = (self.bounds.size.width - kHeaderWidth) / self.pps;
    int s0 = (int)_scrollX, s1 = (int)(_scrollX + span) + 1;
    for (int s = s0; s <= s1; s++) {
        CGFloat x = [self xForTime:s];
        if (x < kHeaderWidth) continue;
        [[NSColor colorWithCalibratedWhite:0.4 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(x, 0, 1, kRulerHeight));
        [[NSString stringWithFormat:@"%d", s] drawAtPoint:NSMakePoint(x + 2, 3) withAttributes:tick];
    }

    // Current playhead time (m:ss.mmm), right-aligned in the ruler — bright.
    NSString *timeStr = [TimelineView formatTime:[self.host playhead]];
    NSDictionary *timeAttrs = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: [NSColor whiteColor] };
    NSSize tsz = [timeStr sizeWithAttributes:timeAttrs];
    [timeStr drawAtPoint:NSMakePoint(self.bounds.size.width - tsz.width - 8, 2) withAttributes:timeAttrs];

    jv_clip *sel = [self.host selectedClip];
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
            if (c == sel) {
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

    // Playhead.
    CGFloat px = [self xForTime:[self.host playhead]];
    [[NSColor systemRedColor] setFill];
    NSRectFill(NSMakeRect(px, 0, 1.5, self.bounds.size.height));
}

// ---- Mouse: scrub / select / move / trim ----
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];

    if (p.y < kRulerHeight) { _drag = DRAG_SCRUB; [self.host seekTo:[self snapTime:[self timeForX:p.x]]]; return; }

    // Header column: start a track reorder drag.
    if (p.x < kHeaderWidth) {
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX) { [self.host recordUndo]; _drag = DRAG_TRACK; _trackDragIdx = ti; return; }
    }

    jv_track *t = NULL; size_t idx = 0;
    jv_clip *c = [self clipAtPoint:p track:&t index:&idx];
    if (c) {
        [self.host recordUndo];
        [self.host selectTrack:t clip:c];
        NSRect r = [self rectForClip:c onTrack:idx];
        if (p.x > NSMaxX(r) - 8) {            // right edge => trim end
            _drag = DRAG_TRIM;
        } else if (p.x < NSMinX(r) + 8) {     // left edge => trim start
            _drag = DRAG_TRIM_LEFT;
        } else {
            _drag = DRAG_MOVE;
            _grabOffset = [self timeForX:p.x] - c->start_time;
        }
        _dragTrack = t; _dragClip = c;
        [self setNeedsDisplay:YES];
    } else {
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
    if (_drag == DRAG_TRACK) {
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX && ti != _trackDragIdx) {
            jv_timeline_move_track(tl, _trackDragIdx, ti);
            _trackDragIdx = ti;
            [self.host refreshAll];
        }
        return;
    }
    if (_drag == DRAG_SCRUB) {
        [self.host seekTo:[self snapTime:t]];
    } else if (_drag == DRAG_MOVE && _dragClip) {
        // Move to the same-kind track under the pointer, if different.
        size_t ti = [self trackIndexForY:p.y];
        if (ti != SIZE_MAX) {
            jv_track *target = &tl->tracks[ti];
            if (target != _dragTrack && target->kind == _dragTrack->kind) {
                size_t ci = (size_t)(_dragClip - _dragTrack->clips);
                jv_clip *moved = jv_clip_move_to_track(_dragTrack, ci, target);
                if (moved) { _dragClip = moved; _dragTrack = target; [self.host selectTrack:target clip:moved]; }
            }
        }
        double ns = t - _grabOffset, dur = _dragClip->duration;
        // Sticky: snap whichever edge (start/end) is closer to a boundary.
        double sStart = [self snapBoundary:ns excluding:_dragClip];
        double sEnd   = [self snapBoundary:ns + dur excluding:_dragClip];
        if (fabs(sStart - ns) <= fabs(sEnd - (ns + dur))) ns = sStart; else ns = sEnd - dur;
        _dragClip->start_time = ns < 0 ? 0 : ns;
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

- (void)mouseUp:(NSEvent *)e {
    if (_drag == DRAG_TRACK) {
        jv_timeline_order_tracks([self.host timeline]);   // keep video above audio
        [self.host refreshAll];
    }
    _drag = DRAG_NONE; _dragClip = NULL; _dragTrack = NULL;
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
    _scrollX -= e.scrollingDeltaX / self.pps;
    if (_scrollX < 0) _scrollX = 0;
    _scrollY -= e.scrollingDeltaY;
    CGFloat maxY = [self contentHeight] - self.bounds.size.height;
    if (_scrollY > maxY) _scrollY = maxY > 0 ? maxY : 0;
    if (_scrollY < 0) _scrollY = 0;
    [self setNeedsDisplay:YES];
}

- (CGFloat)contentHeight {
    jv_timeline *tl = [self.host timeline];
    return kRulerHeight + tl->track_count * (kTrackHeight + kTrackGap) + kTrackGap;
}

// ---- Right-click menu ----
- (void)rightMouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSMenu *menu = [[NSMenu alloc] init];

    // Track header: track-management menu.
    if (p.x < kHeaderWidth) {
        size_t ti = [self trackIndexForY:p.y];
        NSMenuItem *av = [menu addItemWithTitle:@"Add Video Track" action:@selector(addVideoTrack) keyEquivalent:@""];
        NSMenuItem *aa = [menu addItemWithTitle:@"Add Audio Track" action:@selector(addAudioTrack) keyEquivalent:@""];
        av.target = self; aa.target = self;
        if (ti != SIZE_MAX) {
            [menu addItem:[NSMenuItem separatorItem]];
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

- (void)keyDown:(NSEvent *)e {
    NSString *chars = e.charactersIgnoringModifiers;
    unichar k = chars.length ? [chars characterAtIndex:0] : 0;
    NSEventModifierFlags m = e.modifierFlags;
    if ((m & NSEventModifierFlagControl) && (k == '=' || k == '+')) { [self.host zoomBy:1.25]; [self setNeedsDisplay:YES]; return; }
    if ((m & NSEventModifierFlagControl) && (k == '-' || k == '_')) { [self.host zoomBy:0.8];  [self setNeedsDisplay:YES]; return; }
    if (k == ' ') { [self.host transportToggle]; return; }
    if (k == NSLeftArrowFunctionKey  || k == 'h') { [self.host nudgePlayheadBy:-0.5]; return; }
    if (k == NSRightArrowFunctionKey || k == 'l') { [self.host nudgePlayheadBy:0.5];  return; }
    if (k == 't') { [self.host addTextAtPlayhead]; return; }
    if (k == NSDeleteCharacter || k == NSBackspaceCharacter || k == NSDeleteFunctionKey) { [self deleteSelected]; return; }
    [super keyDown:e];
}

- (void)deleteSelected {
    jv_clip *sel = [self.host selectedClip];
    if (!sel) return;
    [self.host recordUndo];
    jv_timeline *tl = [self.host timeline];
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *t = &tl->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) {
            if (&t->clips[j] == sel) {
                jv_clip_free_payload(&t->clips[j]);
                memmove(&t->clips[j], &t->clips[j + 1], (t->clip_count - j - 1) * sizeof(jv_clip));
                t->clip_count--;
                [self.host selectTrack:NULL clip:NULL];
                [self.host refreshAll];
                return;
            }
        }
    }
}

// ---- Paste (Cmd+V via the Edit menu) ----
- (void)paste:(id)sender {
    if ([self.host pasteClipAtPlayhead]) return;   // internal clip clipboard first
    [self ingestPasteboard:[NSPasteboard generalPasteboard] atTime:[self.host playhead]];
}
- (void)copy:(id)sender { [self.host copySelectedClip]; }

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
