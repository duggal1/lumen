#!/usr/bin/env python3
"""Rebuild the shipped interaction-sound catalog from real CC0 recordings.

Run from the repository root:

    python3 scripts/rebuild_recorded_sounds.py [--verify-only]

Every output is a slice of a real recording, converted to 48 kHz mono. Nothing
is synthesised. Unlike the retired legacy builder this does not loudness-
compress each take to -16 LUFS: a short key strike has a large crest factor and
per-take compression flattened exactly the attack that makes a keyboard sound
tactile. Each take instead gets one static gain to a -6 dBFS peak, a 60 Hz
high-pass, and sub-millisecond boundary fades. Attack, decay and relative
dynamics are preserved.

Key releases are only emitted when the source recording contains a second,
separate transient after the down stroke. The detector records the measured
offset and amplitude ratio in the manifest as evidence; a down stroke is never
relabelled as a release.

Sources are CC0 1.0 (public-domain dedication), verified on the linked pages.
Original files are cached under .proof/sfx-cache; the cache is not shipped.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import urllib.request
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Sounds"
CACHE = ROOT / ".proof" / "sfx-cache"
MANIFEST = OUT / "manifest.json"
LICENSES = OUT / "LICENSES.md"
FS = 48_000
HOP = 240  # 5 ms
TARGET_PEAK_DB = -6.0
TARGET_PEAK = 10 ** (TARGET_PEAK_DB / 20)

# All CC0 1.0. The page URL is the licence evidence; the direct URL is the
# publisher's own preview/WAV encode.
SOURCES: dict[str, dict[str, str]] = {
    "woven-typing": {
        "url": "https://assets.sfx.woven.video/sfx/keyboard-typing.wav",
        "page": "https://www.woven.video/sfx/keyboard-typing-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Close-miked mechanical keyboard typing session.",
    },
    "woven-typing-realistic": {
        "url": "https://assets.sfx.woven.video/sfx/keyboard-typing-realistic.wav",
        "page": "https://www.woven.video/sfx/keyboard-typing-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Realistic close-miked keyboard typing session.",
    },
    "fs-mx-blue": {
        "url": "https://cdn.freesound.org/previews/382/382057_1106446-hq.mp3",
        "page": "https://freesound.org/s/382057/",
        "author": "EricsSoundschmiede",
        "license": "CC0 1.0",
        "description": "Cherry MX Blue keyboard typing, isolated strokes.",
    },
    "fs-mx-black": {
        "url": "https://cdn.freesound.org/previews/628/628325_13894315-hq.mp3",
        "page": "https://freesound.org/s/628325/",
        "author": "ujonathan",
        "license": "CC0 1.0",
        "description": "Leopold FC980M PD, Cherry MX Black switches.",
    },
    "fs-topre": {
        "url": "https://cdn.freesound.org/previews/546/546033_12206738-hq.mp3",
        "page": "https://freesound.org/s/546033/",
        "author": "grcekh",
        "license": "CC0 1.0",
        "description": "HHKB Professional Hybrid (Topre), deep soft thock.",
    },
    "fs-whitefox": {
        "url": "https://cdn.freesound.org/previews/546/546167_12206738-hq.mp3",
        "page": "https://freesound.org/s/546167/",
        "author": "grcekh",
        "license": "CC0 1.0",
        "description": "WhiteFox mechanical board, isolated single keys.",
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
        "description": "2018 MacBook Pro laptop keys, close-miked.",
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
        "description": "Clean, full-bodied mouse click.",
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
        "description": "Sharp single mechanical snap (camera shutter).",
    },
    "click-analog": {
        "url": "https://assets.sfx.woven.video/sfx/camera-analog.wav",
        "page": "https://www.woven.video/sfx/click-sound-effect",
        "author": "Woven SFX",
        "license": "CC0 1.0",
        "description": "Soft analog mechanical switch click.",
    },
}

# Each class draws from its own family so letters, numbers, modifiers and
# navigation are genuinely different recordings. Overlap is allowed only when a
# class has too few distinct transients; output hashes are still deduplicated.
# Each class draws from its own family, in priority order, and never reuses a
# source window already claimed by another class. Letters, numbers, space,
# Enter, Backspace, modifiers and navigation therefore come from different
# boards; a class may share a board with another only through different
# recorded strikes.
KEY_CLASS_SOURCES: dict[str, list[str]] = {
    "alpha": ["fs-whitefox", "fs-gateron", "woven-typing"],
    "number": ["fs-mx-blue", "fs-mx-black"],
    "space": ["fs-topre"],
    "enter": ["fs-mx-black", "fs-model-f"],
    "backspace": ["fs-model-f", "fs-mx-black"],
    "shift": ["fs-whitefox", "fs-gateron"],
    "modifier": ["fs-topre", "fs-mx-blue"],
    "nav": ["fs-macbook", "fs-mx-blue"],
    "fn": ["fs-model-f", "fs-macbook"],
}

VARIANTS_PER_CLASS = 5
RELEASES_PER_CLASS = 4
CLICK_NAMES = ["mouse-click-1", "mouse-click-2", "tick", "snap", "analog"]
CLICK_SOURCES = ["click-mouse-1", "click-mouse-2", "click-tick", "click-shutter", "click-analog"]


def log(msg: str) -> None:
    print(f"[sfx] {msg}", flush=True)


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
        return dest
    CACHE.mkdir(parents=True, exist_ok=True)
    log(f"download {source_id} <- {spec['url']}")
    request = urllib.request.Request(spec["url"], headers={"User-Agent": "LumenSoundFetch/2.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=90) as response, dest.open("wb") as fh:
                shutil.copyfileobj(response, fh)
            break
        except Exception as exc:  # noqa: BLE001 - retry is the point
            dest.unlink(missing_ok=True)
            if attempt == 2:
                raise RuntimeError(f"could not download {source_id}: {exc}") from exc
    if dest.stat().st_size < 4096:
        raise RuntimeError(f"download {source_id} is implausibly small")
    return dest


def decode_mono(src: Path, dest: Path) -> None:
    subprocess.run(
        ["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(src), "-ac", "1",
         "-ar", str(FS), "-c:a", "pcm_s16le", str(dest)],
        check=True,
    )


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            raise RuntimeError(f"{path} is not mono 16-bit")
        raw = wf.readframes(wf.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path: Path, samples: np.ndarray) -> None:
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = np.round(clipped * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(FS)
        wf.writeframes(pcm.tobytes())


def rms_envelope(samples: np.ndarray) -> np.ndarray:
    frames = len(samples) // HOP
    if frames == 0:
        return np.zeros(0, dtype=np.float32)
    blocks = samples[: frames * HOP].reshape(frames, HOP)
    return np.sqrt(np.mean(blocks * blocks, axis=1) + 1e-20)


def detect_strikes(samples: np.ndarray) -> list[tuple[int, int]]:
    """Return (onset, body_end) frame pairs for separate physical strikes."""
    env = rms_envelope(samples)
    if len(env) == 0:
        return []
    peak = float(env.max())
    if peak < 1e-4:
        return []
    loud, quiet = peak * 0.18, peak * 0.05
    strikes: list[tuple[int, int]] = []
    i = 1
    while i < len(env):
        if env[i] < loud:
            i += 1
            continue
        start = i
        while i + 1 < len(env) and env[i + 1] >= quiet:
            i += 1
        while start > 0 and env[start - 1] >= quiet:
            start -= 1
        a = max(0, start * HOP - int(0.003 * FS))
        b = min(len(samples), (i + 1) * HOP + int(0.02 * FS))
        if b - a >= int(0.010 * FS) and (not strikes or a - strikes[-1][1] > int(0.040 * FS)):
            strikes.append((a, b))
        i += 1
    return strikes


def analyze_events(samples: np.ndarray) -> list[dict]:
    """Find down strokes and pair a following distinct transient as their release.

    A release candidate must be a second energy peak 30-200 ms after the down
    onset, separated from it by a quiet valley (<40% of the second peak), and no
    louder than the down stroke. Each peak is used once: a paired transient is a
    release, never also a down take. Returns dicts with `onset`, `body_end`,
    `release` (start/end/ratio) or None.
    """
    env = rms_envelope(samples)
    if len(env) == 0:
        return []
    peak = float(env.max())
    if peak < 1e-4:
        return []
    loud = peak * 0.16
    peaks: list[int] = []
    for i in range(1, len(env) - 1):
        if env[i] >= loud and env[i] >= env[i - 1] and env[i] > env[i + 1]:
            if peaks and i - peaks[-1] < int(0.012 * FS / HOP):
                if env[i] > env[peaks[-1]]:
                    peaks[-1] = i
            else:
                peaks.append(i)
    events: list[dict] = []
    used: set[int] = set()
    for idx, f in enumerate(peaks):
        if f in used:
            continue
        onset = max(0, f * HOP - int(0.003 * FS))
        body_end = trim_decay(samples, onset, cap_ms=90.0, min_ms=16.0)
        event = {"onset": onset, "body_end": body_end, "peak_frame": f, "release": None}
        if idx + 1 < len(peaks):
            g = peaks[idx + 1]
            delta_ms = (g - f) * HOP / FS * 1000
            if 30 <= delta_ms <= 200 and env[g] <= env[f] * 0.85:
                valley = float(env[f + 1:g].min()) if g > f + 1 else 0.0
                if valley <= env[g] * 0.4:
                    start = max(0, g * HOP - int(0.002 * FS))
                    end = trim_decay(samples, start, cap_ms=50.0, min_ms=12.0)
                    event["release"] = (start, end, float(env[g]) / float(env[f]))
                    used.add(g)
        events.append(event)
    return events


def trim_decay(samples: np.ndarray, onset: int, cap_ms: float, min_ms: float) -> int:
    """End of the audible body: decay to -42 dB or the cap, whichever is first."""
    env = rms_envelope(samples)
    if len(env) == 0:
        return min(len(samples), onset + int(min_ms / 1000 * FS))
    peak = float(np.max(env[onset // HOP: min(len(env), onset // HOP + 30)]))
    threshold = max(peak * 10 ** (-42 / 20), 1e-6)
    f = onset // HOP
    cap = min(len(env), (onset + int(cap_ms / 1000 * FS)) // HOP)
    while f + 1 < cap and env[f + 1] >= threshold:
        f += 1
    end = min(len(samples), (f + 1) * HOP)
    return max(end, min(len(samples), onset + int(min_ms / 1000 * FS)))


def highpass(samples: np.ndarray, cutoff: float = 60.0) -> np.ndarray:
    """Single-pass one-pole high-pass: removes DC/rumble, keeps the attack."""
    if len(samples) == 0:
        return samples
    rc = 1.0 / (2.0 * math.pi * cutoff)
    dt = 1.0 / FS
    alpha = rc / (rc + dt)
    out = np.empty_like(samples)
    prev_x = float(samples[0])
    prev_y = 0.0
    for i, x in enumerate(samples):
        y = alpha * (prev_y + x - prev_x)
        out[i] = y
        prev_x, prev_y = float(x), y
    return out


def master(samples: np.ndarray) -> tuple[np.ndarray, float]:
    """Static gain to -6 dBFS, 0.5 ms fade in, 3 ms fade out. No compression."""
    x = highpass(samples)
    x = x - float(np.mean(x))
    fade_in = min(len(x) // 2, int(0.0005 * FS))
    fade_out = min(len(x) // 2, int(0.003 * FS))
    if fade_in > 0:
        x[:fade_in] *= np.linspace(0.0, 1.0, fade_in, dtype=np.float32)
    if fade_out > 0:
        x[-fade_out:] *= np.linspace(1.0, 0.0, fade_out, dtype=np.float32)
    # Measure after the boundary fades so the shipped peak is exactly the
    # target; a short take whose transient sits near an edge would otherwise
    # come out quieter than the manifest claims.
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    if peak < 1e-5:
        raise RuntimeError("take has no recorded signal")
    gain = TARGET_PEAK / peak
    return x * gain, 20 * math.log10(gain)


def load_source(source_id: str, spec: dict[str, str], originals: dict[str, Path]) -> tuple[np.ndarray, str]:
    src = download(source_id, spec)
    decoded = CACHE / f"{source_id}-48k.wav"
    if not decoded.exists():
        decode_mono(src, decoded)
    originals[source_id] = src
    return read_wav(decoded), sha256(src)


def pick_evenly(items: list, count: int) -> list:
    if len(items) <= count:
        return items
    return [items[round(i * (len(items) - 1) / (count - 1))] for i in range(count)]


def build_key_classes(originals: dict[str, Path]) -> list[dict]:
    entries: list[dict] = []
    # Only windows actually selected by a previous class are claimed. Scanning a
    # source for candidates must not starve the classes that come after it.
    claimed: set[tuple[str, int, int]] = set()
    seen_output: set[str] = set()

    def claim(candidates: list[tuple[str, np.ndarray, dict]], count: int,
              phase: str) -> list[tuple[str, np.ndarray, dict]]:
        fresh = [c for c in candidates
                 if (c[0], int(round(c[2]["startSeconds"] * FS)),
                     int(round(c[2]["endSeconds"] * FS))) not in claimed]
        if len(fresh) < count:
            raise RuntimeError(f"only {len(fresh)} unclaimed {phase} candidates, need {count}")
        chosen = pick_evenly(fresh, count)
        for sid, _, meta in chosen:
            claimed.add((sid, int(round(meta["startSeconds"] * FS)),
                         int(round(meta["endSeconds"] * FS))))
        return chosen

    for key_class, source_ids in KEY_CLASS_SOURCES.items():
        downs: list[tuple[str, np.ndarray, dict]] = []
        ups: list[tuple[str, np.ndarray, dict]] = []
        for sid in source_ids:
            pcm, original_hash = load_source(sid, SOURCES[sid], originals)
            for event in analyze_events(pcm):
                onset, body_end = event["onset"], event["body_end"]
                rel = event["release"]
                if rel is not None:
                    body_end = min(body_end, max(onset + int(0.010 * FS), rel[0] - int(0.002 * FS)))
                down = pcm[onset:body_end]
                if float(np.max(np.abs(down))) >= 0.02:
                    downs.append((sid, down, {"startSeconds": round(onset / FS, 6),
                                              "endSeconds": round(body_end / FS, 6),
                                              "originalSha256": original_hash}))
                if rel is None:
                    continue
                start, end, ratio = rel
                up = pcm[start:end]
                if float(np.max(np.abs(up))) >= 0.02:
                    ups.append((sid, up, {"startSeconds": round(start / FS, 6),
                                          "endSeconds": round(end / FS, 6),
                                          "originalSha256": original_hash,
                                          "releaseEvidence": "detected-secondary-transient",
                                          "releaseDeltaMs": round((start - onset) / FS * 1000, 2),
                                          "releaseAmplitudeRatio": round(ratio, 3)}))
        for phase, takes, count in (("down", downs, VARIANTS_PER_CLASS),
                                    ("up", ups, RELEASES_PER_CLASS)):
            for index, (sid, raw, meta) in enumerate(claim(takes, count, phase)):
                mastered, gain_db = master(raw)
                path = f"typing/{key_class}/{key_class}-{phase}-{index + 1}.wav"
                dest = OUT / path
                write_wav(dest, mastered)
                digest = sha256(dest)
                if digest in seen_output:
                    raise RuntimeError(f"{path}: duplicated processed recording")
                seen_output.add(digest)
                entries.append({
                    "id": path, "path": path, "keyClass": key_class, "phase": phase,
                    "variant": index + 1, "source": sid,
                    "sourceUrl": SOURCES[sid]["url"], "pageUrl": SOURCES[sid]["page"],
                    "author": SOURCES[sid]["author"], "license": SOURCES[sid]["license"],
                    "sourceSha256": meta["originalSha256"],
                    "sourceWindow": {"startSeconds": meta["startSeconds"],
                                     "endSeconds": meta["endSeconds"]},
                    "sha256": digest, "bytes": dest.stat().st_size,
                    "mastering": {"policy": "static-gain-transient-preserved",
                                  "targetPeakDb": TARGET_PEAK_DB,
                                  "peakDb": round(20 * math.log10(float(np.max(np.abs(mastered)))), 3),
                                  "gainDb": round(gain_db, 3),
                                  "sampleRate": FS},
                    **({"releaseEvidence": meta["releaseEvidence"],
                        "releaseDeltaMs": meta["releaseDeltaMs"],
                        "releaseAmplitudeRatio": meta["releaseAmplitudeRatio"]}
                       if phase == "up" else {}),
                })
        log(f"{key_class}: {VARIANTS_PER_CLASS} down + {RELEASES_PER_CLASS} release")
    return entries


def build_clicks(originals: dict[str, Path]) -> list[dict]:
    entries: list[dict] = []
    seen_output: set[str] = set()
    for sid, name in zip(CLICK_SOURCES, CLICK_NAMES):
        pcm, original_hash = load_source(sid, SOURCES[sid], originals)
        strikes = detect_strikes(pcm)
        if not strikes:
            raise RuntimeError(f"{sid}: no click transient detected")
        onset, body_end = strikes[0]
        end = trim_decay(pcm, onset, cap_ms=260.0, min_ms=25.0)
        mastered, gain_db = master(pcm[onset:end])
        path = f"clicks/{name}.wav"
        dest = OUT / path
        write_wav(dest, mastered)
        digest = sha256(dest)
        if digest in seen_output:
            raise RuntimeError(f"{path}: duplicated processed recording")
        seen_output.add(digest)
        entries.append({
            "id": path, "path": path, "keyClass": "click", "phase": "down",
            "variant": CLICK_NAMES.index(name) + 1, "source": sid,
            "sourceUrl": SOURCES[sid]["url"], "pageUrl": SOURCES[sid]["page"],
            "author": SOURCES[sid]["author"], "license": SOURCES[sid]["license"],
            "sourceSha256": original_hash,
            "sourceWindow": {"startSeconds": round(onset / FS, 6),
                             "endSeconds": round(end / FS, 6)},
            "sha256": digest, "bytes": dest.stat().st_size,
            "mastering": {"policy": "static-gain-transient-preserved",
                          "targetPeakDb": TARGET_PEAK_DB,
                          "peakDb": round(20 * math.log10(float(np.max(np.abs(mastered)))), 3),
                          "gainDb": round(gain_db, 3),
                          "sampleRate": FS},
        })
        log(f"click {name}: {SOURCES[sid]['description']}")
    return entries


def write_licenses(entries: list[dict]) -> None:
    used = sorted({e["source"] for e in entries})
    lines = [
        "# Sound asset licenses",
        "",
        "Every file below is a slice of a real, freely licensed recording, prepared by",
        "`scripts/rebuild_recorded_sounds.py`. All sources are **CC0 1.0**",
        "(public-domain dedication): commercial use, modification and redistribution",
        "are allowed and credit is not legally required. Attribution is kept anyway.",
        "CC0 deed: https://creativecommons.org/publicdomain/zero/1.0/",
        "",
        "The machine-readable `manifest.json` records the source URL, author, license,",
        "source interval, original and processed SHA-256 for **every** file. No file is",
        "synthesised and no release is inferred from a down stroke: a release is only",
        "shipped when the recording contains a measured second transient.",
        "",
        "Mastering policy: one static gain to a -6 dBFS peak, 60 Hz high-pass, 0.5 ms",
        "and 3 ms boundary fades at 48 kHz. No per-take loudness compression.",
        "",
        "## Sources",
        "",
    ]
    for sid in used:
        spec = SOURCES[sid]
        lines += [f"### {sid} — {spec['author']} — {spec['license']}", "",
                  f"- Recording: {spec['description']}",
                  f"- Source file: {spec['url']}",
                  f"- License page / source page: {spec['page']}", ""]
    lines += ["## Files", "",
              "| File | Class | Phase | Source | SHA-256 |", "|---|---|---|---|---|"]
    for e in sorted(entries, key=lambda x: x["path"]):
        lines.append(f"| `{e['path']}` | {e['keyClass']} | {e['phase']} | "
                     f"[{e['source']}]({e['pageUrl']}) | `{e['sha256']}` |")
    lines.append("")
    LICENSES.write_text("\n".join(lines), encoding="utf-8")


def verify(entries: list[dict]) -> None:
    errors: list[str] = []
    hashes: dict[str, str] = {}
    for e in entries:
        path = OUT / e["path"]
        if not path.exists():
            errors.append(f"missing {e['path']}")
            continue
        with wave.open(str(path), "rb") as wf:
            if wf.getframerate() != FS or wf.getnchannels() != 1 or wf.getsampwidth() != 2:
                errors.append(f"{e['path']}: not 48 kHz mono 16-bit")
        pcm = read_wav(path)
        peak = float(np.max(np.abs(pcm))) if len(pcm) else 0.0
        peak_db = 20 * math.log10(peak) if peak else -999
        if abs(peak_db - TARGET_PEAK_DB) > 0.5:
            errors.append(f"{e['path']}: peak {peak_db:.2f} dBFS")
        if sha256(path) != e["sha256"]:
            errors.append(f"sha mismatch {e['path']}")
        if e["sha256"] in hashes:
            errors.append(f"{e['path']} duplicates {hashes[e['sha256']]}")
        hashes[e["sha256"]] = e["path"]
        if e["license"] != "CC0 1.0":
            errors.append(f"non-CC0 source {e['source']}")
        if not e["sourceUrl"].startswith("https://") or not e["pageUrl"].startswith("https://"):
            errors.append(f"{e['path']}: missing HTTPS provenance")
        if f"`{e['path']}`" not in LICENSES.read_text(encoding="utf-8"):
            errors.append(f"{e['path']} absent from LICENSES.md")
        if e["phase"] == "up" and not e.get("releaseEvidence"):
            errors.append(f"{e['path']}: release without recorded evidence")
    for key_class in KEY_CLASS_SOURCES:
        for phase, count in (("down", VARIANTS_PER_CLASS), ("up", RELEASES_PER_CLASS)):
            n = sum(1 for e in entries if e["keyClass"] == key_class and e["phase"] == phase)
            if n != count:
                errors.append(f"{key_class}/{phase}: {n} files, expected {count}")
    clicks = [e for e in entries if e["keyClass"] == "click"]
    if len(clicks) != len(CLICK_NAMES):
        errors.append(f"{len(clicks)} click files, expected {len(CLICK_NAMES)}")
    if errors:
        raise RuntimeError("verification failed:\n  " + "\n  ".join(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        entries = json.loads(MANIFEST.read_text(encoding="utf-8"))["files"]
        verify(entries)
        log(f"OK: {len(entries)} files verified")
        return 0
    originals: dict[str, Path] = {}
    OUT.mkdir(parents=True, exist_ok=True)
    entries = build_key_classes(originals) + build_clicks(originals)
    MANIFEST.write_text(json.dumps({
        "schemaVersion": 2,
        "sampleRate": FS,
        "masteringPolicy": "static-gain-transient-preserved",
        "targetPeakDb": TARGET_PEAK_DB,
        "files": entries,
    }, indent=2) + "\n", encoding="utf-8")
    write_licenses(entries)
    verify(entries)
    log(f"OK: {len(entries)} files, manifest + LICENSES.md verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
