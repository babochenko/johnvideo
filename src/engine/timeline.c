// johnvideo — timeline engine implementation (pure C)
#include "timeline.h"
#include "decoder.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

static char *jv_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// ---- Lifecycle ------------------------------------------------------------

jv_timeline *jv_timeline_create(int width, int height, double fps) {
    jv_timeline *tl = calloc(1, sizeof(*tl));
    if (!tl) return NULL;
    tl->width = width;
    tl->height = height;
    tl->fps = fps;
    return tl;
}

void jv_clip_free_payload(jv_clip *c) {
    if (!c) return;
    switch (c->type) {
        case JV_CLIP_IMAGE:
            free(c->u.image.path);
            free(c->u.image.rgba);
            break;
        case JV_CLIP_TEXT:
            free(c->u.text.string);
            free(c->u.text.rgba);
            break;
        case JV_CLIP_VIDEO:
            free(c->u.video.path);
            if (c->u.video.decoder) jv_decoder_close((jv_decoder *)c->u.video.decoder);
            break;
        case JV_CLIP_AUDIO:
            free(c->u.audio.path);
            free(c->u.audio.pcm);
            break;
    }
    memset(&c->u, 0, sizeof(c->u));
}

void jv_timeline_destroy(jv_timeline *tl) {
    if (!tl) return;
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *t = &tl->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) jv_clip_free_payload(&t->clips[j]);
        free(t->name);
        free(t->clips);
    }
    free(tl->tracks);
    free(tl->markers);
    free(tl);
}

static void *dup_mem(const void *src, size_t n) {
    if (!src || !n) return NULL;
    void *p = malloc(n);
    if (p) memcpy(p, src, n);
    return p;
}

jv_timeline *jv_timeline_clone(const jv_timeline *src) {
    if (!src) return NULL;
    jv_timeline *tl = jv_timeline_create(src->width, src->height, src->fps);
    tl->playhead = src->playhead;
    for (size_t i = 0; i < src->marker_count; i++) jv_timeline_add_marker(tl, src->markers[i]);
    for (size_t i = 0; i < src->track_count; i++) {
        const jv_track *st = &src->tracks[i];
        jv_track *t = jv_timeline_add_track(tl, st->kind, st->name);
        for (size_t j = 0; j < st->clip_count; j++) {
            const jv_clip *sc = &st->clips[j];
            jv_clip *c = jv_track_add_clip(t, sc->type, sc->start_time, sc->duration);
            *c = *sc;                 // copy scalars + pointers, then deep-copy owned buffers
            switch (sc->type) {
                case JV_CLIP_IMAGE:
                    c->u.image.path = sc->u.image.path ? jv_strdup(sc->u.image.path) : NULL;
                    c->u.image.rgba = dup_mem(sc->u.image.rgba, (size_t)sc->u.image.width * sc->u.image.height * 4);
                    break;
                case JV_CLIP_TEXT:
                    c->u.text.string = sc->u.text.string ? jv_strdup(sc->u.text.string) : NULL;
                    c->u.text.rgba = dup_mem(sc->u.text.rgba, (size_t)sc->u.text.width * sc->u.text.height * 4);
                    break;
                case JV_CLIP_VIDEO:
                    c->u.video.path = sc->u.video.path ? jv_strdup(sc->u.video.path) : NULL;
                    c->u.video.decoder = NULL;   // reopened lazily by the compositor
                    break;
                case JV_CLIP_AUDIO:
                    c->u.audio.path = sc->u.audio.path ? jv_strdup(sc->u.audio.path) : NULL;
                    c->u.audio.pcm = (float *)dup_mem(sc->u.audio.pcm, sc->u.audio.frames * 2 * sizeof(float));
                    break;
            }
        }
    }
    return tl;
}

