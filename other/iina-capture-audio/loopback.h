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
 *  loopback. A writer that is the loopback reader itself is ignored, so
 *  its zeroed output cannot replace the browser the way BlackHole's
 *  memcpy WriteMix can.
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
  int hasWritten;
} IINALoopback;

void IINALoopback_Reset(IINALoopback *loop);
void IINALoopback_Write(IINALoopback *loop, double sampleTime, const float *interleaved, uint32_t frames, int writer);
void IINALoopback_Read(IINALoopback *loop, double sampleTime, float *interleaved, uint32_t frames);

#endif
