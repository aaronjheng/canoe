# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "Pillow",
# ]
# ///
"""Generate the Canoe macOS app icon set (glass canoe, top-down).

Design (Liquid Glass inspired, minimal):
  - Squircle background: a simple brand-blue vertical gradient with one
    soft top light and a crisp inner edge light. No extra color blooms.
  - One large top-down canoe, bow pointing up-right (travel/forward
    motion): frosted-glass hull, navy gunwale rim, dark cockpit with two
    white thwart seats, soft drop shadow. Single glyph, nothing else.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# Supersampling factor for smooth, anti-aliased edges.
SS = 2
S = 1024 * SS  # 2048 working canvas
RADIUS = 228 * SS  # macOS-ish squircle corner radius on the working canvas

# Palette (sRGB): bright friendly blues, background stays simple.
TOP = (85, 165, 252)        # light bright blue
MID = (32, 132, 238)        # vivid blue
BOTTOM = (16, 92, 205)       # medium blue (stays luminous, not navy)
NAVY = (9, 46, 105)          # gunwale rim + cockpit #092E69

# Canoe geometry (fractions of S): drawn pointing straight up, then
# rotated 45 degrees clockwise so the bow points up-right.
CANOE_TOP = 0.06             # bow tip
CANOE_BOTTOM = 0.94          # stern tip
CANOE_HALF_WIDTH = 0.120     # max hull half-width (bold for small sizes)
COCKPIT_T = (0.30, 0.70)     # cockpit span, fraction of hull length
COCKPIT_WIDTH = 0.58         # cockpit width vs hull width at same station
THWART_T = (0.385, 0.615)    # thwart seat positions, fraction of hull length
THWART_THICKNESS = 0.018     # fraction of S
SAMPLES = 72


def vertical_gradient(size, stops):
    """Build a vertical linear gradient image from (pos, (r,g,b)) stops."""
    col = Image.new("RGB", (1, size))
    px = col.load()
    for y in range(size):
        t = y / (size - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                local = (t - p0) / (p1 - p0) if p1 > p0 else 0.0
                r = int(c0[0] + (c1[0] - c0[0]) * local)
                g = int(c0[1] + (c1[1] - c0[1]) * local)
                b = int(c0[2] + (c1[2] - c0[2]) * local)
                px[0, y] = (r, g, b)
                break
    return col.resize((size, size))


def radial_glow(size, center, radius, rgb, peak_alpha):
    """RGBA overlay: solid color fading radially to transparent."""
    scale = 8
    w = size // scale
    small = Image.new("L", (w, w), 0)
    ap = small.load()
    cx, cy = center[0] / scale, center[1] / scale
    r = radius / scale
    for y in range(w):
        for x in range(w):
            d = math.hypot(x - cx, y - cy) / r
            if d < 1.0:
                ap[x, y] = int(peak_alpha * (1.0 - d) ** 1.6)
    alpha = small.resize((size, size), Image.BILINEAR)
    alpha = alpha.filter(ImageFilter.GaussianBlur(8))
    solid = Image.new("RGBA", (size, size), rgb + (255,))
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow.putalpha(alpha)
    return Image.composite(solid, glow, alpha)


def squircle_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    return mask


def hull_half_width(t, max_half):
    """Half-width at station t (0 = bow, 1 = stern): pointed ends, bow finer."""
    t = min(max(t, 0.0), 1.0)
    w = max_half * (math.sin(math.pi * t) ** 0.75)
    if t < 0.5:
        w *= 0.94
    return w


def hull_polygon(cx, top, bottom, max_half, samples=SAMPLES):
    """Outline of a vertical top-down canoe hull, bow at the top."""
    left, right = [], []
    for i in range(samples + 1):
        t = i / samples
        y = top + t * (bottom - top)
        w = hull_half_width(t, max_half)
        left.append((cx - w, y))
        right.append((cx + w, y))
    return left + right[::-1]


def build_background(s, mask):
    grad = vertical_gradient(s, [(0.0, TOP), (0.5, MID), (1.0, BOTTOM)]).convert("RGBA")
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    base = Image.alpha_composite(base, grad)
    # One soft top light, nothing else - background stays quiet.
    base = Image.alpha_composite(
        base, radial_glow(s, (0.50 * s, -0.12 * s), 0.90 * s, (255, 255, 255), 80)
    )
    # Clip everything to the squircle.
    clipped = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clipped.paste(base, (0, 0), mask)
    # Crisp inner edge light.
    d = ImageDraw.Draw(clipped)
    d.rounded_rectangle(
        [3, 3, s - 4, s - 4], radius=RADIUS,
        outline=(255, 255, 255, 70), width=max(3, int(2.5 * SS)),
    )
    return clipped


def build_hull(s, frost_source):
    """RGBA layer: upright frosted-glass canoe, rotated bow-up-right."""
    cx = s / 2
    top, bottom = s * CANOE_TOP, s * CANOE_BOTTOM
    max_half = s * CANOE_HALF_WIDTH
    length = bottom - top

    # Navy rim: full-size hull underneath.
    upright = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(upright).polygon(
        hull_polygon(cx, top, bottom, max_half), fill=NAVY + (255,)
    )

    # Frosted-glass hull: blurred background through an inset white shape.
    inset = max_half * 0.10
    white_hull = hull_polygon(cx, top + inset * 0.6, bottom - inset * 0.6, max_half - inset)
    white_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(white_mask).polygon(white_hull, fill=255)
    frost = Image.composite(frost_source, Image.new("RGBA", (s, s), (0, 0, 0, 0)), white_mask)
    overlay = Image.new("RGBA", (s, s), (255, 255, 255, 170))
    frost = Image.alpha_composite(
        frost, Image.composite(overlay, Image.new("RGBA", (s, s), (0, 0, 0, 0)), white_mask)
    )
    upright = Image.alpha_composite(upright, frost)

    # Cockpit opening.
    d = ImageDraw.Draw(upright)
    c_top, c_bot = [], []
    n = 40
    for i in range(n + 1):
        t = COCKPIT_T[0] + (COCKPIT_T[1] - COCKPIT_T[0]) * i / n
        y = top + t * length
        w = hull_half_width(t, max_half * COCKPIT_WIDTH)
        c_top.append((cx - w, y))
        c_bot.append((cx + w, y))
    d.polygon(c_top + c_bot[::-1], fill=NAVY + (255,))

    # Thwart seats: white bars across the cockpit.
    for tt in THWART_T:
        y = top + tt * length
        w = hull_half_width(tt, max_half * COCKPIT_WIDTH)
        half = THWART_THICKNESS * s / 2
        d.rounded_rectangle(
            [cx - w, y - half, cx + w, y + half],
            radius=int(half),
            fill=(255, 255, 255, 255),
        )

    # Bow pointing up-right: rotate 45 degrees clockwise.
    return upright.rotate(-45, resample=Image.BICUBIC, expand=True)


def build_master():
    s = S
    mask = squircle_mask(s, RADIUS)

    # 1. Background.
    base = build_background(s, mask)

    # 2. Frost source: clean blurred background (no glyphs in it).
    frost_source = base.filter(ImageFilter.GaussianBlur(int(18 * SS)))

    # 3. Single glyph: hull, no shadow.
    hull = build_hull(s, frost_source)
    canvas = paste_centered(base, hull)

    # 4. Downscale the supersampled canvas to the 1024 master.
    return canvas.resize((1024, 1024), Image.LANCZOS)


def paste_centered(canvas, layer, dx=0, dy=0):
    """Paste an RGBA layer centered on the canvas, plus an offset."""
    x = (canvas.width - layer.width) // 2 + dx
    y = (canvas.height - layer.height) // 2 + dy
    out = canvas.copy()
    out.paste(layer, (x, y), layer)
    return out


SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def main():
    out_dir = Path(__file__).resolve().parent.parent / "Assets.xcassets" / "Canoe.appiconset"
    out_dir.mkdir(parents=True, exist_ok=True)
    master = build_master()
    for name, size in SIZES.items():
        img = master.resize((size, size), Image.LANCZOS)
        img.save(out_dir / name, "PNG")
        print(f"wrote {name}: {size}x{size}")


if __name__ == "__main__":
    main()
