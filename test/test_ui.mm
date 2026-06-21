// johnvideo — headless UI behaviour tests.
//
// Boots a real AppDelegate (real EditorHost) with real TimelineView/PreviewView
// in an offscreen window, synthesizes NSEvents, and asserts on the resulting
// model + transport state. This exercises the actual mouseDown/Dragged/Up and
// keyDown state machines — the genuine UI behaviours, not reimplementations.
//
// Build/run: see the `test-ui` target in the Makefile.
#import <Cocoa/Cocoa.h>
#import "AppDelegate+Test.h"
#import "PreviewView+Test.h"
#include "timeline.h"

// ---- Tiny test harness ----
static int g_pass = 0, g_fail = 0;
static const char *g_case = "";
#define CASE(name) do { g_case = name; } while (0)
#define CHECK(cond, msg) do { \
    if (cond) { g_pass++; } \
    else { g_fail++; fprintf(stderr, "  FAIL [%s] %s\n", g_case, msg); } \
} while (0)
#define CHECK_EQ(a, b, msg) do { \
    double _a = (a), _b = (b); \
    if (fabs(_a - _b) < 1e-4) { g_pass++; } \
    else { g_fail++; fprintf(stderr, "  FAIL [%s] %s (got %.4f, want %.4f)\n", g_case, msg, _a, _b); } \
} while (0)

// ---- Geometry mirrors TimelineView (Editor.h constants) ----
// xForTime: kHeaderWidth + t*pps ; lanes start at kRulerHeight; track i at
// kRulerHeight + i*(kTrackHeight+kTrackGap) + kTrackGap.
static CGFloat xForTime(double t, double pps) { return kHeaderWidth + t * pps; }
static CGFloat yForTrack(size_t i) { return kRulerHeight + i * (kTrackHeight + kTrackGap) + kTrackGap + kTrackHeight / 2; }
static const CGFloat kRulerY = kRulerHeight / 2;   // a point inside the ruler

// ---- Event synthesis (dispatched directly to the view) ----
static NSEvent *mouseEv(NSEventType type, NSView *v, NSPoint p, NSEventModifierFlags m, NSInteger clicks) {
    NSPoint win = [v convertPoint:p toView:nil];   // flipped view -> window base coords
    return [NSEvent mouseEventWithType:type location:win modifierFlags:m timestamp:0
                         windowNumber:v.window.windowNumber context:nil
                          eventNumber:0 clickCount:clicks pressure:(type == NSEventTypeLeftMouseDown ? 1.0 : 0.0)];
}
// A bare click: down then up at the same point (no intervening drag).
static void click(NSView *v, NSPoint p, NSEventModifierFlags m) {
    [v mouseDown:mouseEv(NSEventTypeLeftMouseDown, v, p, m, 1)];
    [v mouseUp:mouseEv(NSEventTypeLeftMouseUp, v, p, m, 1)];
}
// A drag: down at `from`, one or more drags toward `to`, up at `to`.
static void drag(NSView *v, NSPoint from, NSPoint to, NSEventModifierFlags m) {
    [v mouseDown:mouseEv(NSEventTypeLeftMouseDown, v, from, m, 1)];
    NSPoint mid = NSMakePoint((from.x + to.x) / 2, (from.y + to.y) / 2);
    [v mouseDragged:mouseEv(NSEventTypeLeftMouseDragged, v, mid, m, 1)];
    [v mouseDragged:mouseEv(NSEventTypeLeftMouseDragged, v, to, m, 1)];
    [v mouseUp:mouseEv(NSEventTypeLeftMouseUp, v, to, m, 1)];
}

// ---- Key event synthesis ----
static void key(NSView *v, NSString *chars, NSEventModifierFlags m) {
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:m timestamp:0 windowNumber:v.window.windowNumber context:nil
        characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:0];
    [v keyDown:e];
}
static NSString *arrow(unichar fn) { return [NSString stringWithFormat:@"%C", fn]; }
#define LEFT  arrow(NSLeftArrowFunctionKey)
#define RIGHT arrow(NSRightArrowFunctionKey)
#define UP    arrow(NSUpArrowFunctionKey)
#define DOWN  arrow(NSDownArrowFunctionKey)

// Cast to the host protocol so tests can call any EditorHost method without the
// app having to re-declare each one (AppDelegate conforms privately).
static id<EditorHost> H(AppDelegate *a) { return (id<EditorHost>)a; }

// Fresh booted app with one image clip [start, start+dur] on visual track 0.
static AppDelegate *bootWithClip(double start, double dur, jv_clip **outClip) {
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *c = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, start, dur);
    if (outClip) *outClip = c;
    return app;
}

// An image clip with on-canvas geometry (so the preview can hit-test it).
static jv_clip *addCanvasImage(AppDelegate *app, double start, double dur, float cx, float cy, float scale) {
    jv_timeline *tl = [app timeline];
    jv_clip *c = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, start, dur);
    c->u.image.width = 160; c->u.image.height = 90;
    c->u.image.cx = cx; c->u.image.cy = cy; c->u.image.scale = scale;
    return c;
}

// ============================ Redline tests ============================

static void test_scrub_ruler_moves_playhead(void) {
    CASE("scrub ruler moves playhead");
    AppDelegate *app = bootWithClip(10, 2, NULL);   // clip far away so no snap interferes
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    click(tv, NSMakePoint(xForTime(3.0, pps), kRulerY), 0);
    CHECK_EQ([app playhead], 3.0, "playhead follows a ruler click");
}

static void test_scrub_empty_lane_moves_playhead(void) {
    CASE("scrub empty lane moves playhead");
    AppDelegate *app = bootWithClip(10, 2, NULL);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    click(tv, NSMakePoint(xForTime(4.0, pps), yForTrack(0)), 0);   // empty part of track 0
    CHECK_EQ([app playhead], 4.0, "playhead follows an empty-lane click");
}

static void test_click_clip_body_seeks(void) {
    CASE("bare click on clip body seeks");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    // Body midpoint ~ t=2.0 (clip spans 1..3).
    click(tv, NSMakePoint(xForTime(2.0, pps), yForTrack(0)), 0);
    CHECK_EQ([app playhead], 2.0, "playhead moves to a bare clip click");
    CHECK([app selectedClip] == c, "clip got selected");
}

