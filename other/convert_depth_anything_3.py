#!/usr/bin/env python3
"""Export Depth Anything 3 Small's monocular relative depth to Core ML.

There is no official Core ML build of DA3. This script traces a single-view
forward of depth-anything/DA3-SMALL (Apache-2.0, about 34M parameters in the
ViT-S depth network; the Hugging Face card lists 0.08B for the full any-view
checkpoint) and saves an .mlpackage the player can load.

THIS CONVERSION WAS NOT RUN where the script was added. That environment is
Linux, without the DA3 weights, without a successful coremltools conversion,
and without an M2. Expect to debug trace failures locally. RoPE's
data-dependent frequency length and the DualDPT auxiliary ray head are the
two pieces this script tries to keep out of the graph; scaled-dot-product
attention, 2D RoPE, and einops rearrange still have to lower through
coremltools. If that fails, the traceback is printed and nothing is saved.

What the export keeps
  One RGB image -> ImageNet normalization -> DINOv2 ViT-S (N=1 view) ->
  the depth half of DualDPT. Camera encoder/decoder, sky quantile, Gaussian
  head, and (when the patch applies) the auxiliary ray head are not outputs.
  Depth is the exp-activated relative map: larger means farther.

Input size
  Upstream inference uses process_res=504, and 504 is a multiple of the
  patch size 14, so the default export is 504x504. That square resize
  squashes a 16:9 frame for the duration of the forward; the player samples
  the depth map in normalized coordinates, so the map is stretched back onto
  the frame. --width 364 --height 280 matches the real-time size used for V2
  and should be faster, with a quality cost that was not measured.

Speed (not measured on an M2)
  V2 Small at 518x392 is the default because Apple ships that Core ML model
  and it is the lighter known path. DA3-SMALL at 504x504 has more pixels
  (254016 vs 203056) and a heavier dense head on a similar ViT-S backbone.
  Expect it to be slower than V2 Small at 518x392, often enough that the
  player reuses a depth map across several frames instead of updating every
  frame. A 364x280 DA3 export should land closer to the V2 real-time budget.
  None of those timings were taken here.

Example (M2 Mac):

  git clone https://github.com/ByteDance-Seed/depth-anything-3 /tmp/depth-anything-3
  python3 -m pip install --user -e /tmp/depth-anything-3
  python3 -m pip install --user coremltools torch
  python3 other/convert_depth_anything_3.py
  # faster, lower resolution:
  python3 other/convert_depth_anything_3.py --width 364 --height 280 --force

Then in IINA: Settings -> Video -> Depth Model -> Depth Anything 3 Small.
"""

from __future__ import annotations

import argparse
import sys
import types
from pathlib import Path


def parse_args() -> argparse.Namespace:
    default_out = (
        Path.home()
        / "Library/Application Support/com.colliderli.iina/Models"
        / "DepthAnything3SmallF16-504x504.mlpackage"
    )
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--model",
        default="depth-anything/DA3-SMALL",
        help="Hugging Face id or a local directory from DepthAnything3.from_pretrained.",
    )
    parser.add_argument("--width", type=int, default=504)
    parser.add_argument("--height", type=int, default=504)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def patch_rope(module, seq_len: int) -> int:
    """Bake RoPE's frequency-table length. Upstream uses int(positions.max())+1."""
    patched = 0
    for child in module.modules():
        if child.__class__.__name__ != "RotaryPositionEmbedding2D":
            continue

        def forward(self, tokens, positions, _seq=seq_len):
            import torch

            feature_dim = tokens.size(-1) // 2
            cos_comp, sin_comp = self._compute_frequency_components(
                feature_dim, _seq, tokens.device, tokens.dtype
            )
            vertical, horizontal = tokens.chunk(2, dim=-1)
            vertical = self._apply_1d_rope(vertical, positions[..., 0], cos_comp, sin_comp)
            horizontal = self._apply_1d_rope(horizontal, positions[..., 1], cos_comp, sin_comp)
            return torch.cat((vertical, horizontal), dim=-1)

        child.forward = types.MethodType(forward, child)
        patched += 1
    return patched


