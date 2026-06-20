// johnvideo — application delegate / editor coordinator (Objective-C++)
#import "AppDelegate.h"
#import "PreviewView.h"
#import "TimelineView.h"
#import "AudioController.h"
#import "Media.h"
#import "Editor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>

#include "timeline.h"
#include "decoder.h"
#include "export.h"
#import "Project.h"

static const double kImageDuration = 1.0;
static const double kTextDuration  = 1.0;
static const CGFloat kTimelineHeight = 240.0;
static NSString *const kLastProjectKey = @"lastProject";   // user-defaults key: last open .jvp

// Reusable bottom-right notification: a clickable body (opens fileURL if set)
// plus a ✕ close button. Self-sizing; the host positions and stacks them.
@interface JVNotification : NSView
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic, copy)   void (^onDismiss)(JVNotification *);
- (instancetype)initWithMessage:(NSString *)msg;
- (void)setMessage:(NSString *)msg;
@end

@implementation JVNotification {
    NSButton *_body;
    NSButton *_close;
}
static const CGFloat kNotifH = 30;
- (instancetype)initWithMessage:(NSString *)msg {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 100, kNotifH)])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.82].CGColor;
        self.layer.cornerRadius = 8;
        _body = [NSButton buttonWithTitle:@"" target:self action:@selector(bodyClicked)];
        _body.bordered = NO;
        _body.contentTintColor = [NSColor whiteColor];
        _body.font = [NSFont systemFontOfSize:13];
        [self addSubview:_body];
        _close = [NSButton buttonWithTitle:@"✕" target:self action:@selector(closeClicked)];
        _close.bordered = NO;
        _close.contentTintColor = [NSColor whiteColor];
        _close.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
        [self addSubview:_close];
        [self setMessage:msg];
    }
    return self;
}
- (void)setMessage:(NSString *)msg {
    _body.title = msg;
    [_body sizeToFit];
    CGFloat bw = _body.frame.size.width;
    CGFloat total = 12 + bw + 8 + 18 + 8;       // pad + body + gap + ✕ + pad
    self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y, total, kNotifH);
    _body.frame = NSMakeRect(12, 0, bw, kNotifH);
    _close.frame = NSMakeRect(total - 26, 0, 22, kNotifH);
}
- (void)bodyClicked  { if (self.fileURL) [[NSWorkspace sharedWorkspace] openURL:self.fileURL]; }
- (void)closeClicked { if (self.onDismiss) self.onDismiss(self); }
@end

// Layout: timeline pinned to the bottom, preview filling above it, and a glass
// toolbar floating over the lower part of the preview (Liquid Glass look).
@interface RootView : NSView
@property(nonatomic, strong) NSView *bar;        // glass toolbar pill
@property(nonatomic, strong) NSView *timeline;
@property(nonatomic, strong) NSView *preview;
@property(nonatomic, strong) NSView *leftModule; // optional module chip left of the bar
@property(nonatomic, assign) NSSize  barSize;
@end

@implementation RootView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)r {
    [[NSColor colorWithCalibratedWhite:0.10 alpha:1.0] setFill];
    NSRectFill(r);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self setNeedsLayout:YES]; }
- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    // Timeline fills the bottom region; preview fills above it. The toolbar is
    // an overlay that floats over the timeline and takes no layout space.
    self.timeline.frame = NSMakeRect(0, 0, w, kTimelineHeight);
    self.preview.frame  = NSMakeRect(0, kTimelineHeight, w, h - kTimelineHeight > 0 ? h - kTimelineHeight : 0);
    CGFloat bw = self.barSize.width, bh = self.barSize.height;
    self.bar.frame = NSMakeRect((w - bw) / 2, 10, bw, bh);   // floats, bottom-center
    // Module chip floats just left of the bar, vertically centered in it.
    if (self.leftModule) {
        CGFloat lw = self.leftModule.frame.size.width, lh = self.leftModule.frame.size.height;
        self.leftModule.frame = NSMakeRect((w - bw) / 2 - lw - 8, 10 + (bh - lh) / 2, lw, lh);
    }
}
@end

@interface AppDelegate () <EditorHost>
@end

@implementation AppDelegate {
    NSWindow         *_window;
    jv_timeline      *_timeline;
    PreviewView      *_preview;
    TimelineView     *_timelineView;
    AudioController  *_audio;

    jv_clip          *_selected;
    double            _playhead;
    double            _pps;            // pixels per second
    NSTimer          *_tick;
    NSButton         *_playButton;
    NSButton         *_recButton;

    // Wall-clock transport: the visual playhead advances independently of the
    // audio engine, so Play works even if audio output is unavailable.
    BOOL              _transportPlaying;
    double            _clockHead;       // playhead value when the clock started
    double            _clockWall;       // systemUptime when the clock started
    double            _recStartHead;    // playhead at the moment recording began
    jv_clip          *_liveRecClip;     // voiceover clip shown growing during recording

    NSMutableArray<NSValue *> *_undo;   // stack of jv_timeline* snapshots
    NSMutableArray<NSValue *> *_redo;
    jv_clip            _clipboard;       // copied clip (deep)
    BOOL               _hasClipboard;
    NSInteger          _focusTrack;      // current track for h/l/j/k navigation (-1 = none)
    NSString          *_projectPath;     // current .jvp path (Cmd+S saves here without asking)
    BOOL               _bladeMode;       // modal blade tool
    NSButton          *_bladeButton;
    NSView            *_bladeChip;        // glass wrapper around the blade button
    NSMutableArray<JVNotification *> *_notifications;   // bottom-right stack
}

