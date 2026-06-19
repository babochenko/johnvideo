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

static const double kImageDuration = 4.0;
static const double kTextDuration  = 3.0;
static const CGFloat kTimelineHeight = 240.0;

// A transient bottom-right toast. If it carries a fileURL, clicking it opens
// the file (e.g. the exported movie).
@interface ToastButton : NSButton
@property(nonatomic, strong) NSURL *fileURL;
@end
@implementation ToastButton @end

// Layout: timeline pinned to the bottom, preview filling above it, and a glass
// toolbar floating over the lower part of the preview (Liquid Glass look).
@interface RootView : NSView
@property(nonatomic, strong) NSView *bar;        // glass toolbar pill
@property(nonatomic, strong) NSView *timeline;
@property(nonatomic, strong) NSView *preview;
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
    NSMutableArray<NSValue *> *_selection; // all selected clips (primary = _selected)
    NSString          *_projectPath;     // current .jvp path (Cmd+S saves here without asking)
    BOOL               _bladeMode;       // modal blade tool
    NSButton          *_bladeButton;
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
    _selection = [NSMutableArray array];
    _focusTrack = -1;

    NSRect frame = NSMakeRect(0, 0, 1000, 700);
    _window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:NO];
    [_window setTitle:@"johnvideo"];
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
    _bladeButton = mk(@"Blade", @selector(toggleBladeAction));   // leftmost; fixed slot
    _playButton = mk(@"▶", @selector(togglePlay));
    _recButton  = mk(@"● Rec", @selector(toggleRecord));
    mk(@"Import…", @selector(importMedia));
    mk(@"Export…", @selector(exportMovie));

    NSSize barSize = NSMakeSize(x - gap, bh + vpad * 2);
    inner.frame = NSMakeRect(0, 0, barSize.width, barSize.height);
    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *bar = inner;   // transparent container; capsules float over content

    _preview = [[PreviewView alloc] initWithFrame:NSZeroRect];
    _preview.host = self;
    _timelineView = [[TimelineView alloc] initWithFrame:NSZeroRect];
    _timelineView.host = self;

    RootView *content = [[RootView alloc] initWithFrame:frame];
    content.bar = bar;
    content.barSize = barSize;
    content.timeline = _timelineView;
    content.preview = _preview;
    [content addSubview:_timelineView];
    [content addSubview:_preview];
    [content addSubview:bar];           // glass floats on top of the preview
    [content setNeedsLayout:YES];
    [_window setContentView:content];

    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_timelineView];
    [NSApp activateIgnoringOtherApps:YES];
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
    if (_transportPlaying) [self stopTransport];
    _playhead = t;
    [self refreshAll];
}

- (void)selectTrack:(jv_track *)t clip:(jv_clip *)c {
    _selected = c;
    [_selection setArray:c ? @[ [NSValue valueWithPointer:c] ] : @[]];
    // Keep the navigation focus on the selected clip's track.
    if (c) {
        for (size_t i = 0; i < _timeline->track_count; i++) {
            jv_track *tr = &_timeline->tracks[i];
            for (size_t j = 0; j < tr->clip_count; j++)
                if (&tr->clips[j] == c) { _focusTrack = (NSInteger)i; return; }
        }
    }
}

- (BOOL)isClipSelected:(jv_clip *)c {
    return [_selection containsObject:[NSValue valueWithPointer:c]];
}

- (void)toggleSelectClip:(jv_clip *)c {
    if (!c) return;
    NSValue *v = [NSValue valueWithPointer:c];
    if ([_selection containsObject:v]) {
        [_selection removeObject:v];
        if (_selected == c) _selected = _selection.count ? (jv_clip *)_selection.lastObject.pointerValue : NULL;
    } else {
        [_selection addObject:v];
        _selected = c;
    }
    [self refreshAll];
}

- (void)shiftSelectionExcept:(jv_clip *)c by:(double)delta {
    for (NSValue *v in _selection) {
        jv_clip *o = (jv_clip *)v.pointerValue;
        if (o == c) continue;
        double s = o->start_time + delta;
        o->start_time = s < 0 ? 0 : s;
    }
}

- (void)nudgeSelectedBy:(double)seconds {
    if (_selection.count == 0) return;
    [self recordUndo];
    for (NSValue *v in _selection) {
        jv_clip *o = (jv_clip *)v.pointerValue;
        double s = o->start_time + seconds;
        o->start_time = s < 0 ? 0 : s;
    }
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
    if (pps < 10) pps = 10;
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
    jv_clip *c = jv_track_add_clip(vt, JV_CLIP_IMAGE, t, kImageDuration);
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

// Create a bottom-right toast (no auto-dismiss); caller manages its lifetime.
- (ToastButton *)makeToast:(NSString *)msg {
    NSView *content = _window.contentView;
    ToastButton *toast = [ToastButton buttonWithTitle:msg target:self action:@selector(toastClicked:)];
    toast.bezelStyle = NSBezelStyleRounded;
    toast.bordered = NO;
    toast.wantsLayer = YES;
    toast.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.78].CGColor;
    toast.layer.cornerRadius = 8;
    toast.contentTintColor = [NSColor whiteColor];
    toast.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self sizeToast:toast];
    [content addSubview:toast];
    return toast;
}

