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
  loop->lastFrames = 0;
  loop->hasWritten = 0;
  loop->lastAudible = 0;
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

static void serveHead(IINALoopback *loop, float *interleaved, uint32_t frames) {
  double from = loop->lastWriteEnd - (double)frames;
  if (from < 0) {
    memset(interleaved, 0, (size_t)frames * IINA_RING_CHANNELS * sizeof(float));
    return;
  }
  IINARing_Read(&loop->ring, (uint64_t)from, interleaved, frames);
}

/* The read ends before the last write starts. That is a different input
   timeline, not a buffer that is merely one period behind. */
static int readMissesWrite(const IINALoopback *loop, double sampleTime, uint32_t frames) {
  double readEnd = sampleTime + (double)frames;
  double writeStart = loop->lastWriteEnd - (double)loop->lastFrames;
  return readEnd + 0.5 < writeStart;
}

void IINALoopback_Write(IINALoopback *loop, double sampleTime, const float *interleaved, uint32_t frames, int writer) {
  double end;
  int audible;
  if (loop == NULL || sampleTime < 0 || frames == 0 || interleaved == NULL) {
    return;
  }
  /* The reader's own output is silence. The mixed WriteMix is sometimes
     delivered with that same client id and still holds the browser. */
  if (writer == IINA_LOOPBACK_READER && isSilent(interleaved, frames)) {
    return;
  }
  audible = !isSilent(interleaved, frames);
  end = sampleTime + (double)frames;
  if (!audible) {
    if (!loop->hasWritten || sampleTime >= loop->lastWriteEnd) {
      IINARing_WriteReplace(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
      loop->lastWriteEnd = end;
      loop->hasWritten = 1;
      loop->lastAudible = 0;
    } else {
      IINARing_WriteAdd(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
    }
    loop->lastFrames = frames;
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
  loop->lastFrames = frames;
  loop->lastAudible = 1;
}

void IINALoopback_Read(IINALoopback *loop, double sampleTime, float *interleaved, uint32_t frames) {
  if (interleaved == NULL || frames == 0) {
    return;
  }
  if (loop == NULL || sampleTime < 0 || !loop->hasWritten || loop->lastFrames == 0) {
    memset(interleaved, 0, (size_t)frames * IINA_RING_CHANNELS * sizeof(float));
    return;
  }
  if (sampleTime + 0.5 >= loop->lastWriteEnd || readMissesWrite(loop, sampleTime, frames)) {
    serveHead(loop, interleaved, frames);
    return;
  }
  IINARing_Read(&loop->ring, (uint64_t)sampleTime, interleaved, frames);
  if (loop->lastAudible && isSilent(interleaved, frames)) {
    serveHead(loop, interleaved, frames);
  }
}

void IINAClock_Reset(IINAClock *clock, double ticksPerFrame, uint32_t periodFrames, double nowHost) {
  if (clock == NULL) {
    return;
  }
  clock->ticksPerFrame = ticksPerFrame > 0 ? ticksPerFrame : 1;
  clock->periodFrames = periodFrames == 0 ? 1 : periodFrames;
  clock->anchorHost = nowHost;
  clock->previousTicks = 0;
  clock->stampCount = 0;
}

void IINAClock_Read(IINAClock *clock, double nowHost, double *outSampleTime, double *outHostTime) {
  double period;
  double elapsed;
  uint64_t due;
  if (clock == NULL) {
    return;
  }
  if (clock->ticksPerFrame <= 0) {
    clock->ticksPerFrame = 1;
  }
  if (clock->periodFrames == 0) {
    clock->periodFrames = 1;
  }
  if (clock->anchorHost == 0) {
    clock->anchorHost = nowHost;
  }
  period = clock->ticksPerFrame * (double)clock->periodFrames;
  if (period < 1.0) {
    period = 1.0;
  }
  elapsed = nowHost - clock->anchorHost;
  if (elapsed < 0) {
    elapsed = 0;
  }
  due = (uint64_t)(elapsed / period);
  if (due > clock->stampCount) {
    clock->stampCount = due;
    clock->previousTicks = (double)due * period;
  }
  if (outSampleTime != NULL) {
    *outSampleTime = (double)(clock->stampCount * (uint64_t)clock->periodFrames);
  }
  if (outHostTime != NULL) {
    *outHostTime = clock->anchorHost + clock->previousTicks;
  }
}