jv_track *jv_timeline_add_track(jv_timeline *tl, jv_track_kind kind, const char *name) {
    if (!tl) return NULL;
    if (tl->track_count == tl->track_cap) {
        size_t cap = tl->track_cap ? tl->track_cap * 2 : 4;
        jv_track *grown = realloc(tl->tracks, cap * sizeof(*grown));
        if (!grown) return NULL;
        tl->tracks = grown;
        tl->track_cap = cap;
    }
    jv_track *t = &tl->tracks[tl->track_count++];
    memset(t, 0, sizeof(*t));
    t->kind = kind;
    t->name = jv_strdup(name);
    return t;
}

jv_clip *jv_track_add_clip(jv_track *t, jv_clip_type type,
                           double start_time, double duration) {
    if (!t) return NULL;
    if (t->clip_count == t->clip_cap) {
        size_t cap = t->clip_cap ? t->clip_cap * 2 : 4;
        jv_clip *grown = realloc(t->clips, cap * sizeof(*grown));
        if (!grown) return NULL;
        t->clips = grown;
        t->clip_cap = cap;
    }
    jv_clip *c = &t->clips[t->clip_count++];
    memset(c, 0, sizeof(*c));
    c->type = type;
    c->start_time = start_time;
    c->duration = duration;
    return c;
}

static void track_remove_clip_at(jv_track *t, size_t ci) {
    memmove(&t->clips[ci], &t->clips[ci + 1], (t->clip_count - ci - 1) * sizeof(jv_clip));
    t->clip_count--;
}

jv_clip *jv_clip_move_to_track(jv_track *src, size_t ci, jv_track *dst) {
    if (!src || !dst || ci >= src->clip_count) return NULL;
    jv_clip moved = src->clips[ci];                  // shallow copy owns the payload
    track_remove_clip_at(src, ci);                   // drop from src without freeing payload
    jv_clip *slot = jv_track_add_clip(dst, moved.type, moved.start_time, moved.duration);
    if (!slot) return NULL;
    *slot = moved;
    return slot;
}

// Deep-copy a clip's owned payload buffers into dst (dst already holds a shallow
// copy). Video decoders are not shared (reopened lazily).
static void copy_clip_payload(jv_clip *dst, const jv_clip *src) {
    switch (src->type) {
        case JV_CLIP_IMAGE:
            dst->u.image.path = src->u.image.path ? jv_strdup(src->u.image.path) : NULL;
            dst->u.image.rgba = dup_mem(src->u.image.rgba, (size_t)src->u.image.width * src->u.image.height * 4);
            break;
        case JV_CLIP_TEXT:
            dst->u.text.string = src->u.text.string ? jv_strdup(src->u.text.string) : NULL;
            dst->u.text.rgba = dup_mem(src->u.text.rgba, (size_t)src->u.text.width * src->u.text.height * 4);
            break;
        case JV_CLIP_VIDEO:
            dst->u.video.path = src->u.video.path ? jv_strdup(src->u.video.path) : NULL;
            dst->u.video.decoder = NULL;
            break;
        case JV_CLIP_AUDIO:
            dst->u.audio.path = src->u.audio.path ? jv_strdup(src->u.audio.path) : NULL;
            dst->u.audio.pcm = (float *)dup_mem(src->u.audio.pcm, src->u.audio.frames * 2 * sizeof(float));
            break;
    }
}

jv_clip *jv_track_split_clip(jv_track *t, size_t ci, double atTime) {
    if (!t || ci >= t->clip_count) return NULL;
    jv_clip orig = t->clips[ci];   // by value — surviving a possible realloc below
    double end = orig.start_time + orig.duration;
    if (atTime <= orig.start_time + 1e-4 || atTime >= end - 1e-4) return NULL;

    jv_clip *second = jv_track_add_clip(t, orig.type, atTime, end - atTime);
    if (!second) return NULL;
    *second = orig;                         // shallow copy scalars + payload pointers
    copy_clip_payload(second, &orig);       // then deep-copy the owned buffers
    second->start_time = atTime;
    second->duration = end - atTime;
    second->in_offset = orig.in_offset + (atTime - orig.start_time);

    t->clips[ci].duration = atTime - orig.start_time;   // shrink the first half
    return second;
}

