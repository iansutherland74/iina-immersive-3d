//
//  LiveCaptionDecode.h
//  iina
//
//  Decodes audio with the FFmpeg libraries already linked into IINA.
//  Callers pass a local file. Network streams are not opened here, so a
//  provider that allows one connection is not contacted a second time.

#ifndef LiveCaptionDecode_h
#define LiveCaptionDecode_h

#include <stdint.h>

typedef struct IINACaptionDecode IINACaptionDecode;

typedef struct IINACaptionPCM {
  float *samples;
  int count;
  double start;
  int source_rate;
  int channels;
} IINACaptionPCM;

IINACaptionDecode *iina_caption_open(const char *path, char *error, int error_len);
double iina_caption_duration(IINACaptionDecode *decoder);
int iina_caption_read(IINACaptionDecode *decoder, double start, double seconds, IINACaptionPCM *out, char *error, int error_len);
void iina_caption_pcm_free(IINACaptionPCM *pcm);
void iina_caption_close(IINACaptionDecode *decoder);

#endif
