// Headless engine smoke test: build a timeline with a synthetic image clip and
// a sine-tone audio clip, export to MP4. Validates compositor + mixer + encode.
#include "timeline.h"
#include <stdlib.h>
#include <math.h>
#include <stdio.h>
#include "export.h"

int main(void) {
    jv_timeline *tl = jv_timeline_create(640, 360, 30.0);
    jv_track *v = jv_timeline_add_track(tl, JV_TRACK_VISUAL, "V");
    jv_track *a = jv_timeline_add_track(tl, JV_TRACK_AUDIO, "A");

    // A 320x180 magenta->cyan gradient image clip, 2s.
    int iw = 320, ih = 180;
    unsigned char *rgba = malloc((size_t)iw * ih * 4);
    for (int y = 0; y < ih; y++)
        for (int x = 0; x < iw; x++) {
            unsigned char *p = &rgba[(y * iw + x) * 4];
            p[0] = (unsigned char)(255 * x / iw);
            p[1] = (unsigned char)(255 * y / ih);
            p[2] = 200; p[3] = 255;
        }
    jv_clip *ic = jv_track_add_clip(v, JV_CLIP_IMAGE, 0.0, 2.0);
    ic->u.image.rgba = rgba; ic->u.image.width = iw; ic->u.image.height = ih;
    ic->u.image.cx = 0.5f; ic->u.image.cy = 0.5f; ic->u.image.scale = 0.8f;

    // A 440Hz tone, 2s, stereo 48k.
    int sr = 48000; size_t frames = sr * 2;
    float *pcm = malloc(sizeof(float) * frames * 2);
    for (size_t i = 0; i < frames; i++) {
        float s = 0.3f * sinf(2.0f * 3.14159265f * 440.0f * i / sr);
        pcm[i * 2] = s; pcm[i * 2 + 1] = s;
    }
    jv_clip *ac = jv_track_add_clip(a, JV_CLIP_AUDIO, 0.0, 2.0);
    ac->u.audio.pcm = pcm; ac->u.audio.frames = frames;
    ac->u.audio.sample_rate = sr; ac->u.audio.channels = 2; ac->u.audio.gain = 1.0f;

    int rc = jv_export_mp4(tl, "build/test_out.mp4", NULL, NULL);
    printf("export rc=%d\n", rc);
    jv_timeline_destroy(tl);
    return rc;
}
