"""App Store screenshots for Lumen RAW (6.9-inch, 1320 x 2868) from Angelo's own iPhone screenshots.

Usage: python make_screenshots.py <folder with the phone screenshots> <Manrope.ttf> <DMSans.ttf> <output folder>
Each picture: a short caption on the website's dark blue backdrop, the real screenshot below it in a phone frame.
Only real app screens and Angelo's own photos are used (see COMPLIANCE.md section 4).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

src, manrope, dmsans, out = sys.argv[1:5]
W, H = 1320, 2868
SHOTS = [
    ("editor-car", "Edit RAW files\non your iPhone", "Sony, Canon, Nikon, Fujifilm, DNG and ProRAW"),
    ("mask-car", "Masks that find\nthe background", "Subject, people, sky, landscape, depth and brush"),
    ("person-detect-full", "Remove people\nwith one tap", "Lumen finds them and shows them in red"),
    ("person-after-full", "Gone, with the\nbackground filled in", "Heal runs on the phone. Nothing is uploaded."),
    ("grade-car", "Grade shadows,\nmidtones and highlights", "Colour wheels, curves and a colour mixer"),
    ("presets", "Presets for\na quick look", "Save your own and paste edits onto other photos"),
]


def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    try:
        f.set_variation_by_axes([weight] if "Manrope" in path else [14, weight])
    except Exception:
        pass
    return f


def backdrop():
    bg = Image.new("RGB", (W, H), "#080a0f")
    glow = Image.new("RGB", (W, H), "#080a0f")
    d = ImageDraw.Draw(glow)
    d.ellipse((-200, 900, W + 200, 2600), fill="#173c79")
    glow = glow.filter(ImageFilter.GaussianBlur(260))
    return Image.blend(bg, glow, 0.75)


def phone(img, height):
    w = round(img.width * height / img.height)
    shot = img.resize((w, height), Image.LANCZOS)
    bezel, radius = 22, 92
    frame = Image.new("RGBA", (w + 2 * bezel, height + 2 * bezel), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame.width - 1, frame.height - 1), radius + bezel, fill="#292d39")
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, height - 1), radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    return frame


os.makedirs(out, exist_ok=True)
title_f, sub_f = font(manrope, 104, 800), font(dmsans, 46, 500)
for i, (name, title, sub) in enumerate(SHOTS, 1):
    canvas = backdrop().convert("RGBA")
    d = ImageDraw.Draw(canvas)
    d.multiline_text((W / 2, 250), title, font=title_f, fill="#f8f9ff", anchor="ma", align="center", spacing=18)
    d.text((W / 2, 530), sub, font=sub_f, fill="#9fb4d8", anchor="ma")
    shot = Image.open(os.path.join(src, name + ".webp")).convert("RGB")
    p = phone(shot, 2160)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(((W - p.width) // 2 + 10, 690, (W + p.width) // 2 - 10, 690 + p.height),
                                             110, fill=(0, 0, 0, 170))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.alpha_composite(p, ((W - p.width) // 2, 660))
    canvas.convert("RGB").save(os.path.join(out, f"{i:02d}-{name}.png"), optimize=True)
    print(f"{i:02d}-{name}.png")
