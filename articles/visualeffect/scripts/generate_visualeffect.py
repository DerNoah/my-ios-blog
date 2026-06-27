#!/usr/bin/env python3
"""
Generate the step-by-step output images used in the VisualEffect article (index.md).

Reproduces, on a single source photo, what swift-visual-effect renders. The library
applies SwiftUI's `.visualEffect { ... }` chain (blur, brightness, contrast,
saturation, grayscale, hue rotation, opacity) to a stripped-down backdrop view, so
this script applies the equivalent operations with Pillow:

    01-original.png ... the source photo, no effect (the backdrop)
    02-edgescroll.gif . the primary use case: frosted nav + tab bars pinned over
                        scrolling content, blurring the live backdrop behind them
    03-blur.png ....... blurRadius 6        (.blurredIn)
    04-brightness.png . brightness +0.18    (additive)
    05-contrast.png ... contrast 1.4
    06-saturation.png . saturation 1.8
    07-grayscale.png .. grayscale 0.85
    08-hue.png ........ hueRotation 90 degrees
    09-opacity.png .... a frosted card at opacity 0.75 over the sharp photo
    10-frosted.png .... the composed frosted-glass card (blur + brightness + saturation)
    11-blurin.gif ..... the implicit spring blur-in (blurRadius 0 -> 6)
    12-scrub.gif ...... interactive scrub: fractionComplete 0 -> 1 -> 0
    13-fadeout.gif .... blurOverridesOpacity dismissal (alpha = min(1, blur))

This is the pure-Pillow generator (no numpy) -- it runs anywhere Pillow is
installed. A higher-fidelity Core Image companion lives alongside it in
generate_visualeffect.swift.

Usage:
    python3 articles/visualeffect/scripts/generate_visualeffect.py [input.jpg] [output_dir]

Defaults (resolved from this script's location, so it runs from any directory):
    input = ../../blurhash/blurhash_example.jpg   (reuse the sister article's photo)
    output_dir = ../                              (the articles/visualeffect folder)
"""

import math
import os
import sys

from PIL import Image, ImageColor, ImageDraw, ImageEnhance, ImageFilter, ImageFont

# Article parameters -----------------------------------------------------------
W, H = 320, 480                          # canvas size (2:3, matching the blurhash article)
DISPLAY_WIDTH = 280                      # the {:width="280"} the markdown renders at

# The seven effects, with the demo value each still uses.
BLUR_RADIUS = 6.0                        # .blurredIn
BRIGHTNESS = 0.18                        # additive, normalized 0..1 (-> +46/255)
CONTRAST = 1.4                           # pivots around mid-grey
SATURATION = 1.8
GRAYSCALE = 0.85
HUE_DEGREES = 90.0
OPACITY = 0.75

# The composed frosted-glass card.
CARD_BOX = (28, 150, 292, 330)           # (x0, y0, x1, y1) -> a 264x180 centered panel
CARD_BLUR, CARD_BRIGHT, CARD_SAT = 6.0, 0.10, 1.4
CARD_RADIUS = 28

# GIF timing.
GIF_BLURIN = dict(hold_start=3, trans=20, hold_end=6, ms=40)
GIF_SCRUB = dict(hold=4, steps=16, ms=45)
GIF_FADE = dict(hold_start=3, trans=18, hold_end=8, ms=45)

# Interactive-scrub snapshot (the values captured at beginInteractive()).
SCRUB_BLUR, SCRUB_BRIGHT, SCRUB_SAT = 6.0, 0.15, 1.6

# Edge-scroll demo: a frosted nav bar + tab bar pinned over scrolling content.
FEED_H = 1180                            # tall content the viewport scrolls through
TOPBAR_H, BOTBAR_H = 104, 88             # pinned bar heights
EDGE_BLUR, EDGE_BRIGHT = 14.0, 0.06      # the bars' live backdrop blur
SCROLL_STEPS, SCROLL_HOLD, EDGE_MS = 18, 3, 55
CARD_PALETTE = [(255, 95, 86), (255, 159, 67), (72, 199, 142),
                (45, 152, 229), (155, 89, 217), (255, 107, 158)]


