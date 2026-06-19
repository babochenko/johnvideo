// johnvideo — video/audio decoder (pure C, FFmpeg libav*)
#include "decoder.h"

#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>

struct jv_decoder {
    AVFormatContext *fmt;
    int              vstream;
    int              astream;

    AVCodecContext  *vdec;
    struct SwsContext *sws;
    AVFrame         *vframe;     // decoded
    AVFrame         *rgb;        // converted RGBA
    unsigned char   *rgb_buf;
    int              width, height;
    double           last_decoded_t;

    AVCodecContext  *adec;
};

static AVCodecContext *open_stream(AVFormatContext *fmt, int idx) {
    AVStream *st = fmt->streams[idx];
    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (!ctx) return NULL;
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0 ||
        avcodec_open2(ctx, dec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return NULL;
    }
    return ctx;
}

jv_decoder *jv_decoder_open(const char *path) {
    jv_decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->vstream = d->astream = -1;
    d->last_decoded_t = -1e9;

    if (avformat_open_input(&d->fmt, path, NULL, NULL) < 0) { free(d); return NULL; }
    if (avformat_find_stream_info(d->fmt, NULL) < 0) { jv_decoder_close(d); return NULL; }

    for (unsigned i = 0; i < d->fmt->nb_streams; i++) {
        enum AVMediaType t = d->fmt->streams[i]->codecpar->codec_type;
        if (t == AVMEDIA_TYPE_VIDEO && d->vstream < 0) d->vstream = (int)i;
        else if (t == AVMEDIA_TYPE_AUDIO && d->astream < 0) d->astream = (int)i;
    }

    if (d->vstream >= 0) {
        d->vdec = open_stream(d->fmt, d->vstream);
        if (d->vdec) {
            d->width = d->vdec->width;
            d->height = d->vdec->height;
            d->vframe = av_frame_alloc();
            d->rgb = av_frame_alloc();
            int bytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, d->width, d->height, 1);
            d->rgb_buf = av_malloc(bytes);
            av_image_fill_arrays(d->rgb->data, d->rgb->linesize, d->rgb_buf,
                                 AV_PIX_FMT_RGBA, d->width, d->height, 1);
            d->sws = sws_getContext(d->width, d->height, d->vdec->pix_fmt,
                                    d->width, d->height, AV_PIX_FMT_RGBA,
                                    SWS_BILINEAR, NULL, NULL, NULL);
        }
    }
    if (d->astream >= 0) d->adec = open_stream(d->fmt, d->astream);

    return d;
}

void jv_decoder_close(jv_decoder *d) {
    if (!d) return;
    if (d->sws) sws_freeContext(d->sws);
    if (d->rgb_buf) av_free(d->rgb_buf);
    if (d->rgb) av_frame_free(&d->rgb);
    if (d->vframe) av_frame_free(&d->vframe);
    if (d->vdec) avcodec_free_context(&d->vdec);
    if (d->adec) avcodec_free_context(&d->adec);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d);
}

int jv_decoder_width(const jv_decoder *d)  { return d ? d->width : 0; }
int jv_decoder_height(const jv_decoder *d) { return d ? d->height : 0; }
int jv_decoder_has_audio(const jv_decoder *d) { return d && d->astream >= 0; }

double jv_decoder_duration(const jv_decoder *d) {
    if (!d || !d->fmt || d->fmt->duration == AV_NOPTS_VALUE) return 0.0;
    return (double)d->fmt->duration / AV_TIME_BASE;
}

const unsigned char *jv_decoder_frame_at(jv_decoder *d, double t, int *w, int *h) {
    if (!d || d->vstream < 0 || !d->vdec) return NULL;
    if (w) *w = d->width;
    if (h) *h = d->height;
    if (t < 0) t = 0;

    AVStream *st = d->fmt->streams[d->vstream];
    double tb = av_q2d(st->time_base);

    // Seek when jumping backward or far forward; otherwise decode forward.
    if (t < d->last_decoded_t || t > d->last_decoded_t + 1.0) {
        int64_t ts = (int64_t)(t / tb);
        av_seek_frame(d->fmt, d->vstream, ts, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(d->vdec);
        d->last_decoded_t = -1e9;
    }

    AVPacket *pkt = av_packet_alloc();
    int got = 0;
    while (av_read_frame(d->fmt, pkt) >= 0) {
        if (pkt->stream_index == d->vstream) {
            if (avcodec_send_packet(d->vdec, pkt) == 0) {
                while (avcodec_receive_frame(d->vdec, d->vframe) == 0) {
                    double ft = (d->vframe->best_effort_timestamp == AV_NOPTS_VALUE)
                                ? d->last_decoded_t
                                : d->vframe->best_effort_timestamp * tb;
                    d->last_decoded_t = ft;
                    got = 1;
                    if (ft >= t) goto done;
                }
            }
        }
        av_packet_unref(pkt);
    }
done:
    av_packet_unref(pkt);
    av_packet_free(&pkt);
    if (!got) return NULL;

    sws_scale(d->sws, (const uint8_t *const *)d->vframe->data, d->vframe->linesize,
              0, d->height, d->rgb->data, d->rgb->linesize);
    return d->rgb_buf;
}

size_t jv_decoder_read_all_audio(jv_decoder *d, float **out_pcm, int *sample_rate) {
    *out_pcm = NULL;
    if (!d || d->astream < 0 || !d->adec) return 0;

    AVChannelLayout stereo;
    av_channel_layout_default(&stereo, 2);
    int sr = d->adec->sample_rate;
    if (sample_rate) *sample_rate = sr;

    SwrContext *swr = NULL;
    if (swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_FLT, sr,
                            &d->adec->ch_layout, d->adec->sample_fmt, sr,
                            0, NULL) < 0 || swr_init(swr) < 0) {
        if (swr) swr_free(&swr);
        return 0;
    }

    av_seek_frame(d->fmt, d->astream, 0, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(d->adec);

    float *buf = NULL;
    size_t cap = 0, frames = 0;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();

    while (av_read_frame(d->fmt, pkt) >= 0) {
        if (pkt->stream_index == d->astream && avcodec_send_packet(d->adec, pkt) == 0) {
            while (avcodec_receive_frame(d->adec, fr) == 0) {
                int out_count = (int)av_rescale_rnd(
                    swr_get_delay(swr, sr) + fr->nb_samples, sr, sr, AV_ROUND_UP);
                if (frames + out_count > cap) {
                    cap = (frames + out_count) * 2 + 1024;
                    buf = realloc(buf, cap * 2 * sizeof(float));
                }
                uint8_t *outp = (uint8_t *)(buf + frames * 2);
                int got = swr_convert(swr, &outp, out_count,
                                      (const uint8_t **)fr->data, fr->nb_samples);
                if (got > 0) frames += got;
            }
        }
        av_packet_unref(pkt);
    }

    av_frame_free(&fr);
    av_packet_free(&pkt);
    swr_free(&swr);
    av_channel_layout_uninit(&stereo);

    *out_pcm = buf;
    return frames;
}
