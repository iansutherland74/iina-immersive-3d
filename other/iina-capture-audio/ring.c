/*
 *  ring.c
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 */

#include "ring.h"

#include <string.h>

static void copySpan(float *destination, const float *source, uint32_t frames) {
  if (frames == 0 || destination == NULL || source == NULL) {
    return;
  }
  memcpy(destination, source, (size_t)frames * IINA_RING_CHANNELS * sizeof(float));
}

static void addSpan(float *destination, const float *source, uint32_t frames) {
  uint32_t count = frames * IINA_RING_CHANNELS;
  uint32_t index;
  if (destination == NULL || source == NULL) {
    return;
  }
  for (index = 0; index < count; index++) {
    destination[index] += source[index];
  }
}

static void visit(IINARing *ring, uint64_t sampleTime, const float *interleaved, float *out, uint32_t frames, int add) {
  uint32_t done = 0;
  if (ring == NULL || frames == 0) {
    return;
  }
  while (done < frames) {
    uint32_t start = (uint32_t)((sampleTime + done) % IINA_RING_FRAMES);
    uint32_t chunk = frames - done;
    uint32_t room = IINA_RING_FRAMES - start;
    float *slot = ring->samples + (start * IINA_RING_CHANNELS);
    const float *input = interleaved == NULL ? NULL : interleaved + (done * IINA_RING_CHANNELS);
    float *output = out == NULL ? NULL : out + (done * IINA_RING_CHANNELS);
    if (chunk > room) {
      chunk = room;
    }
    if (out != NULL) {
      copySpan(output, slot, chunk);
    } else if (add) {
      addSpan(slot, input, chunk);
    } else {
      copySpan(slot, input, chunk);
    }
    done += chunk;
  }
}

void IINARing_Clear(IINARing *ring) {
  if (ring == NULL) {
    return;
  }
  memset(ring->samples, 0, sizeof(ring->samples));
}

void IINARing_WriteReplace(IINARing *ring, uint64_t sampleTime, const float *interleaved, uint32_t frames) {
  visit(ring, sampleTime, interleaved, NULL, frames, 0);
}

void IINARing_WriteAdd(IINARing *ring, uint64_t sampleTime, const float *interleaved, uint32_t frames) {
  visit(ring, sampleTime, interleaved, NULL, frames, 1);
}

void IINARing_Read(IINARing *ring, uint64_t sampleTime, float *interleaved, uint32_t frames) {
  visit(ring, sampleTime, NULL, interleaved, frames, 0);
}