// ---- Setup ----
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _timeline = jv_timeline_create(1920, 1080, 30.0);
    jv_timeline_add_track(_timeline, JV_TRACK_VISUAL, "Video 1");
    jv_timeline_add_track(_timeline, JV_TRACK_VISUAL, "Video 2");
    jv_timeline_add_track(_timeline, JV_TRACK_AUDIO,  "Voiceover");
    jv_timeline_add_track(_timeline, JV_TRACK_AUDIO,  "Music");
    _pps = 80.0;

    _audio = [[AudioController alloc] init];
    _audio.timeline = _timeline;
    _undo = [NSMutableArray array];
    _redo = [NSMutableArray array];
    _notifications = [NSMutableArray array];
    _focusTrack = -1;

    NSRect frame = NSMakeRect(0, 0, 1000, 700);
    _window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:NO];
    [_window setTitle:@"John Video"];
    _window.backgroundColor = [NSColor blackColor];
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    [_window center];

    // A row of separate, floating buttons. Each is its own rounded Liquid Glass
    // capsule (NOT merged in a container, so they stay distinct ovals).
    const CGFloat bh = 30, gap = 10, vpad = 6;
    NSView *inner = [[NSView alloc] init];
    __block CGFloat x = 0;
    NSButton *(^mk)(NSString *, SEL) = ^NSButton *(NSString *title, SEL sel) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
        b.bordered = NO;
        b.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [b sizeToFit];
        CGFloat bw = b.frame.size.width + 28;
        b.frame = NSMakeRect(0, 0, bw, bh);
        b.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSView *cap;
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(x, vpad, bw, bh)];
            g.cornerRadius = bh / 2;
            g.contentView = b;
            cap = g;
        } else {
            b.bordered = YES; b.bezelStyle = NSBezelStyleRounded;
            b.frame = NSMakeRect(x, vpad, bw, bh);
            cap = b;
        }
        [inner addSubview:cap];
        x += bw + gap;
        return b;
    };
    _playButton = mk(@"▶", @selector(togglePlay));
    _recButton  = mk(@"● Rec", @selector(toggleRecord));
    mk(@"Import…", @selector(importMedia));
    mk(@"Export…", @selector(exportMovie));

    NSSize barSize = NSMakeSize(x - gap, bh + vpad * 2);
    inner.frame = NSMakeRect(0, 0, barSize.width, barSize.height);
    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *bar = inner;   // transparent container; capsules float over content

    // Module chip (orange Liquid Glass "Blade"), shown only while blade is armed.
    _bladeButton = [NSButton buttonWithTitle:@"Blade" target:self action:@selector(toggleBladeAction)];
    _bladeButton.bordered = NO;
    _bladeButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [_bladeButton sizeToFit];
    CGFloat chipW = _bladeButton.frame.size.width + 28;   // same padding as toolbar buttons
    _bladeButton.frame = NSMakeRect(0, 0, chipW, bh);     // same height as toolbar buttons
    _bladeButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, chipW, bh)];
        g.cornerRadius = bh / 2;
        g.tintColor = [NSColor systemOrangeColor];
        g.contentView = _bladeButton;
        _bladeChip = g;
    } else {
        _bladeButton.wantsLayer = YES;
        _bladeButton.layer.backgroundColor = [NSColor systemOrangeColor].CGColor;
        _bladeButton.layer.cornerRadius = bh / 2;
        _bladeChip = _bladeButton;
    }
    _bladeChip.hidden = YES;

    _preview = [[PreviewView alloc] initWithFrame:NSZeroRect];
    _preview.host = self;
    _timelineView = [[TimelineView alloc] initWithFrame:NSZeroRect];
    _timelineView.host = self;

    RootView *content = [[RootView alloc] initWithFrame:frame];
    content.bar = bar;
    content.barSize = barSize;
    content.timeline = _timelineView;
    content.preview = _preview;
    content.leftModule = _bladeChip;
    [content addSubview:_timelineView];
    [content addSubview:_preview];
    [content addSubview:bar];           // glass floats on top of the preview
    [content addSubview:_bladeChip];
    [content setNeedsLayout:YES];
    [_window setContentView:content];

    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_timelineView];
    [NSApp activateIgnoringOtherApps:YES];

    // Reopen the project that was open last time, if its file still exists.
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kLastProjectKey];
    if (last && [[NSFileManager defaultManager] fileExistsAtPath:last]) [self loadProjectAtPath:last];
}

- (NSButton *)barButton:(NSString *)title x:(CGFloat *)x action:(SEL)sel inBar:(NSView *)bar {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.bezelStyle = NSBezelStyleRounded;
    [b sizeToFit];
    NSRect f = b.frame; f.origin = NSMakePoint(*x, 6); f.size.height = 28;
    b.frame = f;
    *x += f.size.width + 6;
    [bar addSubview:b];
    return b;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }

// Save the project before quitting (Cmd+Q, menu, window close, etc.).
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (_transportPlaying) [self stopTransport];
    if (_projectPath) [self saveToPath:_projectPath];
    else if (![self timelineEmpty]) [self saveProject:nil];   // prompt for a name once
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [_audio stop];
    jv_timeline_destroy(_timeline);
    _timeline = NULL;
}

// ---- Track helpers ----
- (jv_track *)firstTrackOfKind:(jv_track_kind)kind {
    for (size_t i = 0; i < _timeline->track_count; i++)
        if (_timeline->tracks[i].kind == kind) return &_timeline->tracks[i];
    return NULL;
}
- (jv_track *)lastTrackOfKind:(jv_track_kind)kind {
    jv_track *found = NULL;
    for (size_t i = 0; i < _timeline->track_count; i++)
        if (_timeline->tracks[i].kind == kind) found = &_timeline->tracks[i];
    return found;
}

