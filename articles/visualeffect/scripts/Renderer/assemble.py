#!/usr/bin/env python3
"""Assemble the final article assets from the PNG frames the simulator produced.

Stills (01, 03-10) are copied through; the animations (11-13) and the edge GIF (02) are
built from their frame sequences with Pillow (no ffmpeg/ImageMagick on this machine).

    python3 assemble.py <stage_dir> <article_dir>
"""
import glob
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


def save_gif(pattern, name, ms, hold_start=0, hold_end=0, width=None):
    paths = sorted(glob.glob(os.path.join(stage, pattern)))
    if not paths:
        print(f"  SKIP {name} (no frames matched {pattern})")
        return
    frames = [flatten(Image.open(p)) for p in paths]
    if width:
        h = round(frames[0].height * width / frames[0].width)
        frames = [f.resize((width, h), Image.LANCZOS) for f in frames]
    frames = [frames[0]] * hold_start + frames + [frames[-1]] * hold_end
    frames[0].save(os.path.join(out, name), save_all=True, append_images=frames[1:],
                   duration=ms, loop=0, disposal=2)
    print(f"  wrote {name} ({len(frames)} frames, {frames[0].size})")


for s in ("01-original.png", "03-blur.png", "04-brightness.png", "05-contrast.png",
          "06-saturation.png", "07-grayscale.png", "08-hue.png",
          "09-opacity.png", "10-frosted.png"):
    save_still(s)

save_gif("11-blurin-*.png", "11-blurin.gif", 60, hold_start=3, hold_end=5)
save_gif("12-scrub-*.png", "12-scrub.gif", 60)
save_gif("13-fadeout-*.png", "13-fadeout.gif", 60, hold_start=2, hold_end=6)
save_gif("edge-*.png", "02-edgescroll.gif", 80, width=300)

print("Done.")
