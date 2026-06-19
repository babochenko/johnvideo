// johnvideo — project file (de)serialization (Objective-C++)
//
// Text format, one record per line (git-diff friendly):
//   johnvideo 1
//   canvas <w> <h> <fps>
//   track <V|A> <name...>
//   clip image <start> <dur> <inoff> <cx> <cy> <scale> <rot>
//   src <path>            | asset <relfile.png>
//   clip text  <start> <dur> <inoff> <cx> <cy> <scale> <rot> <fontpx> <0xRRGGBBAA>
//   str <text...>
//   clip video <start> <dur> <inoff> <cx> <cy> <scale> <rot>
//   src <path>
//   clip audio <start> <dur> <inoff> <gain> <samplerate>
//   src <path>            | asset <relfile.wav>
#import "Project.h"
#import "Media.h"
#include "decoder.h"
#include <stdio.h>

// ---- sidecar writers --------------------------------------------------------

static NSString *assetsDirFor(NSString *path) { return [path stringByAppendingString:@".assets"]; }

static BOOL writePNG(const unsigned char *rgba, int w, int h, NSString *file) {
    if (!rgba || w <= 0 || h <= 0) return NO;
    unsigned char *planes[1] = { (unsigned char *)rgba };
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:planes pixelsWide:w pixelsHigh:h bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:file atomically:YES];
}

static BOOL writeWAV(const float *pcm, size_t frames, int sr, NSString *file) {
    if (!pcm || frames == 0) return NO;
    FILE *f = fopen(file.UTF8String, "wb");
    if (!f) return NO;
    int ch = 2, bps = 16;
    uint32_t dataBytes = (uint32_t)(frames * ch * (bps / 8));
    uint32_t byteRate = sr * ch * (bps / 8);
    uint16_t blockAlign = ch * (bps / 8);
    fwrite("RIFF", 1, 4, f);
    uint32_t riff = 36 + dataBytes; fwrite(&riff, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    uint32_t fmtLen = 16; fwrite(&fmtLen, 4, 1, f);
    uint16_t pcmFmt = 1; fwrite(&pcmFmt, 2, 1, f);
    uint16_t chs = ch; fwrite(&chs, 2, 1, f);
    uint32_t srate = sr; fwrite(&srate, 4, 1, f);
    fwrite(&byteRate, 4, 1, f);
    fwrite(&blockAlign, 2, 1, f);
    uint16_t bits = bps; fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f);
    for (size_t i = 0; i < frames * ch; i++) {
        float v = pcm[i]; if (v > 1) v = 1; if (v < -1) v = -1;
        int16_t s = (int16_t)(v * 32767);
        fwrite(&s, 2, 1, f);
    }
    fclose(f);
    return YES;
}

// ---- save -------------------------------------------------------------------

