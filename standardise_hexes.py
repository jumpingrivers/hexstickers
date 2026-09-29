#!/usr/bin/env python3
"""Identify hex stickers in raw/ and write standardised copies to hexstickers/.

For each raw/PKG.png:
  1. Remove any solid background connected to the image border.
  2. Trim to the sticker and score its shape against an ideal hexagon, both
     pointy-top and flat-top (intersection over union of the two masks).
  3. If it is a hex, resize it to exactly WIDTH x HEIGHT (HEIGHT x WIDTH for
     flat-top), clip it to a clean anti-aliased hexagon so everything outside
     is transparent, and save it as hexstickers/PKG.png. The matching
     raw/PKG.svg is copied unchanged.

Slightly squashed hexes are stretched to the standard shape, so every
sticker has an identical outline.

Every image is scored in hexstickers/report.csv, so the threshold can be
reviewed. PNGs are run through optipng unless --no-optipng is given.

Usage:
  python3 standardise_hexes.py                # all PNGs in raw/
  python3 standardise_hexes.py ggplot2 dplyr  # named packages only
"""

import csv
import shutil
import subprocess
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

RAW = Path("raw")
OUT = Path("hexstickers")
WIDTH, HEIGHT = 518, 600  # standard hex sticker proportions (hexSticker)
MIN_IOU = 0.90            # shape score needed to count as a hex...
MIN_RATIO, MAX_RATIO = 0.95, 1.35  # ...with long side / short side in range
LOOSE_IOU = 0.85          # accepted if the proportions are close to a true hex
LOOSE_RATIO = 1.10, 1.21
BG_TOLERANCE = 40         # RGB distance from the corner colour
SUPERSAMPLE = 4
# Shapes that pass the hex test but aren't hexes, checked by eye
EXCLUDE = {"dataspice": "octagon", "flexlsx": "octagon", "morestopwords": "octagon"}


def hex_mask(w, h, flat=False, supersample=SUPERSAMPLE):
    """Anti-aliased hexagon filling a w x h box, values 0-255."""
    W, H = w * supersample, h * supersample
    img = Image.new("L", (W, H), 0)
    if flat:
        pts = [(0, H / 2), (W / 4, 0), (3 * W / 4, 0),
               (W, H / 2), (3 * W / 4, H), (W / 4, H)]
    else:
        pts = [(W / 2, 0), (W, H / 4), (W, 3 * H / 4),
               (W / 2, H), (0, 3 * H / 4), (0, H / 4)]
    ImageDraw.Draw(img).polygon(pts, fill=255)
    return img.resize((w, h), Image.LANCZOS) if supersample > 1 else img


def remove_background(rgba):
    """Alpha with any border-connected background made transparent."""
    rgb = rgba[..., :3].astype(int)
    alpha = rgba[..., 3].copy()
    candidate = alpha < 16

    # Only colour-match when most of the border is visible background (possibly
    # semi-transparent). Otherwise the few visible border pixels are likely the
    # sticker itself touching the edge, and matching them would eat into it.
    edge = np.concatenate([rgba[0], rgba[-1], rgba[:, 0], rgba[:, -1]])
    visible = edge[edge[:, 3] >= 16]
    if len(visible) >= 0.5 * len(edge):
        bg = np.median(visible[:, :3], axis=0)
        candidate |= np.sqrt(((rgb - bg) ** 2).sum(axis=2)) < BG_TOLERANCE
    labels, _ = ndimage.label(candidate)
    border = np.unique(np.concatenate(
        [labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    border = border[border > 0]
    alpha[np.isin(labels, border)] = 0
    return alpha


def score(alpha):
    """(bbox, flat-top?, long/short side ratio, IoU with an ideal hexagon)."""
    ys, xs = np.nonzero(alpha > 128)
    if len(xs) == 0:
        return None, False, 0.0, 0.0
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    w, h = x1 - x0, y1 - y0
    # Transparent details inside the sticker shouldn't count against its outline
    shape = ndimage.binary_fill_holes(alpha[y0:y1, x0:x1] > 128)
    best = None
    for flat in (False, True):
        ideal = np.asarray(hex_mask(w, h, flat, supersample=1)) > 128
        iou = float((shape & ideal).sum() / max((shape | ideal).sum(), 1))
        if best is None or iou > best[1]:
            best = (flat, iou)
    flat, iou = best
    ratio = w / h if flat else h / w
    return (x0, y0, x1, y1), flat, ratio, iou


def looks_like_hex(ratio, iou):
    if MIN_RATIO <= ratio <= MAX_RATIO and iou >= MIN_IOU:
        return True
    return LOOSE_RATIO[0] <= ratio <= LOOSE_RATIO[1] and iou >= LOOSE_IOU


def standardise(img, bbox, flat):
    """Crop to bbox, resize to the standard size and clip to a clean hexagon."""
    w, h = (HEIGHT, WIDTH) if flat else (WIDTH, HEIGHT)
    crop = img.crop(bbox).convert("RGBa")  # premultiplied for clean resizing
    crop = crop.resize((w, h), Image.LANCZOS).convert("RGBA")
    arr = np.asarray(crop).copy()
    arr[..., 3] = np.minimum(arr[..., 3], np.asarray(hex_mask(w, h, flat)))
    return Image.fromarray(arr)


def process(path, optipng=True):
    pkg = path.stem
    if pkg in EXCLUDE:
        return dict(package=pkg, status="excluded", orientation="",
                    ratio="", iou="", note=EXCLUDE[pkg])
    try:
        img = Image.open(path)
        img.load()
        img = img.convert("RGBA")
    except Exception as e:
        return dict(package=pkg, status="unreadable", orientation="",
                    ratio="", iou="", note=str(e))

    alpha = remove_background(np.asarray(img))
    bbox, flat, ratio, iou = score(alpha)
    is_hex = bbox is not None and looks_like_hex(ratio, iou)
    row = dict(package=pkg, status="hex" if is_hex else "not_hex",
               orientation="flat" if flat else "pointy",
               ratio=f"{ratio:.3f}", iou=f"{iou:.3f}", note="")
    if not is_hex:
        return row

    out = OUT / f"{pkg}.png"
    standardise(img, bbox, flat).save(out, optimize=True)
    if optipng:
        subprocess.run(["optipng", "-quiet", "-o2", "-strip", "all", str(out)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    svg = RAW / f"{pkg}.svg"
    if svg.exists():
        shutil.copy2(svg, OUT / svg.name)
    return row


def main():
    args = sys.argv[1:]
    optipng = "--no-optipng" not in args and shutil.which("optipng") is not None
    args = [a for a in args if a != "--no-optipng"]

    OUT.mkdir(exist_ok=True)
    paths = [RAW / f"{a}.png" for a in args] if args else sorted(RAW.glob("*.png"))
    with Pool() as pool:
        rows = pool.starmap(process, [(p, optipng) for p in paths])

    report = OUT / "report.csv"
    if args and report.exists():
        # Partial run: update these packages' rows and keep everyone else's
        done = {r["package"] for r in rows}
        with report.open(newline="") as f:
            rows += [r for r in csv.DictReader(f) if r["package"] not in done]
    with report.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["package", "status", "orientation", "ratio", "iou", "note"])
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: r["package"].lower()))

    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(", ".join(f"{k}={v}" for k, v in sorted(counts.items())), f"-> {report}")


if __name__ == "__main__":
    main()