static void test_drag_clip_body_keeps_playhead(void) {
    CASE("dragging clip body does NOT move playhead");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    [app seekTo:0.0];
    double y = yForTrack(0);
    drag(tv, NSMakePoint(xForTime(2.0, pps), y), NSMakePoint(xForTime(5.0, pps), y), 0);
    CHECK_EQ([app playhead], 0.0, "playhead stays put while dragging a clip");
    CHECK(c->start_time > 1.0, "the clip actually moved");
}

static void test_trim_edge_keeps_playhead(void) {
    CASE("trimming an edge does NOT move playhead");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    [app seekTo:0.0];
    // Right edge is at t=3.0 (x = 96 + 240). Grab within 8px of it and drag right.
    CGFloat rightX = xForTime(3.0, pps);
    double y = yForTrack(0);
    drag(tv, NSMakePoint(rightX - 2, y), NSMakePoint(rightX + 80, y), 0);
    CHECK_EQ([app playhead], 0.0, "playhead stays put while trimming");
    CHECK(c->duration > 2.0, "the clip got longer (trim end)");
}

static void test_seek_preserves_play_state(void) {
    CASE("seekTo preserves play/pause state");
    AppDelegate *app = bootWithClip(10, 2, NULL);
    // Paused -> stays paused.
    [app seekTo:1.0];
    CHECK(![app isPlaying], "paused seek stays paused");
    CHECK_EQ([app playhead], 1.0, "paused seek moves playhead");
    // Playing -> stays playing.
    [app forcePlay];
    [app seekTo:5.0];
    CHECK([app isPlaying], "playing seek keeps playing");
    CHECK_EQ([app playhead], 5.0, "playing seek moves playhead");
}

static void test_follow_playhead_pages_scroll(void) {
    CASE("followPlayhead pages scroll_x");
    AppDelegate *app = bootWithClip(0, 100, NULL);
    TimelineView *tv = [app tlView];
    jv_timeline *tl = [app timeline];
    double pps = [app pps];
    double span = (tv.bounds.size.width - kHeaderWidth) / pps;

    // Playhead inside the visible window -> no scroll.
    tl->scroll_x = 0;
    [app seekTo:span / 2];
    [tv followPlayhead];
    CHECK_EQ(tl->scroll_x, 0.0, "no paging while playhead is on screen");

    // Playhead past the right edge -> page so it lands at the left edge.
    [app seekTo:span + 5];
    [tv followPlayhead];
    CHECK_EQ(tl->scroll_x, span + 5, "pages right when playhead runs off the end");

    // Playhead before the left edge -> bring it back.
    tl->scroll_x = 50;
    [app seekTo:20];
    [tv followPlayhead];
    CHECK_EQ(tl->scroll_x, 20.0, "pages left when playhead is behind the window");
}

static void test_trim_left_edge(void) {
    CASE("drag left edge trims into source");
    jv_clip *c; AppDelegate *app = bootWithClip(2.0, 2.0, &c);   // spans 2..4
    TimelineView *tv = [app tlView];
    double pps = [app pps], y = yForTrack(0);
    [app seekTo:9.0];   // playhead out of the way (no snap)
    CGFloat leftX = xForTime(2.0, pps);
    drag(tv, NSMakePoint(leftX + 2, y), NSMakePoint(xForTime(1.0, pps), y), 0);
    CHECK(c->start_time < 2.0, "left edge moved left");
    CHECK(c->duration > 2.0, "duration grew");
    CHECK(c->in_offset >= 0.0, "in_offset stays valid");
}

static void test_drag_clip_between_tracks(void) {
    CASE("drag clip to another track");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    TimelineView *tv = [app tlView];
    jv_timeline *tl = [app timeline];
    double pps = [app pps];
    click(tv, NSMakePoint(xForTime(2.0, pps), yForTrack(0)), 0);   // select it
    drag(tv, NSMakePoint(xForTime(2.0, pps), yForTrack(0)),
             NSMakePoint(xForTime(2.0, pps), yForTrack(1)), 0);    // drag onto track 1
    CHECK(tl->tracks[0].clip_count == 0, "left source track");
    CHECK(tl->tracks[1].clip_count == 1, "landed on track 1 (same kind)");
}

// ---- Selection ----
static void test_selection_single_and_deselect(void) {
    CASE("single select then click-empty deselects");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    click(tv, NSMakePoint(xForTime(2.0, pps), yForTrack(0)), 0);
    CHECK([app selectedClip] == c, "clip selected");
    click(tv, NSMakePoint(xForTime(8.0, pps), yForTrack(0)), 0);   // empty space
    CHECK([app selectedClip] == NULL, "empty click deselects");
}

static void test_selection_cmd_and_shift(void) {
    CASE("cmd-click multi + shift-click range");
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *a = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 1, 1);
    jv_clip *b = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 3, 1);
    jv_clip *d = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 5, 1);
    TimelineView *tv = [app tlView];
    double pps = [app pps], y = yForTrack(0);
    click(tv, NSMakePoint(xForTime(1.5, pps), y), 0);                                 // select a
    click(tv, NSMakePoint(xForTime(3.5, pps), y), NSEventModifierFlagCommand);        // + b
    CHECK([app isClipSelected:a] && [app isClipSelected:b], "cmd-click adds to selection");
    CHECK(![app isClipSelected:d], "third clip not selected yet");
    // Re-anchor on a, then shift-click d -> a,b,d all in range.
    click(tv, NSMakePoint(xForTime(1.5, pps), y), 0);
    click(tv, NSMakePoint(xForTime(5.5, pps), y), NSEventModifierFlagShift);
    CHECK([app isClipSelected:a] && [app isClipSelected:b] && [app isClipSelected:d], "shift-click selects range");
}

static void test_select_all_key(void) {
    CASE("cmd+A selects all clips on all tracks");
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *a = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 1, 1);
    jv_clip *b = jv_track_add_clip(&tl->tracks[1], JV_CLIP_IMAGE, 1, 1);
    key([app tlView], @"a", NSEventModifierFlagCommand);
    CHECK([app isClipSelected:a] && [app isClipSelected:b], "all clips selected across tracks");
}