// Where to drop a newly inserted clip on a track: at `t`, or after the last
// clip already there (so repeated inserts line up one after another).
- (double)appendTimeOnTrack:(jv_track *)t atLeast:(double)t0 {
    double end = t0;
    for (size_t j = 0; j < t->clip_count; j++) {
        double e = t->clips[j].start_time + t->clips[j].duration;
        if (e > end) end = e;
    }
    return end;
}

- (BOOL)timelineEmpty {
    for (size_t i = 0; i < _timeline->track_count; i++)
        if (_timeline->tracks[i].clip_count) return NO;
    return YES;
}

// Fit fraction (of canvas height) so a wxh source sits within 90% of the canvas.
- (float)fitScaleForW:(int)w h:(int)h {
    double cw = _timeline->width, ch = _timeline->height;
    double targetH = fmin(0.9 * ch, 0.9 * cw * h / w);
    return (float)(targetH / ch);
}

// ---- EditorHost ----
- (jv_timeline *)timeline { return _timeline; }
- (double)pixelsPerSecond { return _pps; }
- (double)playhead { return _playhead; }
- (jv_clip *)selectedClip { return _selected; }

- (void)refreshAll {
    [_preview setNeedsDisplay:YES];
    [_timelineView setNeedsDisplay:YES];
}

- (void)seekTo:(double)t {
    if (t < 0) t = 0;
    _playhead = t;
    if (_transportPlaying) { [self startClockFrom:t]; [_audio playFrom:t]; }   // scrubbing keeps play/pause state
    [self refreshAll];
}

// Selection lives as a per-clip flag, so it survives array moves/reallocs.
- (void)clearSelectionFlags {
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) t->clips[j].selected = 0;
    }
}
- (jv_clip *)anySelectedClip {
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) if (t->clips[j].selected) return &t->clips[j];
    }
    return NULL;
}
- (size_t)selectedCount {
    size_t n = 0;
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) if (t->clips[j].selected) n++;
    }
    return n;
}

- (void)selectTrack:(jv_track *)t clip:(jv_clip *)c {
    [self clearSelectionFlags];
    _selected = c;
    if (c) {
        c->selected = 1;
        for (size_t i = 0; i < _timeline->track_count; i++) {
            jv_track *tr = &_timeline->tracks[i];
            for (size_t j = 0; j < tr->clip_count; j++)
                if (&tr->clips[j] == c) { _focusTrack = (NSInteger)i; return; }
        }
    }
}

- (BOOL)isClipSelected:(jv_clip *)c { return c && c->selected; }

- (void)selectAllClips {
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) t->clips[j].selected = 1;
    }
    _selected = [self anySelectedClip];
    [self refreshAll];
}

- (void)toggleSelectClip:(jv_clip *)c {
    if (!c) return;
    c->selected = !c->selected;
    _selected = c->selected ? c : [self anySelectedClip];
    [self refreshAll];
}

- (void)shiftSelectionExcept:(jv_clip *)c by:(double)delta {
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) {
            jv_clip *o = &t->clips[j];
            if (!o->selected || o == c) continue;
            double s = o->start_time + delta;
            o->start_time = s < 0 ? 0 : s;
        }
    }
}

- (void)nudgeSelectedBy:(double)seconds {
    if ([self selectedCount] == 0) return;
    [self recordUndo];
    [self shiftSelectionExcept:NULL by:seconds];
    [self refreshAll];
}

// Select every clip on c's track between the current primary selection and c.
- (void)extendSelectionTo:(jv_clip *)c {
    if (!c) return;
    // Find c's track.
    jv_track *track = NULL;
    for (size_t i = 0; i < _timeline->track_count && !track; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) if (&t->clips[j] == c) { track = t; break; }
    }
    if (!track) return;
    double a = _selected ? _selected->start_time : c->start_time;
    double lo = a < c->start_time ? a : c->start_time;
    double hi = a > c->start_time ? a : c->start_time;
    for (size_t j = 0; j < track->clip_count; j++)
        if (track->clips[j].start_time >= lo - 1e-6 && track->clips[j].start_time <= hi + 1e-6)
            track->clips[j].selected = 1;
    _selected = c;
    [self refreshAll];
}

// Move every selected clip by `delta` tracks (same kind), keeping selection
// and the primary clip identity.
- (void)shiftSelectionTracksBy:(int)delta {
    if (delta == 0 || [self selectedCount] == 0) return;
    size_t cap = [self selectedCount];
    jv_clip *ex = (jv_clip *)malloc(cap * sizeof(jv_clip));
    NSInteger *srcTrk = (NSInteger *)malloc(cap * sizeof(NSInteger));
    size_t n = 0; NSInteger primaryIdx = -1;
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        size_t w = 0;
        for (size_t j = 0; j < t->clip_count; j++) {
            if (t->clips[j].selected) {
                if (&t->clips[j] == _selected) primaryIdx = (NSInteger)n;
                ex[n] = t->clips[j]; srcTrk[n] = (NSInteger)i; n++;
            } else t->clips[w++] = t->clips[j];
        }
        t->clip_count = w;
    }
    jv_clip **slots = (jv_clip **)malloc(n * sizeof(jv_clip *));
    for (size_t k = 0; k < n; k++) {
        NSInteger tgt = srcTrk[k] + delta;
        if (tgt < 0) tgt = 0;
        if (tgt >= (NSInteger)_timeline->track_count) tgt = (NSInteger)_timeline->track_count - 1;
        jv_track_kind want = (ex[k].type == JV_CLIP_AUDIO) ? JV_TRACK_AUDIO : JV_TRACK_VISUAL;
        if (_timeline->tracks[tgt].kind != want) tgt = srcTrk[k];   // don't cross the kind boundary
        jv_track *dt = &_timeline->tracks[tgt];
        jv_clip *slot = jv_track_add_clip(dt, ex[k].type, ex[k].start_time, ex[k].duration);
        *slot = ex[k];
        slot->selected = 1;
        slots[k] = slot;
    }
    _selected = (primaryIdx >= 0) ? slots[primaryIdx] : [self anySelectedClip];
    free(ex); free(srcTrk); free(slots);
    [self refreshAll];
}

