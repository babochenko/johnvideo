// Round-trip test: build a timeline, save .jvp, load it back, verify.
#import <Cocoa/Cocoa.h>
#import "Project.h"
#include "timeline.h"
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        jv_timeline *tl = jv_timeline_create(1280, 720, 25.0);
        jv_track *v = jv_timeline_add_track(tl, JV_TRACK_VISUAL, "Video 1");
        jv_timeline_add_track(tl, JV_TRACK_AUDIO, "Music");

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

        NSString *path = @"/tmp/jv_test.jvp";
        BOOL ok = jv_project_save(tl, path);
        printf("save: %s\n", ok ? "ok" : "FAIL");
        jv_timeline_destroy(tl);

        jv_timeline *r = jv_project_load(path);
        if (!r) { printf("load FAIL\n"); return 1; }
        printf("tracks=%zu (expect 2)\n", r->track_count);
        printf("canvas=%dx%d @%.0f (expect 1280x720 @25)\n", r->width, r->height, r->fps);
        jv_track *vt = &r->tracks[0];
        printf("clips on track0=%zu (expect 2)\n", vt->clip_count);
        for (size_t j = 0; j < vt->clip_count; j++) {
            jv_clip *c = &vt->clips[j];
            if (c->type == JV_CLIP_TEXT)
                printf("text='%s' rot=%.2f rgba=%s\n", c->u.text.string, c->u.text.rotation, c->u.text.rgba?"yes":"no");
            if (c->type == JV_CLIP_IMAGE)
                printf("image scale=%.2f rgba=%s %dx%d\n", c->u.image.scale, c->u.image.rgba?"yes":"no", c->u.image.width, c->u.image.height);
        }
        jv_timeline_destroy(r);
    }
    return 0;
}