// ---- Keyboard transport / navigation ----
static void test_space_toggles_transport(void) {
    CASE("space toggles play/pause");
    AppDelegate *app = bootWithClip(0, 10, NULL);
    TimelineView *tv = [app tlView];
    CHECK(![app isPlaying], "starts paused");
    key(tv, @" ", 0);
    CHECK([app isPlaying], "space starts playback");
    key(tv, @" ", 0);
    CHECK(![app isPlaying], "space stops playback");
}

static void test_arrows_nudge_playhead_keep_playing(void) {
    CASE("arrows nudge playhead and keep playing");
    AppDelegate *app = bootWithClip(0, 100, NULL);
    TimelineView *tv = [app tlView];
    [app seekTo:5.0];
    [app forcePlay];
    key(tv, RIGHT, 0);
    CHECK_EQ([app playhead], 5.5, "right arrow +0.5");
    CHECK([app isPlaying], "still playing after nudge");
    key(tv, LEFT, 0);
    CHECK_EQ([app playhead], 5.0, "left arrow -0.5");
}

static void test_hl_selects_adjacent_clip(void) {
    CASE("h/l select adjacent clip");
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *a = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 1, 1);
    jv_clip *b = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 3, 1);
    TimelineView *tv = [app tlView];
    click(tv, NSMakePoint(xForTime(1.5, [app pps]), yForTrack(0)), 0);   // select a (sets focus track)
    CHECK([app selectedClip] == a, "a selected");
    key(tv, @"l", 0);
    CHECK([app selectedClip] == b, "l moves to next clip");
    key(tv, @"h", 0);
    CHECK([app selectedClip] == a, "h moves to previous clip");
}

static void test_option_arrows_move_selected(void) {
    CASE("option+arrows nudge the selected clip");
    jv_clip *c; AppDelegate *app = bootWithClip(2.0, 1.0, &c);
    TimelineView *tv = [app tlView];
    click(tv, NSMakePoint(xForTime(2.5, [app pps]), yForTrack(0)), 0);
    key(tv, RIGHT, NSEventModifierFlagOption);
    CHECK_EQ(c->start_time, 2.5, "opt+right moves clip +0.5");
    key(tv, LEFT, NSEventModifierFlagOption);
    CHECK_EQ(c->start_time, 2.0, "opt+left moves clip -0.5");
}

static void test_cmd_h_not_captured(void) {
    CASE("cmd+h is left for the system Hide (not eaten by the view)");
    jv_clip *c; AppDelegate *app = bootWithClip(2.0, 1.0, &c);
    TimelineView *tv = [app tlView];
    click(tv, NSMakePoint(xForTime(2.5, [app pps]), yForTrack(0)), 0);
    key(tv, @"h", NSEventModifierFlagCommand);   // must NOT nudge the clip anymore
    CHECK_EQ(c->start_time, 2.0, "cmd+h does not move the clip");
}

static void test_t_adds_text_clip(void) {
    CASE("t inserts a text clip");
    AppDelegate *app = bootWithClip(0, 1, NULL);
    jv_timeline *tl = [app timeline];
    size_t before = tl->tracks[0].clip_count;
    [app seekTo:3.0];
    key([app tlView], @"t", 0);
    CHECK(tl->tracks[0].clip_count == before + 1, "a clip was added");
}

static void test_delete_removes_selected_clip(void) {
    CASE("delete removes the selected clip");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 2.0, &c);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    [app seekTo:9.0];   // no marker here
    click(tv, NSMakePoint(xForTime(2.0, [app pps]), yForTrack(0)), 0);
    key(tv, [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter], 0);
    CHECK(tl->tracks[0].clip_count == 0, "clip deleted");
}

// ---- Markers ----
static void test_marker_add_and_delete(void) {
    CASE("m adds a marker, delete removes it");
    AppDelegate *app = bootWithClip(0, 10, NULL);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    [app seekTo:2.0];
    key(tv, @"m", 0);
    CHECK(tl->marker_count == 1, "marker added");
    CHECK_EQ(tl->markers[0], 2.0, "marker at playhead");
    key(tv, [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter], 0);
    CHECK(tl->marker_count == 0, "delete-at-playhead removes the marker");
}

static void test_marker_drag(void) {
    CASE("drag a marker along the ruler");
    AppDelegate *app = bootWithClip(0, 10, NULL);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    [app seekTo:2.0];
    key(tv, @"m", 0);
    double pps = [app pps];
    drag(tv, NSMakePoint(xForTime(2.0, pps), kRulerY), NSMakePoint(xForTime(6.0, pps), kRulerY), 0);
    CHECK(tl->marker_count == 1, "still one marker");
    CHECK(tl->markers[0] > 5.0, "marker moved toward the drop point");
}

// ---- Blade ----
static void test_blade_toggle_and_cut(void) {
    CASE("b arms blade; click splits a clip");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 4.0, &c);   // spans 1..5
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    key(tv, @"b", 0);
    CHECK([app bladeActive], "blade armed");
    click(tv, NSMakePoint(xForTime(3.0, [app pps]), yForTrack(0)), 0);   // cut at t=3
    CHECK(tl->tracks[0].clip_count == 2, "clip split into two");
}

// ---- Zoom ----
static void test_zoom_keys(void) {
    CASE("ctrl +/- zoom the timeline");
    AppDelegate *app = bootWithClip(0, 10, NULL);
    TimelineView *tv = [app tlView];
    double before = [app pps];
    key(tv, @"=", NSEventModifierFlagControl);
    CHECK([app pps] > before, "ctrl+= zooms in");
    double mid = [app pps];
    key(tv, @"-", NSEventModifierFlagControl);
    CHECK([app pps] < mid, "ctrl+- zooms out");
}

static void test_keyboard_zoom_anchors_playhead(void) {
    CASE("ctrl+/- zoom keeps the playhead at the same screen x");
    AppDelegate *app = bootWithClip(0, 30, NULL);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    [app seekTo:4.0];
    double x0 = kHeaderWidth + (4.0 - tl->scroll_x) * [app pps];
    key(tv, @"=", NSEventModifierFlagControl);
    double x1 = kHeaderWidth + (4.0 - tl->scroll_x) * [app pps];
    CHECK([app pps] > 80.0, "zoomed in");
    CHECK_EQ(x1, x0, "playhead stayed at the same screen x");
}