- (void)jumpStartMarksEnd:(int)dir {
    double dur = jv_timeline_duration(_timeline);
    // Candidate stops: start, every marker, end.
    NSMutableArray<NSNumber *> *stops = [NSMutableArray arrayWithObject:@(0.0)];
    for (size_t i = 0; i < _timeline->marker_count; i++) [stops addObject:@(_timeline->markers[i])];
    [stops addObject:@(dur)];
    [stops sortUsingSelector:@selector(compare:)];
    const double eps = 1e-4;
    double best = _playhead; int got = 0;
    for (NSNumber *n in stops) {
        double s = n.doubleValue;
        if (dir > 0 && s > _playhead + eps) { if (!got || s < best) { best = s; got = 1; } }
        else if (dir < 0 && s < _playhead - eps) { if (!got || s > best) { best = s; got = 1; } }
    }
    if (!got) return;
    _playhead = best;
    if (_transportPlaying) { [self startClockFrom:best]; [_audio playFrom:best]; }   // keep playing
    [self refreshAll];
}

// Clips of a track, sorted by start time (returns clip pointers).
- (NSArray<NSValue *> *)clipsOfTrackSorted:(size_t)ti {
    NSMutableArray<NSValue *> *a = [NSMutableArray array];
    jv_track *t = &_timeline->tracks[ti];
    for (size_t j = 0; j < t->clip_count; j++) [a addObject:[NSValue valueWithPointer:&t->clips[j]]];
    [a sortUsingComparator:^NSComparisonResult(NSValue *x, NSValue *y) {
        double sx = ((jv_clip *)x.pointerValue)->start_time, sy = ((jv_clip *)y.pointerValue)->start_time;
        return sx < sy ? NSOrderedAscending : (sx > sy ? NSOrderedDescending : NSOrderedSame);
    }];
    return a;
}

- (void)setPixelsPerSecond:(double)pps {
    if (pps < 1) pps = 1;
    if (pps > 600) pps = 600;
    _pps = pps;
    [self refreshAll];
}

- (void)addTrackOfKind:(jv_track_kind)kind {
    [self recordUndo];
    static int vn = 2, an = 0;
    char name[32];
    if (kind == JV_TRACK_VISUAL) snprintf(name, sizeof name, "Video %d", ++vn);
    else                          snprintf(name, sizeof name, "Audio %d", ++an);
    jv_timeline_add_track(_timeline, kind, name);
    jv_timeline_order_tracks(_timeline);   // keep video tracks above audio
    [self refreshAll];
}

- (void)renameTrackAtIndex:(size_t)index to:(NSString *)name {
    if (index >= _timeline->track_count || name.length == 0) return;
    [self recordUndo];
    jv_track *t = &_timeline->tracks[index];
    free(t->name);
    t->name = strdup(name.UTF8String);
    [self refreshAll];
}

- (void)removeTrackAtIndex:(size_t)index {
    if (index >= _timeline->track_count) return;
    [self recordUndo];
    // Clear selection if it lived on this track.
    jv_track *t = &_timeline->tracks[index];
    for (size_t j = 0; j < t->clip_count; j++)
        if (&t->clips[j] == _selected) _selected = NULL;
    jv_timeline_remove_track(_timeline, index);
    [self refreshAll];
}

- (void)addImageData:(NSData *)data path:(NSString *)path atTime:(double)t {
    [self recordUndo];
    int w = 0, h = 0;
    unsigned char *rgba = data ? jv_rgba_from_bytes(data.bytes, data.length, &w, &h)
                               : jv_rgba_from_file(path.UTF8String, &w, &h);
    if (!rgba) { NSBeep(); return; }

    jv_track *vt = [self firstTrackOfKind:JV_TRACK_VISUAL];
    jv_clip *c = jv_track_add_clip(vt, JV_CLIP_IMAGE, [self appendTimeOnTrack:vt atLeast:t], kImageDuration);
    c->u.image.rgba = rgba;
    c->u.image.width = w;
    c->u.image.height = h;
    c->u.image.cx = 0.5f; c->u.image.cy = 0.5f;
    c->u.image.scale = [self fitScaleForW:w h:h];
    if (path) c->u.image.path = strdup(path.UTF8String);
    [self selectTrack:vt clip:c];
    [self refreshAll];
}

- (void)importMediaPath:(NSString *)path atTime:(double)t {
    [self recordUndo];
    // Try as a still image first.
    int w = 0, h = 0;
    unsigned char *rgba = jv_rgba_from_file(path.UTF8String, &w, &h);
    if (rgba) { free(rgba); [self addImageData:nil path:path atTime:t]; return; }

    // Otherwise probe with the decoder: video, or audio-only (music).
    jv_decoder *d = jv_decoder_open(path.UTF8String);
    if (!d) { NSBeep(); return; }
    double dur = jv_decoder_duration(d);
    if (dur <= 0) dur = 5.0;

    if (jv_decoder_width(d) > 0) {
        // Adopt the first imported video's native resolution as the canvas, so
        // export is true source size (1080p stays 1080p, 4K stays 4K).
        if ([self timelineEmpty]) {
            _timeline->width = jv_decoder_width(d);
            _timeline->height = jv_decoder_height(d);
        }
        // Video clip on first visual track.
        jv_track *vt = [self firstTrackOfKind:JV_TRACK_VISUAL];
        jv_clip *c = jv_track_add_clip(vt, JV_CLIP_VIDEO, t, dur);
        c->u.video.path = strdup(path.UTF8String);
        c->u.video.cx = 0.5f; c->u.video.cy = 0.5f;
        c->u.video.scale = [self fitScaleForW:jv_decoder_width(d) h:jv_decoder_height(d)];
        // Pull the clip's audio onto the Music track so it plays/exports.
        if (jv_decoder_has_audio(d)) [self addAudioFromDecoder:d path:path atTime:t track:[self lastTrackOfKind:JV_TRACK_AUDIO]];
        [self selectTrack:vt clip:c];
    } else if (jv_decoder_has_audio(d)) {
        [self addAudioFromDecoder:d path:path atTime:t track:[self lastTrackOfKind:JV_TRACK_AUDIO]];
    } else {
        NSBeep();
    }
    jv_decoder_close(d);
    [self refreshAll];
}

