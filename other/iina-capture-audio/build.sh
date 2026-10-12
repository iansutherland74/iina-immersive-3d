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

# Minimum OS is 12.0, which is <= 13.0. macOS 13.7.8 loads that binary.
# unguarded-availability is an error so a newer SDK cannot slip in an
# API that Ventura's coreaudiod does not have.
clang -bundle \
  -arch arm64 \
  -isysroot "$sdk" \
  -mmacosx-version-min=12.0 \
  -fvisibility=hidden \
  -Wall -Wextra -Werror \
  -Werror=unguarded-availability \
  -Werror=unguarded-availability-new \
  -Werror=deprecated-declarations \
  -Wl,-exported_symbol,_IINACaptureAudio_Create \
  -framework CoreAudio \
  -framework CoreFoundation \
  -I "$root" \
  -o "$stage/MacOS/IINACaptureAudio" \
  "$root/IINACaptureAudio.c" \
  "$root/ring.c" \
  "$root/loopback.c"

codesign --force --sign - "$root/build/IINACaptureAudio.driver"
test -x "$stage/MacOS/IINACaptureAudio"
file "$stage/MacOS/IINACaptureAudio"
echo "IINA Capture Audio driver built"