BOOL jv_project_save(jv_timeline *tl, NSString *path) {
    if (!tl) return NO;
    NSString *assets = assetsDirFor(path);
    NSString *assetsName = assets.lastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:assets
                              withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *f = fopen(path.UTF8String, "w");
    if (!f) return NO;
    fprintf(f, "johnvideo 1\n");
    fprintf(f, "canvas %d %d %.4f\n", tl->width, tl->height, tl->fps);
    if (tl->pixels_per_second > 0) fprintf(f, "zoom %.4f\n", tl->pixels_per_second);
    for (size_t i = 0; i < tl->marker_count; i++) fprintf(f, "mark %.4f\n", tl->markers[i]);

    int asset = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (size_t i = 0; i < tl->track_count; i++) {
        jv_track *t = &tl->tracks[i];
        fprintf(f, "track %c %s\n", t->kind == JV_TRACK_VISUAL ? 'V' : 'A',
                t->name ? t->name : "track");
        for (size_t j = 0; j < t->clip_count; j++) {
            jv_clip *c = &t->clips[j];
            switch (c->type) {
                case JV_CLIP_IMAGE: {
                    jv_image *im = &c->u.image;
                    fprintf(f, "  clip image start=%.4f dur=%.4f in=%.4f cx=%.4f cy=%.4f scale=%.4f rot=%.4f\n",
                            c->start_time, c->duration, c->in_offset, im->cx, im->cy, im->scale, im->rotation);
                    BOOL hasFile = im->path && [fm fileExistsAtPath:@(im->path)];
                    if (hasFile) fprintf(f, "    src %s\n", im->path);
                    else {
                        NSString *rel = [NSString stringWithFormat:@"img%d.png", asset++];
                        writePNG(im->rgba, im->width, im->height, [assets stringByAppendingPathComponent:rel]);
                        fprintf(f, "    asset %s/%s\n", assetsName.UTF8String, rel.UTF8String);
                    }
                    break;
                }
                case JV_CLIP_TEXT: {
                    jv_text *tx = &c->u.text;
                    fprintf(f, "  clip text start=%.4f dur=%.4f in=%.4f cx=%.4f cy=%.4f scale=%.4f rot=%.4f font=%.4f color=0x%08X\n",
                            c->start_time, c->duration, c->in_offset, tx->cx, tx->cy,
                            tx->scale, tx->rotation, tx->font_size, tx->color);
                    fprintf(f, "    str %s\n", tx->string ? tx->string : "");
                    break;
                }
                case JV_CLIP_VIDEO: {
                    jv_video *v = &c->u.video;
                    fprintf(f, "  clip video start=%.4f dur=%.4f in=%.4f cx=%.4f cy=%.4f scale=%.4f rot=%.4f\n",
                            c->start_time, c->duration, c->in_offset, v->cx, v->cy, v->scale, v->rotation);
                    if (v->path) fprintf(f, "    src %s\n", v->path);
                    break;
                }
                case JV_CLIP_AUDIO: {
                    jv_audio *a = &c->u.audio;
                    fprintf(f, "  clip audio start=%.4f dur=%.4f in=%.4f gain=%.4f rate=%d\n",
                            c->start_time, c->duration, c->in_offset, a->gain, a->sample_rate);
                    BOOL hasFile = a->path && [fm fileExistsAtPath:@(a->path)];
                    if (hasFile) fprintf(f, "    src %s\n", a->path);
                    else {
                        NSString *rel = [NSString stringWithFormat:@"aud%d.wav", asset++];
                        writeWAV(a->pcm, a->frames, a->sample_rate, [assets stringByAppendingPathComponent:rel]);
                        fprintf(f, "    asset %s/%s\n", assetsName.UTF8String, rel.UTF8String);
                    }
                    break;
                }
            }
        }
        fprintf(f, "\n");   // blank line after each track (ignored on load)
    }
    fclose(f);
    return YES;
}

// ---- load -------------------------------------------------------------------

static void loadImageInto(jv_clip *c, NSString *file) {
    int w = 0, h = 0;
    unsigned char *rgba = jv_rgba_from_file(file.UTF8String, &w, &h);
    if (rgba) { c->u.image.rgba = rgba; c->u.image.width = w; c->u.image.height = h; }
}

static void loadAudioInto(jv_clip *c, NSString *file) {
    jv_decoder *d = jv_decoder_open(file.UTF8String);
    if (!d) return;
    float *pcm = NULL; int sr = 0;
    size_t frames = jv_decoder_read_all_audio(d, &pcm, &sr);
    jv_decoder_close(d);
    if (frames && pcm) {
        c->u.audio.pcm = pcm; c->u.audio.frames = frames;
        if (c->u.audio.sample_rate <= 0) c->u.audio.sample_rate = sr;
        c->u.audio.channels = 2;
    }
}

// Read a labeled "key=value" field from a line (order-independent).
static double pf(const char *s, const char *key, double def) {
    char pat[24]; snprintf(pat, sizeof pat, "%s=", key);
    const char *q = strstr(s, pat);
    return q ? atof(q + strlen(pat)) : def;
}
static unsigned int pfhex(const char *s, const char *key, unsigned int def) {
    char pat[24]; snprintf(pat, sizeof pat, "%s=", key);
    const char *q = strstr(s, pat);
    return q ? (unsigned int)strtoul(q + strlen(pat), NULL, 0) : def;
}

