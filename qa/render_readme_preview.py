#!/usr/bin/env python3
"""Render the README interface preview without launching a macOS application."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "images" / "codex-quota-preview.png"
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(size: int, bold: bool = False, mono: bool = False) -> ImageFont.FreeTypeFont:
    path = MONO if mono else FONT
    return ImageFont.truetype(path, size=size, index=1 if bold and not mono else 0)


def vertical_gradient(size, top, bottom):
    image = Image.new("RGBA", size)
    pixels = image.load()
    for y in range(size[1]):
        ratio = y / max(1, size[1] - 1)
        color = tuple(round(top[i] * (1 - ratio) + bottom[i] * ratio) for i in range(4))
        for x in range(size[0]):
            pixels[x, y] = color
    return image


def rounded_surface(size, radius):
    surface = vertical_gradient(size, (31, 34, 38, 250), (17, 19, 22, 250))
    mask = Image.new("L", size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    surface.putalpha(mask)
    edge = ImageDraw.Draw(surface)
    edge.rounded_rectangle((1, 1, size[0] - 2, size[1] - 2), radius=radius - 1, outline=(255, 255, 255, 34), width=2)
    return surface


def text(draw, xy, value, size, color, bold=False, mono=False, anchor=None):
    draw.text(xy, value, font=font(size, bold=bold, mono=mono), fill=color, anchor=anchor)


def draw_progress(draw, x, y, width, remaining, accent):
    draw.rounded_rectangle((x, y, x + width, y + 8), radius=4, fill=(255, 255, 255, 23))
    draw.rounded_rectangle((x, y, x + round(width * remaining / 100), y + 8), radius=4, fill=accent)


def draw_capsule(canvas, origin):
    x, y = origin
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x + 2, y + 8, x + 194, y + 76), radius=34, fill=(0, 0, 0, 100))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16)))
    capsule = rounded_surface((192, 68), 34)
    canvas.alpha_composite(capsule, (x, y))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((x + 26, y + 20, x + 54, y + 48), outline=(255, 255, 255, 38), width=4)
    draw.arc((x + 26, y + 20, x + 54, y + 48), start=-90, end=224, fill=(130, 212, 186, 255), width=4)
    text(draw, (x + 72, y + 34), "87%", 28, (242, 245, 247, 255), bold=True, mono=True, anchor="lm")


def draw_panel(canvas, origin):
    x, y = origin
    width, height = 560, 728
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x + 4, y + 12, x + width + 4, y + height + 12), radius=40, fill=(0, 0, 0, 105))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    canvas.alpha_composite(rounded_surface((width, height), 40), (x, y))
    draw = ImageDraw.Draw(canvas)
    primary = (242, 245, 247, 255)
    secondary = (158, 166, 176, 255)
    green = (130, 212, 186, 255)
    amber = (237, 189, 112, 255)

    text(draw, (x + 40, y + 48), "CODEX", 20, primary, bold=True, anchor="lm")
    draw.rounded_rectangle((x + 354, y + 35, x + 370, y + 45), radius=3, fill=green)
    draw.line((x + 362, y + 45, x + 362, y + 58), fill=green, width=3)
    draw.polygon(((x + 357, y + 55), (x + 367, y + 55), (x + 362, y + 62)), fill=green)
    for dot_x in (418, 426, 434):
        draw.ellipse((x + dot_x - 2, y + 43, x + dot_x + 2, y + 47), fill=secondary)
    draw.line((x + 483, y + 38, x + 497, y + 52), fill=secondary, width=3)
    draw.line((x + 497, y + 38, x + 483, y + 52), fill=secondary, width=3)

    rows = [
        ("5 小时剩余", 87, "可用", green, "9/8 16:00 重置", "2小时后"),
        ("本周剩余", 24, "额度偏低", amber, "9/11 18:00 重置", "3天4小时后"),
    ]
    for index, (label, remaining, badge, accent, reset, countdown) in enumerate(rows):
        top = y + 106 + index * 244
        text(draw, (x + 40, top), label, 21, secondary, anchor="lm")
        text(draw, (x + 36, top + 72), str(remaining), 78, primary, bold=True, mono=True, anchor="lm")
        number_width = draw.textlength(str(remaining), font=font(78, bold=True, mono=True))
        text(draw, (x + 40 + number_width, top + 84), "%", 34, secondary, anchor="lm")
        text(draw, (x + 520, top + 72), badge, 20, accent, anchor="rm")
        draw_progress(draw, x + 40, top + 150, 480, remaining, accent)
        text(draw, (x + 40, top + 190), reset, 19, secondary, anchor="lm")
        text(draw, (x + 520, top + 190), countdown, 19, secondary, anchor="rm")

    footer_y = y + 624
    draw.line((x + 40, footer_y, x + 520, footer_y), fill=(255, 255, 255, 24), width=2)
    text(draw, (x + 40, footer_y + 42), "已更新 14:25:36", 19, secondary, anchor="lm")
    draw.arc((x + 476, footer_y + 29, x + 500, footer_y + 53), start=20, end=320, fill=secondary, width=3)
    draw.polygon(((x + 497, footer_y + 29), (x + 503, footer_y + 37), (x + 493, footer_y + 38)), fill=secondary)
    text(draw, (x + 40, footer_y + 86), "bistar.ai  ↗", 19, green, bold=True, anchor="lm")


def main():
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas = vertical_gradient((1040, 840), (44, 50, 59, 255), (19, 23, 29, 255))
    background = Image.new("RGBA", canvas.size)
    backdrop = ImageDraw.Draw(background)
    backdrop.ellipse((20, 80, 620, 680), fill=(29, 129, 118, 32))
    backdrop.ellipse((500, -100, 1100, 500), fill=(62, 88, 153, 34))
    canvas.alpha_composite(background.filter(ImageFilter.GaussianBlur(70)))
    draw_capsule(canvas, (80, 104))
    draw_panel(canvas, (400, 56))
    canvas.convert("RGB").save(OUTPUT, quality=95)
    print(OUTPUT)


if __name__ == "__main__":
    main()
