// johnvideo — timeline engine (pure C, UI-agnostic)
//
// The engine owns the data model plus the two pipelines that preview and export
// both share: the visual compositor (jv_render_frame) and the audio mixer
// (jv_mix_audio). Platform code (AppKit) only feeds clips in and draws results.
#ifndef JV_TIMELINE_H
#define JV_TIMELINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    JV_TRACK_VISUAL,
    JV_TRACK_AUDIO,
} jv_track_kind;

typedef enum {
    JV_CLIP_IMAGE,
    JV_CLIP_TEXT,
    JV_CLIP_VIDEO,
    JV_CLIP_AUDIO,
} jv_clip_type;

// ---- Clip payloads --------------------------------------------------------
// Visual payloads expose an RGBA8 (premultiplied, top-down) bitmap plus a
// normalized center position (0..1 in timeline space) and a scale factor.
// IMAGE/TEXT bitmaps are produced once by the UI; VIDEO bitmaps are produced
// on demand by the decoder at the playhead time.

typedef struct {
    char          *path;     // source file, may be NULL for pasted/text bitmaps
    unsigned char *rgba;     // width*height*4, owned
    int            width;
    int            height;
    float          cx, cy;   // normalized center on the canvas
    float          scale;    // fraction of canvas height (aspect preserved)
    float          rotation; // radians, clockwise
} jv_image;

typedef struct {
    char          *string;   // editable source text (UTF-8), owned
    double         font_size;
    unsigned int   color;    // 0xRRGGBBAA
    unsigned char *rgba;     // rasterized by the UI (Core Text), owned
    int            width;
    int            height;
    float          cx, cy;
    float          scale;    // fraction of canvas height; 0 => use native height
    float          rotation; // radians, clockwise
} jv_text;

typedef struct {
    char  *path;
    void  *decoder;          // jv_decoder*, owned (opened lazily)
    float  cx, cy;
    float  scale;
    float  rotation;         // radians, clockwise
} jv_video;

typedef struct {
    char  *path;             // source media (wav / music / video)
    float *pcm;              // interleaved stereo float32, owned
    size_t frames;           // sample frames per channel
    int    sample_rate;
    int    channels;         // always stored as 2 after load
    float  gain;             // linear 0..1+
} jv_audio;

typedef struct jv_clip {
    jv_clip_type type;
    double       start_time; // seconds on the timeline
    double       duration;   // seconds
    double       in_offset;  // seconds into the source (trim head)
    union {
        jv_image image;
        jv_text  text;
        jv_video video;
        jv_audio audio;
    } u;
} jv_clip;

typedef struct jv_track {
    jv_track_kind kind;
    char         *name;
    jv_clip      *clips;
    size_t        clip_count;
    size_t        clip_cap;
} jv_track;

typedef struct jv_timeline {
    double    fps;
    int       width;
    int       height;
    jv_track *tracks;
    size_t    track_count;
    size_t    track_cap;
    double    playhead;      // seconds
    double    pixels_per_second; // UI zoom hint, persisted (0 = unset)
    double   *markers;       // sorted marker times (seconds)
    size_t    marker_count;
    size_t    marker_cap;
} jv_timeline;

// ---- Lifecycle ------------------------------------------------------------
jv_timeline *jv_timeline_create(int width, int height, double fps);
void         jv_timeline_destroy(jv_timeline *tl);

// Deep copy (owned buffers duplicated; video decoders reopened lazily). Used
// for undo/redo snapshots.
jv_timeline *jv_timeline_clone(const jv_timeline *tl);

jv_track *jv_timeline_add_track(jv_timeline *tl, jv_track_kind kind, const char *name);

// Remove a track (and free its clips) by index.
void jv_timeline_remove_track(jv_timeline *tl, size_t index);

// Reorder: move the track at `from` to position `to`.
void jv_timeline_move_track(jv_timeline *tl, size_t from, size_t to);

// Stable-partition tracks so every visual track precedes every audio track.
void jv_timeline_order_tracks(jv_timeline *tl);

// Move clip at index `ci` from `src` to the end of `dst` (same struct copied).
// Returns the clip's new location in dst, or NULL on failure.
jv_clip *jv_clip_move_to_track(jv_track *src, size_t ci, jv_track *dst);

// Split the clip at index `ci` at absolute time `atTime` into two clips (the
// payload is deep-copied; the second half's in_offset advances). Returns the
// new second clip, or NULL if atTime is outside the clip.
jv_clip *jv_track_split_clip(jv_track *t, size_t ci, double atTime);

// Append a zeroed clip of the given type to a track; returns a borrowed pointer.
jv_clip *jv_track_add_clip(jv_track *t, jv_clip_type type,
                           double start_time, double duration);

// Free any payload buffers owned by a clip (does not remove it from the track).
void jv_clip_free_payload(jv_clip *c);

double jv_timeline_duration(const jv_timeline *tl);

// ---- Markers --------------------------------------------------------------
void   jv_timeline_add_marker(jv_timeline *tl, double t);
// Remove the marker nearest t within tolerance (seconds); returns 1 if removed.
int    jv_timeline_remove_marker_near(jv_timeline *tl, double t, double tol);
// Nearest marker strictly in `dir` (-1 before / +1 after) from t.
// Returns its time and sets *found; if none, returns t and *found = 0.
double jv_timeline_adjacent_marker(const jv_timeline *tl, double t, int dir, int *found);

// ---- Compositor (shared by preview + export) ------------------------------
// Renders every visual track (track order = back-to-front z-order) at time t
// into a pre-allocated RGBA8 buffer of size out_w*out_h*4. The buffer is
// cleared to opaque black first.
void jv_render_frame(jv_timeline *tl, double t,
                     unsigned char *out_rgba, int out_w, int out_h);

// ---- Mixer (shared by playback + export) ----------------------------------
// Sums all audio clips overlapping [t, t + frames/sample_rate) into an
// interleaved stereo float buffer (out has frames*2 samples). Cleared first.
void jv_mix_audio(jv_timeline *tl, double t, int sample_rate,
                  int frames, float *out_stereo);

#ifdef __cplusplus
}
#endif

#endif // JV_TIMELINE_H
