#!/usr/bin/env python3
"""Flatten the ImageRenderer still PNGs into the article dir.

The animations are produced as H.264 .mp4 by the Swift tools (encode_frames.swift /
export_mp4.swift), so this only handles the stills now.

    python3 assemble.py <stage_dir> <article_dir>
"""
import os
import sys

from PIL import Image

stage, out = sys.argv[1], sys.argv[2]


def flatten(im):
    if im.mode == "RGBA":
        bg = Image.new("RGB", im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[3])
        return bg
    return im.convert("RGB")


def save_still(name):
    src = os.path.join(stage, name)
    if os.path.exists(src):
        flatten(Image.open(src)).save(os.path.join(out, name))
        print(f"  wrote {name}")


for s in ("01-original.png", "03-blur.png", "04-brightness.png", "05-contrast.png",
          "06-saturation.png", "07-grayscale.png", "08-hue.png",
          "09-opacity.png", "10-frosted.png"):
    save_still(s)

print("Done.")
