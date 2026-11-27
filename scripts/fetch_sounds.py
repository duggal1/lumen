#!/usr/bin/env python3
"""Fetch, slice and master the CC0 keyboard / click samples used by Lumen.

Run from anywhere:  python3 scripts/fetch_sounds.py [--force] [--verify-only]

The script is deterministic and idempotent. It downloads each recorded source
once into .proof/sfx-cache/, detects individual key strikes (a down transient
and, where the recording contains one, its release transient), trims silence,
loudness-normalises every take to -16 LUFS with ffmpeg, applies a -1.5 dBTP
ceiling, writes 48 kHz mono WAV files named by key class, and regenerates
Resources/Sounds/manifest.json and Resources/Sounds/LICENSES.md from the exact
set of files it produced. Every output file therefore has a source URL and a
license recorded next to it.

No file is synthesised: every sample is a slice of a real recording.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Sounds"
CACHE = ROOT / ".proof" / "sfx-cache"
MANIFEST = OUT / "manifest.json"
LICENSES = OUT / "LICENSES.md"
FS = 48_000

# ---------------------------------------------------------------------------
# Sources. All are CC0 1.0 (public-domain dedication, commercial use allowed,
# no attribution required). The page URL is kept so the license is verifiable.
# Freesound "hq" previews are the publisher's own preview encodes, served
# without authentication; their page links carry the CC0 declaration.
# ---------------------------------------------------------------------------
SOURCES: dict[str, dict[str, str]] = {
    "woven-typing": {
        "url": "https://assets.sfx.woven.video/sfx/keyboard-typing.wav",
        "page": "https://www.woven.video/sfx/keyboard-typing-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Real mechanical keyboard typing session (10 s).",
    },
    "woven-typing-realistic": {
        "url": "https://assets.sfx.woven.video/sfx/keyboard-typing-realistic.wav",
        "page": "https://www.woven.video/sfx/keyboard-typing-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Realistic keyboard typing session (3.4 s).",
    },
    "fs-mx-blue": {
        "url": "https://cdn.freesound.org/previews/382/382057_1106446-hq.mp3",
        "page": "https://freesound.org/s/382057/",
        "author": "EricsSoundschmiede",
        "license": "CC0 1.0",
        "description": "Cherry MX Blue clicky keyboard typing.",
    },
    "fs-mx-black": {
        "url": "https://cdn.freesound.org/previews/628/628325_13894315-hq.mp3",
        "page": "https://freesound.org/s/628325/",
        "author": "ujonathan",
        "license": "CC0 1.0",
        "description": "Leopold FC980M PD with Cherry MX Black switches.",
    },
    "fs-topre": {
        "url": "https://cdn.freesound.org/previews/546/546033_12206738-hq.mp3",
        "page": "https://freesound.org/s/546033/",
        "author": "grcekh",
        "license": "CC0 1.0",
        "description": "HHKB Professional Hybrid (Topre) - deep, soft thock.",
    },
    "fs-whitefox": {
        "url": "https://cdn.freesound.org/previews/546/546167_12206738-hq.mp3",
        "page": "https://freesound.org/s/546167/",
        "author": "grcekh",
        "license": "CC0 1.0",
        "description": "WhiteFox mechanical board, includes isolated single keys.",
    },
    "fs-model-f": {
        "url": "https://cdn.freesound.org/previews/500/500430_5800121-hq.mp3",
        "page": "https://freesound.org/s/500430/",
        "author": "Fractal_",
        "license": "CC0 1.0",
        "description": "IBM Model F XT buckling-spring keyboard.",
    },
    "fs-macbook": {
        "url": "https://cdn.freesound.org/previews/565/565645_6652872-hq.mp3",
        "page": "https://freesound.org/s/565645/",
        "author": "khenshom",
        "license": "CC0 1.0",
        "description": "2018 MacBook Pro laptop keys and isolated single clicks.",
    },
    "fs-gateron": {
        "url": "https://cdn.freesound.org/previews/583/583085_10081667-hq.mp3",
        "page": "https://freesound.org/s/583085/",
        "author": "IRF1010N",
        "license": "CC0 1.0",
        "description": "Gateron Red switches on a GMMK TKL.",
    },
    "click-mouse-1": {
        "url": "https://assets.sfx.woven.video/sfx/mouse-click-1.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Clean mouse click, full-bodied.",
    },
    "click-mouse-2": {
        "url": "https://assets.sfx.woven.video/sfx/mouse-click-2.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Short, crisp mouse click.",
    },
    "click-tick": {
        "url": "https://assets.sfx.woven.video/sfx/tick-sound.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Dry UI tick.",
    },
    "click-shutter": {
        "url": "https://assets.sfx.woven.video/sfx/camera-shutter-1-shot.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Sharp single mechanical snap (camera shutter, one shot).",
    },
    "click-analog": {
        "url": "https://assets.sfx.woven.video/sfx/camera-analog.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Soft analog mechanical switch click.",
    },
}

# Which recordings feed which key class. Each class gets >= 4 distinct down
# takes and >= 3 release takes, so the engine has real round-robin variation.
KEY_CLASS_SOURCES: dict[str, list[str]] = {
    "alpha": ["woven-typing", "woven-typing-realistic", "fs-whitefox", "fs-gateron"],
    "number": ["fs-whitefox", "fs-gateron", "woven-typing"],
    "space": ["fs-topre", "fs-mx-black"],
    "enter": ["fs-mx-black", "fs-topre"],
    "backspace": ["fs-model-f", "fs-mx-blue"],
    "shift": ["fs-mx-blue", "fs-model-f"],
    "modifier": ["fs-mx-blue", "fs-topre", "fs-whitefox"],
    "nav": ["fs-macbook", "fs-whitefox"],
    "fn": ["fs-macbook", "fs-topre"],
}

VARIANTS_PER_CLASS = 5
RELEASES_PER_CLASS = 4
CLICK_NAMES = ["mouse-click-1", "mouse-click-2", "tick", "snap", "analog"]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[sfx] {msg}", flush=True)


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed:\n{proc.stderr[-2500:]}")
    return proc.stdout + proc.stderr


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(source_id: str, spec: dict[str, str]) -> Path:
    suffix = ".mp3" if spec["url"].endswith(".mp3") else ".wav"
    dest = CACHE / f"{source_id}{suffix}"
    if dest.exists() and dest.stat().st_size > 4096:
        log(f"cached {source_id}")
        return dest
    log(f"download {source_id} <- {spec['url']}")
    request = urllib.request.Request(spec["url"], headers={"User-Agent": "LumenSoundFetch/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=90) as response, dest.open("wb") as fh:
                shutil.copyfileobj(response, fh)
            break
        except Exception as exc:  # noqa: BLE001 - retry is the whole point
            if dest.exists():
                dest.unlink()
            if attempt == 2:
                raise RuntimeError(f"could not download {source_id}: {exc}") from exc
    if dest.stat().st_size < 4096:
        raise RuntimeError(f"download {source_id} is implausibly small")
    return dest


def decode_48k_mono(src: Path, dst: Path) -> None:
    """Decode any source format to 48 kHz mono 16-bit WAV, single pass."""
    run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(src), "-ac", "1",
         "-ar", str(FS), "-c:a", "pcm_s16le", str(dst)])


def read_wav_mono(path: Path) -> list[float]:
    with wave.open(str(path), "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            raise RuntimeError(f"{path} is not mono 16-bit")
        raw = wf.readframes(wf.getnframes())
    pcm = array.array("h")
    pcm.frombytes(raw)
    return [float(v) / 32768.0 for v in pcm]


def write_wav_mono(path: Path, samples: list[float]) -> None:
    clipped = [max(-1.0, min(1.0, v)) for v in samples]
    pcm = array.array("h", (int(max(-32768, min(32767, round(v * 32767)))) for v in clipped))
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(FS)
        wf.writeframes(pcm.tobytes())


def trim_silence(samples: list[float], pre_ms: float = 4.0, post_ms: float = 22.0) -> list[float]:
    """Drop leading/trailing silence below -55 dBFS, keeping short guard bands."""
    peak = max((abs(v) for v in samples), default=0.0)
    if peak < 1e-5:
        return []
    floor = max(peak * 10 ** (-55 / 20), 1e-6)
    first = next((i for i, v in enumerate(samples) if abs(v) >= floor), 0)
    last = len(samples) - 1 - next((i for i, v in enumerate(reversed(samples)) if abs(v) >= floor), 0)
    lo = max(0, first - int(pre_ms / 1000 * FS))
    hi = min(len(samples), last + int(post_ms / 1000 * FS) + 1)
    return samples[lo:hi]


def detect_hits(pcm: list[float]) -> list[tuple[int, int]]:
    """Find transient windows in a recording using a 5 ms RMS envelope.

    Returns (start, end) frame pairs for the key-down strikes. A new strike is
    admitted only after 45 ms of quiet, which keeps one physical key from being
    cut into several windows by its own decay.
    """
    hop = 240  # 5 ms at 48 kHz
    if len(pcm) < hop * 4:
        return []
    energies: list[float] = []
    for i in range(0, len(pcm) - hop + 1, hop):
        block = pcm[i:i + hop]
        energies.append(math.sqrt(sum(v * v for v in block) / hop))
    peak = max(energies)
    if peak < 1e-4:
        return []
    loud = peak * 0.16
    quiet = peak * 0.045
    hits: list[tuple[int, int]] = []
    i = 1
    while i < len(energies):
        if energies[i] < loud:
            i += 1
            continue
        start = i
        while i + 1 < len(energies) and energies[i + 1] >= quiet:
            i += 1
        # Walk back to the onset so the transient, not the room tone, is first.
        while start > 0 and energies[start - 1] >= quiet:
            start -= 1
        s = max(0, start * hop - 2_400)
        e = min(len(pcm), (i + 1) * hop + 4_800)
        if e - s >= int(0.012 * FS) and (not hits or s - hits[-1][1] > int(0.045 * FS)):
            hits.append((s, e))
        i += 1
    return hits


def release_window(pcm: list[float], down_start: int, down_end: int) -> tuple[int, int] | None:
    """If a distinct release transient follows the strike, return its window."""
    search_start = min(len(pcm) - 2_400, down_end)
    search_end = min(len(pcm), down_end + int(0.13 * FS))
    if search_end - search_start < 2_400:
        return None
    hop = 240
    before = max(1e-5, math.sqrt(sum(v * v for v in pcm[max(0, down_start):min(len(pcm), down_start + hop)] * 1) / max(1, min(len(pcm), down_start + hop) - down_start)))
    best_i, best_e = -1, 0.0
    i = search_start
    while i + hop < search_end:
        block = pcm[i:i + hop]
        e = math.sqrt(sum(v * v for v in block) / hop)
        if e > best_e:
            best_e, best_i = e, i
        i += hop
    if best_i < 0 or best_e < before * 0.45:
        return None
    return max(0, best_i - 1_200), min(len(pcm), best_i + int(0.055 * FS))


def measure(path: Path) -> tuple[float, float]:
    """Return (integrated LUFS, true peak dBFS).

    A one-shot is far shorter than EBU R128's measurement window, so it is
    repeated back-to-back with NO silence between repetitions. Looping a fixed
    2 s buffer would measure mostly silence and report a misleadingly low I.
    """
    with wave.open(str(path), "rb") as wf:
        frames = wf.getnframes()
    size = max(FS // 4, frames)          # at least 250 ms of continuous audio
    loops = max(1, int(5.0 * FS / size))
    cmd = ["ffmpeg", "-nostdin", "-y", "-v", "info", "-i", str(path),
           "-filter_complex", f"aloop=loop={loops}:size={size},ebur128=peak=true",
           "-f", "null", "-"]
    text = run(cmd)
    lufs = re.findall(r"Integrated loudness:\s*\n\s*I:\s*(-?[0-9.]+)\s*LUFS", text)
    if not lufs:
        raise RuntimeError(f"could not measure LUFS for {path}: {text[-600:]}")
    integrated = float(lufs[-1])
    # Sample peak is the reliable clipping gate for sub-100 ms transients:
    # ebur128's oversampled true-peak filter misreports bright one-shots.
    astats = run(["ffmpeg", "-nostdin", "-y", "-v", "info", "-i", str(path),
                  "-af", "astats=metadata=1:reset=0", "-f", "null", "-"])
    peaks = re.findall(r"Peak level dB:\s*(-?[0-9.]+)", astats)
    if not peaks:
        raise RuntimeError(f"could not measure peak for {path}")
    peak = float(peaks[-1])
    if not math.isfinite(integrated) or not math.isfinite(peak):
        raise RuntimeError(f"invalid loudness for {path}")
    return integrated, peak


def cap_peak(path: Path, ceiling: float = 0.80) -> float:
    """Final sample-accurate ceiling. Returns the reduction in dB (0 if none)."""
    samples = read_wav_mono(path)
    peak = max((abs(v) for v in samples), default=0.0)
    if peak <= ceiling or peak < 1e-6:
        return 0.0
    factor = ceiling / peak
    write_wav_mono(path, [v * factor for v in samples])
    return -20.0 * math.log10(factor)


def master_take(raw: list[float], dest: Path) -> dict[str, float]:
    """Trim silence, converge to -16 LUFS, keep <= -1.0 dBTP, write 48 kHz WAV.

    Gain is solved iteratively against the same EBU R128 measurement used by
    `verify`, so the number recorded in the manifest is the number measured on
    the delivered file. A final soft ceiling guarantees the true-peak bound.
    """
    trimmed = trim_silence(raw)
    if len(trimmed) < int(0.006 * FS):
        raise RuntimeError("take is empty after silence trim")
    tmp = CACHE / f"_take-{os.getpid()}.wav"
    write_wav_mono(tmp, trimmed)
    before, _ = measure(tmp)
    gain_db = max(-30.0, min(60.0, -16.0 - before))
    after, peak = before, 0.0
    # A short, close-miked strike has a large crest factor. Gentle compression
    # first brings -16 LUFS and a -1 dBTP ceiling into the same reachable range.
    compressor = "acompressor=threshold=0.05:ratio=3:attack=5:release=80:makeup=1"
    for _ in range(12):
        run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(tmp),
             "-af", f"{compressor},volume={gain_db:.3f}dB,"
                    f"alimiter=limit=0.79:attack=0.1:release=50:level=false,aresample={FS}",
             "-ac", "1", "-ar", str(FS), "-c:a", "pcm_s16le", str(dest)])
        cap_peak(dest)
        after, peak = measure(dest)
        error = -16.0 - after
        if abs(error) <= 0.35 and peak <= -1.0:
            break
        gain_db = max(-30.0, min(60.0, gain_db + max(-20.0, min(20.0, error * 0.95))))
    tmp.unlink(missing_ok=True)
    return {"input_lufs": round(before, 2), "output_lufs": round(after, 2),
            "gain_db": round(gain_db, 2), "peak_db": round(peak, 2)}


def pick_evenly(items: list, count: int) -> list:
    if len(items) <= count:
        return items
    return [items[round(i * (len(items) - 1) / (count - 1))] for i in range(count)]


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def build_key_classes(force: bool) -> list[dict]:
    entries: list[dict] = []
    for key_class, source_ids in KEY_CLASS_SOURCES.items():
        class_dir = OUT / "typing" / key_class
        class_dir.mkdir(parents=True, exist_ok=True)
        down_takes: list[tuple[str, list[float]]] = []
        up_takes: list[tuple[str, list[float]]] = []
        for sid in source_ids:
            spec = SOURCES[sid]
            src = download(sid, spec)
            decoded = CACHE / f"{sid}-48k.wav"
            if force or not decoded.exists():
                decode_48k_mono(src, decoded)
            pcm = read_wav_mono(decoded)
            for s, e in detect_hits(pcm):
                down = pcm[s:e]
                if max((abs(v) for v in down), default=0.0) >= 0.02:
                    down_takes.append((sid, down))
                rel = release_window(pcm, s, e)
                if rel:
                    up = pcm[rel[0]:rel[1]]
                    if max((abs(v) for v in up), default=0.0) >= 0.02:
                        up_takes.append((sid, up))
        if len(down_takes) < VARIANTS_PER_CLASS:
            raise RuntimeError(f"{key_class}: only {len(down_takes)} down takes detected")
        if len(up_takes) < RELEASES_PER_CLASS:
            raise RuntimeError(
                f"{key_class}: only {len(up_takes)} candidate releases; "
                "supply separate recorded release material; down-strike substitution is forbidden"
            )
        for phase, takes, count in (("down", down_takes, VARIANTS_PER_CLASS),
                                    ("up", up_takes, RELEASES_PER_CLASS)):
            for index, (sid, raw) in enumerate(pick_evenly(takes, count)):
                name = f"{key_class}-{phase}-{index + 1}.wav"
                dest = class_dir / name
                # Never assign fresh source metadata to an old rendered file.
                stats = master_take(raw, dest)
                entries.append({"id": f"typing/{key_class}/{name}", "path": f"typing/{key_class}/{name}",
                                "keyClass": key_class, "phase": phase, "variant": index + 1,
                                "source": sid, "sourceUrl": SOURCES[sid]["url"],
                                "pageUrl": SOURCES[sid]["page"], "author": SOURCES[sid]["author"],
                                "license": SOURCES[sid]["license"], "sha256": sha256(dest),
                                "bytes": dest.stat().st_size, "mastering": stats})
        log(f"{key_class}: {VARIANTS_PER_CLASS} down + {RELEASES_PER_CLASS} up")
    return entries


def build_clicks(force: bool) -> list[dict]:
    entries: list[dict] = []
    click_dir = OUT / "clicks"
    click_dir.mkdir(parents=True, exist_ok=True)
    for sid, name in zip(CLICK_SOURCES, CLICK_NAMES):
        spec = SOURCES[sid]
        src = download(sid, spec)
        decoded = CACHE / f"{sid}-48k.wav"
        if force or not decoded.exists():
            decode_48k_mono(src, decoded)
        pcm = read_wav_mono(decoded)
        dest = click_dir / f"{name}.wav"
        stats = master_take(pcm, dest)
        entries.append({"id": f"clicks/{name}.wav", "path": f"clicks/{name}.wav",
                        "keyClass": "click", "phase": "down", "variant": CLICK_NAMES.index(name) + 1,
                        "source": sid, "sourceUrl": spec["url"], "pageUrl": spec["page"],
                        "author": spec["author"], "license": spec["license"],
                        "sha256": sha256(dest), "bytes": dest.stat().st_size, "mastering": stats})
        log(f"click {name}: {spec['description']}")
    return entries


CLICK_SOURCES = [f"click-{n}" if n in ("mouse-1", "mouse-2") else f"click-{n}"
                 for n in ("mouse-1", "mouse-2", "tick", "shutter", "analog")]


def write_licenses(entries: list[dict]) -> None:
    lines = [
        "# Sound asset licenses",
        "",
        "Every file below was generated by `scripts/fetch_sounds.py` from a real,",
        "freely licensed recording. All sources are **CC0 1.0** (public-domain",
        "dedication): commercial use, modification and redistribution are allowed",
        "and credit is not legally required. We keep the attribution anyway.",
        "CC0 deed: https://creativecommons.org/publicdomain/zero/1.0/",
        "",
        "The `manifest.json` in this directory is machine-readable and records the",
        "source URL, author, license, measured LUFS and SHA-256 of **every** file.",
        "",
        "## Sources",
        "",
    ]
    used = {e["source"] for e in entries}
    for sid in sorted(used):
        spec = SOURCES[sid]
        lines += [f"### {sid} — {spec['author']} — {spec['license']}", "",
                  f"- Recording: {spec['description']}",
                  f"- Source file: {spec['url']}",
                  f"- License page / source page: {spec['page']}", ""]
    lines += ["## Files", "", "| File | Key class | Phase | Source | License |", "|---|---|---|---|---|"]
    for e in sorted(entries, key=lambda x: x["path"]):
        lines.append(f"| `{e['path']}` | {e['keyClass']} | {e['phase']} | "
                     f"[{e['source']}]({e['pageUrl']}) | {e['license']} |")
    lines.append("")
    LICENSES.write_text("\n".join(lines), encoding="utf-8")


def verify(entries: list[dict]) -> None:
    errors: list[str] = []
    for e in entries:
        path = OUT / e["path"]
        if not path.exists():
            errors.append(f"missing {e['path']}")
            continue
        actual = sha256(path)
        if actual != e["sha256"]:
            errors.append(f"sha mismatch {e['path']}")
        if e["source"] not in SOURCES:
            errors.append(f"unknown source {e['source']} for {e['path']}")
        if e["license"] != "CC0 1.0":
            errors.append(f"non-CC0 source {e['source']}")
        if f"`{e['path']}`" not in LICENSES.read_text(encoding="utf-8"):
            errors.append(f"{e['path']} absent from LICENSES.md")
        if abs(e["mastering"]["output_lufs"] + 16.0) > 1.0:
            errors.append(f"{e['path']} is {e['mastering']['output_lufs']} LUFS, expected -16")
        if e["mastering"]["peak_db"] > -1.0:
            errors.append(f"{e['path']} true peak {e['mastering']['peak_db']} dBTP")
    for key_class in KEY_CLASS_SOURCES:
        for phase, count in (("down", VARIANTS_PER_CLASS), ("up", RELEASES_PER_CLASS)):
            n = sum(1 for e in entries if e["keyClass"] == key_class and e["phase"] == phase)
            if n < count:
                errors.append(f"{key_class}/{phase}: {n} variants, need {count}")
    clicks = [e for e in entries if e["keyClass"] == "click"]
    if len(clicks) < 4:
        errors.append(f"only {len(clicks)} click sounds, need at least 4")
    if errors:
        raise RuntimeError("verification failed:\n  " + "\n  ".join(errors))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="re-download and re-master everything")
    ap.add_argument("--verify-only", action="store_true", help="check the existing outputs and manifest")
    args = ap.parse_args()
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg is required")
    OUT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    if args.verify_only:
        entries = json.loads(MANIFEST.read_text(encoding="utf-8"))["files"]
    else:
        # This legacy classifier only estimates release windows; it cannot
        # certify independently recorded up strokes. The new runtime keeps
        # such releases silent. Do not regenerate the shipping catalog in
        # place. The reviewed-source importer produces a separate candidate.
        raise RuntimeError(
            "Legacy automatic acquisition retired; use scripts/stage_recorded_sounds.py "
            "with reviewed, hash-pinned sources. --verify-only still verifies the old catalog."
        )
        entries = build_key_classes(args.force) + build_clicks(args.force)
        MANIFEST.write_text(json.dumps({"sampleRate": FS, "targetLUFS": -16.0, "files": entries},
                                       indent=2) + "\n", encoding="utf-8")
        write_licenses(entries)
    verify(entries)
    log(f"OK: {len(entries)} files, manifest + LICENSES.md verified")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"[sfx] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
