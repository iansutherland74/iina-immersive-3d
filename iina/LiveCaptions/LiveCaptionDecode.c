//
//  LiveCaptionDecode.c
//  iina
//
//  16 kHz mono float from a file FFmpeg can demux. The same libraries decode
//  what mpv is already playing, including a cache dump of a live MPEG-TS or
//  HLS stream.

#include "LiveCaptionDecode.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/samplefmt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct IINACaptionDecode {
  AVFormatContext *fmt;
  AVCodecContext *dec;
  int audio_index;
  AVRational time_base;
};

static void set_error(char *error, int error_len, const char *message) {
  if (!error || error_len <= 0) {
    return;
  }
  snprintf(error, (size_t)error_len, "%s", message ? message : "unknown error");
}

static void set_averror(char *error, int error_len, int code, const char *what) {
  char detail[128];
  av_strerror(code, detail, sizeof(detail));
  if (!error || error_len <= 0) {
    return;
  }
  snprintf(error, (size_t)error_len, "%s (%s)", what ? what : "ffmpeg", detail);
}

IINACaptionDecode *iina_caption_open(const char *path, char *error, int error_len) {
  if (!path || !path[0]) {
    set_error(error, error_len, "missing media path");
    return NULL;
  }
  AVFormatContext *fmt = NULL;
  int rc = avformat_open_input(&fmt, path, NULL, NULL);
  if (rc < 0) {
    set_averror(error, error_len, rc, "could not open audio");
    return NULL;
  }
  rc = avformat_find_stream_info(fmt, NULL);
  if (rc < 0) {
    set_averror(error, error_len, rc, "could not read streams");
    avformat_close_input(&fmt);
    return NULL;
  }
  int index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (index < 0) {
    set_error(error, error_len, "no audio track");
    avformat_close_input(&fmt);
    return NULL;
  }
  AVStream *stream = fmt->streams[index];
  const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
  if (!codec) {
    set_error(error, error_len, "no decoder for the audio track");
    avformat_close_input(&fmt);
    return NULL;
  }
  AVCodecContext *dec = avcodec_alloc_context3(codec);
  if (!dec) {
    set_error(error, error_len, "could not allocate a decoder");
    avformat_close_input(&fmt);
    return NULL;
  }
  rc = avcodec_parameters_to_context(dec, stream->codecpar);
  if (rc < 0) {
    set_averror(error, error_len, rc, "could not copy audio parameters");
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return NULL;
  }
  dec->pkt_timebase = stream->time_base;
  rc = avcodec_open2(dec, codec, NULL);
  if (rc < 0) {
    set_averror(error, error_len, rc, "could not open the audio decoder");
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return NULL;
  }
  IINACaptionDecode *decoder = (IINACaptionDecode *)calloc(1, sizeof(IINACaptionDecode));
  if (!decoder) {
    set_error(error, error_len, "out of memory");
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return NULL;
  }
  decoder->fmt = fmt;
  decoder->dec = dec;
  decoder->audio_index = index;
  decoder->time_base = stream->time_base;
  set_error(error, error_len, "");
  return decoder;
}

double iina_caption_duration(IINACaptionDecode *decoder) {
  if (!decoder || !decoder->fmt || decoder->fmt->duration == AV_NOPTS_VALUE) {
    return -1;
  }
  return (double)decoder->fmt->duration / (double)AV_TIME_BASE;
}

static int grow(float **samples, int *capacity, int needed) {
  if (needed <= *capacity) {
    return 0;
  }
  int next = *capacity > 0 ? *capacity : 4096;
  while (next < needed) {
    if (next > 16000 * 60 * 3) {
      return -1;
    }
    next *= 2;
  }
  float *grown = (float *)realloc(*samples, (size_t)next * sizeof(float));
  if (!grown) {
    return -1;
  }
  *samples = grown;
  *capacity = next;
  return 0;
}