static void test_pointer_zoom_anchors_under_cursor(void) {
    CASE("mouse-anchored zoom keeps the time under the pointer fixed");
    AppDelegate *app = bootWithClip(0, 60, NULL);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    tl->scroll_x = 5.0;
    CGFloat anchorX = 600;
    double tUnder = tl->scroll_x + (anchorX - kHeaderWidth) / [app pps];
    [tv zoomToPps:[app pps] * 1.5 anchorX:anchorX];
    double tAfter = tl->scroll_x + (anchorX - kHeaderWidth) / [app pps];
    CHECK_EQ(tAfter, tUnder, "time under the anchor x preserved");
}

// ---- Audio clip volume (gain) ----
static void test_audio_volume_gain(void) {
    CASE("audio clip volume: set, clamp, audio-only, undo");
    AppDelegate *app = bootWithClip(0, 1, NULL);
    jv_timeline *tl = [app timeline];
    jv_clip *img = &tl->tracks[0].clips[0];                              // an image clip
    jv_clip *ac = jv_track_add_clip(&tl->tracks[2], JV_CLIP_AUDIO, 0, 3); // an audio clip (track 2 = audio)
    ac->u.audio.gain = 1.0f;
    [H(app) setGain:0.5f forClip:ac];
    CHECK_EQ(ac->u.audio.gain, 0.5, "gain set to 0.5");
    [H(app) setGain:10.0f forClip:ac];
    CHECK_EQ(ac->u.audio.gain, 4.0, "gain clamps to 4.0 (max +12dB)");
    [H(app) setGain:-2.0f forClip:ac];
    CHECK_EQ(ac->u.audio.gain, 0.0, "gain clamps to 0 (silent)");
    [H(app) setGain:0.8f forClip:img];   // non-audio clip: ignored, no crash
    [H(app) performUndo];                // undo the last gain change (0 -> 4.0)
    CHECK_EQ([app timeline]->tracks[2].clips[0].u.audio.gain, 4.0, "undo restores prior gain");
}

static void test_audio_gain_affects_mix(void) {
    CASE("gain scales the mixed/exported audio");
    // The exporter mixes via jv_mix_audio, so this is the render path too.
    AppDelegate *app = bootWithClip(0, 1, NULL);
    jv_timeline *tl = [app timeline];
    jv_clip *ac = jv_track_add_clip(&tl->tracks[2], JV_CLIP_AUDIO, 0, 1);
    int sr = 48000; size_t frames = sr;
    float *pcm = (float *)malloc(sizeof(float) * frames * 2);
    for (size_t i = 0; i < frames * 2; i++) pcm[i] = 0.4f;   // constant tone
    ac->u.audio.pcm = pcm; ac->u.audio.frames = frames;
    ac->u.audio.sample_rate = sr; ac->u.audio.channels = 2;

    float out[8] = {0};
    ac->u.audio.gain = 1.0f;
    jv_mix_audio(tl, 0.0, sr, 4, out);
    float full = out[0];
    memset(out, 0, sizeof out);
    [H(app) setGain:0.5f forClip:ac];
    jv_mix_audio(tl, 0.0, sr, 4, out);
    CHECK(fabs(out[0] - full * 0.5f) < 1e-4, "half gain halves the mixed sample");
    CHECK(fabs(full - 0.4f) < 1e-4, "unity gain passes the sample through");
}

// ---- Image crop (trim) ----
static void test_compositor_honors_crop(void) {
    CASE("compositor draws only the cropped sub-region");
    // White image filling the canvas; crop to the right half -> left half stays black.
    jv_timeline *tl = jv_timeline_create(100, 100, 30.0);
    jv_timeline_add_track(tl, JV_TRACK_VISUAL, "V");
    jv_clip *c = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 0, 1);
    int w = 100, h = 100;
    c->u.image.rgba = (unsigned char *)malloc(w * h * 4);
    for (int i = 0; i < w * h * 4; i++) c->u.image.rgba[i] = 255;   // opaque white
    c->u.image.width = w; c->u.image.height = h;
    c->u.image.cx = 0.5f; c->u.image.cy = 0.5f; c->u.image.scale = 1.0f;
    c->u.image.crop_x = 0.5f; c->u.image.crop_y = 0.0f; c->u.image.crop_w = 0.5f; c->u.image.crop_h = 1.0f;

    unsigned char *out = (unsigned char *)malloc(100 * 100 * 4);
    jv_render_frame(tl, 0.0, out, 100, 100);
    // Sample a left-half pixel (should be black) and a right-half pixel (white).
    unsigned char *left  = &out[(50 * 100 + 25) * 4];
    unsigned char *right = &out[(50 * 100 + 75) * 4];
    CHECK(left[0] < 10, "left (cropped-out) half is black");
    CHECK(right[0] > 245, "right (kept) half is white");
    free(out); jv_timeline_destroy(tl);
}

static void test_crop_button_enters_and_commits(void) {
    CASE("crop button enters trim mode; drag + button commits a crop");
    AppDelegate *app = bootWithClip(0, 0, NULL);
    [app timeline]->tracks[0].clip_count = 0;
    jv_clip *c = addCanvasImage(app, 0, 5, 0.5f, 0.5f, 0.8f);   // big enough to hit-test
    [app seekTo:1.0];
    [H(app) selectTrack:NULL clip:c];
    PreviewView *pv = [app pvView];
    [pv layoutForTest];

    NSRect btn = [pv cropButtonForClip:c];
    NSPoint btnC = NSMakePoint(NSMidX(btn), NSMidY(btn));
    click(pv, btnC, 0);                                  // enter crop mode
    CHECK([pv isCropping], "crop mode entered");
    CHECK(c->u.image.crop_w >= 0.999f, "clip shows full image while cropping");

    // Drag the top-left corner of the (currently-full) frame inward.
    NSRect dr = [pv cropButtonForClip:c];   // recompute after entering (frame=full)
    (void)dr;
    [pv layoutForTest];
    // Full-image display rect corners: drag TL corner toward the center.
    // Recompute the frame: full image == display rect.
    // Approximate TL via the preview bounds-derived display rect.
    NSRect vb = pv.bounds;   // image cx=cy=0.5 scale 0.8 -> centered
    CGFloat ih = 0.8f * vb.size.height, iw = ih * 160.0 / 90.0;
    NSPoint mid = NSMakePoint(NSMidX(vb), NSMidY(vb));
    NSPoint tl = NSMakePoint(mid.x - iw/2, mid.y + ih/2);          // top-left (screen y-up)
    drag(pv, tl, NSMakePoint(mid.x, mid.y), 0);                    // shrink to ~bottom-right quadrant

    NSRect btn2 = [pv cropButtonForClip:c];
    click(pv, NSMakePoint(NSMidX(btn2), NSMidY(btn2)), 0);         // commit
    CHECK(![pv isCropping], "crop mode committed/exited");
    CHECK(c->u.image.crop_w < 0.9f && c->u.image.crop_h < 0.9f, "a smaller crop was applied");
}