- (void)addAudioFromDecoder:(jv_decoder *)d path:(NSString *)path atTime:(double)t track:(jv_track *)at {
    float *pcm = NULL; int sr = 0;
    size_t frames = jv_decoder_read_all_audio(d, &pcm, &sr);
    if (!frames || !pcm) return;
    double dur = (double)frames / sr;
    jv_clip *c = jv_track_add_clip(at, JV_CLIP_AUDIO, t, dur);
    c->u.audio.path = strdup(path.UTF8String);
    c->u.audio.pcm = pcm;
    c->u.audio.frames = frames;
    c->u.audio.sample_rate = sr;
    c->u.audio.channels = 2;
    c->u.audio.gain = 1.0f;
}

- (void)addTextAtCanvasX:(float)cx y:(float)cy time:(double)t {
    [self recordUndo];
    // Insert a default text clip immediately; the preview enters in-place edit.
    const char *initial = "Text";
    double fontPx = _timeline->height * 0.06;
    int w = 0, h = 0;
    unsigned char *rgba = jv_rasterize_text(initial, fontPx, 0xFFFFFFFF, &w, &h);
    if (!rgba) { NSBeep(); return; }
    jv_track *vt = [self firstTrackOfKind:JV_TRACK_VISUAL];
    jv_clip *c = jv_track_add_clip(vt, JV_CLIP_TEXT, t, kTextDuration);
    c->u.text.string = strdup(initial);
    c->u.text.font_size = fontPx;
    c->u.text.color = 0xFFFFFFFF;
    c->u.text.rgba = rgba;
    c->u.text.width = w; c->u.text.height = h;
    c->u.text.cx = cx; c->u.text.cy = cy;
    [self selectTrack:vt clip:c];
    [self refreshAll];
}

// ---- Transport ----
- (void)startClockFrom:(double)head { _clockHead = head; _clockWall = NSProcessInfo.processInfo.systemUptime; }

- (void)togglePlay {
    if (_transportPlaying) { [self stopTransport]; return; }
    double dur = jv_timeline_duration(_timeline);
    if (dur > 0 && _playhead >= dur - 1e-6) _playhead = 0;   // at the end -> restart from the beginning
    _transportPlaying = YES;
    [self startClockFrom:_playhead];
    [_audio playFrom:_playhead];          // best effort; visuals don't depend on it
    _playButton.title = @"⏸";
    [self startTick];
}

- (void)stopTransport {
    if (!_transportPlaying) return;
    _transportPlaying = NO;
    [_audio stop];
    [self stopTick];
    _playButton.title = @"▶";
}

- (void)updatePlayButton { _playButton.title = _transportPlaying ? @"⏸" : @"▶"; }

- (void)startTick {
    [self stopTick];
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *_) {
        double elapsed = NSProcessInfo.processInfo.systemUptime - self->_clockWall;
        self->_playhead = self->_clockHead + elapsed;
        // Grow the live recording clip in real time.
        if (self->_liveRecClip && [self->_audio isRecording]) {
            size_t fr = [self->_audio recordingFrames];
            int sr = [self->_audio recordingSampleRate];
            self->_liveRecClip->u.audio.frames = fr;
            self->_liveRecClip->duration = sr > 0 ? (double)fr / sr : 0;
        }
        // Stop at the end only while playing back (recording may run past it).
        double dur = jv_timeline_duration(self->_timeline);
        if (self->_transportPlaying && dur > 0 && self->_playhead >= dur) {
            [self stopTransport];
            self->_playhead = dur;   // hold at the last frame; pressing play restarts from 0
        }
        [self->_timelineView followPlayhead];   // scroll the timeline to track the playhead
        [self refreshAll];
    }];
}
- (void)stopTick { [_tick invalidate]; _tick = nil; }

- (void)alert:(NSString *)title info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    if (info) a.informativeText = info;
    [a runModal];
}

// ---- Notifications (abstract, reusable) ----
// Present a bottom-right notification. sticky:YES stays until the ✕ or a click;
// sticky:NO auto-fades after a few seconds. Returns it so callers can update it.
- (JVNotification *)presentNotification:(NSString *)msg fileURL:(NSURL *)url sticky:(BOOL)sticky {
    JVNotification *n = [[JVNotification alloc] initWithMessage:msg];
    n.fileURL = url;
    n.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    __weak AppDelegate *ws = self;
    n.onDismiss = ^(JVNotification *x) { [ws dismissNotification:x]; };
    [_notifications addObject:n];
    [_window.contentView addSubview:n];
    [self layoutNotifications];
    if (!sticky) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self dismissNotification:n]; });
    }
    return n;
}

- (void)dismissNotification:(JVNotification *)n {
    if (![_notifications containsObject:n]) return;
    [_notifications removeObject:n];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.3; n.animator.alphaValue = 0;
    } completionHandler:^{ [n removeFromSuperview]; }];
    [self layoutNotifications];
}