# --- Helpers ------------------------------------------------------------------
def clamp8(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius, fill=255)
    return m


def load_font(px):
    for path in ("/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/SFNS.ttf",
                 "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(path, px)
        except Exception:
            continue
    return ImageFont.load_default()


# --- The seven effects (faithful to the SwiftUI .visualEffect semantics) -------
def fx_blur(img, radius=BLUR_RADIUS):
    return img.filter(ImageFilter.GaussianBlur(radius)) if radius > 0.01 else img


def fx_brightness(img, amount=BRIGHTNESS):
    # SwiftUI's .brightness is additive in 0..1 space: add amount*255 to every channel.
    d = round(amount * 255)
    return img.point(lambda v: clamp8(v + d))


def fx_contrast(img, amount=CONTRAST):
    # Pivot around mid-grey (128), matching Core Image's .colorControls inputContrast,
    # rather than PIL's ImageEnhance.Contrast which pivots around the image mean.
    return img.point(lambda v: clamp8((v - 128) * amount + 128))


def fx_saturation(img, amount=SATURATION):
    # enhance(0) == greyscale, enhance(1) == unchanged -> exactly saturation semantics.
    return ImageEnhance.Color(img).enhance(amount)


def fx_grayscale(img, amount=GRAYSCALE):
    gray = img.convert("L").convert("RGB")
    return Image.blend(img, gray, amount)


def fx_hue(img, degrees=HUE_DEGREES):
    h, s, v = img.convert("HSV").split()
    shift = round(degrees / 360.0 * 255) % 256
    h = h.point(lambda x: (x + shift) % 256)
    return Image.merge("HSV", (h, s, v)).convert("RGB")


def make_card(photo, box=CARD_BOX, blur=CARD_BLUR, bright=CARD_BRIGHT,
              sat=CARD_SAT, radius=CARD_RADIUS, opacity=1.0):
    """A rounded frosted-glass panel carved from the photo and composited back over
    the sharp photo -- the canonical use case, and how `opacity` becomes legible."""
    crop = photo.crop(box)
    crop = fx_blur(crop, blur)
    crop = fx_brightness(crop, bright)
    crop = fx_saturation(crop, sat)
    crop = crop.convert("RGBA")
    mask = rounded_mask(crop.size, radius)
    if opacity < 1.0:
        mask = mask.point(lambda a: round(a * opacity))
    crop.putalpha(mask)

    out = photo.convert("RGBA")
    out.alpha_composite(crop, dest=(box[0], box[1]))
    # A faint rim so the glass panel reads as a distinct surface.
    ImageDraw.Draw(out).rounded_rectangle(list(box), radius, outline=(255, 255, 255, 90), width=1)
    return out.convert("RGB")


# --- Easing for the GIFs (pure Python math, no numpy) -------------------------
def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def ease_out(t):
    return 1 - (1 - t) * (1 - t)


def spring_ease(t):
    # Slight overshoot then settle -- mimics .spring(bounce: 0.1). 0 at t=0, ~1 at t=1.
    if t >= 1:
        return 1.0
    return 1.0 - math.exp(-6.0 * t) * math.cos(7.5 * t)


def save_gif(frames, path, ms):
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=ms, loop=0, disposal=2)
    print(f"  wrote {path} ({len(frames)} frames)")


def make_blurin_gif(photo, path):
    """The implicit spring: assigning .blurredIn animates blurRadius 0 -> 6."""
    cfg = GIF_BLURIN
    frames = [photo] * cfg["hold_start"]
    for k in range(1, cfg["trans"] + 1):
        r = BLUR_RADIUS * spring_ease(k / cfg["trans"])    # may briefly exceed 6, then settle
        frames.append(fx_blur(photo, r))
    frames += [fx_blur(photo, BLUR_RADIUS)] * cfg["hold_end"]
    save_gif(frames, path, cfg["ms"])


