#!/usr/bin/env python3
"""Export Depth Anything V2 Small to a Core ML .mlpackage for Immersive 3D.

This script was not executed in the environment that added it (a Linux VM
without the checkpoint, without coremltools, and without an M2). Run it on
the Mac. If coremltools or the upstream repo has moved, the traceback is the
source of truth.

Model
  Depth Anything V2 Small (ViT-S), Apache-2.0
  https://github.com/DepthAnything/Depth-Anything-V2
  Checkpoint (about 99 MB, not committed):
  https://huggingface.co/depth-anything/Depth-Anything-V2-Small/resolve/main/depth_anything_v2_vits.pth

Apple already publishes a fixed 518x392 Core ML build. Prefer
other/fetch_depth_model.sh unless you want the 364x280 real-time size.

The traced module applies ImageNet normalization internally. The player feeds
RGB in 0...255 via an image input (scale 1/255). Output is relative depth
named "depth", shape (1, 1, H, W), larger = farther. The player normalizes
per frame and treats larger values as farther.

Example (M2 Mac):

  git clone https://github.com/DepthAnything/Depth-Anything-V2 /tmp/Depth-Anything-V2
  python3 -m pip install --user torch coremltools pillow
  python3 other/convert_depth_anything_v2.py \\
      --repo /tmp/Depth-Anything-V2 \\
      --checkpoint /tmp/depth_anything_v2_vits.pth \\
      --width 364 --height 280
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    default_out = (
        Path.home()
        / "Library/Application Support/com.colliderli.iina/Models"
        / "DepthAnythingV2SmallF16-364x280.mlpackage"
    )
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Clone of Depth-Anything-V2 (the repo root).")
    parser.add_argument("--checkpoint", required=True, help="Path to depth_anything_v2_vits.pth.")
    parser.add_argument("--width", type=int, default=364)
    parser.add_argument("--height", type=int, default=280)
    parser.add_argument("--output", type=Path, default=default_out)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.width % 14 or args.height % 14 or args.width < 14 or args.height < 14:
        print("Width and height must be positive multiples of 14 (the ViT patch).", file=sys.stderr)
        return 2
    if args.output.exists() and not args.force:
        print(f"Refusing to overwrite {args.output} (pass --force).", file=sys.stderr)
        return 2

    try:
        import torch
        import coremltools as ct
    except ImportError as exc:
        print(f"Missing dependency: {exc}. Install torch and coremltools.", file=sys.stderr)
        return 2

    repo = Path(args.repo).resolve()
    sys.path.insert(0, str(repo))
    try:
        from depth_anything_v2.dpt import DepthAnythingV2
    except ImportError as exc:
        print(f"Could not import depth_anything_v2 from {repo}: {exc}", file=sys.stderr)
        return 2

    network = DepthAnythingV2(
        encoder="vits",
        features=64,
        out_channels=[48, 96, 192, 384],
    )
    state = torch.load(args.checkpoint, map_location="cpu")
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    network.load_state_dict(state)
    network.eval()

    class NormalizedDepth(torch.nn.Module):
        def __init__(self, model: torch.nn.Module) -> None:
            super().__init__()
            self.model = model
            mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
            std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
            self.register_buffer("mean", mean)
            self.register_buffer("std", std)

        def forward(self, image: torch.Tensor) -> torch.Tensor:
            # image is RGB in 0...1. Official V2 returns [B, H, W], larger = farther.
            depth = self.model((image - self.mean) / self.std)
            if depth.ndim == 3:
                depth = depth.unsqueeze(1)
            return depth

    wrapper = NormalizedDepth(network).eval()
    example = torch.rand(1, 3, args.height, args.width)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    color_layout = getattr(ct, "colorlayout", None)
    rgb = getattr(color_layout, "RGB", None) if color_layout is not None else None
    if rgb is None:
        print("This coremltools build has no ct.colorlayout.RGB. Install coremltools>=7.", file=sys.stderr)
        return 2

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.ImageType(
                name="image",
                shape=example.shape,
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=rgb,
            )
        ],
        outputs=[ct.TensorType(name="depth")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = (
        f"Depth Anything V2 Small relative depth, {args.width}x{args.height}, ImageNet norm inside."
    )
    mlmodel.author = "Depth Anything V2 (Apache-2.0); Core ML export by the IINA Immersive 3D fork"
    mlmodel.license = "Apache-2.0"
    mlmodel.version = "v2-small"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.output))
    print(f"Wrote {args.output}")
    print("Not timed here. On an M2, 364x280 is the size aimed at real-time;")
    print("Apple's 518x392 F16 package is the one fetch_depth_model.sh installs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
