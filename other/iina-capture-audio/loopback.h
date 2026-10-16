/*
 *  loopback.h
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 *
 *  The mix BlackHole uses, without the silence gate that drops a read
 *  which arrives at the write head. coreaudiod calls ReadInput before
 *  WriteMix in the same cycle (AudioServerPlugIn.h operation order), so
 *  the input sample time is the end of the last completed write. BlackHole
 *  vends silence in that case (lastOutputSampleTime - bufferSize < input
 *  time). Existential Audio's own note on that is issue 448: the read
 *  happens before the write. Serving the last completed buffer is the
 *  loopback. On macOS 13.7 the input sample time can also sit on a
 *  different part of the timeline than the output sample time; a read
 *  that does not overlap the last write is the same case, and it returns
 *  that buffer instead of zeros.
 *
 *  A silent WriteMix from the loopback reader is ignored, so its zeroed
 *  output cannot replace the browser. A WriteMix that still contains
 *  audio is kept even when coreaudiod tags the mixed buffer with the
 *  reader's client id.
 *
 *  The device clock jumps forward by every period that has elapsed.
 *  Advancing one period per GetZeroTimeStamp call leaves the clock behind
 *  and coreaudiod stops the IO cycle, which is silence for the capture.
 */

#ifndef IINA_CAPTURE_AUDIO_LOOPBACK_H
#define IINA_CAPTURE_AUDIO_LOOPBACK_H

#include "ring.h"

#include <stdint.h>

#define IINA_LOOPBACK_SOURCE 0
#define IINA_LOOPBACK_READER 1

typedef struct IINALoopback {
  IINARing ring;
  double lastWriteEnd;
  double mixSampleTime;
  uint32_t lastFrames;
  int hasWritten;
  int lastAudible;
} IINALoopback;

typedef struct IINAClock {
  double ticksPerFrame;
  double anchorHost;
  double previousTicks;
  uint64_t stampCount;
  uint32_t periodFrames;
} IINAClock;

void IINALoopback_Reset(IINALoopback *loop);
void IINALoopback_Write(IINALoopback *loop, double sampleTime, const float *interleaved, uint32_t frames, int writer);
void IINALoopback_Read(IINALoopback *loop, double sampleTime, float *interleaved, uint32_t frames);

void IINAClock_Reset(IINAClock *clock, double ticksPerFrame, uint32_t periodFrames, double nowHost);
void IINAClock_Read(IINAClock *clock, double nowHost, double *outSampleTime, double *outHostTime);

#endif
