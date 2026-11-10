#!/usr/bin/env python3
"""Audit wallpaper files: low resolution, flat colour, or a visible seam.

    audit-wallpapers.py <dir>...            # dry run, prints the verdict
    audit-wallpapers.py --delete <dir>...   # deletes the files it rejects

HEIC is converted with macOS `sips` first, so no third-party decoder is
needed. Pillow only. Nothing is deleted unless --delete is passed.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageFilter, ImageStat

MIN_LONG = 2560      # longest side must be at least this (Apple ships 3024x1964)
MIN_SHARP = 6.0      # edge-energy variance: below this the image is mush
MAX_SEAM = 25.0      # largest column-to-column mean jump: a stitched seam
EXTS = {".jpg", ".jpeg", ".png", ".heic", ".webp"}


def sharp(im):
    g = im.convert("L")
    g = g.resize((1024, max(1, int(1024 * g.height / g.width))))
    edges = g.filter(ImageFilter.FIND_EDGES)
    return ImageStat.Stat(edges).var[0]


def flat(im):
    stat = ImageStat.Stat(im.convert("RGB").resize((64, 64)))
    return sum(stat.stddev) / 3.0 < 12


def seam(im):
    g = im.convert("L").resize((512, 512))
    px = list(g.getdata())
    means = [sum(px[row * 512:(row + 1) * 512]) / 512 for row in range(512)]
    return max(abs(b - a) for a, b in zip(means, means[1:]))


def open_image(path):
    if path.suffix.lower() == ".heic":
        tmp = tempfile.mkdtemp()
        png = pathlib.Path(tmp) / (path.stem + ".png")
        subprocess.run(["sips", "-s", "format", "png", str(path), "--out", str(png)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if not png.exists():
            shutil.rmtree(tmp, ignore_errors=True)
            return None, tmp
        return Image.open(png), tmp
    return Image.open(path), None


def main(argv):
    delete = "--delete" in argv
    roots = [a for a in argv[1:] if not a.startswith("--")]
    keep = drop = 0
    for root in roots:
        for p in sorted(pathlib.Path(root).rglob("*")):
            if p.suffix.lower() not in EXTS or not p.is_file():
                continue
            im, tmp = open_image(p)
            if im is None:
                shutil.rmtree(tmp, ignore_errors=True)
                print(f"SKIP    {p} (unreadable)")
                continue
            why = []
            if max(im.size) < MIN_LONG:
                why.append(f"res {im.size[0]}x{im.size[1]}")
            if flat(im):
                why.append("flat")
            s = sharp(im)
            if s < MIN_SHARP:
                why.append("soft")
            sm = seam(im)
            if sm > MAX_SEAM:
                why.append("seam")
            if why:
                drop += 1
                print(f"DELETE  {p}  {','.join(why)}  sharp={s:.1f} seam={sm:.1f}")
                if delete:
                    p.unlink()
            else:
                keep += 1
                print(f"KEEP    {p}  sharp={s:.1f} seam={sm:.1f}")
            shutil.rmtree(tmp, ignore_errors=True) if tmp else None
    print(f"\n{keep} keep, {drop} delete")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
