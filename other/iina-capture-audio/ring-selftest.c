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

#include "ring.h"

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

  if (fails != 0) {
    fprintf(stderr, "%d ring checks failed\n", fails);
    return 1;
  }
  printf("ring self-test passed\n");
  return 0;
}