// Stack notifications up from the bottom-right corner.
- (void)layoutNotifications {
    CGFloat w = _window.contentView.bounds.size.width;
    CGFloat y = 16;
    for (JVNotification *n in _notifications) {
        n.frame = NSMakeRect(w - n.frame.size.width - 16, y, n.frame.size.width, n.frame.size.height);
        y += n.frame.size.height + 8;
    }
}

// Convenience: transient auto-fading toast (e.g. "saved").
- (void)showToast:(NSString *)msg fileURL:(NSURL *)url {
    [self presentNotification:msg fileURL:url sticky:NO];
}

- (void)toggleRecord {
    if (![_audio isRecording]) {
        // Ask for mic permission, then start synchronously so button state and
        // feedback are correct.
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!granted) {
                    [self alert:@"Microphone access denied"
                           info:@"Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again."];
                    return;
                }
                [self->_audio startRecordingFrom:self->_playhead];
                if (![self->_audio isRecording]) {
                    [self alert:@"Recording failed" info:@"No microphone input is available."];
                    return;
                }
                self->_recStartHead = self->_playhead;   // place the take here on stop
                [self startClockFrom:self->_playhead];
                // Live clip on the voiceover track, referencing the capture
                // buffer so it (and its waveform) grow in real time.
                jv_track *vo = [self firstTrackOfKind:JV_TRACK_AUDIO];
                jv_clip *c = jv_track_add_clip(vo, JV_CLIP_AUDIO, self->_recStartHead, 0);
                c->u.audio.pcm = (float *)[self->_audio recordingPCM];   // borrowed until stop
                c->u.audio.frames = 0;
                c->u.audio.sample_rate = [self->_audio recordingSampleRate];
                c->u.audio.channels = 2;
                c->u.audio.gain = 1.0f;
                c->u.audio.path = NULL;
                self->_liveRecClip = c;
                [self selectTrack:vo clip:c];
                self->_recButton.title = @"■ Stop";
                [self startTick];
            });
        }];
        return;
    }

    {
        size_t frames = 0; int sr = 0;
        float *pcm = [_audio stopRecordingFrames:&frames sampleRate:&sr];   // transfers buffer ownership
        [self stopTick];
        [self updatePlayButton];
        _recButton.title = @"● Rec";
        if (_liveRecClip) {
            if (pcm && frames) {
                // The live clip already points at this buffer; it now owns it.
                _liveRecClip->u.audio.pcm = pcm;
                _liveRecClip->u.audio.frames = frames;
                _liveRecClip->u.audio.sample_rate = sr;
                _liveRecClip->u.audio.channels = 2;
                _liveRecClip->u.audio.path = strdup("voiceover");
                _liveRecClip->duration = (double)frames / sr;
            } else {
                // Nothing captured: drop the placeholder clip.
                _liveRecClip->u.audio.pcm = NULL;   // wasn't owned
                [self removeClip:_liveRecClip];
                free(pcm);
            }
            _liveRecClip = NULL;
        } else {
            free(pcm);
        }
        [self refreshAll];
    }
}

// ---- Transport / navigation ----
- (void)transportToggle { [self togglePlay]; }

- (void)nudgePlayheadBy:(double)seconds {
    double t = _playhead + seconds;
    if (t < 0) t = 0;
    double dur = jv_timeline_duration(_timeline);
    if (dur > 0 && t > dur) t = dur;
    _playhead = t;
    if (_transportPlaying) { [self startClockFrom:t]; [_audio playFrom:t]; }   // keep playing from the new spot
    [self refreshAll];
}

- (void)zoomBy:(double)factor { [self setPixelsPerSecond:_pps * factor]; }

- (void)addTextAtPlayhead {
    [self addTextAtCanvasX:0.5f y:0.5f time:_playhead];
    if (_selected && _selected->type == JV_CLIP_TEXT)
        [_preview beginEditingTextClip:_selected];
}

// ---- Clipboard (deep single-clip copy) ----
static void clone_clip_payload(jv_clip *dst, const jv_clip *src) {
    *dst = *src;
    size_t n;
    switch (src->type) {
        case JV_CLIP_IMAGE:
            dst->u.image.path = src->u.image.path ? strdup(src->u.image.path) : NULL;
            n = (size_t)src->u.image.width * src->u.image.height * 4;
            dst->u.image.rgba = src->u.image.rgba ? (unsigned char *)memcpy(malloc(n), src->u.image.rgba, n) : NULL;
            break;
        case JV_CLIP_TEXT:
            dst->u.text.string = src->u.text.string ? strdup(src->u.text.string) : NULL;
            n = (size_t)src->u.text.width * src->u.text.height * 4;
            dst->u.text.rgba = src->u.text.rgba ? (unsigned char *)memcpy(malloc(n), src->u.text.rgba, n) : NULL;
            break;
        case JV_CLIP_VIDEO:
            dst->u.video.path = src->u.video.path ? strdup(src->u.video.path) : NULL;
            dst->u.video.decoder = NULL;
            break;
        case JV_CLIP_AUDIO:
            dst->u.audio.path = src->u.audio.path ? strdup(src->u.audio.path) : NULL;
            n = src->u.audio.frames * 2 * sizeof(float);
            dst->u.audio.pcm = src->u.audio.pcm ? (float *)memcpy(malloc(n), src->u.audio.pcm, n) : NULL;
            break;
    }
}

- (void)copySelectedClip {
    if (!_selected) return;
    if (_hasClipboard) jv_clip_free_payload(&_clipboard);
    clone_clip_payload(&_clipboard, _selected);
    _hasClipboard = YES;
}

