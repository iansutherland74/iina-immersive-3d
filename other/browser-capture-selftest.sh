#!/bin/bash
# Headless Browser Capture checks: session, drawable size, window follow, and
# one synthetic frame through the side-by-side Metal pass. No display is required.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun -sdk macosx metal -c "$root/iina/Immersive3D/Immersive3D.metal" -o "$work/immersive.air"
xcrun -sdk macosx metallib "$work/immersive.air" -o "$work/immersive.metallib"

swiftc -parse-as-library \
  -sdk "$sdk" \
  -framework Metal \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework Foundation \
  -o "$work/capture-selftest" \
  "$root/iina/Immersive3D/GlassesDrawable.swift" \
  "$root/iina/Immersive3D/GlassesSession.swift" \
  "$root/iina/Immersive3D/CaptureWindowMatch.swift" \
  "$root/iina/Immersive3D/StereoOffscreen.swift" \
  "$root/other/capture-selftest/main.swift"

CAPTURE_METALLIB="$work/immersive.metallib" "$work/capture-selftest"
