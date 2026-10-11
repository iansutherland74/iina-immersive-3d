#include <metal_stdlib>
using namespace metal;

// Full-frame side-by-side synthesis.
//
// The source color is the mpv frame already aspect-fitted into the viewport.
// Each eye is packed into one half of that same viewport (half-SBS), which is
// what a 1920x1080 glasses panel consumes in 3D mode.
//
// Coordinate contract (see Immersive3DCompositor.swift):
//   * gid.y == 0 is the top of the picture.
//   * The depth texture is uploaded top-down, so its v=0 is the top.
//   * The color IOSurface was filled by OpenGL, whose first row is the bottom
//     of the image. Metal's normalized v=0 addresses that first row, so color
//     is sampled at (1 - yTop) unless the user flips the picture.

struct StereoParams {
  float maxShift;
  float convergence;
  float holeThreshold;
  float invertDepth;
  float glOriented;
  float searchPixels;
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

  float depth = depthTex.sample(linear, float2(localX, yTop)).r;
  if (params.invertDepth > 0.5) {
    depth = 1.0 - depth;
  }
  depth = clamp(depth, 0.0, 1.0);

  // Positive shift moves nearer-than-screen pixels outward in each eye.
  // Backward mapping: the output pixel samples the source that would have
  // landed on it after that outward move.
  const float shift = (depth - params.convergence) * params.maxShift;
  const float srcX = leftEye ? (localX + shift) : (localX - shift);
  const float clampedX = clamp(srcX, 0.0, 1.0);

  // glOriented > 0.5 means Metal v=0 is the bottom row of the color image.
  const float colorY = params.glOriented > 0.5 ? (1.0 - yTop) : yTop;

  float4 color = colorTex.sample(linear, float2(clampedX, colorY));

  float sampledDepth = depthTex.sample(linear, float2(clampedX, yTop)).r;
  if (params.invertDepth > 0.5) {
    sampledDepth = 1.0 - sampledDepth;
  }

  // A much nearer sample means the backward map landed on an occluder.
  // Walk back toward the unshifted pixel and take the first background hit.
  if (sampledDepth > depth + params.holeThreshold && srcX >= 0.0 && srcX <= 1.0) {
    const float direction = leftEye ? -1.0 : 1.0;
    const float step = 1.0 / max(float(colorTex.get_width()), 1.0);
    const int limit = clamp(int(params.searchPixels), 1, 24);
    for (int i = 1; i <= 24; ++i) {
      if (i > limit) {
        break;
      }
      const float x = srcX + direction * step * float(i);
      if (x < 0.0 || x > 1.0) {
        break;
      }
      float candidate = depthTex.sample(linear, float2(x, yTop)).r;
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