- (BOOL)pasteClipAtPlayhead {
    if (!_hasClipboard) return NO;
    // Paste onto the first track whose kind matches the clipboard clip.
    BOOL wantAudio = (_clipboard.type == JV_CLIP_AUDIO);
    jv_track *dst = [self firstTrackOfKind:wantAudio ? JV_TRACK_AUDIO : JV_TRACK_VISUAL];
    if (!dst) return NO;
    [self recordUndo];
    double at = [self appendTimeOnTrack:dst atLeast:_playhead];   // line up after existing clips
    jv_clip *c = jv_track_add_clip(dst, _clipboard.type, at, _clipboard.duration);
    clone_clip_payload(c, &_clipboard);
    c->start_time = at;
    [self selectTrack:dst clip:c];
    [self refreshAll];
    return YES;
}

// ---- Undo / redo ----
- (void)recordUndo {
    [_undo addObject:[NSValue valueWithPointer:jv_timeline_clone(_timeline)]];
    if (_undo.count > 50) {
        jv_timeline_destroy((jv_timeline *)[_undo[0] pointerValue]);
        [_undo removeObjectAtIndex:0];
    }
    for (NSValue *v in _redo) jv_timeline_destroy((jv_timeline *)v.pointerValue);
    [_redo removeAllObjects];
}

- (void)swapTimelineTo:(jv_timeline *)tl {
    _selected = NULL;
    _liveRecClip = NULL;
    _timeline = tl;
    _audio.timeline = tl;
    if (_playhead > jv_timeline_duration(tl)) _playhead = 0;
    [self refreshAll];
}

- (void)performUndo {
    if (_undo.count == 0) return;
    [_redo addObject:[NSValue valueWithPointer:_timeline]];   // current -> redo
    jv_timeline *prev = (jv_timeline *)[_undo.lastObject pointerValue];
    [_undo removeLastObject];
    [self swapTimelineTo:prev];
}

- (void)performRedo {
    if (_redo.count == 0) return;
    [_undo addObject:[NSValue valueWithPointer:_timeline]];   // current -> undo
    jv_timeline *next = (jv_timeline *)[_redo.lastObject pointerValue];
    [_redo removeLastObject];
    [self swapTimelineTo:next];
}

// Standard responder-chain actions (Edit menu key equivalents).
- (void)copy:(id)sender { [self copySelectedClip]; }
- (void)undo:(id)sender { [self performUndo]; }
- (void)redo:(id)sender { [self performRedo]; }

- (void)deleteSelectedClip {
    if (!_selected) return;
    [self recordUndo];
    [self removeClip:_selected];
    [self refreshAll];
}

// ---- Markers ----
- (void)addMarkerAtPlayhead {
    [self recordUndo];
    jv_timeline_add_marker(_timeline, _playhead);
    [self refreshAll];
}

- (BOOL)deleteMarkerNearPlayhead {
    double tol = 8.0 / _pps;   // ~8px
    [self recordUndo];
    if (jv_timeline_remove_marker_near(_timeline, _playhead, tol)) { [self refreshAll]; return YES; }
    // No marker there: discard the no-op snapshot.
    if (_undo.count) { jv_timeline_destroy((jv_timeline *)[_undo.lastObject pointerValue]); [_undo removeLastObject]; }
    return NO;
}

- (void)jumpToMarker:(int)dir {
    int found = 0;
    double m = jv_timeline_adjacent_marker(_timeline, _playhead, dir, &found);
    if (!found) return;
    if (_transportPlaying) [self stopTransport];
    _playhead = m;
    [self refreshAll];
}

// ---- Clip / track navigation ----
- (void)selectClipAndSeek:(jv_clip *)c {
    if (!c) return;
    [self clearSelectionFlags];
    _selected = c; c->selected = 1;
    if (_transportPlaying) [self stopTransport];
    _playhead = c->start_time;
    [self refreshAll];
}

// h / l: move horizontally to the previous / next clip ON THE CURRENT TRACK
// (by start time), wrapping around.
- (void)selectAdjacentClip:(int)dir {
    if (_timeline->track_count == 0) return;
    if (_focusTrack < 0) _focusTrack = 0;
    NSArray<NSValue *> *clips = [self clipsOfTrackSorted:(size_t)_focusTrack];
    if (clips.count == 0) return;
    NSInteger idx = -1;
    for (NSUInteger i = 0; i < clips.count; i++)
        if ((jv_clip *)clips[i].pointerValue == _selected) { idx = (NSInteger)i; break; }
    NSInteger n = (NSInteger)clips.count;
    NSInteger next = (idx < 0) ? (dir > 0 ? 0 : n - 1) : (idx + dir + n) % n;
    [self selectClipAndSeek:(jv_clip *)clips[(NSUInteger)next].pointerValue];
}

// Select the clip on track ti nearest the playhead (or NULL if empty).
- (void)focusOnTrack:(NSInteger)ti {
    _focusTrack = ti;
    jv_track *t = &_timeline->tracks[ti];
    jv_clip *best = NULL; double bestD = 1e18;
    for (size_t j = 0; j < t->clip_count; j++) {
        double d = fabs(t->clips[j].start_time - _playhead);
        if (d < bestD) { bestD = d; best = &t->clips[j]; }
    }
    [self clearSelectionFlags];
    _selected = best;
    if (best) best->selected = 1;
    [self refreshAll];
}

// j (dir +1, down): wraps to the top.  k (dir -1, up): wraps to the bottom.
// With no focus yet, j starts at the top and k starts at the bottom.
- (void)focusTrack:(int)dir {
    NSInteger n = (NSInteger)_timeline->track_count;
    if (n == 0) return;
    NSInteger ti = (_focusTrack < 0) ? (dir > 0 ? -1 : n) : _focusTrack;
    for (NSInteger step = 0; step < n; step++) {        // skip empty tracks, wrapping
        ti = (ti + dir + n) % n;
        if (_timeline->tracks[ti].clip_count > 0) { [self focusOnTrack:ti]; return; }
    }
}

