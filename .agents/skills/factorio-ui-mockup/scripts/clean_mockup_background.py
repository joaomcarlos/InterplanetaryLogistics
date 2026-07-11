#!/usr/bin/env python3
"""Create a cleaned Factorio UI background from a full mockup image."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


def rgba(value, default):
    if value is None:
        value = default
    if len(value) == 3:
        return tuple(value) + (255,)
    return tuple(value)


def box(value):
    if len(value) != 4:
        raise ValueError(f"box must have 4 values, got {value!r}")
    return tuple(int(v) for v in value)


def draw_soft_edge(img, bounds, alpha=75, width=2, blur=0.45):
    edge = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge, "RGBA")
    ed.rectangle(bounds, outline=(0, 0, 0, alpha), width=width)
    img.alpha_composite(edge.filter(ImageFilter.GaussianBlur(blur)))


def draw_line(draw, item):
    color = rgba(item.get("color"), (8, 9, 9, 110))
    width = int(item.get("width", 1))
    start = tuple(int(v) for v in item["from"])
    end = tuple(int(v) for v in item["to"])
    repeat_y = item.get("repeat_y")
    if not repeat_y:
        draw.line((*start, *end), fill=color, width=width)
        return

    step = int(repeat_y["step"])
    until = int(repeat_y["until"])
    y = start[1]
    while y <= until:
        dy = y - start[1]
        draw.line((start[0], start[1] + dy, end[0], end[1] + dy), fill=color, width=width)
        y += step


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Source mockup PNG")
    parser.add_argument("--output", required=True, help="Output cleaned PNG")
    parser.add_argument("--rects", required=True, help="JSON file with clear/restore/lines arrays")
    parser.add_argument("--default-color", default="31,33,33,244", help="RGBA fallback for clear rects")
    args = parser.parse_args()

    default_color = tuple(int(v) for v in args.default_color.split(","))
    src_path = Path(args.input)
    out_path = Path(args.output)
    spec = json.loads(Path(args.rects).read_text(encoding="utf-8-sig"))

    src = Image.open(src_path).convert("RGBA")
    img = src.copy()
    draw = ImageDraw.Draw(img, "RGBA")

    for item in spec.get("clear", []):
        bounds = box(item["box"])
        color = rgba(item.get("color"), default_color)
        draw.rectangle(bounds, fill=color)
        if item.get("edge", True):
            draw_soft_edge(
                img,
                bounds,
                alpha=int(item.get("edge_alpha", 75)),
                width=int(item.get("edge_width", 2)),
                blur=float(item.get("edge_blur", 0.45)),
            )

    for item in spec.get("restore", []):
        bounds = box(item["box"])
        img.alpha_composite(src.crop(bounds), dest=(bounds[0], bounds[1]))

    draw = ImageDraw.Draw(img, "RGBA")
    for item in spec.get("lines", []):
        draw_line(draw, item)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)
    print(out_path)


if __name__ == "__main__":
    main()