// ---- In-place text editing (notes-app caret semantics) ----
// Boot, add a text clip (begins editing with "Text" selected), then replace it
// with a known multi-line/multi-word string. Caret ends at the document end.
//   "hello world\nfoo bar"  indices: h0..d10 \n11 f12 o13 o14 ' '15 b16 a17 r18  (len 19)
static PreviewView *bootEditingText(AppDelegate **outApp) {
    AppDelegate *app = bootWithClip(0, 5, NULL);
    [app seekTo:0.0];
    key([app tlView], @"t", 0);          // adds a text clip + begins editing on the preview
    PreviewView *pv = [app pvView];
    key(pv, @"hello world", 0);          // replaces the selected "Text"
    key(pv, [NSString stringWithFormat:@"%C", (unichar)0x0D], 0);   // newline
    key(pv, @"foo bar", 0);
    if (outApp) *outApp = app;
    return pv;
}

static void test_text_typing_and_selall(void) {
    CASE("typing replaces selection; cmd+A reselects");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    CHECK([pv isEditing], "editing active");
    CHECK([[pv editText] isEqualToString:@"hello world\nfoo bar"], "typed text assembled");
    CHECK([pv editCaret] == 19, "caret at end after typing");
    key(pv, @"a", NSEventModifierFlagCommand);
    CHECK([pv editSelAll], "cmd+A selects all");
}

static void test_text_plain_arrows(void) {
    CASE("plain arrows move caret by char / line");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, LEFT, 0);
    CHECK([pv editCaret] == 18, "left arrow -1 char");
    key(pv, RIGHT, 0);
    CHECK([pv editCaret] == 19, "right arrow +1 char");
    key(pv, UP, 0);   // from col 7 of line 2 -> line 1 col 7
    CHECK([pv editCaret] == 7, "up arrow keeps column on previous line");
}

static void test_text_cmd_arrows_line_doc(void) {
    CASE("cmd+arrows -> line/document ends");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, LEFT, NSEventModifierFlagCommand);
    CHECK([pv editCaret] == 12, "cmd+left -> start of current line");
    key(pv, RIGHT, NSEventModifierFlagCommand);
    CHECK([pv editCaret] == 19, "cmd+right -> end of current line");
    key(pv, UP, NSEventModifierFlagCommand);
    CHECK([pv editCaret] == 0, "cmd+up -> document start");
    key(pv, DOWN, NSEventModifierFlagCommand);
    CHECK([pv editCaret] == 19, "cmd+down -> document end");
}

static void test_text_option_arrows_word(void) {
    CASE("option+arrows -> word boundaries");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, LEFT, NSEventModifierFlagOption);
    CHECK([pv editCaret] == 16, "opt+left -> start of 'bar'");
    key(pv, LEFT, NSEventModifierFlagOption);
    CHECK([pv editCaret] == 12, "opt+left -> start of 'foo'");
    key(pv, RIGHT, NSEventModifierFlagOption);
    CHECK([pv editCaret] == 15, "opt+right -> end of 'foo' (after the last letter)");
}

static void test_text_backspace_and_newline(void) {
    CASE("backspace deletes; return inserts newline");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter], 0);
    CHECK([[pv editText] isEqualToString:@"hello world\nfoo ba"], "backspace removed last char");
    key(pv, [NSString stringWithFormat:@"%C", (unichar)0x0D], 0);
    CHECK([[pv editText] isEqualToString:@"hello world\nfoo ba\n"], "return inserts newline");
}

// ---- Scrubbing while playing (today's request, end-to-end via events) ----
static void test_scrub_while_playing_keeps_playing(void) {
    CASE("clicking the timeline while playing keeps playing");
    AppDelegate *app = bootWithClip(20, 2, NULL);   // clip far away (no snap)
    TimelineView *tv = [app tlView];
    [app forcePlay];
    click(tv, NSMakePoint(xForTime(3.0, [app pps]), kRulerY), 0);
    CHECK([app isPlaying], "still playing after a ruler scrub");
    CHECK_EQ([app playhead], 3.0, "playhead moved to the scrub point");
}

// ---- Snapping ----
static void test_scrub_snaps_to_clip_edge(void) {
    CASE("scrub snaps to a nearby clip boundary");
    bootWithClip(2.0, 2.0, NULL);   // edges at 2.0 and 4.0
    AppDelegate *app = bootWithClip(2.0, 2.0, NULL);
    TimelineView *tv = [app tlView];
    double pps = [app pps];
    // 0.05s away from the edge (< 8px/pps = 0.1s) -> snaps to exactly 2.0.
    click(tv, NSMakePoint(xForTime(2.05, pps), kRulerY), 0);
    CHECK_EQ([app playhead], 2.0, "snapped to the clip start");
}

static void test_move_snaps_to_neighbor_edge(void) {
    CASE("dragging a clip snaps to a neighbour's edge");
    jv_clip *c; AppDelegate *app = bootWithClip(2.0, 2.0, &c);   // dragged clip [2,4], dur 2
    jv_timeline *tl = [app timeline];
    jv_track_add_clip(&tl->tracks[1], JV_CLIP_IMAGE, 6.0, 2.0);   // neighbour [6,8] on track 1
    TimelineView *tv = [app tlView];
    double pps = [app pps], y = yForTrack(0);
    [app seekTo:0.0];   // playhead far away
    // Grab at center (t=3.0, offset 1.0); drop so start lands ~5.95 -> snaps to 6.0
    // (end ~7.95 also aligns to the neighbour's 8.0, so the snap fires).
    drag(tv, NSMakePoint(xForTime(3.0, pps), y), NSMakePoint(xForTime(6.95, pps), y), 0);
    CHECK_EQ(c->start_time, 6.0, "clip start snapped to the neighbour's start");
}