def install_depth_only_head(head) -> bool:
    """Replace DualDPT._forward_impl with the main depth path only.

    The auxiliary ray fusion does not feed the depth output. Dropping it keeps
    the exported graph smaller. Returns False if the module does not look like
    the DualDPT this was written against; the caller then traces the full head.
    """
    scratch = getattr(head, "scratch", None)
    required = (
        "projects",
        "resize_layers",
        "intermediate_layer_idx",
        "patch_size",
        "down_ratio",
        "activation",
        "head_main",
        "norm",
        "_apply_activation_single",
    )
    if getattr(head, "pos_embed", False) and not hasattr(head, "_add_pos_embed"):
        return False
    if scratch is None or any(not hasattr(head, name) for name in required):
        return False
    for name in (
        "layer1_rn",
        "layer2_rn",
        "layer3_rn",
        "layer4_rn",
        "refinenet1",
        "refinenet2",
        "refinenet3",
        "refinenet4",
        "output_conv1",
        "output_conv2",
    ):
        if not hasattr(scratch, name):
            return False

    try:
        from depth_anything_3.model.utils.head_utils import custom_interpolate
    except ImportError:
        return False

    def depth_only(feats, height, width, patch_start_idx):
        batch, _, channels = feats[0].shape
        patch_h = height // head.patch_size
        patch_w = width // head.patch_size
        resized = []
        for stage_idx, take_idx in enumerate(head.intermediate_layer_idx):
            tokens = feats[take_idx][:, patch_start_idx:]
            tokens = head.norm(tokens)
            tokens = tokens.permute(0, 2, 1).reshape(batch, channels, patch_h, patch_w)
            tokens = head.projects[stage_idx](tokens)
            if getattr(head, "pos_embed", False):
                tokens = head._add_pos_embed(tokens, width, height)
            resized.append(head.resize_layers[stage_idx](tokens))
        level1, level2, level3, level4 = resized
        level1 = scratch.layer1_rn(level1)
        level2 = scratch.layer2_rn(level2)
        level3 = scratch.layer3_rn(level3)
        level4 = scratch.layer4_rn(level4)
        fused = scratch.refinenet4(level4, size=level3.shape[2:])
        fused = scratch.refinenet3(fused, level3, size=level2.shape[2:])
        fused = scratch.refinenet2(fused, level2, size=level1.shape[2:])
        fused = scratch.refinenet1(fused, level1)
        fused = scratch.output_conv1(fused)
        out_h = int(patch_h * head.patch_size / head.down_ratio)
        out_w = int(patch_w * head.patch_size / head.down_ratio)
        fused = custom_interpolate(fused, (out_h, out_w), mode="bilinear", align_corners=True)
        if getattr(head, "pos_embed", False):
            fused = head._add_pos_embed(fused, width, height)
        logits = scratch.output_conv2(fused)
        feature_map = logits.permute(0, 2, 3, 1)
        depth = head._apply_activation_single(feature_map[..., :-1], head.activation)
        return depth.squeeze(-1)

    head._forward_impl = depth_only
    return True