static float sample_at(const AVFrame *frame, int index, int channel, int channels, int planar, enum AVSampleFormat format) {
  const uint8_t *plane;
  int sample_index;
  if (planar) {
    plane = frame->extended_data[channel];
    sample_index = index;
  } else {
    plane = frame->extended_data[0];
    sample_index = index * channels + channel;
  }
  if (!plane) {
    return 0;
  }
  switch (format) {
    case AV_SAMPLE_FMT_FLT:
    case AV_SAMPLE_FMT_FLTP: {
      const float *values = (const float *)plane;
      return values[sample_index];
    }
    case AV_SAMPLE_FMT_S16:
    case AV_SAMPLE_FMT_S16P: {
      const int16_t *values = (const int16_t *)plane;
      return (float)values[sample_index] / 32768.0f;
    }
    case AV_SAMPLE_FMT_S32:
    case AV_SAMPLE_FMT_S32P: {
      const int32_t *values = (const int32_t *)plane;
      return (float)values[sample_index] / 2147483648.0f;
    }
    case AV_SAMPLE_FMT_DBL:
    case AV_SAMPLE_FMT_DBLP: {
      const double *values = (const double *)plane;
      return (float)values[sample_index];
    }
    default:
      return 0;
  }
}

static int append_mono(float **samples, int *count, int *capacity, const AVFrame *frame, int *rate, int *channels_out) {
  int channels = frame->ch_layout.nb_channels > 0 ? frame->ch_layout.nb_channels : 1;
  if (*channels_out == 0) {
    *channels_out = channels;
  }
  if (frame->sample_rate > 0 && *rate == 0) {
    *rate = frame->sample_rate;
  }
  enum AVSampleFormat format = (enum AVSampleFormat)frame->format;
  int planar = av_sample_fmt_is_planar(format);
  if (format != AV_SAMPLE_FMT_FLT && format != AV_SAMPLE_FMT_FLTP &&
      format != AV_SAMPLE_FMT_S16 && format != AV_SAMPLE_FMT_S16P &&
      format != AV_SAMPLE_FMT_S32 && format != AV_SAMPLE_FMT_S32P &&
      format != AV_SAMPLE_FMT_DBL && format != AV_SAMPLE_FMT_DBLP) {
    return -2;
  }
  if (grow(samples, capacity, *count + frame->nb_samples) != 0) {
    return -1;
  }
  for (int i = 0; i < frame->nb_samples; i++) {
    float sum = 0;
    for (int channel = 0; channel < channels; channel++) {
      sum += sample_at(frame, i, channel, channels, planar, format);
    }
    (*samples)[*count + i] = sum / (float)channels;
  }
  *count += frame->nb_samples;
  return 0;
}

static void resample(const float *input, int input_count, int input_rate, IINACaptionPCM *out) {
  if (input_count <= 0 || input_rate <= 0) {
    return;
  }
  if (abs(input_rate - 16000) < 2) {
    out->samples = (float *)malloc((size_t)input_count * sizeof(float));
    if (!out->samples) {
      return;
    }
    memcpy(out->samples, input, (size_t)input_count * sizeof(float));
    out->count = input_count;
    return;
  }
  double ratio = (double)input_rate / 16000.0;
  int count = (int)((double)input_count / ratio);
  if (count < 1) {
    return;
  }
  float *output = (float *)malloc((size_t)count * sizeof(float));
  if (!output) {
    return;
  }
  int last = input_count - 1;
  for (int i = 0; i < count; i++) {
    double position = (double)i * ratio;
    int left = (int)position;
    if (left > last) {
      left = last;
    }
    int right = left + 1;
    if (right > last) {
      right = last;
    }
    float fraction = (float)(position - (double)left);
    output[i] = input[left] * (1.0f - fraction) + input[right] * fraction;
  }
  out->samples = output;
  out->count = count;
}

static double frame_pts(const AVFrame *frame, AVRational fallback) {
  if (frame->pts == AV_NOPTS_VALUE) {
    return -1;
  }
  AVRational base = frame->time_base.den > 0 ? frame->time_base : fallback;
  if (base.den <= 0) {
    return -1;
  }
  return av_q2d(base) * (double)frame->pts;
}