// ---- Track navigation: j/k focus ----
static void test_jk_focus_track(void) {
    CASE("j/k focus the next/prev non-empty track");
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *a = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 1, 1);   // Video 1
    jv_clip *b = jv_track_add_clip(&tl->tracks[1], JV_CLIP_IMAGE, 1, 1);   // Video 2
    TimelineView *tv = [app tlView];
    key(tv, @"j", 0);
    CHECK([app selectedClip] == a, "j focuses first non-empty track");
    key(tv, @"j", 0);
    CHECK([app selectedClip] == b, "j moves to next non-empty track");
}

// ---- Playhead jumps: cmd+arrows (start/marks/end), ctrl+arrows (markers) ----
static void test_cmd_arrows_jump_start_end(void) {
    CASE("cmd+arrows jump through {start, marks, end}");
    AppDelegate *app = bootWithClip(0, 8, NULL);   // duration 8
    TimelineView *tv = [app tlView];
    [app seekTo:3.0];
    key(tv, RIGHT, NSEventModifierFlagCommand);
    CHECK_EQ([app playhead], 8.0, "cmd+right jumps to the end");
    key(tv, LEFT, NSEventModifierFlagCommand);
    CHECK_EQ([app playhead], 0.0, "cmd+left jumps back to the start");
}

static void test_ctrl_arrows_jump_markers(void) {
    CASE("ctrl+arrows jump between markers");
    AppDelegate *app = bootWithClip(0, 10, NULL);
    jv_timeline *tl = [app timeline];
    jv_timeline_add_marker(tl, 2.0);
    jv_timeline_add_marker(tl, 6.0);
    TimelineView *tv = [app tlView];
    [app seekTo:0.0];
    key(tv, RIGHT, NSEventModifierFlagControl);
    CHECK_EQ([app playhead], 2.0, "ctrl+right -> first marker");
    key(tv, RIGHT, NSEventModifierFlagControl);
    CHECK_EQ([app playhead], 6.0, "ctrl+right -> next marker");
    key(tv, LEFT, NSEventModifierFlagControl);
    CHECK_EQ([app playhead], 2.0, "ctrl+left -> previous marker");
}

// ---- History: undo / redo ----
static void test_undo_redo(void) {
    CASE("undo/redo a clip move");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 1.0, &c);
    TimelineView *tv = [app tlView];
    jv_timeline *tl = [app timeline];
    click(tv, NSMakePoint(xForTime(1.5, [app pps]), yForTrack(0)), 0);   // select
    key(tv, RIGHT, NSEventModifierFlagOption);                          // move +0.5 (records undo)
    CHECK_EQ(tl->tracks[0].clips[0].start_time, 1.5, "moved to 1.5");
    [H(app) performUndo];
    CHECK_EQ([app timeline]->tracks[0].clips[0].start_time, 1.0, "undo restores 1.0");
    [H(app) performRedo];
    CHECK_EQ([app timeline]->tracks[0].clips[0].start_time, 1.5, "redo reapplies 1.5");
}

// ---- Clipboard: copy / paste ----
static void test_copy_paste_clip(void) {
    CASE("copy then paste duplicates a clip");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 1.0, &c);
    TimelineView *tv = [app tlView];
    jv_timeline *tl = [app timeline];
    click(tv, NSMakePoint(xForTime(1.5, [app pps]), yForTrack(0)), 0);
    [H(app) copySelectedClip];
    [app seekTo:5.0];
    BOOL pasted = [H(app) pasteClipAtPlayhead];
    CHECK(pasted, "paste reports success");
    CHECK(tl->tracks[0].clip_count == 2, "a second clip now exists");
}

static void test_clipboard_prefers_newer_system_copy(void) {
    CASE("a newer system copy wins over the internal clip clipboard");
    jv_clip *c; AppDelegate *app = bootWithClip(1.0, 1.0, &c);
    TimelineView *tv = [app tlView];
    click(tv, NSMakePoint(xForTime(1.5, [app pps]), yForTrack(0)), 0);   // select
    [H(app) copySelectedClip];                                           // internal copy
    CHECK([H(app) pasteClipAtPlayhead], "internal clip pastes right after copying it");
    // Simulate copying elsewhere (e.g. an image in a browser): bump the pasteboard.
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:@"newer" forType:NSPasteboardTypeString];
    CHECK(![H(app) pasteClipAtPlayhead], "defers to the newer system pasteboard");
}

// ---- Tracks: add / remove / reorder ----
static void test_add_remove_track(void) {
    CASE("add and remove tracks");
    AppDelegate *app = bootWithClip(0, 1, NULL);
    jv_timeline *tl = [app timeline];
    size_t before = tl->track_count;
    [H(app) addTrackOfKind:JV_TRACK_VISUAL];
    CHECK(tl->track_count == before + 1, "track added");
    [H(app) removeTrackAtIndex:tl->track_count - 1];
    CHECK(tl->track_count == before, "track removed");
}

static void test_track_reorder_drag(void) {
    CASE("drag a track header to reorder");
    AppDelegate *app = bootWithClip(0, 1, NULL);
    jv_timeline *tl = [app timeline];
    TimelineView *tv = [app tlView];
    // Tracks: 0=Video 1, 1=Video 2. Drag header 0 down onto row 1.
    drag(tv, NSMakePoint(kHeaderWidth / 2, yForTrack(0)), NSMakePoint(kHeaderWidth / 2, yForTrack(1)), 0);
    CHECK(strcmp(tl->tracks[0].name, "Video 2") == 0, "Video 2 is now first");
}

// ---- Scroll: horizontal pan via scroll wheel ----
static void test_scroll_pans_time(void) {
    CASE("horizontal scroll pans the timeline");
    AppDelegate *app = bootWithClip(0, 100, NULL);
    TimelineView *tv = [app tlView];
    jv_timeline *tl = [app timeline];
    tl->scroll_x = 0;
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, -200);
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    [tv scrollWheel:e];
    CFRelease(cg);
    CHECK(tl->scroll_x > 0, "scroll_x advanced (panned right)");
}

// ---- Blade disarm ----
static void test_blade_toggle_off(void) {
    CASE("b toggles the blade off again");
    AppDelegate *app = bootWithClip(0, 4, NULL);
    TimelineView *tv = [app tlView];
    key(tv, @"b", 0);
    CHECK([app bladeActive], "armed");
    key(tv, @"b", 0);
    CHECK(![app bladeActive], "disarmed");
}

