#!/bin/bash
# Fail if any Mach-O under the given roots has a macOS minimum newer than 13.0.
# macOS 13.7.8 will not load a binary whose LC_BUILD_VERSION minos is higher.
# Uses otool -l, which prints LC_BUILD_VERSION and the older LC_VERSION_MIN_MACOSX.
set -euo pipefail

maximum="13.0"

version_gt() {
  local left="$1"
  local right="$2"
  local -a a b
  IFS='.' read -r -a a <<< "$left"
  IFS='.' read -r -a b <<< "$right"
  local i av bv
  for i in 0 1 2; do
    av="${a[$i]:-0}"
    bv="${b[$i]:-0}"
    av="${av%%[!0-9]*}"
    bv="${bv%%[!0-9]*}"
    av="${av:-0}"
    bv="${bv:-0}"
    if ((10#$av > 10#$bv)); then
      return 0
    fi
    if ((10#$av < 10#$bv)); then
      return 1
    fi
  done
  return 1
}

self_test() {
  version_gt 13.0 13.0 && { echo "13.0 should not be newer than 13.0"; exit 1; }
  version_gt 13.0.0 13.0 && { echo "13.0.0 should not be newer than 13.0"; exit 1; }
  version_gt 12.0 13.0 && { echo "12.0 should not be newer than 13.0"; exit 1; }
  version_gt 11.0 13.0 && { echo "11.0 should not be newer than 13.0"; exit 1; }
  version_gt 13.1 13.0 || { echo "13.1 should be newer than 13.0"; exit 1; }
  version_gt 14.0 13.0 || { echo "14.0 should be newer than 13.0"; exit 1; }
  version_gt 26.5 13.0 || { echo "26.5 should be newer than 13.0"; exit 1; }
  echo "minos comparison self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 [--self-test] <app-or-binary>..." >&2
  exit 2
fi

is_macho() {
  local magic
  magic="$(od -An -tx1 -N 4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|bebafeca|cafebabf) return 0 ;;
    *) return 1 ;;
  esac
}

collect_minos() {
  # platform 1 is PLATFORM_MACOS. LC_VERSION_MIN_MACOSX is macOS-only.
  otool -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build = 1; old = 0; platform = 0; next }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { old = 1; build = 0; next }
    $1 == "cmd" { build = 0; old = 0; next }
    build && $1 == "platform" { platform = $2; next }
    build && $1 == "minos" && platform == 1 { print $2; next }
    old && $1 == "version" { print $2; old = 0; next }
  '
}

checked=0
failed=0
while IFS= read -r -d '' path; do
  if [[ ! -f "$path" ]] || ! is_macho "$path"; then
    continue
  fi
  checked=$((checked + 1))
  versions="$(collect_minos "$path")"
  if [[ -z "$versions" ]]; then
    echo "no LC_BUILD_VERSION minos: $path" >&2
    failed=1
    continue
  fi
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    if version_gt "$version" "$maximum"; then
      echo "minos $version is newer than $maximum: $path" >&2
      failed=1
    else
      echo "minos $version  $path"
    fi
  done <<< "$versions"
done < <(find "$@" -type f -print0)

if [[ "$checked" -eq 0 ]]; then
  echo "no Mach-O files found" >&2
  exit 1
fi
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "checked $checked Mach-O file(s); every minos is $maximum or older"