def scrub_frame(photo, p, font):
    """fractionComplete p: 0 = full blur, 1 = none. Interpolate blur/brightness/
    saturation from the snapshot toward neutral, exactly as the setter does."""
    blur = SCRUB_BLUR * (1 - p)
    bright = SCRUB_BRIGHT * (1 - p)
    sat = 1 + (SCRUB_SAT - 1) * (1 - p)
    f = fx_blur(photo, blur)
    f = fx_brightness(f, bright)
    f = fx_saturation(f, sat)

    d = ImageDraw.Draw(f, "RGBA")
    x0, y0, bw = 22, H - 34, W - 44
    d.rounded_rectangle([x0, y0, x0 + bw, y0 + 7], 3, fill=(255, 255, 255, 80))
    d.rounded_rectangle([x0, y0, x0 + int(bw * p), y0 + 7], 3, fill=(255, 255, 255, 235))
    d.text((x0, y0 - 20), f"fractionComplete {p:.2f}", font=font, fill=(255, 255, 255, 235))
    return f


def make_scrub_gif(photo, path):
    cfg = GIF_SCRUB
    font = load_font(13)
    frames = [scrub_frame(photo, 0.0, font)] * cfg["hold"]           # full blur
    for k in range(1, cfg["steps"] + 1):                            # dismiss: 0 -> 1
        frames.append(scrub_frame(photo, smoothstep(k / cfg["steps"]), font))
    frames += [scrub_frame(photo, 1.0, font)] * cfg["hold"]          # cleared
    for k in range(1, cfg["steps"] + 1):                            # re-blur: 1 -> 0
        frames.append(scrub_frame(photo, smoothstep(1 - k / cfg["steps"]), font))
    save_gif(frames, path, cfg["ms"])


def make_fadeout_gif(photo, path):
    """blurOverridesOpacity: as blurRadius drops 6 -> 0, the rendered blur is clamped
    to >= 1 while the surface alpha = min(1, blur), so it dissolves over the sharp
    photo instead of snapping to an un-blurred frame."""
    cfg = GIF_FADE
    full = fx_blur(photo, BLUR_RADIUS).convert("RGBA")
    frames = [full.convert("RGB")] * cfg["hold_start"]
    for k in range(1, cfg["trans"] + 1):
        blur = BLUR_RADIUS * (1 - ease_out(k / cfg["trans"]))       # 6 -> 0
        eff = max(1.0, blur)
        alpha = min(1.0, blur)
        surf = fx_blur(photo, eff).convert("RGBA")
        surf.putalpha(round(alpha * 255))
        frames.append(Image.alpha_composite(photo.convert("RGBA"), surf).convert("RGB"))
    frames += [photo] * cfg["hold_end"]
    save_gif(frames, path, cfg["ms"])


# --- Edge-scroll demo: the primary use case (a variable blur pinned to edges) -
def text_shadowed(d, pos, text, font, fill):
    x, y = pos
    d.text((x + 1, y + 1), text, font=font, fill=(0, 0, 0, 110))
    d.text((x, y), text, font=font, fill=fill)


def build_feed(photo):
    """A tall scrollable 'screen': the photo as a hero, then a column of cards."""
    feed = Image.new("RGB", (W, FEED_H), (244, 245, 248))
    feed.paste(photo, (0, 0))
    d = ImageDraw.Draw(feed, "RGBA")
    title_font, sub_font = load_font(15), load_font(11)
    y, i = 496, 0
    while y < FEED_H - 116:
        col = CARD_PALETTE[i % len(CARD_PALETTE)]
        d.rounded_rectangle([16, y, W - 16, y + 96], 18, fill=col)
        d.ellipse([30, y + 24, 78, y + 72], fill=(255, 255, 255, 70))
        d.text((92, y + 26), f"Item {i + 1}", font=title_font, fill=(255, 255, 255, 240))
        d.text((92, y + 50), "Tap to open this card", font=sub_font, fill=(255, 255, 255, 205))
        y += 112
        i += 1
    return feed