- (void)sizeToast:(ToastButton *)toast {
    [toast sizeToFit];
    NSSize sz = NSMakeSize(toast.frame.size.width + 28, 30);
    toast.frame = NSMakeRect(_window.contentView.bounds.size.width - sz.width - 16, 16, sz.width, sz.height);
}

- (void)fadeToast:(ToastButton *)toast after:(double)secs {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.4; toast.animator.alphaValue = 0;
        } completionHandler:^{ [toast removeFromSuperview]; }];
    });
}

// Transient toast that fades after a few seconds.
- (void)showToast:(NSString *)msg fileURL:(NSURL *)url {
    ToastButton *toast = [self makeToast:msg];
    toast.fileURL = url;
    [self fadeToast:toast after:4.0];
}

- (void)toastClicked:(ToastButton *)sender {
    if (sender.fileURL) [[NSWorkspace sharedWorkspace] openURL:sender.fileURL];
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
    jv_clip *c = jv_track_add_clip(dst, _clipboard.type, _playhead, _clipboard.duration);
    clone_clip_payload(c, &_clipboard);
    c->start_time = _playhead;
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
    [_selection removeAllObjects];
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
    _selected = c;
    [_selection setArray:@[ [NSValue valueWithPointer:c] ]];
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
    _selected = best;
    [_selection setArray:best ? @[ [NSValue valueWithPointer:best] ] : @[]];
    [self refreshAll];
}

// j (dir +1, down): wraps to the top.  k (dir -1, up): wraps to the bottom.
// With no focus yet, j starts at the top and k starts at the bottom.
- (void)focusTrack:(int)dir {
    NSInteger n = (NSInteger)_timeline->track_count;
    if (n == 0) return;
    NSInteger ti;
    if (_focusTrack < 0) ti = (dir > 0) ? 0 : n - 1;
    else ti = (_focusTrack + dir + n) % n;
    [self focusOnTrack:ti];
}

// ---- Blade tool ----
- (BOOL)bladeActive { return _bladeMode; }

- (void)toggleBlade {
    _bladeMode = !_bladeMode;
    _bladeButton.contentTintColor = _bladeMode ? [NSColor systemOrangeColor] : nil;
    _bladeButton.bordered = _bladeMode;   // subtle emphasis when armed
    [self refreshAll];
}
- (void)toggleBladeAction { [self toggleBlade]; }

- (void)bladeCutClip:(jv_clip *)c {
    if (!c) return;
    for (size_t i = 0; i < _timeline->track_count; i++) {
        jv_track *t = &_timeline->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) {
            if (&t->clips[j] == c) {
                if (_playhead <= c->start_time || _playhead >= c->start_time + c->duration) return;
                [self recordUndo];
                jv_clip *second = jv_track_split_clip(t, j, _playhead);
                if (second) [self selectTrack:t clip:second];
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
                [_selection removeObject:[NSValue valueWithPointer:clip]];
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
- (void)saveToPath:(NSString *)path {
    if (jv_project_save(_timeline, path)) {
        _projectPath = path;
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

- (void)openProject:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[ @"jvp" ];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    jv_timeline *loaded = jv_project_load(panel.URL.path);
    if (!loaded) { [self alert:@"Open failed" info:panel.URL.path]; return; }
    [self stopTransport];
    _selected = NULL;
    [_selection removeAllObjects];
    jv_timeline *old = _timeline;
    _timeline = loaded;
    _audio.timeline = _timeline;
    jv_timeline_destroy(old);
    _playhead = 0;
    _projectPath = panel.URL.path;     // subsequent Cmd+S saves here
    [self refreshAll];
}

- (void)exportMovie {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"export.mp4";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *out = panel.URL.path;
    [self stopTransport];

    // Non-blocking toast with a live elapsed timer (no modal sheet).
    ToastButton *toast = [self makeToast:@"Exporting… 0.0s"];
    double start = NSProcessInfo.processInfo.systemUptime;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *_) {
        toast.title = [NSString stringWithFormat:@"Exporting… %.1fs",
                       NSProcessInfo.processInfo.systemUptime - start];
        [self sizeToast:toast];
    }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = jv_export_mp4(self->_timeline, out.UTF8String, NULL, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            double secs = NSProcessInfo.processInfo.systemUptime - start;
            if (rc == 0) {
                toast.title = [NSString stringWithFormat:@"Exported %@ in %.1fs — click to view", out.lastPathComponent, secs];
                toast.fileURL = [NSURL fileURLWithPath:out];
            } else {
                toast.title = [NSString stringWithFormat:@"Export failed (error %d)", rc];
            }
            [self sizeToast:toast];
            [self fadeToast:toast after:8.0];
        });
    });
}

@end
