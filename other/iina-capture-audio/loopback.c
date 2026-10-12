/*
 *  loopback.c
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 */

#include "loopback.h"

#include <string.h>

void IINALoopback_Reset(IINALoopback *loop) {
  if (loop == NULL) {
    return;
  }
  IINARing_Clear(&loop->ring);
  loop->lastWriteEnd = 0;
  loop->mixSampleTime = -1;
  loop->hasWritten = 0;
}

static int isSilent(const float *samples, uint32_t frames) {
  uint32_t count = frames * IINA_RING_CHANNELS;
  uint32_t index;
  if (samples == NULL) {
    return 1;
  }
  for (index = 0; index < count; index++) {
    if (samples[index] != 0.0f) {
      return 0;
    }
  }
  return 1;
}

void IINALoopback_Write(IINALoopback *loop, double sampleTime, const float *interleaved, uint32_t frames, int writer) {
  double end;
  if (loop == NULL || sampleTime < 0 || frames == 0 || interleaved == NULL) {
    return;
  }
  if (writer == IINA_LOOPBACK_READER) {
    return;
  }
  end = sampleTime + (double)frames;
  if (isSilent(interleaved, frames)) {
    if (!loop->hasWritten || sampleTime >= loop->lastWriteEnd) {
      IINARing_WriteReplace(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
      loop->lastWriteEnd = end;
      loop->hasWritten = 1;
    } else {
      IINARing_WriteAdd(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
    }
    return;
  }
  if (sampleTime != loop->mixSampleTime) {
    IINARing_WriteReplace(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
    loop->mixSampleTime = sampleTime;
  } else {
    IINARing_WriteAdd(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
  }
  if (!loop->hasWritten || end > loop->lastWriteEnd) {
    loop->lastWriteEnd = end;
  }
  loop->hasWritten = 1;
}

void IINALoopback_Read(IINALoopback *loop, double sampleTime, float *interleaved, uint32_t frames) {
  double from;
  if (interleaved == NULL || frames == 0) {
    return;
  }
  if (loop == NULL || sampleTime < 0 || !loop->hasWritten) {
    memset(interleaved, 0, (size_t)frames * IINA_RING_CHANNELS * sizeof(float));
    return;
  }
  if (sampleTime + 0.5 < loop->lastWriteEnd) {
    IINARing_Read(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
    return;
  }
  from = loop->lastWriteEnd - (double)frames;
  if (from < 0) {
    memset(interleaved, 0, (size_t)frames * IINA_RING_CHANNELS * sizeof(float));
    return;
  }
  IINARing_Read(&loop->ring, (uint64_t)from, interleaved, frames);
}
