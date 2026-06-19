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

static const double kImageDuration = 4.0;
static const double kTextDuration  = 3.0;
static const CGFloat kTimelineHeight = 240.0;

// Layout: timeline pinned to the bottom, preview filling above it, and a glass
// toolbar floating over the lower part of the preview (Liquid Glass look).
@interface RootView : NSView
@property(nonatomic, strong) NSView *bar;        // glass toolbar pill
@property(nonatomic, strong) NSView *timeline;
@property(nonatomic, strong) NSView *preview;
@property(nonatomic, assign) NSSize  barSize;
@end

@implementation RootView
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self setNeedsLayout:YES]; }
- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat bw = self.barSize.width, bh = self.barSize.height;
    CGFloat barY = 12;                                  // glass pill at the bottom
    self.bar.frame = NSMakeRect((w - bw) / 2, barY, bw, bh);
    CGFloat tlY = barY + bh + 12;
    self.timeline.frame = NSMakeRect(0, tlY, w, kTimelineHeight);
    CGFloat py = tlY + kTimelineHeight;
    self.preview.frame  = NSMakeRect(0, py, w, h - py > 0 ? h - py : 0);
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

    NSRect frame = NSMakeRect(0, 0, 1000, 700);
    _window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:NO];
    [_window setTitle:@"johnvideo"];
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    [_window center];

    // Compact row of rounded buttons inside a small floating glass pill.
    const CGFloat bh = 28, gap = 6, padEnds = 10;
    NSView *inner = [[NSView alloc] init];
    NSButton *(^mk)(NSString *, SEL, CGFloat *) = ^NSButton *(NSString *title, SEL sel, CGFloat *x) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
        b.bezelStyle = NSBezelStyleRounded;
        [b sizeToFit];
        NSRect f = b.frame; f.origin = NSMakePoint(*x, 6); f.size.height = bh;
        b.frame = f;
        *x += f.size.width + gap;
        [inner addSubview:b];
        return b;
    };
    CGFloat x = padEnds;
    _playButton = mk(@"Play", @selector(togglePlay), &x);
    _recButton  = mk(@"● Rec", @selector(toggleRecord), &x);
    mk(@"Import…", @selector(importMedia), &x);
    mk(@"Export…", @selector(exportMovie), &x);

    NSSize barSize = NSMakeSize(x - gap + padEnds, bh + 12);
    inner.frame = NSMakeRect(0, 0, barSize.width, barSize.height);
    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *bar;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:inner.frame];
        glass.cornerRadius = barSize.height / 2;
        glass.contentView = inner;
        bar = glass;
    } else {
        NSVisualEffectView *vev = [[NSVisualEffectView alloc] initWithFrame:inner.frame];
        vev.material = NSVisualEffectMaterialHUDWindow;
        vev.state = NSVisualEffectStateActive;
        vev.wantsLayer = YES;
        vev.layer.cornerRadius = barSize.height / 2;
        vev.layer.masksToBounds = YES;
        [vev addSubview:inner];
        bar = vev;
    }

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

- (void)selectTrack:(jv_track *)t clip:(jv_clip *)c { _selected = c; }

- (void)setPixelsPerSecond:(double)pps {
    if (pps < 10) pps = 10;
    if (pps > 600) pps = 600;
    _pps = pps;
    [self refreshAll];
}

- (void)addTrackOfKind:(jv_track_kind)kind {
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
    // Clear selection if it lived on this track.
    jv_track *t = &_timeline->tracks[index];
    for (size_t j = 0; j < t->clip_count; j++)
        if (&t->clips[j] == _selected) _selected = NULL;
    jv_timeline_remove_track(_timeline, index);
    [self refreshAll];
}

- (void)addImageData:(NSData *)data path:(NSString *)path atTime:(double)t {
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
    _transportPlaying = YES;
    [self startClockFrom:_playhead];
    [_audio playFrom:_playhead];          // best effort; visuals don't depend on it
    _playButton.title = @"Pause";
    [self startTick];
}

- (void)stopTransport {
    if (!_transportPlaying) return;
    _transportPlaying = NO;
    [_audio stop];
    [self stopTick];
    _playButton.title = @"Play";
}

- (void)updatePlayButton { _playButton.title = _transportPlaying ? @"Pause" : @"Play"; }

- (void)startTick {
    [self stopTick];
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *_) {
        double elapsed = NSProcessInfo.processInfo.systemUptime - self->_clockWall;
        self->_playhead = self->_clockHead + elapsed;
        // Stop at the end only while playing back (recording may run past it).
        double dur = jv_timeline_duration(self->_timeline);
        if (self->_transportPlaying && dur > 0 && self->_playhead >= dur) {
            self->_playhead = dur;
            [self stopTransport];
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
                self->_recButton.title = @"■ Stop";
                [self startTick];
            });
        }];
        return;
    }

    {
        size_t frames = 0; int sr = 0;
        float *pcm = [_audio stopRecordingFrames:&frames sampleRate:&sr];
        [self stopTick];
        [self updatePlayButton];
        _recButton.title = @"● Rec";
        if (pcm && frames) {
            jv_track *vo = [self firstTrackOfKind:JV_TRACK_AUDIO];
            jv_clip *c = jv_track_add_clip(vo, JV_CLIP_AUDIO, _recStartHead, (double)frames / sr);
            c->u.audio.pcm = pcm;
            c->u.audio.frames = frames;
            c->u.audio.sample_rate = sr;
            c->u.audio.channels = 2;
            c->u.audio.gain = 1.0f;
            c->u.audio.path = strdup("voiceover");
        } else {
            free(pcm);
        }
        [self refreshAll];
    }
}

- (void)importMedia {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] == NSModalResponseOK && panel.URL)
        [self importMediaPath:panel.URL.path atTime:_playhead];
}

- (void)exportMovie {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"export.mp4";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *out = panel.URL.path;

    [self stopTransport];

    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    spin.indeterminate = NO; spin.minValue = 0; spin.maxValue = 1;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Exporting…";
    alert.accessoryView = spin;
    // Show non-modally while the background thread runs.
    NSWindow *sheet = _window;
    [alert beginSheetModalForWindow:sheet completionHandler:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = jv_export_mp4(self->_timeline, out.UTF8String, NULL, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            [sheet endSheet:alert.window];
            NSAlert *done = [[NSAlert alloc] init];
            done.messageText = rc == 0 ? @"Export complete" : @"Export failed";
            done.informativeText = rc == 0 ? out : [NSString stringWithFormat:@"error %d", rc];
            [done runModal];
        });
    });
}

@end