// ---- Group move-together ----
static void test_group_nudge_together(void) {
    CASE("cmd+l nudges the whole multi-selection");
    AppDelegate *app = [[AppDelegate alloc] init];
    [app bootForTestWithSize:NSMakeSize(1000, 400)];
    jv_timeline *tl = [app timeline];
    jv_clip *a = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 1, 1);
    jv_clip *b = jv_track_add_clip(&tl->tracks[0], JV_CLIP_IMAGE, 4, 1);
    TimelineView *tv = [app tlView];
    double pps = [app pps], y = yForTrack(0);
    click(tv, NSMakePoint(xForTime(1.5, pps), y), 0);
    click(tv, NSMakePoint(xForTime(4.5, pps), y), NSEventModifierFlagCommand);
    key(tv, RIGHT, NSEventModifierFlagOption);
    CHECK_EQ(a->start_time, 1.5, "first clip moved +0.5");
    CHECK_EQ(b->start_time, 4.5, "second clip moved +0.5 too");
}

// ---- Reopen last project (today's request) ----
static void test_reopen_last_project(void) {
    CASE("the last-open project reopens on next launch");
    NSString *path = @"/tmp/jv_reopen_test.jvp";
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    // Session 1: build, save (persists the path to user defaults).
    AppDelegate *a1 = bootWithClip(2.5, 1.5, NULL);
    [a1 timeline]->tracks[0].clips[0].start_time = 2.5;
    [a1 seekTo:1.25];
    [a1 saveToPath:path];
    CHECK([[a1 projectPath] isEqualToString:path], "save remembers the path");
    // Session 2: a fresh coordinator reopens it from user defaults.
    AppDelegate *a2 = [[AppDelegate alloc] init];
    [a2 bootForTestWithSize:NSMakeSize(1000, 400)];
    BOOL reopened = [a2 reopenLastProject];
    CHECK(reopened, "reopenLastProject loaded a file");
    CHECK([[a2 projectPath] isEqualToString:path], "reopened the same path");
    CHECK([a2 timeline]->tracks[0].clip_count == 1, "the saved clip came back");
    CHECK_EQ([a2 timeline]->tracks[0].clips[0].start_time, 2.5, "clip position restored");
    CHECK_EQ([a2 playhead], 1.25, "playhead restored");
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// ---- Text editing: commit + in-editor clipboard ----
static void test_text_esc_commits(void) {
    CASE("Esc commits the text edit");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, [NSString stringWithFormat:@"%C", (unichar)0x1B], 0);   // esc
    CHECK(![pv isEditing], "editing ended on Esc");
    CHECK([app selectedClip] && [app selectedClip]->u.text.string &&
          strcmp([app selectedClip]->u.text.string, "hello world\nfoo bar") == 0, "text committed to the clip");
}

static void test_text_clipboard_cut_paste(void) {
    CASE("Cmd+A/X then Cmd+V in the editor");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);
    key(pv, @"a", NSEventModifierFlagCommand);   // select all
    key(pv, @"x", NSEventModifierFlagCommand);   // cut -> empties
    CHECK([[pv editText] length] == 0, "cut empties the field");
    key(pv, @"v", NSEventModifierFlagCommand);   // paste back
    CHECK([[pv editText] isEqualToString:@"hello world\nfoo bar"], "paste restores the text");
}

static void test_text_double_click_edits_on_canvas(void) {
    CASE("double-click a text clip on the canvas edits it");
    AppDelegate *app = bootWithClip(0, 5, NULL);
    [app seekTo:0.0];
    key([app tlView], @"t", 0);          // make a text clip (begins editing)
    PreviewView *pv = [app pvView];
    key(pv, [NSString stringWithFormat:@"%C", (unichar)0x1B], 0);   // commit so we can re-open
    CHECK(![pv isEditing], "not editing after commit");
    [pv layoutForTest];
    jv_clip *txt = [app selectedClip];
    NSPoint center = NSZeroPoint;   // text clip is at cx=cy=0.5 -> view center
    NSRect b = pv.bounds; center = NSMakePoint(NSMidX(b), NSMidY(b));
    (void)txt;
    [pv mouseDown:mouseEv(NSEventTypeLeftMouseDown, pv, center, 0, 2)];   // double-click
    [pv mouseUp:mouseEv(NSEventTypeLeftMouseUp, pv, center, 0, 2)];
    CHECK([pv isEditing], "double-click re-entered editing");
}

// ---- Canvas: move / resize / rotate ----
static void test_canvas_move_clip(void) {
    CASE("drag a clip on the canvas moves it");
    AppDelegate *app = bootWithClip(0, 0, NULL);   // placeholder track exists
    [app timeline]->tracks[0].clip_count = 0;       // drop the empty placeholder clip
    jv_clip *c = addCanvasImage(app, 0, 5, 0.5f, 0.5f, 0.3f);
    [app seekTo:1.0];                               // clip active
    PreviewView *pv = [app pvView];
    [pv layoutForTest];
    NSRect vb = pv.bounds;
    NSPoint from = NSMakePoint(NSMidX(vb), NSMidY(vb));        // clip center
    NSPoint to   = NSMakePoint(NSMidX(vb) - 150, NSMidY(vb));  // well clear of center snap
    drag(pv, from, to, 0);
    CHECK(c->u.image.cx < 0.5f, "clip center moved left");
}

static void test_canvas_resize_clip(void) {
    CASE("drag the resize handle scales the clip");
    AppDelegate *app = bootWithClip(0, 0, NULL);
    [app timeline]->tracks[0].clip_count = 0;
    jv_clip *c = addCanvasImage(app, 0, 5, 0.5f, 0.5f, 0.3f);
    [app seekTo:1.0];
    [H(app) selectTrack:NULL clip:c];               // resize handle only when selected
    PreviewView *pv = [app pvView];
    [pv layoutForTest];
    // Resize handle is at the clip's bottom-right; drag it further out.
    CGFloat h = 0.3f * pv.bounds.size.height;
    CGFloat aspectW = h * 160.0 / 90.0;
    NSPoint mid = NSMakePoint(NSMidX(pv.bounds), NSMidY(pv.bounds));
    NSPoint handle = NSMakePoint(mid.x + aspectW / 2, mid.y - h / 2);
    float before = c->u.image.scale;
    drag(pv, handle, NSMakePoint(handle.x, handle.y - 80), 0);   // pull down -> bigger
    CHECK(c->u.image.scale > before, "scale increased");
    // Anchored at the top-left corner: growing pushes the center toward the
    // bottom-right (cy is top-down), instead of staying put at 0.5/0.5.
    CHECK(c->u.image.cx > 0.5f, "center moved right (left edge anchored)");
    CHECK(c->u.image.cy > 0.5f, "center moved down (top edge anchored)");
}

