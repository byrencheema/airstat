#!/usr/bin/env python3
"""Draws the backdrop the .dmg window shows behind the app and the Applications alias.

Finder places the two icons on top of this image at the coordinates in dmg.py, so the
arrow is drawn to sit in the gap between them. Run it whenever those coordinates move:

    uv run Scripts/dmg-background.py

It writes Resources/dmg-background.png and @2x beside it, then combines the pair into
the .tiff Finder needs to pick the right one per display.
"""

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 640, 400
ICON_Y = 205
APP_X, ALIAS_X = 165, 475

PAPER = (245, 248, 250)
INK = (11, 31, 51)
INK_3 = (122, 143, 161)
LINE = (206, 218, 227)

# SFNS.ttf is a variable font and PIL renders its default instance compressed, so the
# heading comes out looking like a different typeface. HelveticaNeue is static.
FONTS = [
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
]


def font(size, index=0):
    for path in FONTS:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                continue
    return ImageFont.load_default()


def centred(draw, text, y, fnt, fill, scale):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((W * scale - (right - left)) / 2 - left, y * scale - top), text, font=fnt, fill=fill)


def draw(scale):
    img = Image.new("RGB", (W * scale, H * scale), PAPER)
    d = ImageDraw.Draw(img)

    centred(d, "Drag AirStats into Applications", 56 * scale, font(20 * scale, index=1), INK, 1)
    centred(d, "Then eject this disk image", 88 * scale, font(13 * scale), INK_3, 1)

    # The arrow spans the gap between the two icon slots. 128px icons are drawn
    # centred on those slots, so 82px of clearance keeps it off both of them.
    y = ICON_Y * scale
    x0, x1 = (APP_X + 82) * scale, (ALIAS_X - 82) * scale
    d.line([(x0, y), (x1 - 9 * scale, y)], fill=LINE, width=max(1, 2 * scale))
    d.polygon(
        [(x1, y), (x1 - 13 * scale, y - 8 * scale), (x1 - 13 * scale, y + 8 * scale)],
        fill=LINE,
    )
    return img


def main():
    out = Path(__file__).resolve().parent.parent / "Resources"
    one, two = out / "dmg-background.png", out / "dmg-background@2x.png"
    draw(1).save(one)
    draw(2).save(two)
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(out / "dmg-background.tiff")],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    print(f"wrote {one.name}, {two.name} and dmg-background.tiff")


if __name__ == "__main__":
    main()
