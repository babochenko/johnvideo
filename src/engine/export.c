// johnvideo — timeline export (pure C, FFmpeg libav*)
//
// Walks the timeline frame by frame: composites visuals -> H.264, mixes audio
// -> AAC, interleaves both into one MP4 by PTS.
#include "export.h"

#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>

typedef struct {
    AVStream      *st;
    AVCodecContext *ctx;
} stream_t;

static int encode_and_write(AVFormatContext *fmt, AVCodecContext *ctx,
                            AVStream *st, AVFrame *frame, AVPacket *pkt) {
    int ret = avcodec_send_frame(ctx, frame);
    if (ret < 0) return ret;
    while (ret >= 0) {
        ret = avcodec_receive_packet(ctx, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) return ret;
        av_packet_rescale_ts(pkt, ctx->time_base, st->time_base);
        pkt->stream_index = st->index;
        av_interleaved_write_frame(fmt, pkt);
        av_packet_unref(pkt);
    }
    return 0;
}

int jv_export_mp4(jv_timeline *tl, const char *out_path,
                  jv_export_progress cb, void *user) {
    if (!tl) return -1;
    const int W = tl->width, H = tl->height;
    const double fps = tl->fps > 0 ? tl->fps : 30.0;
    const int SR = 48000;
    const double dur = jv_timeline_duration(tl);
    const int64_t total_frames = (int64_t)(dur * fps + 0.5);
    if (total_frames <= 0) return -2;

    AVFormatContext *fmt = NULL;
    avformat_alloc_output_context2(&fmt, NULL, NULL, out_path);
    if (!fmt) return -3;

    int rc = -10;
    stream_t vs = {0}, as = {0};
    AVFrame *vframe = NULL, *aframe = NULL;
    struct SwsContext *sws = NULL;
    unsigned char *rgba = NULL;
    float *mixbuf = NULL;
    AVPacket *pkt = NULL;

    // ---- Video encoder (H.264) ----
    const AVCodec *vcodec = avcodec_find_encoder(AV_CODEC_ID_H264);
    if (!vcodec) goto done;
    vs.st = avformat_new_stream(fmt, NULL);
    vs.ctx = avcodec_alloc_context3(vcodec);
    vs.ctx->width = W;
    vs.ctx->height = H;
    vs.ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    vs.ctx->time_base = (AVRational){1, (int)(fps + 0.5)};
    vs.ctx->framerate = (AVRational){(int)(fps + 0.5), 1};
    vs.ctx->gop_size = 12;
    // Source-quality output: CRF 0 is mathematically lossless for the composited
    // frames (preset medium keeps it from being unbearably slow/large).
    av_opt_set(vs.ctx->priv_data, "preset", "medium", 0);
    av_opt_set(vs.ctx->priv_data, "crf", "0", 0);
    if (fmt->oformat->flags & AVFMT_GLOBALHEADER)
        vs.ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(vs.ctx, vcodec, NULL) < 0) goto done;
    avcodec_parameters_from_context(vs.st->codecpar, vs.ctx);
    vs.st->time_base = vs.ctx->time_base;

    // ---- Audio encoder (AAC) ----
    const AVCodec *acodec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!acodec) goto done;
    as.st = avformat_new_stream(fmt, NULL);
    as.ctx = avcodec_alloc_context3(acodec);
    as.ctx->sample_rate = SR;
    as.ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_default(&as.ctx->ch_layout, 2);
    as.ctx->bit_rate = 192000;
    as.ctx->time_base = (AVRational){1, SR};
    if (fmt->oformat->flags & AVFMT_GLOBALHEADER)
        as.ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(as.ctx, acodec, NULL) < 0) goto done;
    avcodec_parameters_from_context(as.st->codecpar, as.ctx);
    as.st->time_base = as.ctx->time_base;

    // ---- Open output ----
    if (!(fmt->oformat->flags & AVFMT_NOFILE))
        if (avio_open(&fmt->pb, out_path, AVIO_FLAG_WRITE) < 0) goto done;
    if (avformat_write_header(fmt, NULL) < 0) goto done;

    // ---- Buffers ----
    pkt = av_packet_alloc();
    rgba = malloc((size_t)W * H * 4);
    sws = sws_getContext(W, H, AV_PIX_FMT_RGBA, W, H, AV_PIX_FMT_YUV420P,
                         SWS_BILINEAR, NULL, NULL, NULL);
    vframe = av_frame_alloc();
    vframe->format = AV_PIX_FMT_YUV420P;
    vframe->width = W; vframe->height = H;
    av_frame_get_buffer(vframe, 0);

    const int AFRAME = as.ctx->frame_size > 0 ? as.ctx->frame_size : 1024;
    aframe = av_frame_alloc();
    aframe->format = AV_SAMPLE_FMT_FLTP;
    aframe->nb_samples = AFRAME;
    av_channel_layout_default(&aframe->ch_layout, 2);
    av_frame_get_buffer(aframe, 0);
    mixbuf = malloc(sizeof(float) * AFRAME * 2);

    // ---- Encode video frames ----
    for (int64_t i = 0; i < total_frames; i++) {
        double t = i / fps;
        jv_render_frame(tl, t, rgba, W, H);
        const uint8_t *src[4] = { rgba, NULL, NULL, NULL };
        int stride[4] = { W * 4, 0, 0, 0 };
        av_frame_make_writable(vframe);
        sws_scale(sws, src, stride, 0, H, vframe->data, vframe->linesize);
        vframe->pts = i;
        encode_and_write(fmt, vs.ctx, vs.st, vframe, pkt);
        if (cb && !cb((double)i / total_frames * 0.5, user)) { rc = -20; goto flush; }
    }

    // ---- Encode audio ----
    {
        int64_t total_samples = (int64_t)(dur * SR + 0.5);
        int64_t pts = 0;
        for (int64_t s = 0; s < total_samples; s += AFRAME) {
            int n = (int)((total_samples - s < AFRAME) ? (total_samples - s) : AFRAME);
            double t = (double)s / SR;
            jv_mix_audio(tl, t, SR, n, mixbuf);
            av_frame_make_writable(aframe);
            float *L = (float *)aframe->data[0];
            float *R = (float *)aframe->data[1];
            for (int f = 0; f < n; f++) { L[f] = mixbuf[f*2]; R[f] = mixbuf[f*2+1]; }
            for (int f = n; f < AFRAME; f++) { L[f] = 0; R[f] = 0; }
            aframe->nb_samples = AFRAME;
            aframe->pts = pts;
            pts += AFRAME;
            encode_and_write(fmt, as.ctx, as.st, aframe, pkt);
            if (cb && !cb(0.5 + (double)s / total_samples * 0.5, user)) { rc = -20; goto flush; }
        }
    }

    rc = 0;
flush:
    encode_and_write(fmt, vs.ctx, vs.st, NULL, pkt);
    encode_and_write(fmt, as.ctx, as.st, NULL, pkt);
    av_write_trailer(fmt);

done:
    if (pkt) av_packet_free(&pkt);
    if (vframe) av_frame_free(&vframe);
    if (aframe) av_frame_free(&aframe);
    if (sws) sws_freeContext(sws);
    free(rgba);
    free(mixbuf);
    if (vs.ctx) avcodec_free_context(&vs.ctx);
    if (as.ctx) avcodec_free_context(&as.ctx);
    if (fmt) {
        if (fmt->pb && !(fmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&fmt->pb);
        avformat_free_context(fmt);
    }
    return rc;
}
