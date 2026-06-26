#!/usr/bin/env python3
"""
Generate the step-by-step output images used in the BlurHash article (index.md).

Reproduces the article's pipeline on a single source image:

    Step 1  encode .................. prints the BlurHash string
    Step 2  decode (32x48) .......... 02-decoded.png
    Step 3  + tonal compression ..... 03-tonal.png      (out = in*0.65 + 0.175)
    Step 3  + Gaussian blur (r=2) ... 04-blurred.png     (the final placeholder)
    Step 4  reveal animation ........ 04-reveal.gif      (dissolve + frosted shimmer)
    Step 1/4 source image ........... 01-original.png

If tshirt_example.jpg is present, also emits the Step 3 "black hole" demo
(tshirt-original.png, tshirt-raw.png, tshirt-processed.png) showing why the
Core Image filters matter for high-contrast, dark-on-light product shots.

The article decodes at 32x48 and the Core Image filters run at that extent, so
this script filters at 32x48 too and only then upscales each result to 320x480
for display -- matching what the iOS code actually renders.

Usage:
    pip install blurhash Pillow numpy
    python3 articles/blurhash/scripts/generate_blurhash.py [input.jpg] [output_dir]

Defaults (resolved from this script's location, so it runs from any directory):
    input = ../blurhash_example.jpg, output_dir = ../  (the articles/blurhash folder)
The `blurhash` PyPI package (the one the article installs) is used for
encode/decode when present; a vendored reference implementation is the fallback
so the script always runs with just Pillow + numpy.
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

# Article parameters -----------------------------------------------------------
X_COMPONENTS = 4
Y_COMPONENTS = 3
DECODE_W, DECODE_H = 32, 48          # the article's decode size
DISPLAY_W, DISPLAY_H = 320, 480      # upscaled size for the saved PNGs (2:3)
TONAL_SCALE, TONAL_BIAS = 0.65, 0.175
BLUR_RADIUS = 2

# Step 4 reveal animation (GIF): hold placeholder -> cross-dissolve -> hold photo.
GIF_HOLD_START = 4
GIF_TRANSITION = 16
GIF_HOLD_END = 8
GIF_FRAME_MS = 50
SHIMMER_MAX = 6.0                    # peak Gaussian "frosted-glass" radius mid-transition

# --- Vendored reference BlurHash (used if the pip package is unavailable) ------
_B83 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"


def _srgb_to_linear(c):              # c in 0..255 -> linear 0..1
    v = c / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def _linear_to_srgb(v):              # linear 0..1 -> sRGB 0..255 (uint8)
    v = np.clip(v, 0.0, 1.0)
    s = np.where(v <= 0.0031308, v * 12.92, 1.055 * (v ** (1 / 2.4)) - 0.055)
    return np.round(s * 255.0).astype(np.uint8)


def _sign_pow(x, e):
    return np.sign(x) * (np.abs(x) ** e)


def _b83_encode(value, length):
    out = ""
    for i in range(1, length + 1):
        digit = (value // (83 ** (length - i))) % 83
        out += _B83[digit]
    return out


def _b83_decode(s):
    value = 0
    for ch in s:
        value = value * 83 + _B83.index(ch)
    return value


def vendored_encode(rgb, x_comp, y_comp):
    """Reference encoder. rgb: HxWx3 uint8 array."""
    h, w, _ = rgb.shape
    lin = _srgb_to_linear(rgb.astype(np.float64))            # HxWx3
    xs = np.arange(w)
    ys = np.arange(h)
    components = []
    for j in range(y_comp):
        cos_y = np.cos(math.pi * j * ys / h)                 # (h,)
        for i in range(x_comp):
            cos_x = np.cos(math.pi * i * xs / w)             # (w,)
            basis = np.outer(cos_y, cos_x)                   # (h,w)
            norm = 1.0 if (i == 0 and j == 0) else 2.0
            factor = (basis[:, :, None] * lin).sum(axis=(0, 1)) * (norm / (w * h))
            components.append(factor)

    dc = components[0]
    ac = components[1:]

    def enc_dc(c):
        r, g, b = _linear_to_srgb(np.array(c))
        return (int(r) << 16) + (int(g) << 8) + int(b)

    def enc_ac(c, maximum):
        q = np.clip(np.floor(_sign_pow(c / maximum, 0.5) * 9 + 9.5), 0, 18).astype(int)
        return q[0] * 19 * 19 + q[1] * 19 + q[2]

    size_flag = (x_comp - 1) + (y_comp - 1) * 9
    out = _b83_encode(size_flag, 1)
    if ac:
        max_ac = max(float(np.abs(c).max()) for c in ac)
        quant_max = int(max(0, min(82, math.floor(max_ac * 166 - 0.5))))
        maximum = (quant_max + 1) / 166.0
        out += _b83_encode(quant_max, 1)
    else:
        maximum = 1.0
        out += _b83_encode(0, 1)
    out += _b83_encode(enc_dc(dc), 4)
    for c in ac:
        out += _b83_encode(enc_ac(c, maximum), 2)
    return out


def vendored_decode(blurhash, width, height, punch=1.0):
    """Reference decoder -> HxWx3 uint8 array (sRGB)."""
    size_flag = _b83_decode(blurhash[0])
    num_x = (size_flag % 9) + 1
    num_y = (size_flag // 9) + 1
    quant_max = _b83_decode(blurhash[1])
    real_max = ((quant_max + 1) / 166.0) * punch

    colors = []
    dc_val = _b83_decode(blurhash[2:6])
    colors.append([
        float(_srgb_to_linear(np.array(dc_val >> 16))),
        float(_srgb_to_linear(np.array((dc_val >> 8) & 255))),
        float(_srgb_to_linear(np.array(dc_val & 255))),
    ])
    for comp in range(1, num_x * num_y):
        val = _b83_decode(blurhash[4 + comp * 2: 6 + comp * 2])
        qr = val // (19 * 19)
        qg = (val // 19) % 19
        qb = val % 19
        colors.append([
            float(_sign_pow((qr - 9) / 9.0, 2.0) * real_max),
            float(_sign_pow((qg - 9) / 9.0, 2.0) * real_max),
            float(_sign_pow((qb - 9) / 9.0, 2.0) * real_max),
        ])

    xs = np.arange(width)
    ys = np.arange(height)
    img = np.zeros((height, width, 3), dtype=np.float64)
    for j in range(num_y):
        cos_y = np.cos(math.pi * j * ys / height)
        for i in range(num_x):
            cos_x = np.cos(math.pi * i * xs / width)
            basis = np.outer(cos_y, cos_x)
            color = np.array(colors[i + j * num_x])
            img += basis[:, :, None] * color[None, None, :]
    return _linear_to_srgb(img)


# --- Prefer the pip `blurhash` package (what the article installs) ------------
def encode_hash(rgb, input_path):
    """Both common `blurhash` builds encode from a numpy array but spell the
    component kwargs differently: woltapp uses x_components/y_components (the
    article's call), halcy uses components_x/components_y. Try both, then fall
    back to the vendored reference (verified to match the package output)."""
    try:
        from blurhash import encode as pip_encode  # noqa: WPS433
        for kwargs in ({"x_components": X_COMPONENTS, "y_components": Y_COMPONENTS},
                       {"components_x": X_COMPONENTS, "components_y": Y_COMPONENTS}):
            try:
                return pip_encode(rgb, **kwargs), "blurhash (pip)"
            except TypeError:
                continue
    except Exception:
        pass
    return vendored_encode(rgb, X_COMPONENTS, Y_COMPONENTS), "vendored"


def decode_at(blurhash, width, height):
    try:
        from blurhash import decode as pip_decode  # noqa: WPS433
        pixels = np.array(pip_decode(blurhash, width, height, punch=1), dtype=np.float64)
        return np.clip(np.round(pixels), 0, 255).astype(np.uint8)
    except Exception:
        return vendored_decode(blurhash, width, height, punch=1.0)


def decode_small(blurhash):
    return decode_at(blurhash, DECODE_W, DECODE_H)


# --- Article filter passes (run at the 32x48 decode extent) -------------------
def tonal_compress(arr):
    out = np.clip(arr.astype(np.float64) / 255.0 * TONAL_SCALE + TONAL_BIAS, 0.0, 1.0)
    return (out * 255.0).round().astype(np.uint8)


def gaussian_blur(arr):
    return np.array(Image.fromarray(arr, "RGB").filter(ImageFilter.GaussianBlur(BLUR_RADIUS)))


def upscale(arr, size=(DISPLAY_W, DISPLAY_H)):
    return Image.fromarray(arr.astype(np.uint8), "RGB").resize(size, Image.BICUBIC)


def upscale_and_save(arr, path):
    upscale(arr).save(path)
    print(f"  wrote {path}")


def make_reveal_gif(placeholder, real, path):
    """Step 4 -- cross-dissolve from the blurred placeholder to the real photo
    with a Gaussian 'frosted-glass' shimmer that peaks mid-transition, then loop."""
    frames = [placeholder] * GIF_HOLD_START
    for k in range(1, GIF_TRANSITION + 1):
        t = k / (GIF_TRANSITION + 1)                       # (0, 1), endpoints are the holds
        base = Image.blend(placeholder, real, t)
        radius = SHIMMER_MAX * math.sin(math.pi * t)       # 0 at ends, peak at t=0.5
        frames.append(base.filter(ImageFilter.GaussianBlur(radius)) if radius > 0.05 else base)
    frames += [real] * GIF_HOLD_END
    frames[0].save(
        path, save_all=True, append_images=frames[1:],
        duration=GIF_FRAME_MS, loop=0, disposal=2,
    )
    print(f"  wrote {path} ({len(frames)} frames)")


def make_artifact_demo(input_path, out_dir, prefix):
    """Step 3 demo -- show why the Core Image filters matter. A near-black subject
    on a white background (e.g. a t-shirt) overshoots the 4x3 DCT and clips the
    center to pure black (a 'black hole'); the same tonal + blur passes lift it."""
    src = Image.open(input_path).convert("RGB")
    aspect = src.width / src.height                    # keep the source's own aspect
    dec_w, dec_h = max(1, round(DECODE_H * aspect)), DECODE_H
    size = (max(1, round(DISPLAY_H * aspect)), DISPLAY_H)

    blurhash, source_used = encode_hash(np.array(src), input_path)
    print(f"BlurHash [{prefix}] ({source_used}): {blurhash}")

    src.resize(size, Image.BICUBIC).save(os.path.join(out_dir, f"{prefix}-original.png"))
    decoded = decode_at(blurhash, dec_w, dec_h)        # raw decode -> the black hole
    upscale(decoded, size).save(os.path.join(out_dir, f"{prefix}-raw.png"))
    processed = gaussian_blur(tonal_compress(decoded))  # Pass 1 + Pass 2 -> rescued
    upscale(processed, size).save(os.path.join(out_dir, f"{prefix}-processed.png"))
    for name in ("original", "raw", "processed"):
        print(f"  wrote {os.path.join(out_dir, f'{prefix}-{name}.png')}")


def main():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the articles/blurhash folder
    input_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base, "blurhash_example.jpg")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else base
    os.makedirs(out_dir, exist_ok=True)

    source = Image.open(input_path).convert("RGB")
    rgb = np.array(source)

    # Step 1 -- encode
    blurhash, source_used = encode_hash(rgb, input_path)
    print(f"BlurHash ({source_used}): {blurhash}")

    # Step 1/4 -- the source image, downscaled for display
    original_display = source.resize((DISPLAY_W, DISPLAY_H), Image.BICUBIC)
    original_display.save(os.path.join(out_dir, "01-original.png"))
    print(f"  wrote {os.path.join(out_dir, '01-original.png')}")

    # Step 2 -- raw decode at 32x48
    decoded = decode_small(blurhash)
    upscale_and_save(decoded, os.path.join(out_dir, "02-decoded.png"))

    # Step 3, Pass 1 -- tonal compression
    tonal = tonal_compress(decoded)
    upscale_and_save(tonal, os.path.join(out_dir, "03-tonal.png"))

    # Step 3, Pass 2 -- Gaussian blur on the compressed image (the final placeholder)
    blurred = gaussian_blur(tonal)
    placeholder_display = upscale(blurred)
    placeholder_display.save(os.path.join(out_dir, "04-blurred.png"))
    print(f"  wrote {os.path.join(out_dir, '04-blurred.png')}")

    # Step 4 -- the reveal animation
    make_reveal_gif(placeholder_display, original_display, os.path.join(out_dir, "04-reveal.gif"))

    # Step 3 demo -- the black-hole failure case (only if the t-shirt source is present)
    tshirt = os.path.join(base, "tshirt_example.jpg")
    if os.path.exists(tshirt):
        make_artifact_demo(tshirt, out_dir, "tshirt")

    print("Done.")


if __name__ == "__main__":
    main()