def edge_frame(feed, off, title_font, tab_font):
    """One scroll frame: blur only the two pinned bar strips of the live viewport."""
    view = feed.crop((0, int(round(off)), W, int(round(off)) + H)).convert("RGB")
    blurred = fx_brightness(fx_blur(view, EDGE_BLUR), EDGE_BRIGHT)

    out = view.copy()
    out.paste(blurred.crop((0, 0, W, TOPBAR_H)), (0, 0))                  # top nav bar
    out.paste(blurred.crop((0, H - BOTBAR_H, W, H)), (0, H - BOTBAR_H))   # bottom tab bar

    d = ImageDraw.Draw(out, "RGBA")
    d.rectangle([0, 0, W, TOPBAR_H], fill=(255, 255, 255, 30))            # frosted material wash
    d.rectangle([0, H - BOTBAR_H, W, H], fill=(255, 255, 255, 30))
    d.line([(0, TOPBAR_H), (W, TOPBAR_H)], fill=(0, 0, 0, 45))            # hairline separators
    d.line([(0, H - BOTBAR_H), (W, H - BOTBAR_H)], fill=(0, 0, 0, 45))

    text_shadowed(d, (16, 16), "9:41", tab_font, (255, 255, 255, 240))
    title = "Gallery"
    text_shadowed(d, ((W - d.textlength(title, font=title_font)) / 2, 58), title,
                  title_font, (255, 255, 255, 245))

    tabs = ["Home", "Search", "Saved", "Profile"]
    for j, t in enumerate(tabs):
        cx = (j + 0.5) * W / len(tabs)
        d.ellipse([cx - 6, H - BOTBAR_H + 20, cx + 6, H - BOTBAR_H + 32], fill=(255, 255, 255, 235))
        text_shadowed(d, (cx - d.textlength(t, font=tab_font) / 2, H - BOTBAR_H + 36), t,
                      tab_font, (255, 255, 255, 230))
    return out


def make_edge_scroll_gif(photo, path):
    """The headline use case: pinned frosted bars whose blur tracks scrolling content."""
    feed = build_feed(photo)
    max_off = FEED_H - H
    title_font, tab_font = load_font(16), load_font(11)

    offsets = [max_off * smoothstep(k / SCROLL_STEPS) for k in range(SCROLL_STEPS + 1)]
    offsets += [max_off] * SCROLL_HOLD
    offsets += [max_off * smoothstep(1 - k / SCROLL_STEPS) for k in range(1, SCROLL_STEPS + 1)]
    offsets += [0.0] * SCROLL_HOLD

    frames = [edge_frame(feed, off, title_font, tab_font) for off in offsets]
    save_gif(frames, path, EDGE_MS)


# --- Driver -------------------------------------------------------------------
def save_png(img, out_dir, name):
    assert img.size == (W, H), f"{name} is {img.size}, expected {(W, H)}"
    path = os.path.join(out_dir, name)
    img.save(path)
    print(f"  wrote {path}")


def main():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # articles/visualeffect
    default_input = os.path.join(base, os.pardir, "blurhash", "blurhash_example.jpg")
    input_path = sys.argv[1] if len(sys.argv) > 1 else default_input
    out_dir = sys.argv[2] if len(sys.argv) > 2 else base
    os.makedirs(out_dir, exist_ok=True)

    photo = Image.open(input_path).convert("RGB").resize((W, H), Image.LANCZOS)
    print(f"source: {input_path} -> {photo.size}")

    # Baseline + the primary use case ------------------------------------------
    save_png(photo, out_dir, "01-original.png")
    make_edge_scroll_gif(photo, os.path.join(out_dir, "02-edgescroll.gif"))

    # The seven effects --------------------------------------------------------
    save_png(fx_blur(photo), out_dir, "03-blur.png")
    save_png(fx_brightness(photo), out_dir, "04-brightness.png")
    save_png(fx_contrast(photo), out_dir, "05-contrast.png")
    save_png(fx_saturation(photo), out_dir, "06-saturation.png")
    save_png(fx_grayscale(photo), out_dir, "07-grayscale.png")
    save_png(fx_hue(photo), out_dir, "08-hue.png")
    save_png(make_card(photo, opacity=OPACITY), out_dir, "09-opacity.png")
    save_png(make_card(photo), out_dir, "10-frosted.png")

    # Animations ---------------------------------------------------------------
    make_blurin_gif(photo, os.path.join(out_dir, "11-blurin.gif"))
    make_scrub_gif(photo, os.path.join(out_dir, "12-scrub.gif"))
    make_fadeout_gif(photo, os.path.join(out_dir, "13-fadeout.gif"))

    print("Done.")


if __name__ == "__main__":
    main()