int iina_caption_read(IINACaptionDecode *decoder, double start, double seconds, IINACaptionPCM *out, char *error, int error_len) {
  if (out) {
    memset(out, 0, sizeof(*out));
  }
  if (!decoder || !out || seconds <= 0) {
    set_error(error, error_len, "nothing to decode");
    return 1;
  }
  if (start < 0) {
    start = 0;
  }
  if (seconds > 30) {
    seconds = 30;
  }
  avcodec_flush_buffers(decoder->dec);
  if (start > 0.05 && decoder->time_base.den > 0) {
    int64_t stamp = (int64_t)(start / av_q2d(decoder->time_base));
    av_seek_frame(decoder->fmt, decoder->audio_index, stamp, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(decoder->dec);
  } else if (start <= 0.05) {
    av_seek_frame(decoder->fmt, decoder->audio_index, 0, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(decoder->dec);
  }

  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  float *native = NULL;
  int native_count = 0;
  int native_cap = 0;
  int rate = 0;
  int channels = 0;
  double first_pts = -1;
  int unsupported = 0;
  if (!packet || !frame) {
    set_error(error, error_len, "out of memory");
    av_packet_free(&packet);
    av_frame_free(&frame);
    return 5;
  }

  // A backward seek lands on an earlier packet. Skip that lead-in, then keep
  // samples that overlap [start, start+seconds]. Stopping after `seconds` of
  // audio measured from the keyframe used to return a buffer that ended
  // before the playhead, so the window check never saw a covered range.
  const double window_end = start + seconds;
  int finished = 0;
  int scanned = 0;
  while (!finished && scanned < 24000) {
    int rc = av_read_frame(decoder->fmt, packet);
    if (rc < 0) {
      break;
    }
    scanned += 1;
    if (packet->stream_index != decoder->audio_index) {
      av_packet_unref(packet);
      continue;
    }
    rc = avcodec_send_packet(decoder->dec, packet);
    av_packet_unref(packet);
    if (rc < 0) {
      continue;
    }
    while ((rc = avcodec_receive_frame(decoder->dec, frame)) == 0) {
      double pts = frame_pts(frame, decoder->time_base);
      int frame_rate = frame->sample_rate > 0 ? frame->sample_rate : 0;
      double frame_span = (frame_rate > 0 && frame->nb_samples > 0)
        ? (double)frame->nb_samples / (double)frame_rate
        : 0;
      if (pts >= 0 && frame_span > 0 && pts + frame_span < start - 0.02) {
        av_frame_unref(frame);
        continue;
      }
      if (first_pts < 0 && pts >= 0) {
        first_pts = pts;
      }
      int appended = append_mono(&native, &native_count, &native_cap, frame, &rate, &channels);
      av_frame_unref(frame);
      if (appended == -2) {
        unsupported = 1;
        finished = 1;
        break;
      }
      if (appended != 0) {
        finished = 1;
        break;
      }
      if (rate > 0 && (double)native_count / (double)rate >= seconds + 2.0) {
        finished = 1;
        break;
      }
      if (pts >= window_end) {
        finished = 1;
        break;
      }
    }
  }
  avcodec_send_packet(decoder->dec, NULL);
  while (avcodec_receive_frame(decoder->dec, frame) == 0) {
    double pts = frame_pts(frame, decoder->time_base);
    int frame_rate = frame->sample_rate > 0 ? frame->sample_rate : 0;
    double frame_span = (frame_rate > 0 && frame->nb_samples > 0)
      ? (double)frame->nb_samples / (double)frame_rate
      : 0;
    if (pts >= 0 && frame_span > 0 && pts + frame_span < start - 0.02) {
      av_frame_unref(frame);
      continue;
    }
    if (first_pts < 0 && pts >= 0) {
      first_pts = pts;
    }
    append_mono(&native, &native_count, &native_cap, frame, &rate, &channels);
    av_frame_unref(frame);
    if (rate > 0 && (double)native_count / (double)rate >= seconds + 2.0) {
      break;
    }
    if (pts >= window_end) {
      break;
    }
  }

  av_packet_free(&packet);
  av_frame_free(&frame);
  if (unsupported) {
    free(native);
    set_error(error, error_len, "unsupported audio sample format");
    return 2;
  }
  if (native_count <= 0 || rate <= 0) {
    free(native);
    set_error(error, error_len, "no audio decoded");
    return 3;
  }
  resample(native, native_count, rate, out);
  free(native);
  if (!out->samples || out->count <= 0) {
    set_error(error, error_len, "could not resample audio");
    return 4;
  }
  out->start = first_pts >= 0 ? first_pts : start;
  out->source_rate = rate;
  out->channels = channels > 0 ? channels : 1;
  set_error(error, error_len, "");
  return 0;
}

void iina_caption_pcm_free(IINACaptionPCM *pcm) {
  if (!pcm) {
    return;
  }
  free(pcm->samples);
  pcm->samples = NULL;
  pcm->count = 0;
}

void iina_caption_close(IINACaptionDecode *decoder) {
  if (!decoder) {
    return;
  }
  if (decoder->dec) {
    avcodec_free_context(&decoder->dec);
  }
  if (decoder->fmt) {
    avformat_close_input(&decoder->fmt);
  }
  free(decoder);
}
