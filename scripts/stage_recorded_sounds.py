#!/usr/bin/env python3
"""Stage reviewed real recordings; never overwrite the shipped catalog.

Usage: python3 scripts/stage_recorded_sounds.py reviewed.json --output /tmp/lumen-sounds-v2

reviewed.json is a JSON array of objects with path, localFile (relative to the
JSON), sourceUrl, pageUrl, author, license ("CC0 1.0"), sourceSha256, keyClass,
phase, startSeconds, endSeconds, reviewedBy, and reviewNote. For phase "up",
releaseEvidence must be "separate-recorded-release". These are human review
assertions, not inferred by a waveform or fabricated by this program.

Download originals separately from their licensed source. This deliberately
does not fetch a guessed URL, synthesize samples, or treat a down stroke as up.
Requires ffmpeg. Output is a candidate, not an automatic packaging change.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import wave
from array import array

FS = 48000
KEYS = {"alpha", "number", "space", "enter", "backspace", "shift", "modifier", "nav", "fn"}
CLICKS = {"mouse-click-1", "mouse-click-2", "tick", "snap", "analog"}
HASH = re.compile(r"[0-9a-f]{64}")
TARGET_PEAK = 0.63  # about -4 dBFS, before the linked SFX bus
MAX_BOOST = 2.0  # at most +6 dB; do not turn room noise into a strike

def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()

def checked(row, base):
    for field in ("path", "localFile", "sourceUrl", "pageUrl", "author", "license",
                  "sourceSha256", "keyClass", "phase", "reviewedBy", "reviewNote"):
        if not isinstance(row.get(field), str) or not row[field].strip():
            raise ValueError(f"missing {field}")
    if row["license"] != "CC0 1.0" or not all(row[k].startswith("https://") for k in ("sourceUrl", "pageUrl")):
        raise ValueError("require reviewed CC0 source and HTTPS provenance")
    key, phase, path = row["keyClass"], row["phase"], row["path"]
    if key == "click":
        if phase != "down" or path not in {f"clicks/{name}.wav" for name in CLICKS}:
            raise ValueError(f"invalid click slot {path}")
    elif key not in KEYS or phase not in {"down", "up"} or not re.fullmatch(
            rf"typing/{key}/{key}-{phase}-[1-8]\.wav", path):
        raise ValueError(f"invalid key slot {path}")
    if phase == "up" and row.get("releaseEvidence") != "separate-recorded-release":
        raise ValueError(f"{path}: separate release review required")
    src = (base / row["localFile"]).resolve(strict=True)
    expected = row["sourceSha256"].lower()
    if not HASH.fullmatch(expected) or digest(src) != expected:
        raise ValueError(f"{path}: original hash mismatch")
    start, end = float(row["startSeconds"]), float(row["endSeconds"])
    if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end
            and 0.006 <= end - start <= 0.5):
        raise ValueError(f"{path}: invalid reviewed time window")
    return src, start, end

def stage(rows, base, output):
    if output.exists():
        raise FileExistsError(f"refuse overwrite: {output}")
    if not rows or not shutil.which("ffmpeg"):
        raise RuntimeError("nonempty review manifest and ffmpeg required")
    output.parent.mkdir(parents=True, exist_ok=True)
    entries, paths, hashes, source_windows = [], set(), set(), set()
    with tempfile.TemporaryDirectory(prefix=".sound-stage-", dir=output.parent) as temp:
        stage_root = Path(temp)
        for row in rows:
            src, start, end = checked(row, base)
            path = row["path"]
            # The same source interval cannot be assigned to a second slot
            # or mislabeled as both down and up. Intersecting opposite phases
            # are also refused; review must isolate each physical transient.
            original = row["sourceSha256"].lower()
            for old_hash, old_start, old_end, old_phase in source_windows:
                if original == old_hash and start < old_end and end > old_start:
                    raise ValueError(f"{path}: overlapping reviewed source intervals")
            source_windows.add((original, start, end, row["phase"]))
            if path in paths:
                raise ValueError(f"duplicate slot {path}")
            paths.add(path)
            pcm = subprocess.check_output([
                "ffmpeg", "-nostdin", "-v", "error", "-ss", str(start), "-i", str(src),
                "-t", str(end - start), "-ac", "1", "-ar", str(FS),
                "-f", "s16le", "-acodec", "pcm_s16le", "-"
            ])
            samples = array("h")
            samples.frombytes(pcm)
            if os.sys.byteorder != "little":
                samples.byteswap()
            if len(samples) < int(0.006 * FS):
                raise ValueError(f"{path}: insufficient decoded samples")
            peak = max(abs(v) for v in samples)
            if peak < 327:
                raise ValueError(f"{path}: inadequate recorded signal")
            gain = min(MAX_BOOST, TARGET_PEAK * 32767 / peak)
            # Single static gain, tiny boundary fades; no per-take loudness
            # compressor or generated transient. Retain original attack.
            fade_in, fade_out = 12, min(96, len(samples) // 4)
            for i, value in enumerate(samples):
                envelope = min(1.0, i / fade_in, (len(samples) - 1 - i) / max(1, fade_out))
                samples[i] = round(value * gain * envelope)
            if os.sys.byteorder != "little":
                samples.byteswap()
            target = stage_root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            with wave.open(str(target), "wb") as file:
                file.setnchannels(1); file.setsampwidth(2); file.setframerate(FS)
                file.writeframes(samples.tobytes())
            sha = digest(target)
            if sha in hashes:
                raise ValueError(f"{path}: duplicated processed recording")
            hashes.add(sha)
            entry = {k: v for k, v in row.items() if k != "localFile"}
            entry.update(id=path, sha256=sha, bytes=target.stat().st_size,
                         mastering={"gain_db": round(20 * math.log10(gain), 3),
                                    "peak_policy": "static-gain-attack-preserved"})
            entries.append(entry)
        manifest = {"schemaVersion": 2, "sampleRate": FS, "status": "candidate",
                    "files": sorted(entries, key=lambda e: e["path"])}
        (stage_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        lines = ["# Reviewed candidate recordings", "", "CC0 1.0; not shipped until audited.", ""]
        for entry in manifest["files"]:
            lines.append(f"- `{entry['path']}`: {entry['author']} — {entry['pageUrl']} — {entry['sha256']}")
        (stage_root / "LICENSES.md").write_text("\n".join(lines) + "\n")
        # Only publish a complete candidate. No changes to Resources/Sounds.
        stage_root.rename(output)
    return len(entries)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("review", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    review = args.review.resolve(strict=True)
    output = args.output.resolve()
    repo = Path(__file__).resolve().parents[1]
    if output == repo or repo in output.parents:
        raise ValueError("candidate must be staged outside the repository")
    rows = json.loads(review.read_text())
    if not isinstance(rows, list):
        raise ValueError("review must be a JSON array")
    print(f"Staged {stage(rows, review.parent, output)} reviewed recordings at {output}")

if __name__ == "__main__":
    main()
