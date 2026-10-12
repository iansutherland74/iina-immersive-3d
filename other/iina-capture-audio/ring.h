/*
 *  ring.h
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 *
 *  Interleaved stereo ring shared by the HAL plugin and the headless test.
 *  The loopback idea follows BlackHole (Existential Audio, 2019, GPLv3):
 *  one sample-time clock, the writer replaces or adds, the reader copies.
 */

#ifndef IINA_CAPTURE_AUDIO_RING_H
#define IINA_CAPTURE_AUDIO_RING_H

#include <stdint.h>

#define IINA_RING_FRAMES 16384
#define IINA_RING_CHANNELS 2

typedef struct IINARing {
  float samples[IINA_RING_FRAMES * IINA_RING_CHANNELS];
} IINARing;

void IINARing_Clear(IINARing *ring);
void IINARing_WriteReplace(IINARing *ring, uint64_t sampleTime, const float *interleaved, uint32_t frames);
void IINARing_WriteAdd(IINARing *ring, uint64_t sampleTime, const float *interleaved, uint32_t frames);
void IINARing_Read(IINARing *ring, uint64_t sampleTime, float *interleaved, uint32_t frames);

#endif
