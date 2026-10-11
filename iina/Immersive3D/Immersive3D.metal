#include <metal_stdlib>
using namespace metal;

// Side-by-side synthesis for the glasses display.
//
// The output is the screen framebuffer. It is split at width/2, so each eye
// owns exactly half of the screen's pixel width.
//
// On a 1920x1080 panel, content is the full frame (half-SBS): each eye samples
// the whole picture and the glasses unsqueeze that half.
// On a 3840x1080 panel, content is the aspect-fitted video inside the
// framebuffer (the center 1920x1080 for a 16:9 picture). Each eye samples that
// rect into its 1920-wide half, so the eye is full size instead of a squashed
// view of the pillarboxed frame.
//
// contentX/Y/W/H are top-down and normalized. (0, 0, 1, 1) matches the
// half-SBS path. Shift is a fraction of the content width.
//
// Coordinate contract (see Immersive3DCompositor.swift):
//   * gid.y == 0 is the top of the picture.
//   * The depth texture is uploaded top-down, so its v=0 is the top.
//   * The color IOSurface was filled by OpenGL, whose first row is the bottom
//     of the image. Metal's normalized v=0 addresses that first row, so color
//     is sampled at (1 - vTop) unless the user flips the picture.

struct StereoParams {
  float maxShift;
  float convergence;
  float holeThreshold;
  float invertDepth;
  float glOriented;
  float searchPixels;
  float contentX;
  float contentY;
  float contentW;
  float contentH;
};

kernel void immersiveStereo(
  texture2d<float, access::sample> colorTex [[texture(0)]],
  texture2d<float, access::sample> depthTex [[texture(1)]],
  texture2d<float, access::write> outTex [[texture(2)]],
  constant StereoParams &params [[buffer(0)]],
  uint2 gid [[thread_position_in_grid]]
) {
  const uint width = outTex.get_width();
  const uint height = outTex.get_height();
  if (gid.x >= width || gid.y >= height || width < 2 || height < 2) {
    return;
  }

  constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);

  const float yTop = (float(gid.y) + 0.5) / float(height);
  const bool leftEye = gid.x < (width / 2);
  const float halfWidth = float(width) * 0.5;
  float localX = leftEye
    ? (float(gid.x) + 0.5) / halfWidth
    : (float(gid.x) - halfWidth + 0.5) / halfWidth;
  localX = clamp(localX, 0.0, 1.0);

  const float contentX = params.contentX;
  const float contentY = params.contentY;
  const float contentW = max(params.contentW, 1e-4);
  const float contentH = max(params.contentH, 1e-4);
  const float vTop = contentY + yTop * contentH;
  const float u = contentX + localX * contentW;

  float depth = depthTex.sample(linear, float2(u, vTop)).r;
  if (params.invertDepth > 0.5) {
    depth = 1.0 - depth;
  }
  depth = clamp(depth, 0.0, 1.0);

  // Positive shift moves nearer-than-screen pixels outward in each eye.
  // Backward mapping: the output pixel samples the source that would have
  // landed on it after that outward move. Shift is a fraction of content width.
  const float shift = (depth - params.convergence) * params.maxShift;
  const float srcLocal = leftEye ? (localX + shift) : (localX - shift);
  const float clampedLocal = clamp(srcLocal, 0.0, 1.0);
  const float srcU = contentX + clampedLocal * contentW;

  // glOriented > 0.5 means Metal v=0 is the bottom row of the color image.
  const float colorY = params.glOriented > 0.5 ? (1.0 - vTop) : vTop;

  float4 color = colorTex.sample(linear, float2(srcU, colorY));

  float sampledDepth = depthTex.sample(linear, float2(srcU, vTop)).r;
  if (params.invertDepth > 0.5) {
    sampledDepth = 1.0 - sampledDepth;
  }

  // A much nearer sample means the backward map landed on an occluder.
  // Walk back toward the unshifted pixel and take the first background hit.
  if (sampledDepth > depth + params.holeThreshold && srcLocal >= 0.0 && srcLocal <= 1.0) {
    const float direction = leftEye ? -1.0 : 1.0;
    const float contentPixels = max(float(colorTex.get_width()) * contentW, 1.0);
    const float step = 1.0 / contentPixels;
    const int limit = clamp(int(params.searchPixels), 1, 24);
    for (int i = 1; i <= 24; ++i) {
      if (i > limit) {
        break;
      }
      const float xLocal = srcLocal + direction * step * float(i);
      if (xLocal < 0.0 || xLocal > 1.0) {
        break;
      }
      const float x = contentX + xLocal * contentW;
      float candidate = depthTex.sample(linear, float2(x, vTop)).r;
      if (params.invertDepth > 0.5) {
        candidate = 1.0 - candidate;
      }
      if (candidate <= depth + params.holeThreshold) {
        color = colorTex.sample(linear, float2(x, colorY));
        break;
      }
    }
  }

  color.a = 1.0;
  const uint yWrite = params.glOriented > 0.5 ? (height - 1 - gid.y) : gid.y;
  outTex.write(color, uint2(gid.x, yWrite));
}
