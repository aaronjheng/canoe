# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "resvg-py"]
# ///
"""Generate the Canoe app icon (all 10 AppIcon sizes).

Pipeline: the icon is drawn as SVG (crisp strokes with round joins, so the
canoe outline has no raster nicks), rendered to a 2048 master with resvg,
then downscaled with Pillow. Everything stays in memory; only the 10 PNGs
(and `--preview`, if given) touch disk.

Design: plan-view double-ended canoe (both tips pointed, dark cockpit with
two white thwarts) lying stern-bottom-left / bow-top-right, on the original
vivid blue gradient lightened slightly. Everything sampled from the previous
icon: backdrop #105DCE -> #1F80E7 -> #4978AB (each stop mixed ~22% toward
white: #4581D9 -> #539DEB -> #7899BF), hull #B4D2F2, cockpit/outline #0A2E69,
hull beam profile (110/99/90/64/28 @ u=0/100/200/300/400), cockpit +-150 x
+-68, seats at +-112 ending flush with the cockpit edge. Tile corner radius
(225 @1024) measured from the previous icon's baked alpha.

Usage:
    uv run Tools/gen_appicon.py [--preview /tmp/canoe_icon_master.png]

Writes the 10 PNGs into Assets.xcassets/Canoe.appiconset/.
"""

import argparse
import io
import sys
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Assets.xcassets" / "Canoe.appiconset"

# ---- palette ----
BG_TOP = "#4581D9"
BG_MID = "#539DEB"
BG_BOT = "#7899BF"
HULL = "#B4D2F2"
NAVY = "#0A2E69"
WHITE = "#FFFFFF"

# ---- geometry (1024-space) ----
TILE_R = 225  # measured from the previous icon's alpha
BOAT_ANGLE = 135.0  # bow (drawn pointing down) lands top-right
HULL_HALF_LEN = 448  # axial half-length, sampled
HULL_HALF_BEAM = 110  # max half-beam at midship, sampled
OUTLINE_W = 16  # previous icon used 10; thickened to strengthen the silhouette
BOAT_SCALE = 1.08  # boat drawn slightly larger than the original to fill the tile
COCKPIT_HALF_LEN = 150  # sampled: dark block extends past the seats
COCKPIT_HALF_W = 68  # sampled
SEAT_POS = 112  # seat centers, sampled
SEAT_HALF_W = 68  # seats end flush with the cockpit edge
SEAT_H = 18  # sampled
RENDER_PX = 2048  # qlmanage master size before downscaling

SIZES = {
    "icon_512x512@2x.png": 1024,
    "icon_512x512.png": 512,
    "icon_256x256@2x.png": 512,
    "icon_256x256.png": 256,
    "icon_128x128@2x.png": 256,
    "icon_128x128.png": 128,
    "icon_32x32@2x.png": 64,
    "icon_32x32.png": 32,
    "icon_16x16@2x.png": 32,
    "icon_16x16.png": 16,
}


def _beam(y: float) -> float:
    return HULL_HALF_BEAM * max(0.0, 1 - (y / HULL_HALF_LEN) ** 2) ** 0.8


def _pt(x: float, y: float) -> str:
    return f"{512 + x * BOAT_SCALE:.2f},{512 + y * BOAT_SCALE:.2f}"


def hull_path() -> str:
    """Double-ended outline through the sampled beam profile. Both tips are
    closed with explicit quadratic caps through the exact tip points: the
    beam curve has a vertical tangent at the tips, so a bare polyline vertex
    there creases no matter how densely it is sampled."""
    n = 140
    cap = HULL_HALF_LEN - 12  # caps take over the last 12 units each end
    sb = [
        _pt(_beam(-cap + 2 * cap * i / n), -cap + 2 * cap * i / n) for i in range(n + 1)
    ]
    ps = [
        _pt(-_beam(cap - 2 * cap * i / n), cap - 2 * cap * i / n) for i in range(1, n)
    ]
    bow_tip = _pt(0, HULL_HALF_LEN)
    stern_tip = _pt(0, -HULL_HALF_LEN)
    return (
        f"M{sb[0]}L"
        + "L".join(sb[1:])
        + f"Q{bow_tip} {ps[0]}L"
        + "L".join(ps[1:])
        + f"Q{stern_tip} {sb[0]}Z"
    )


def rect(x, y, w, h, rx, fill) -> str:
    return (
        f'<rect x="{x * BOAT_SCALE + 512 * (1 - BOAT_SCALE):.2f}" '
        f'y="{y * BOAT_SCALE + 512 * (1 - BOAT_SCALE):.2f}" '
        f'width="{w * BOAT_SCALE:.2f}" height="{h * BOAT_SCALE:.2f}" '
        f'rx="{rx * BOAT_SCALE:.2f}" fill="{fill}"/>'
    )


def build_svg() -> str:
    hull = hull_path()
    cx = 512 - COCKPIT_HALF_W
    parts = [
        f'<rect x="0" y="0" width="1024" height="1024" rx="{TILE_R}" fill="url(#bg)"/>',
        # SVG rotate() is clockwise (y-down); negating lands the bow top-right.
        f'<g transform="rotate({-BOAT_ANGLE} 512 512)">',
        (
            f'<path d="{hull}" fill="{HULL}" stroke="{NAVY}" '
            f'stroke-width="{OUTLINE_W}" stroke-linejoin="round"/>'
        ),
        rect(
            cx,
            512 - COCKPIT_HALF_LEN,
            COCKPIT_HALF_W * 2,
            COCKPIT_HALF_LEN * 2,
            28,
            NAVY,
        ),
        rect(cx, 512 - SEAT_POS - SEAT_H / 2, SEAT_HALF_W * 2, SEAT_H, 6, WHITE),
        rect(cx, 512 + SEAT_POS - SEAT_H / 2, SEAT_HALF_W * 2, SEAT_H, 6, WHITE),
        "</g>",
    ]
    body = "\n    ".join(parts)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="{BG_BOT}"/>
      <stop offset="0.45" stop-color="{BG_MID}"/>
      <stop offset="1" stop-color="{BG_TOP}"/>
    </linearGradient>
  </defs>
  <g>
    {body}
  </g>
</svg>
'''


def render_master() -> Image.Image:
    png = resvg_py.svg_to_bytes(
        svg_string=build_svg(), width=RENDER_PX, height=RENDER_PX
    )
    return (
        Image.open(io.BytesIO(png)).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--preview",
        type=str,
        default="/tmp/canoe_icon_master.png",
        help="also write the 1024 master to this path",
    )
    args = ap.parse_args()

    master = render_master()
    for name, s in SIZES.items():
        img = master if s == 1024 else master.resize((s, s), Image.LANCZOS)
        img.save(ICONSET / name)
    if args.preview:
        master.save(args.preview)
    print(
        f"wrote {len(SIZES)} sizes to {ICONSET}"
        + (f", preview {args.preview}" if args.preview else "")
    )


if __name__ == "__main__":
    sys.exit(main())
