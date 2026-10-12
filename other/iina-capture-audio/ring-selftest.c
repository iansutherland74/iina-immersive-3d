/*
 *  ring-selftest.c
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 *
 *  A writer that wraps the ring, and a second writer that adds, must come
 *  back out unchanged. This is the loopback the HAL plugin uses.
 */

#include "loopback.h"
#include "ring.h"

#include <math.h>
#include <stdio.h>

static int fails = 0;

static void check(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL %s\n", message);
    fails += 1;
  }
}

int main(void) {
  static IINARing ring;
  float in[40];
  float out[40];
  uint32_t index;
  IINARing_Clear(&ring);
  for (index = 0; index < 40; index++) {
    in[index] = (float)index;
    out[index] = -1.0f;
  }
  IINARing_WriteReplace(&ring, 0, in, 20);
  IINARing_Read(&ring, 0, out, 20);
  check(out[0] == 0.0f && out[39] == 39.0f, "a stereo write is read back");

  for (index = 0; index < 40; index++) {
    in[index] = 100.0f + (float)index;
    out[index] = -1.0f;
  }
  IINARing_WriteReplace(&ring, IINA_RING_FRAMES - 10, in, 20);
  IINARing_Read(&ring, IINA_RING_FRAMES - 10, out, 20);
  check(out[0] == 100.0f && out[19] == 119.0f, "the first half sits at the end of the ring");
  check(out[20] == 120.0f && out[39] == 139.0f, "the second half wraps to the start of the ring");

  for (index = 0; index < 4; index++) {
    in[index] = 1.0f;
  }
  IINARing_WriteReplace(&ring, 50, in, 2);
  for (index = 0; index < 4; index++) {
    in[index] = 0.5f;
  }
  IINARing_WriteAdd(&ring, 50, in, 2);
  IINARing_Read(&ring, 50, out, 2);
  check(out[0] == 1.5f && out[1] == 1.5f && out[2] == 1.5f && out[3] == 1.5f, "a second writer adds instead of erasing");

  IINARing_Clear(&ring);
  IINARing_Read(&ring, 0, out, 2);
  check(out[0] == 0.0f && out[3] == 0.0f, "a cleared ring reads silence");

  /* Chrome writes a buffer. coreaudiod then asks for the NEXT buffer, which
     starts where that write ended, before the next WriteMix. That read used
     to be silence for the whole capture. */
  {
    static IINALoopback loop;
    float tone[512 * 2];
    float zeros[512 * 2];
    float heard[512 * 2];
    double energy = 0;
    uint32_t i;
    IINALoopback_Reset(&loop);
    for (i = 0; i < 512 * 2; i++) {
      tone[i] = (i % 2 == 0) ? 0.25f : -0.25f;
      zeros[i] = 0.0f;
      heard[i] = 0.0f;
    }
    IINALoopback_Write(&loop, 1000, tone, 512, IINA_LOOPBACK_SOURCE);
    IINALoopback_Write(&loop, 1000, zeros, 512, IINA_LOOPBACK_SOURCE);
    IINALoopback_Read(&loop, 1000, heard, 512);
    check(heard[0] == 0.25f && heard[1] == -0.25f, "silence mixed at the same time does not erase the tone");
    for (i = 0; i < 512 * 2; i++) {
      heard[i] = 0.0f;
    }
    IINALoopback_Read(&loop, loop.lastWriteEnd, heard, 512);
    for (i = 0; i < 512 * 2; i++) {
      energy += (double)heard[i] * (double)heard[i];
    }
    check(sqrt(energy / (512.0 * 2.0)) > 0.05, "a read at the write head is the last tone, not silence");

    IINALoopback_Write(&loop, loop.lastWriteEnd, zeros, 512, IINA_LOOPBACK_READER);
    for (i = 0; i < 512 * 2; i++) {
      heard[i] = 0.0f;
    }
    energy = 0;
    IINALoopback_Read(&loop, loop.lastWriteEnd, heard, 512);
    for (i = 0; i < 512 * 2; i++) {
      energy += (double)heard[i] * (double)heard[i];
    }
    check(sqrt(energy / (512.0 * 2.0)) > 0.05, "the loopback reader's own silence does not erase the tone");

    IINALoopback_Write(&loop, 1000 + 256, zeros, 256, IINA_LOOPBACK_SOURCE);
    IINALoopback_Read(&loop, 1000, heard, 512);
    check(heard[0] == 0.25f && heard[511 * 2] == 0.25f, "silence that overlaps the tone does not erase it");

    IINALoopback_Write(&loop, loop.lastWriteEnd, zeros, 512, IINA_LOOPBACK_SOURCE);
    IINALoopback_Read(&loop, loop.lastWriteEnd, heard, 512);
    check(heard[0] == 0.0f && heard[511 * 2 + 1] == 0.0f, "a source that goes silent is heard as silence");

    IINALoopback_Reset(&loop);
    IINALoopback_Write(&loop, 0, tone, 512, IINA_LOOPBACK_SOURCE);
    IINALoopback_Read(&loop, 512, heard, 512);
    check(heard[0] == 0.25f, "the next buffer, read before it is written, is the previous tone");
    for (i = 0; i < 512 * 2; i++) {
      tone[i] = 0.5f;
    }
    IINALoopback_Write(&loop, 512, tone, 512, IINA_LOOPBACK_SOURCE);
    IINALoopback_Read(&loop, 1024, heard, 512);
    check(heard[0] == 0.5f, "the buffer after that is the tone just written");
  }

  if (fails != 0) {
    fprintf(stderr, "%d ring checks failed\n", fails);
    return 1;
  }
  printf("ring self-test passed\n");
  return 0;
}
