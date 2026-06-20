// Round-trip test: build a timeline, save .jvp, load it back, verify fields.
#import <Cocoa/Cocoa.h>
#import "Project.h"
#include "timeline.h"
#include <stdio.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, msg) do { if (!(cond)) { g_fail++; fprintf(stderr, "  FAIL %s\n", msg); } } while (0)

int main(void) {
    @autoreleasepool {
        jv_timeline *tl = jv_timeline_create(1280, 720, 25.0);
        jv_track *v = jv_timeline_add_track(tl, JV_TRACK_VISUAL, "Video 1");
        jv_timeline_add_track(tl, JV_TRACK_AUDIO, "Music");
        tl->pixels_per_second = 42.0; tl->playhead = 1.5; tl->scroll_x = 2.0;
        jv_timeline_add_marker(tl, 3.25);

        // Text clip.
        jv_clip *tc = jv_track_add_clip(v, JV_CLIP_TEXT, 1.0, 3.0);
        tc->u.text.string = strdup("Hello World");
        tc->u.text.font_size = 64; tc->u.text.color = 0xFFFFFFFF;
        tc->u.text.cx = 0.5; tc->u.text.cy = 0.4; tc->u.text.rotation = 0.3f;

        // Synthetic image clip (no path -> PNG sidecar).
        jv_clip *ic = jv_track_add_clip(v, JV_CLIP_IMAGE, 0.0, 2.0);
        int w = 8, h = 8; ic->u.image.rgba = (unsigned char *)malloc(w*h*4);
        for (int i = 0; i < w*h; i++) { ic->u.image.rgba[i*4]=200; ic->u.image.rgba[i*4+1]=50; ic->u.image.rgba[i*4+2]=50; ic->u.image.rgba[i*4+3]=255; }
        ic->u.image.width = w; ic->u.image.height = h; ic->u.image.scale = 0.6f; ic->u.image.cx = 0.3f; ic->u.image.cy = 0.3f;

        // Audio clip with a non-unity gain + synthetic PCM (saved as a WAV sidecar).
        jv_track *mt = &tl->tracks[1];
        jv_clip *ac = jv_track_add_clip(mt, JV_CLIP_AUDIO, 0.0, 1.0);
        int sr = 48000; size_t fr = sr;
        ac->u.audio.pcm = (float *)malloc(sizeof(float) * fr * 2);
        for (size_t i = 0; i < fr * 2; i++) ac->u.audio.pcm[i] = 0.25f;
        ac->u.audio.frames = fr; ac->u.audio.sample_rate = sr; ac->u.audio.channels = 2;
        ac->u.audio.gain = 0.35f;

        NSString *path = @"/tmp/jv_test.jvp";
        CHECK(jv_project_save(tl, path), "save succeeds");
        jv_timeline_destroy(tl);

        jv_timeline *r = jv_project_load(path);
        CHECK(r != NULL, "load succeeds");
        if (r) {
            CHECK(r->track_count == 2, "two tracks restored");
            CHECK(r->width == 1280 && r->height == 720, "canvas size restored");
            CHECK(fabs(r->fps - 25.0) < 1e-6, "fps restored");
            CHECK(fabs(r->pixels_per_second - 42.0) < 1e-6, "zoom restored");
            CHECK(fabs(r->playhead - 1.5) < 1e-6, "playhead restored");
            CHECK(fabs(r->scroll_x - 2.0) < 1e-6, "scroll restored");
            CHECK(r->marker_count == 1 && fabs(r->markers[0] - 3.25) < 1e-6, "marker restored");
            jv_track *vt = &r->tracks[0];
            CHECK(vt->clip_count == 2, "two clips on track 0");
            int sawText = 0, sawImage = 0;
            for (size_t j = 0; j < vt->clip_count; j++) {
                jv_clip *c = &vt->clips[j];
                if (c->type == JV_CLIP_TEXT) {
                    sawText = 1;
                    CHECK(strcmp(c->u.text.string, "Hello World") == 0, "text string restored");
                    CHECK(fabs(c->u.text.rotation - 0.3f) < 1e-4, "text rotation restored");
                    CHECK(c->u.text.rgba != NULL, "text re-rasterized on load");
                }
                if (c->type == JV_CLIP_IMAGE) {
                    sawImage = 1;
                    CHECK(fabs(c->u.image.scale - 0.6f) < 1e-4, "image scale restored");
                    CHECK(c->u.image.rgba != NULL, "image sidecar reloaded");
                }
            }
            CHECK(sawText && sawImage, "both clip types present");
            // Audio gain round-trips on the Music track.
            jv_track *mt2 = &r->tracks[1];
            CHECK(mt2->clip_count == 1 && mt2->clips[0].type == JV_CLIP_AUDIO, "audio clip restored");
            if (mt2->clip_count == 1) {
                CHECK(fabs(mt2->clips[0].u.audio.gain - 0.35f) < 1e-4, "audio gain restored");
                CHECK(mt2->clips[0].u.audio.pcm != NULL, "audio sidecar reloaded");
            }
            jv_timeline_destroy(r);
        }

        fprintf(stderr, "test_project: %s\n", g_fail ? "FAILED" : "ok");
        return g_fail ? 1 : 0;
    }
}
