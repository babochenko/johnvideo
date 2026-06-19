// johnvideo — video decoder module (pure C, FFmpeg).
//
// Wraps one source file and answers "give me the RGBA frame at time T" plus
// "give me the audio as stereo float PCM". Used by the compositor (video
// clips) and at import time (to pull a clip's embedded audio into a mixer
// track).
#ifndef JV_DECODER_H
#define JV_DECODER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jv_decoder jv_decoder;

jv_decoder *jv_decoder_open(const char *path);
void        jv_decoder_close(jv_decoder *d);

// Source video frame size; 0 if the file has no video stream.
int jv_decoder_width(const jv_decoder *d);
int jv_decoder_height(const jv_decoder *d);
double jv_decoder_duration(const jv_decoder *d);
int jv_decoder_has_audio(const jv_decoder *d);

// Decodes the frame nearest source time `t` (seconds) into an internal RGBA
// buffer and returns a borrowed pointer; *w/*h receive its size. The pointer
// is valid until the next call. Returns NULL if there is no video stream.
const unsigned char *jv_decoder_frame_at(jv_decoder *d, double t, int *w, int *h);

// Decodes the entire audio stream to interleaved stereo float32 at its native
// sample rate. Caller owns *out_pcm (free with free). Returns frame count per
// channel, or 0 if there is no audio.
size_t jv_decoder_read_all_audio(jv_decoder *d, float **out_pcm, int *sample_rate);

#ifdef __cplusplus
}
#endif

#endif // JV_DECODER_H
