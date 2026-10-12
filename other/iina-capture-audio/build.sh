#!/bin/bash
# Build the IINA Capture Audio HAL plugin for arm64, macOS 12 and later.
# Sign it ad-hoc, the same way IINA.app is signed. Do not install it and do
# not restart coreaudiod. The app copies it into /Library with an admin prompt.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
stage="$root/build/IINACaptureAudio.driver/Contents"
rm -rf "$root/build"
mkdir -p "$stage/MacOS"
cp "$root/Info.plist" "$stage/Info.plist"

clang -bundle \
  -arch arm64 \
  -isysroot "$sdk" \
  -mmacosx-version-min=12.0 \
  -fvisibility=hidden \
  -Wl,-exported_symbol,_IINACaptureAudio_Create \
  -framework CoreAudio \
  -framework CoreFoundation \
  -I "$root" \
  -o "$stage/MacOS/IINACaptureAudio" \
  "$root/IINACaptureAudio.c" \
  "$root/ring.c"

codesign --force --sign - "$root/build/IINACaptureAudio.driver"
test -x "$stage/MacOS/IINACaptureAudio"
file "$stage/MacOS/IINACaptureAudio"
echo "IINA Capture Audio driver built"