void jv_timeline_move_track(jv_timeline *tl, size_t from, size_t to) {
    if (!tl || from >= tl->track_count || to >= tl->track_count || from == to) return;
    jv_track tmp = tl->tracks[from];
    if (from < to)
        memmove(&tl->tracks[from], &tl->tracks[from + 1], (to - from) * sizeof(jv_track));
    else
        memmove(&tl->tracks[to + 1], &tl->tracks[to], (from - to) * sizeof(jv_track));
    tl->tracks[to] = tmp;
}

void jv_timeline_order_tracks(jv_timeline *tl) {
    if (!tl) return;
    // Stable partition: visual tracks first, audio after, preserving order.
    jv_track *out = malloc(tl->track_count * sizeof(jv_track));
    if (!out) return;
    size_t n = 0;
    for (size_t i = 0; i < tl->track_count; i++)
        if (tl->tracks[i].kind == JV_TRACK_VISUAL) out[n++] = tl->tracks[i];
    for (size_t i = 0; i < tl->track_count; i++)
        if (tl->tracks[i].kind == JV_TRACK_AUDIO) out[n++] = tl->tracks[i];
    memcpy(tl->tracks, out, tl->track_count * sizeof(jv_track));
    free(out);
}

void jv_timeline_remove_track(jv_timeline *tl, size_t index) {
    if (!tl || index >= tl->track_count) return;
    jv_track *t = &tl->tracks[index];
    for (size_t j = 0; j < t->clip_count; j++) jv_clip_free_payload(&t->clips[j]);
    free(t->name);
    free(t->clips);
    memmove(&tl->tracks[index], &tl->tracks[index + 1],
            (tl->track_count - index - 1) * sizeof(jv_track));
    tl->track_count--;
}

void jv_timeline_add_marker(jv_timeline *tl, double t) {
    if (!tl || t < 0) return;
    if (tl->marker_count == tl->marker_cap) {
        size_t cap = tl->marker_cap ? tl->marker_cap * 2 : 8;
        double *g = realloc(tl->markers, cap * sizeof(double));
        if (!g) return;
        tl->markers = g; tl->marker_cap = cap;
    }
    // Insert keeping the array sorted ascending.
    size_t i = tl->marker_count;
    while (i > 0 && tl->markers[i - 1] > t) { tl->markers[i] = tl->markers[i - 1]; i--; }
    tl->markers[i] = t;
    tl->marker_count++;
}

int jv_timeline_remove_marker_near(jv_timeline *tl, double t, double tol) {
    if (!tl) return 0;
    size_t best = (size_t)-1; double bestD = tol;
    for (size_t i = 0; i < tl->marker_count; i++) {
        double d = fabs(tl->markers[i] - t);
        if (d <= bestD) { bestD = d; best = i; }
    }
    if (best == (size_t)-1) return 0;
    memmove(&tl->markers[best], &tl->markers[best + 1], (tl->marker_count - best - 1) * sizeof(double));
    tl->marker_count--;
    return 1;
}

double jv_timeline_adjacent_marker(const jv_timeline *tl, double t, int dir, int *found) {
    if (found) *found = 0;
    if (!tl) return t;
    const double eps = 1e-4;
    double best = t; int got = 0;
    for (size_t i = 0; i < tl->marker_count; i++) {
        double m = tl->markers[i];
        if (dir > 0 && m > t + eps) { if (!got || m < best) { best = m; got = 1; } }
        else if (dir < 0 && m < t - eps) { if (!got || m > best) { best = m; got = 1; } }
    }
    if (found) *found = got;
    return got ? best : t;
}

