#!/usr/bin/env python3
"""Draw Caravan's app icon and write the icon set Xcode compiles.

**Generated rather than committed as art**, for the same reason the README's ASCII art is:
a PNG in a repository is a thing nobody can review or adjust, and every change to it is a
binary diff. This is the drawing, in the form that can be argued with.

**No SF Symbol.** Apple's SF Symbols licence forbids their use in app icons, so the globe
here is drawn from circles and ellipses — a wireframe, which is also a more generic idea of
"globe" than any particular coastline.

    ./Scripts/render-icon.py            # write App/Assets.xcassets/AppIcon.appiconset
    ./Scripts/render-icon.py --preview  # also write icon-preview.png beside the repo root
"""

import json
import math
import pathlib
import sys

from PIL import Image, ImageDraw

# Drawn at eight times the largest size and downsampled. Curves this thin alias badly
# otherwise, and the 16pt icon is mostly curve.
SUPERSAMPLE = 8
CANVAS = 1024

# macOS draws no mask for you: the rounded square is part of the picture. Apple's grid puts
# an 824pt square inside the 1024pt canvas, with a 185pt corner radius.
PLATE = 824
RADIUS = 185

# Dark, as asked. A little blue rather than neutral grey, so it does not read as "disabled"
# beside the colourful icons either side of it in a Dock.
PLATE_TOP = (26, 32, 40)
PLATE_BOTTOM = (13, 16, 20)
# The green the client already uses for a live connection, lightened enough to hold at 16pt.
GLOBE = (95, 211, 168)
GLOBE_DIM = (58, 133, 108)


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return gradient.resize((size, size), Image.Resampling.BILINEAR)


def draw_globe(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float, stroke: int,
               detail: str) -> None:
    """A wireframe globe: the outline, some meridians and some parallels.

    **`detail` is not a nicety.** Rendered from one master, the 16pt icon — Finder's list
    view, every menu — came out a green smudge: seven curves inside sixteen pixels cannot be
    anything else. Small sizes get one meridian and one parallel and a heavier stroke, which
    is a globe at that size; the full wireframe returns once there is room for it.
    """
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=GLOBE, width=stroke)
    draw.line([cx, cy - r, cx, cy + r], fill=GLOBE if detail == "plain" else GLOBE_DIM,
              width=stroke)
    draw.line([cx - r, cy, cx + r, cy], fill=GLOBE, width=stroke)

    if detail == "plain":
        return

    # Meridians. One seen from the side is an ellipse whose half-width is the cosine of how
    # far round the sphere it has turned; at 90 degrees it degenerates to the vertical line
    # already drawn above.
    for turn in (0.34, 0.68):
        half = r * math.cos(turn * math.pi / 2)
        draw.ellipse([cx - half, cy - r, cx + half, cy + r], outline=GLOBE_DIM, width=stroke)

    # Parallels. Straight lines rather than ellipses: at these sizes the curvature of a
    # latitude line is a pixel or less, and a straight one stays crisp.
    for fraction in (-0.55, 0.55):
        y = cy + r * fraction
        half = r * math.sqrt(max(1 - fraction * fraction, 0))
        draw.line([cx - half, y, cx + half, y], fill=GLOBE_DIM, width=stroke)


def render(size: int = CANVAS) -> Image.Image:
    big = size * SUPERSAMPLE
    plate = round(PLATE * big / CANVAS)
    radius = round(RADIUS * big / CANVAS)

    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    background = vertical_gradient(plate, PLATE_TOP, PLATE_BOTTOM)
    offset = (big - plate) // 2
    canvas.paste(background, (offset, offset), rounded_rect_mask(plate, radius))

    draw = ImageDraw.Draw(canvas)
    centre = big / 2

    # Below 40 pixels there is no room for a wireframe, and a heavier line is the only thing
    # that survives the downsample.
    detail = "plain" if size < 40 else "full"
    weight = 0.020 if detail == "plain" else 0.011
    # Inside the plate with room to breathe: an icon that fills its square looks bigger than
    # its neighbours and reads as shouting. The small one is allowed a little more of it,
    # because at sixteen pixels the margin costs more than it buys.
    radius_globe = plate * (0.345 if detail == "plain" else 0.315)

    draw_globe(draw, centre, centre, radius_globe, max(round(big * weight), 1), detail)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


VARIANTS = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]


def main() -> None:
    root = pathlib.Path(__file__).resolve().parent.parent
    out = root / "App" / "Assets.xcassets" / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)

    images = []
    for points, scale in VARIANTS:
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        render(pixels).save(out / name)
        images.append(
            {
                "filename": name,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{points}x{points}",
            }
        )

    (out / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )

    catalog = out.parent / "Contents.json"
    if not catalog.exists():
        catalog.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    if "--preview" in sys.argv:
        render(512).save(root / "icon-preview.png")

    print(f"wrote {len(images)} images to {out.relative_to(root)}")


if __name__ == "__main__":
    main()