jv_timeline *jv_project_load(NSString *path) {
    NSString *base = [path stringByDeletingLastPathComponent];
    NSError *err = nil;
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!txt) return NULL;

    jv_timeline *tl = jv_timeline_create(1920, 1080, 30.0);
    jv_track *curTrack = NULL;
    jv_clip *curClip = NULL;

    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        const char *s = line.UTF8String;

        if (strncmp(s, "canvas ", 7) == 0) {
            int w, h; double fps;
            if (sscanf(s, "canvas %d %d %lf", &w, &h, &fps) == 3) {
                tl->width = w; tl->height = h; tl->fps = fps;
            }
        } else if (strncmp(s, "zoom ", 5) == 0) {
            tl->pixels_per_second = atof(s + 5);
        } else if (strncmp(s, "mark ", 5) == 0) {
            jv_timeline_add_marker(tl, atof(s + 5));
        } else if (strncmp(s, "track ", 6) == 0) {
            char kind = s[6];
            const char *name = s + 8;            // "track X <name>"
            curTrack = jv_timeline_add_track(tl, kind == 'A' ? JV_TRACK_AUDIO : JV_TRACK_VISUAL, name);
            curClip = NULL;
        } else if (strncmp(s, "clip ", 5) == 0 && curTrack) {
            char type[16] = {0};
            sscanf(s, "clip %15s", type);
            double st = pf(s, "start", 0), du = pf(s, "dur", 0), io = pf(s, "in", 0);
            double cx = pf(s, "cx", 0.5), cy = pf(s, "cy", 0.5), sc = pf(s, "scale", 1), ro = pf(s, "rot", 0);
            if (strcmp(type, "image") == 0) {
                curClip = jv_track_add_clip(curTrack, JV_CLIP_IMAGE, st, du);
                curClip->in_offset = io;
                curClip->u.image.cx = cx; curClip->u.image.cy = cy;
                curClip->u.image.scale = sc; curClip->u.image.rotation = ro;
            } else if (strcmp(type, "text") == 0) {
                curClip = jv_track_add_clip(curTrack, JV_CLIP_TEXT, st, du);
                curClip->in_offset = io;
                curClip->u.text.cx = cx; curClip->u.text.cy = cy;
                curClip->u.text.scale = sc; curClip->u.text.rotation = ro;
                curClip->u.text.font_size = pf(s, "font", 64);
                curClip->u.text.color = pfhex(s, "color", 0xFFFFFFFF);
            } else if (strcmp(type, "video") == 0) {
                curClip = jv_track_add_clip(curTrack, JV_CLIP_VIDEO, st, du);
                curClip->in_offset = io;
                curClip->u.video.cx = cx; curClip->u.video.cy = cy;
                curClip->u.video.scale = sc; curClip->u.video.rotation = ro;
            } else if (strcmp(type, "audio") == 0) {
                curClip = jv_track_add_clip(curTrack, JV_CLIP_AUDIO, st, du);
                curClip->in_offset = io;
                curClip->u.audio.gain = pf(s, "gain", 1);
                curClip->u.audio.sample_rate = (int)pf(s, "rate", 48000);
                curClip->u.audio.channels = 2;
            }
        } else if (strncmp(s, "str ", 4) == 0 && curClip && curClip->type == JV_CLIP_TEXT) {
            curClip->u.text.string = strdup(s + 4);
            int w = 0, h = 0;
            curClip->u.text.rgba = jv_rasterize_text(s + 4, curClip->u.text.font_size,
                                                     curClip->u.text.color, &w, &h);
            curClip->u.text.width = w; curClip->u.text.height = h;
        } else if ((strncmp(s, "src ", 4) == 0 || strncmp(s, "asset ", 6) == 0) && curClip) {
            BOOL isAsset = strncmp(s, "asset ", 6) == 0;
            NSString *ref = @(s + (isAsset ? 6 : 4));
            NSString *file = isAsset ? [base stringByAppendingPathComponent:ref] : ref;
            if (curClip->type == JV_CLIP_IMAGE) {
                curClip->u.image.path = isAsset ? NULL : strdup(file.UTF8String);
                loadImageInto(curClip, file);
            } else if (curClip->type == JV_CLIP_VIDEO) {
                curClip->u.video.path = strdup(file.UTF8String);
            } else if (curClip->type == JV_CLIP_AUDIO) {
                curClip->u.audio.path = strdup(isAsset ? "voiceover" : file.UTF8String);
                loadAudioInto(curClip, file);
            }
        }
    }
    return tl;
}