double jv_timeline_duration(const jv_timeline *tl) {
    double end = 0.0;
    if (!tl) return end;
    for (size_t i = 0; i < tl->track_count; i++) {
        const jv_track *t = &tl->tracks[i];
        for (size_t j = 0; j < t->clip_count; j++) {
            double e = t->clips[j].start_time + t->clips[j].duration;
            if (e > end) end = e;
        }
    }
    return end;
}

// ---- Compositor -----------------------------------------------------------

static int clip_active(const jv_clip *c, double t) {
    return t >= c->start_time && t < c->start_time + c->duration;
}

// Bilinear-sample a premultiplied RGBA source at (u,v) in source pixels.
static void sample_bilinear(const unsigned char *src, int sw, int sh,
                            float u, float v, float out[4]) {
    if (u < 0) u = 0; if (u > sw - 1) u = sw - 1;
    if (v < 0) v = 0; if (v > sh - 1) v = sh - 1;
    int x0 = (int)u, x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
    int y0 = (int)v, y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    float wx = u - x0, wy = v - y0;
    const unsigned char *p00 = &src[(y0 * sw + x0) * 4];
    const unsigned char *p01 = &src[(y0 * sw + x1) * 4];
    const unsigned char *p10 = &src[(y1 * sw + x0) * 4];
    const unsigned char *p11 = &src[(y1 * sw + x1) * 4];
    float w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy);
    float w10 = (1 - wx) * wy,       w11 = wx * wy;
    for (int k = 0; k < 4; k++)
        out[k] = p00[k] * w00 + p01[k] * w01 + p10[k] * w10 + p11[k] * w11;
}

// Composite a source RGBA bitmap onto dst, centered at normalized (cx,cy),
// scaled to `scale` fraction of canvas HEIGHT (aspect preserved) and rotated by
// `rot` radians. Iterates the rotated bounding box and inverse-maps each dst
// pixel back into the source (premultiplied source-over).
static void blit_rgba(unsigned char *dst, int dw, int dh,
                      const unsigned char *src, int sw, int sh,
                      float cx, float cy, float scale, float rot) {
    if (!src || sw <= 0 || sh <= 0 || scale <= 0.f) return;
    float outh = scale * dh;
    float outw = outh * (float)sw / sh;
    if (outw < 1 || outh < 1) return;

    float centerX = cx * dw, centerY = cy * dh;
    float c = cosf(rot), s = sinf(rot);
    // Half-extent of the axis-aligned bounding box of the rotated rectangle.
    float hw = outw / 2, hh = outh / 2;
    float bx = fabsf(hw * c) + fabsf(hh * s);
    float by = fabsf(hw * s) + fabsf(hh * c);
    int minx = (int)floorf(centerX - bx), maxx = (int)ceilf(centerX + bx);
    int miny = (int)floorf(centerY - by), maxy = (int)ceilf(centerY + by);

    for (int dy = miny; dy <= maxy; dy++) {
        if (dy < 0 || dy >= dh) continue;
        for (int dx = minx; dx <= maxx; dx++) {
            if (dx < 0 || dx >= dw) continue;
            // Offset from center, inverse-rotated into the clip's local frame.
            float rx = dx + 0.5f - centerX, ry = dy + 0.5f - centerY;
            float lx =  rx * c + ry * s;
            float ly = -rx * s + ry * c;
            if (lx < -hw || lx >= hw || ly < -hh || ly >= hh) continue;
            float u = (lx + hw) / outw * sw;
            float v = (ly + hh) / outh * sh;
            float sc[4];
            sample_bilinear(src, sw, sh, u, v, sc);
            float a = sc[3];
            if (a < 0.5f) continue;
            float ia = (255.0f - a) / 255.0f;
            unsigned char *dp = &dst[(dy * dw + dx) * 4];
            dp[0] = (unsigned char)(sc[0] + dp[0] * ia + 0.5f);
            dp[1] = (unsigned char)(sc[1] + dp[1] * ia + 0.5f);
            dp[2] = (unsigned char)(sc[2] + dp[2] * ia + 0.5f);
            dp[3] = (unsigned char)(a + dp[3] * ia + 0.5f);
        }
    }
}