static void test_canvas_rotate_snaps_90(void) {
    CASE("rotate handle snaps to 90 degrees");
    AppDelegate *app = bootWithClip(0, 0, NULL);
    [app timeline]->tracks[0].clip_count = 0;
    jv_clip *c = addCanvasImage(app, 0, 5, 0.5f, 0.5f, 0.3f);
    [app seekTo:1.0];
    [H(app) selectTrack:NULL clip:c];
    PreviewView *pv = [app pvView];
    [pv layoutForTest];
    CGFloat h = 0.3f * pv.bounds.size.height;
    NSPoint mid = NSMakePoint(NSMidX(pv.bounds), NSMidY(pv.bounds));
    NSPoint rotHandle = NSMakePoint(mid.x, mid.y + h / 2 + 22);
    // Drag the rotate handle to roughly the 3-o'clock direction (~90 deg).
    drag(pv, rotHandle, NSMakePoint(mid.x + 120, mid.y), 0);
    CHECK(fabs(fabs(c->u.image.rotation) - M_PI_2) < 0.05, "rotation snapped to 90 deg");
}

static void test_canvas_click_empty_deselects(void) {
    CASE("clicking empty canvas deselects");
    AppDelegate *app = bootWithClip(0, 0, NULL);
    [app timeline]->tracks[0].clip_count = 0;
    jv_clip *c = addCanvasImage(app, 0, 5, 0.5f, 0.5f, 0.3f);
    [app seekTo:1.0];
    [H(app) selectTrack:NULL clip:c];
    PreviewView *pv = [app pvView];
    [pv layoutForTest];
    click(pv, NSMakePoint(2, 2), 0);   // corner, outside the clip
    CHECK([app selectedClip] == NULL, "selection cleared");
}

static void test_text_option_backspace_deletes_word(void) {
    CASE("option+backspace deletes the previous word");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);   // "hello world\nfoo bar", caret 19
    unichar bs = NSDeleteCharacter;
    key(pv, [NSString stringWithFormat:@"%C", bs], NSEventModifierFlagOption);
    CHECK([[pv editText] isEqualToString:@"hello world\nfoo "], "deleted 'bar'");
    key(pv, [NSString stringWithFormat:@"%C", bs], NSEventModifierFlagOption);
    CHECK([[pv editText] isEqualToString:@"hello world\n"], "deleted 'foo '");
}

static void test_text_cmd_backspace_deletes_to_line_start(void) {
    CASE("cmd+backspace deletes to the start of the line");
    AppDelegate *app; PreviewView *pv = bootEditingText(&app);   // caret at end of line 2
    unichar bs = NSDeleteCharacter;
    key(pv, [NSString stringWithFormat:@"%C", bs], NSEventModifierFlagCommand);
    CHECK([[pv editText] isEqualToString:@"hello world\n"], "cleared the current line");
    CHECK([pv editCaret] == 12, "caret at the line start");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];   // needed for NSWindow / NSView

        // Redline / playhead
        test_scrub_ruler_moves_playhead();
        test_scrub_empty_lane_moves_playhead();
        test_click_clip_body_seeks();
        test_drag_clip_body_keeps_playhead();
        test_trim_edge_keeps_playhead();
        test_seek_preserves_play_state();
        test_follow_playhead_pages_scroll();

        // Clip move / trim / track move
        test_trim_left_edge();
        test_drag_clip_between_tracks();

        // Selection
        test_selection_single_and_deselect();
        test_selection_cmd_and_shift();
        test_select_all_key();

        // Keyboard transport / navigation
        test_space_toggles_transport();
        test_arrows_nudge_playhead_keep_playing();
        test_hl_selects_adjacent_clip();
        test_option_arrows_move_selected();
        test_cmd_h_not_captured();
        test_t_adds_text_clip();
        test_delete_removes_selected_clip();

        // Markers / blade / zoom
        test_marker_add_and_delete();
        test_marker_drag();
        test_blade_toggle_and_cut();
        test_zoom_keys();

        // In-place text editing (notes-app caret semantics)
        test_text_typing_and_selall();
        test_text_plain_arrows();
        test_text_cmd_arrows_line_doc();
        test_text_option_arrows_word();
        test_text_backspace_and_newline();
        test_text_esc_commits();
        test_text_clipboard_cut_paste();
        test_text_double_click_edits_on_canvas();
        test_text_option_backspace_deletes_word();
        test_text_cmd_backspace_deletes_to_line_start();

        // Scrub-while-playing + snapping
        test_scrub_while_playing_keeps_playing();
        test_scrub_snaps_to_clip_edge();
        test_move_snaps_to_neighbor_edge();

        // Navigation / jumps
        test_jk_focus_track();
        test_cmd_arrows_jump_start_end();
        test_ctrl_arrows_jump_markers();

        // History / clipboard
        test_undo_redo();
        test_copy_paste_clip();
        test_clipboard_prefers_newer_system_copy();

        // Tracks / scroll / blade / group
        test_add_remove_track();
        test_track_reorder_drag();
        test_scroll_pans_time();
        test_blade_toggle_off();
        test_group_nudge_together();
        test_keyboard_zoom_anchors_playhead();
        test_pointer_zoom_anchors_under_cursor();
        test_audio_volume_gain();
        test_audio_gain_affects_mix();
        test_compositor_honors_crop();
        test_crop_button_enters_and_commits();

        // Project persistence
        test_reopen_last_project();

        // Canvas (preview) interactions
        test_canvas_move_clip();
        test_canvas_resize_clip();
        test_canvas_rotate_snaps_90();
        test_canvas_click_empty_deselects();

        fprintf(stderr, "\ntest_ui: %d passed, %d failed\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
}