// ---- Blade tool ----
- (BOOL)bladeActive { return _bladeMode; }

- (void)toggleBlade {
    _bladeMode = !_bladeMode;
    _bladeChip.hidden = !_bladeMode;       // chip only present while armed
    [(RootView *)_window.contentView setNeedsLayout:YES];
    [self refreshAll];
}
- (void)toggleBladeAction { [self toggleBlade]; }

// Split clip c at absolute time t (where the user clicked).
- (void)bladeCutClip:(jv_clip *)c atTime:(double)t {
    if (!c) return;
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *trk = &_timeline->tracks[i];
        for (size_t j = 0; j < trk->clip_count; j++) {
            if (&trk->clips[j] == c) {
                if (t <= c->start_time || t >= c->start_time + c->duration) return;
                [self recordUndo];
                jv_clip *second = jv_track_split_clip(trk, j, t);
                if (second) [self selectTrack:trk clip:second];
                [self refreshAll];
                return;
            }
        }
    }
}

// ---- Reveal current project in Finder (Cmd+Shift+O) ----
- (void)revealProject:(id)sender {
    if (_projectPath && [[NSFileManager defaultManager] fileExistsAtPath:_projectPath])
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:_projectPath] ]];
}

- (void)beginEditingClip:(jv_clip *)c {
    if (!c || c->type != JV_CLIP_TEXT) return;
    _selected = c;
    // Move the playhead into the clip so it's visible in the preview.
    if (_playhead < c->start_time || _playhead >= c->start_time + c->duration)
        _playhead = c->start_time + c->duration * 0.5;
    [self refreshAll];
    [_preview beginEditingTextClip:c];
}

// Remove a clip from whatever track holds it.
- (void)removeClip:(jv_clip *)clip {
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) {
            if (&t->clips[j] == clip) {
                jv_clip_free_payload(&t->clips[j]);
                memmove(&t->clips[j], &t->clips[j + 1], (t->clip_count - j - 1) * sizeof(jv_clip));
                t->clip_count--;
                if (_selected == clip) _selected = NULL;
                return;
            }
        }
    }
}

- (void)importMedia {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] == NSModalResponseOK && panel.URL)
        [self importMediaPath:panel.URL.path atTime:_playhead];
}

// ---- Project save / open (text .jvp) ----
// Remember the current project path in user defaults so the app reopens it on
// next launch (see applicationDidFinishLaunching: / kLastProjectKey).
- (void)setProjectPath:(NSString *)path {
    _projectPath = path;
    if (path) [[NSUserDefaults standardUserDefaults] setObject:path forKey:kLastProjectKey];
    else      [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLastProjectKey];
}

- (void)saveToPath:(NSString *)path {
    _timeline->pixels_per_second = _pps;   // persist the timeline zoom
    _timeline->playhead = _playhead;       // persist the redline position
    if (jv_project_save(_timeline, path)) {
        [self setProjectPath:path];
        [self showToast:[NSString stringWithFormat:@"%@ saved", path.lastPathComponent]
                fileURL:[NSURL fileURLWithPath:path]];
    } else {
        [self alert:@"Save failed" info:path];
    }
}

- (void)saveProject:(id)sender {
    if (_projectPath) { [self saveToPath:_projectPath]; return; }   // Cmd+S saves in place
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"project.jvp";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    [self saveToPath:panel.URL.path];
}

// Load a .jvp into the editor, replacing the current timeline. Returns NO (and
// leaves the current timeline untouched) if the file can't be parsed.
- (BOOL)loadProjectAtPath:(NSString *)path {
    jv_timeline *loaded = jv_project_load(path);
    if (!loaded) return NO;
    [self stopTransport];
    _selected = NULL;
    jv_timeline *old = _timeline;
    _timeline = loaded;
    _audio.timeline = _timeline;
    jv_timeline_destroy(old);
    _playhead = _timeline->playhead;     // restore the redline position
    if (_timeline->pixels_per_second > 0) _pps = _timeline->pixels_per_second;   // restore zoom
    [self setProjectPath:path];          // subsequent Cmd+S saves here; reopened next launch
    [self refreshAll];
    return YES;
}

- (void)openProject:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[ @"jvp" ];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    if (![self loadProjectAtPath:panel.URL.path]) [self alert:@"Open failed" info:panel.URL.path];
}

- (void)exportMovie {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"export.mp4";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *out = panel.URL.path;
    [self stopTransport];

    // Sticky notification with a live elapsed timer (no modal sheet); it stays
    // until clicked or dismissed with the ✕.
    JVNotification *note = [self presentNotification:@"Exporting… 0.0s" fileURL:nil sticky:YES];
    double start = NSProcessInfo.processInfo.systemUptime;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *_) {
        [note setMessage:[NSString stringWithFormat:@"Exporting… %.1fs", NSProcessInfo.processInfo.systemUptime - start]];
        [self layoutNotifications];
    }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = jv_export_mp4(self->_timeline, out.UTF8String, NULL, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            double secs = NSProcessInfo.processInfo.systemUptime - start;
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss";
            NSString *finishedAt = [df stringFromDate:[NSDate date]];
            if (rc == 0) {
                [note setMessage:[NSString stringWithFormat:@"Exported %@ at %@ (%.1fs) — click to view",
                                  out.lastPathComponent, finishedAt, secs]];
                note.fileURL = [NSURL fileURLWithPath:out];
            } else {
                [note setMessage:[NSString stringWithFormat:@"Export failed at %@ (error %d)", finishedAt, rc]];
            }
            [self layoutNotifications];   // sticky: remains until the user dismisses it
        });
    });
}

@end