def main() -> int:
    args = parse_args()
    if args.width % 14 or args.height % 14 or args.width < 14 or args.height < 14:
        print("Width and height must be positive multiples of 14.", file=sys.stderr)
        return 2
    output = args.output
    if output is None:
        output = (
            Path.home()
            / "Library/Application Support/com.colliderli.iina/Models"
            / f"DepthAnything3SmallF16-{args.width}x{args.height}.mlpackage"
        )
    if output.exists() and not args.force:
        print(f"Refusing to overwrite {output} (pass --force).", file=sys.stderr)
        return 2

    try:
        import torch
        import coremltools as ct
        from depth_anything_3.api import DepthAnything3
    except ImportError as exc:
        print(
            "Need torch, coremltools, and an installed Depth Anything 3 checkout "
            f"(pip install -e /path/to/depth-anything-3).\n{exc}",
            file=sys.stderr,
        )
        return 2

    print(f"Loading {args.model} on CPU. This downloads weights on first use.")
    api = DepthAnything3.from_pretrained(args.model)
    net = getattr(api, "model", None)
    if net is None or not hasattr(net, "backbone") or not hasattr(net, "head"):
        print(f"Unexpected object from from_pretrained: {type(api)}", file=sys.stderr)
        return 2
    net.eval()
    # Single-view export does not use pose tokens or the camera decoder.
    net.cam_dec = None
    net.cam_enc = None

    # Positions are 0 for the class token and 1..grid for patches.
    seq_len = max(args.height, args.width) // 14 + 2
    patched = patch_rope(net, seq_len)
    print(f"Patched {patched} RoPE module(s) to a fixed frequency length of {seq_len}.")
    if patched == 0:
        print("Warning: no RotaryPositionEmbedding2D found; tracing may fail on int(positions.max()).")

    depth_only = install_depth_only_head(net.head)
    if depth_only:
        print("DualDPT auxiliary ray head will not be traced.")
    else:
        print("Could not patch DualDPT; tracing the full head and reading the depth key.")

    class MonoRelativeDepth(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.backbone = net.backbone
            self.head = net.head
            mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
            std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
            self.register_buffer("mean", mean)
            self.register_buffer("std", std)

        def forward(self, image: torch.Tensor) -> torch.Tensor:
            views = ((image - self.mean) / self.std).unsqueeze(1)
            feats, _aux = self.backbone(
                views,
                export_feat_layers=[],
                cam_token=None,
                ref_view_strategy="first",
            )
            tokens = []
            for feat in feats:
                token = feat[0]
                batch, views_n, count, channels = token.shape
                tokens.append(token.reshape(batch * views_n, count, channels))
            if depth_only:
                depth = self.head._forward_impl(tokens, args.height, args.width, 0)
            else:
                depth = self.head(feats, args.height, args.width, patch_start_idx=0)["depth"]
                if depth.ndim == 4:
                    depth = depth[:, 0]
            if depth.ndim == 3:
                depth = depth.unsqueeze(1)
            return depth

    wrapper = MonoRelativeDepth().eval()
    example = torch.rand(1, 3, args.height, args.width)
    print(f"Tracing a {args.width}x{args.height} forward. This can take several minutes.")
    try:
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, example)
    except Exception as exc:
        print("torch.jit.trace failed. The export was not tested upstream of this message.", file=sys.stderr)
        print(exc, file=sys.stderr)
        return 1

    color_layout = getattr(ct, "colorlayout", None)
    rgb = getattr(color_layout, "RGB", None) if color_layout is not None else None
    if rgb is None:
        print("This coremltools build has no ct.colorlayout.RGB. Install coremltools>=7.", file=sys.stderr)
        return 2

    try:
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
    except Exception as exc:
        print("coremltools conversion failed. No package was written.", file=sys.stderr)
        print(exc, file=sys.stderr)
        return 1

    mlmodel.short_description = (
        f"Depth Anything 3 Small monocular relative depth, {args.width}x{args.height}. "
        "ImageNet normalization is inside the model. Larger depth is farther."
    )
    mlmodel.author = "Depth Anything 3 (Apache-2.0, ByteDance Seed); Core ML export by the IINA Immersive 3D fork"
    mlmodel.license = "Apache-2.0"
    mlmodel.version = "da3-small"
    output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output))
    print(f"Wrote {output}")
    print("Select Depth Anything 3 Small in Settings → Video, or Video → Depth Model.")
    print("Conversion and M2 timing were not verified when this script was written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
