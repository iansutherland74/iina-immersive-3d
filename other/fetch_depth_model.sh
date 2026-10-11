#!/bin/bash
# Fetch Apple's published Depth Anything V2 Small Core ML package.
#
# Source: https://huggingface.co/apple/coreml-depth-anything-v2-small
# License: Apache-2.0 (model weights and Apple's conversion). Not vendored here.
# This does not download anything from VITURE / SpaceWalk.
#
# The F16 package is a fixed 518x392 RGB model with a float16 grayscale depth
# output. It needs macOS 13 or later. For a 364x280 build, use
# other/convert_depth_anything_v2.py instead.

set -euo pipefail

VARIANT="f16"
DEST="${HOME}/Library/Application Support/com.colliderli.iina/Models"

usage() {
  echo "Usage: $0 [--p6] [--dest DIR]"
  echo "  --p6     Download the smaller palettized F16P6 package instead of F16."
  echo "  --dest   Directory to place the .mlpackage (default: the IINA Models folder)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p6) VARIANT="p6"; shift ;;
    --dest) DEST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ "$VARIANT" == "p6" ]]; then
  PACKAGE="DepthAnythingV2SmallF16P6.mlpackage"
else
  PACKAGE="DepthAnythingV2SmallF16.mlpackage"
fi

mkdir -p "$DEST"
REPO="apple/coreml-depth-anything-v2-small"

echo "Downloading ${PACKAGE} from ${REPO}"
echo "into ${DEST}"
echo "Apache-2.0 weights stay outside git."

if python3 -c "import huggingface_hub" >/dev/null 2>&1; then
  DEST_DIR="$DEST" PACKAGE_NAME="$PACKAGE" REPO_ID="$REPO" python3 - <<'PY'
import os
from huggingface_hub import snapshot_download
dest = os.environ["DEST_DIR"]
package = os.environ["PACKAGE_NAME"]
snapshot_download(
    repo_id=os.environ["REPO_ID"],
    allow_patterns=[f"{package}/**"],
    local_dir=dest,
)
print(os.path.join(dest, package))
PY
elif command -v hf >/dev/null 2>&1; then
  hf download "$REPO" --include "${PACKAGE}/*" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO" --include "${PACKAGE}/*" --local-dir "$DEST"
else
  echo "Need huggingface_hub. On the Mac: python3 -m pip install --user huggingface_hub" >&2
  exit 1
fi

if [[ ! -d "${DEST}/${PACKAGE}" ]]; then
  echo "Download finished but ${DEST}/${PACKAGE} is missing." >&2
  exit 1
fi

echo "Ready: ${DEST}/${PACKAGE}"
echo "Launch IINA, then Settings → Video → Depth Model → Depth Anything V2 Small,"
echo "or Video → Immersive 3D. The player prefers a 364x280 package when that file exists."
