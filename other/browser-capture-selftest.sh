#!/bin/bash
# Headless Browser Capture checks: session, drawable size, window follow, frame
# coalescing, audio policy, texture lifetime, and one synthetic side-by-side
# frame. No display is required. AddressSanitizer and a zombie run cover the
# texture retain path.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun -sdk macosx metal -c "$root/iina/Immersive3D/Immersive3D.metal" -o "$work/immersive.air"
xcrun -sdk macosx metallib "$work/immersive.air" -o "$work/immersive.metallib"

sources=(
  "$root/iina/Immersive3D/GlassesDrawable.swift"
  "$root/iina/Immersive3D/GlassesSession.swift"
  "$root/iina/Immersive3D/CaptureWindowMatch.swift"
  "$root/iina/Immersive3D/CaptureFrameCoalescer.swift"
  "$root/iina/Immersive3D/CaptureAudioPolicy.swift"
  "$root/iina/Immersive3D/CaptureTextureLifetime.swift"
  "$root/iina/Immersive3D/StereoOffscreen.swift"
  "$root/other/capture-selftest/main.swift"
)

compile() {
  local output="$1"
  shift
  swiftc -parse-as-library \
    -sdk "$sdk" \
    -framework Metal \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework Foundation \
    "$@" \
    -o "$output" \
    "${sources[@]}"
}

compile "$work/capture-selftest" -sanitize=address
echo "AddressSanitizer + MallocScribble"
MallocScribble=1 MallocPreScribble=1 CAPTURE_METALLIB="$work/immersive.metallib" "$work/capture-selftest"

compile "$work/capture-selftest-zombies"
echo "NSZombieEnabled + MallocScribble"
NSZombieEnabled=YES MallocScribble=1 CAPTURE_ZOMBIES=1 CAPTURE_METALLIB="$work/immersive.metallib" "$work/capture-selftest-zombies"
