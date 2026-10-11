//
//  LiveCaptionTap.h
//  iina
//
//  Copies PCM from the audio callback mpv installs for playback. The same
//  connection and the same decoder feed the speakers and the captions, so
//  every format mpv can play can be captioned.

#ifndef LiveCaptionTap_h
#define LiveCaptionTap_h

#include <stdint.h>

void iina_caption_tap_set_enabled(int enabled);
void iina_caption_tap_arm(void);
void iina_caption_tap_disarm(void);
void iina_caption_tap_mark(void);
int iina_caption_tap_attached(void);
int iina_caption_tap_rate(void);
int iina_caption_tap_channels(void);
int iina_caption_tap_copy(float *dst, int max_frames);

#endif