void jv_render_frame(jv_timeline *tl, double t,
                     unsigned char *out, int ow, int oh) {
    // Opaque black background.
    for (int i = 0; i < ow * oh; i++) {
        out[i * 4 + 0] = 0; out[i * 4 + 1] = 0;
        out[i * 4 + 2] = 0; out[i * 4 + 3] = 255;
    }
    if (!tl) return;

    // Iterate tracks bottom-to-top in z: the LAST track is drawn first and the
    // FIRST track (top of the timeline list) is drawn last, so it sits on top.
    for (size_t i = tl->track_count; i-- > 0;) {
        jv_track *trk = &tl->tracks[i];
        if (trk->kind != JV_TRACK_VISUAL) continue;
        for (size_t j = 0; j < trk->clip_count; j++) {
            jv_clip *c = &trk->clips[j];
            if (!clip_active(c, t)) continue;
            if (c->type == JV_CLIP_IMAGE) {
                blit_rgba(out, ow, oh, c->u.image.rgba, c->u.image.width,
                          c->u.image.height, c->u.image.cx, c->u.image.cy,
                          c->u.image.scale, c->u.image.rotation);
            } else if (c->type == JV_CLIP_TEXT) {
                // Size text relative to the canvas height it was authored for,
                // unless an explicit scale was set.
                float ts = c->u.text.scale > 0 ? c->u.text.scale
                         : (float)c->u.text.height / (tl->height > 0 ? tl->height : oh);
                blit_rgba(out, ow, oh, c->u.text.rgba, c->u.text.width,
                          c->u.text.height, c->u.text.cx, c->u.text.cy, ts,
                          c->u.text.rotation);
            } else if (c->type == JV_CLIP_VIDEO) {
                if (!c->u.video.decoder && c->u.video.path)
                    c->u.video.decoder = jv_decoder_open(c->u.video.path);
                if (c->u.video.decoder) {
                    int fw = 0, fh = 0;
                    double src_t = c->in_offset + (t - c->start_time);
                    const unsigned char *frame = jv_decoder_frame_at(
                        (jv_decoder *)c->u.video.decoder, src_t, &fw, &fh);
                    blit_rgba(out, ow, oh, frame, fw, fh, c->u.video.cx,
                              c->u.video.cy, c->u.video.scale, c->u.video.rotation);
                }
            }
        }
    }
}

// ---- Mixer ----------------------------------------------------------------

void jv_mix_audio(jv_timeline *tl, double t, int sample_rate,
                  int frames, float *out) {
    memset(out, 0, sizeof(float) * frames * 2);
    if (!tl) return;

    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *trk = &tl->tracks[i];
        if (trk->kind != JV_TRACK_AUDIO) continue;
        for (size_t j = 0; j < trk->clip_count; j++) {
            jv_clip *c = &trk->clips[j];
            if (c->type != JV_CLIP_AUDIO || !c->u.audio.pcm) continue;
            jv_audio *a = &c->u.audio;

            for (int f = 0; f < frames; f++) {
                double tt = t + (double)f / sample_rate;
                if (tt < c->start_time || tt >= c->start_time + c->duration) continue;
                // Map timeline time to a source sample (nearest), honoring trim
                // and any sample-rate difference.
                double src_sec = c->in_offset + (tt - c->start_time);
                long s = (long)(src_sec * a->sample_rate + 0.5);
                if (s < 0 || (size_t)s >= a->frames) continue;
                out[f * 2 + 0] += a->pcm[s * 2 + 0] * a->gain;
                out[f * 2 + 1] += a->pcm[s * 2 + 1] * a->gain;
            }
        }
    }

    // Soft clip to [-1, 1].
    for (int i = 0; i < frames * 2; i++) {
        if (out[i] > 1.f) out[i] = 1.f;
        else if (out[i] < -1.f) out[i] = -1.f;
    }
}
