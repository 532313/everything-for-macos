#!/usr/bin/env python3
"""Generate the Everything app icon.

Draws a modern macOS-style rounded-square icon (deep blue -> indigo gradient,
white magnifying glass, amber lightning bolt) at 4x supersampling and
downsamples with LANCZOS. Produces the 1024 master, a 256 preview, and a full
.iconset directory ready for `iconutil -c icns`.

Requires Pillow:
    python3 Tools/make_icon.py
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------- constants ---
S = 4                      # supersample factor
CANVAS = 1024              # logical master size
N = CANVAS * S             # supersampled working size

# macOS-style margins: rounded rect ~824x824 centered on a 1024 canvas.
ART = 824
MARGIN = (CANVAS - ART) // 2          # 100
RADIUS = 185

# Palette
GRAD_TOP = (18, 52, 148)      # deep blue
GRAD_BOTTOM = (74, 44, 176)   # indigo
EDGE_LIGHT = (255, 255, 255, 46)
AMBER = (255, 197, 61)
AMBER_HI = (255, 224, 130)
WHITE = (255, 255, 255, 255)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
BUILD = os.path.join(ROOT, ".icon-build")
ICONSET = os.path.join(BUILD, "Everything.iconset")

ICONSET_ENTRIES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def sc(v: float) -> float:
    """Scale a value from 1024-space into the supersampled working space."""
    return v * S


def rounded_mask(size: int, box, radius: float) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    """Two-stop vertical gradient with a subtle top-left sheen."""
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        t = y / max(1, size - 1)
        # ease-out so the deep blue holds longer at the top
        t = t ** 1.12
        px[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    img = grad.resize((size, size), Image.Resampling.NEAREST).convert("RGBA")

    # soft diagonal highlight in the upper-left for depth
    sheen = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(sheen)
    cx, cy = size * 0.24, size * 0.10
    r = size * 0.85
    steps = 64
    for i in range(steps, 0, -1):
        rr = r * i / steps
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                  fill=round(38 * (1 - i / steps)))
    sheen = sheen.filter(ImageFilter.GaussianBlur(size * 0.05))
    highlight = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    highlight.putalpha(sheen)
    return Image.alpha_composite(img, highlight)


def bolt_points(cx: float, cy: float, w: float, h: float):
    """Classic lightning bolt polygon centered on (cx, cy)."""
    unit = [
        (0.60, 0.00),
        (0.02, 0.58),
        (0.40, 0.58),
        (0.22, 1.00),
        (0.98, 0.36),
        (0.55, 0.36),
    ]
    pts = []
    for ux, uy in unit:
        pts.append((cx + (ux - 0.5) * w, cy + (uy - 0.5) * h))
    return pts


def draw_ring(d: ImageDraw.ImageDraw, center, outer_r: float, thickness: float, fill):
    """Thick magnifier ring."""
    cx, cy = center
    r = outer_r - thickness / 2.0
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=fill, width=round(thickness))


def draw_handle(d: ImageDraw.ImageDraw, start, end, thickness: float, fill):
    """Rounded-cap handle from the ring's lower-right edge."""
    d.line([start, end], fill=fill, width=round(thickness))
    for p in (start, end):
        r = thickness / 2.0
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)


def build_master() -> Image.Image:
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    box = [sc(MARGIN), sc(MARGIN), sc(MARGIN + ART), sc(MARGIN + ART)]
    body_mask = rounded_mask(N, box, sc(RADIUS))

    # --- optional soft drop shadow beneath the rounded square -----------------
    shadow = Image.new("L", (N, N), 0)
    shadow.paste(body_mask, (0, round(sc(16))))
    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(22)))
    shadow = shadow.point(lambda v: round(v * 0.42))
    shadow_layer = Image.new("RGBA", (N, N), (6, 12, 40, 0))
    shadow_layer.putalpha(shadow)
    canvas = Image.alpha_composite(canvas, shadow_layer)

    # --- gradient body --------------------------------------------------------
    body = vertical_gradient(N, GRAD_TOP, GRAD_BOTTOM)
    body.putalpha(body_mask)
    canvas = Image.alpha_composite(canvas, body)

    # --- artwork layer --------------------------------------------------------
    art = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # inner top edge light: a hairline inside the top rim for a glassy rim
    rim = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle(
        [box[0] + sc(3), box[1] + sc(3), box[2] - sc(3), box[3] - sc(3)],
        radius=sc(RADIUS - 4),
        outline=EDGE_LIGHT,
        width=sc(3),
    )
    art = Image.alpha_composite(art, rim)

    d = ImageDraw.Draw(art)

    # --- magnifying glass -----------------------------------------------------
    lens_c = (sc(452), sc(430))
    outer_r = sc(226)
    ring_t = sc(62)
    draw_ring(d, lens_c, outer_r, ring_t, WHITE)

    # handle: starts under the ring's lower-right edge, extends out at 45 deg
    ang = 0.70710678
    start = (lens_c[0] + (outer_r - ring_t * 0.55) * ang,
             lens_c[1] + (outer_r - ring_t * 0.55) * ang)
    end = (sc(762), sc(740))
    draw_handle(d, start, end, sc(76), WHITE)

    # --- amber bolt inside the lens ------------------------------------------
    # Sized to clear the ring's inner edge (outer_r - ring_t = 164px radius).
    bolt = bolt_points(sc(450), sc(430), sc(176), sc(248))
    d.line(bolt + [bolt[0]], fill=AMBER, width=sc(26), joint="curve")
    d.polygon(bolt, fill=AMBER)
    # warm highlight sliver on the left half of the bolt
    d.line([bolt[0], bolt[1], bolt[2]], fill=AMBER_HI, width=sc(11), joint="curve")
    d.line([bolt[3], bolt[4]], fill=AMBER_HI, width=sc(7), joint="curve")

    canvas = Image.alpha_composite(canvas, art)
    return canvas


def downscale(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.Resampling.LANCZOS)


def main() -> int:
    os.makedirs(RESOURCES, exist_ok=True)
    os.makedirs(ICONSET, exist_ok=True)

    master = build_master()
    master_1024 = downscale(master, CANVAS)

    # 1) 1024 master deliverable
    master_path = os.path.join(RESOURCES, "AppIcon-1024.png")
    master_1024.save(master_path, format="PNG", optimize=True)
    print(f"wrote {master_path} ({os.path.getsize(master_path)} bytes)")

    # 2) full .iconset (dedupe identical pixel sizes)
    cache: dict[int, Image.Image] = {CANVAS: master_1024}
    for name, size in ICONSET_ENTRIES:
        if size not in cache:
            cache[size] = downscale(master, size)
        cache[size].save(os.path.join(ICONSET, name), format="PNG")
        print(f"wrote {os.path.join(ICONSET, name)} ({size}x{size})")

    # 3) 256 preview deliverable
    preview_path = os.path.join(RESOURCES, "AppIcon-preview.png")
    downscale(master, 256).save(preview_path, format="PNG", optimize=True)
    print(f"wrote {preview_path} ({os.path.getsize(preview_path)} bytes)")

    # contact sheet for visual review (temporary)
    sheet = Image.new("RGBA", (16 + 32 + 64 + 128 + 256 + 4 * 12, 268), (245, 245, 247, 255))
    x = 8
    for s in (16, 32, 64, 128, 256):
        sheet.alpha_composite(cache[s], (x, 8))
        x += s + 12
    sheet.save(os.path.join(BUILD, "contact-sheet.png"))
    print(f"wrote {os.path.join(BUILD, 'contact-sheet.png')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
