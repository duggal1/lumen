#!/usr/bin/env python3
"""Install Orange Deluxe locally for personal use only. Never commit this pack.

Official source: https://mechvibes.com/sound-packs/orange-deluxe-press-release-separated
Use --zip PATH for a locally downloaded copy, otherwise use the official download
endpoint. Requires ffmpeg (for Ogg -> PCM WAV). Restart Lumen after installation.
"""
import argparse
import io
import json
import math
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import urllib.request
import wave
import zipfile

URL = "https://mechvibes.com/api/sound-packs/mv-591a38a826614dd39210e579be729101/download"
TARGET = Path.home() / "Library/Application Support/Lumen/TypingPacks/orange-deluxe"
MAX_BYTES = 16 * 1024 * 1024

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", type=Path)
    parser.add_argument("--accept-personal-use", action="store_true", required=True)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    if TARGET.exists() and not args.replace:
        raise SystemExit("Already installed; pass --replace to replace your private pack.")
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required to convert the original recording to PCM.")
    if args.zip:
        if args.zip.stat().st_size > MAX_BYTES:
            raise ValueError("archive too large")
        raw = args.zip.read_bytes()
    else:
        request = urllib.request.Request(URL, headers={"User-Agent": "Lumen personal pack installer"})
        with urllib.request.urlopen(request, timeout=45) as response:
            raw = response.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("archive too large")
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".orange-", dir=TARGET.parent) as tmp, zipfile.ZipFile(io.BytesIO(raw)) as archive:
        folder = Path(tmp) / "pack"
        folder.mkdir()
        members = [i for i in archive.infolist() if not i.is_dir()]
        if len(members) > 64 or sum(i.file_size for i in members) > MAX_BYTES:
            raise ValueError("invalid archive limits")
        config_entries = [i for i in members if PurePosixPath(i.filename).name == "config.json"]
        if len(config_entries) != 1:
            raise ValueError("expected one config.json")
        config_entry = config_entries[0]
        config = json.loads(archive.read(config_entry))
        definitions = config.get("definitions")
        if not isinstance(definitions, dict):
            raise ValueError("unsupported pack config; require explicit per-key timings")
        source = config.get("audio_file")
        if not isinstance(source, str) or not source or PurePosixPath(source).name != source or source in {".", ".."}:
            raise ValueError("invalid audio filename")
        source_path = str(PurePosixPath(config_entry.filename).parent / source)
        audio_entries = [i for i in members if i.filename == source_path]
        if len(audio_entries) != 1:
            raise ValueError("missing unique source audio")
        original = Path(tmp) / ("original" + Path(source).suffix)
        original.write_bytes(archive.read(audio_entries[0]))
        wav = folder / "sound.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(original),
                        "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", str(wav)], check=True)
        with wave.open(str(wav), "rb") as audio:
            duration_ms = 1000 * audio.getnframes() / audio.getframerate()
        required = {"Key" + c for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"} | {"Space", "Enter", "Backspace"}
        down_count = up_count = 0
        for key, definition in definitions.items():
            if definition is None:
                continue
            timing = definition.get("timing")
            if not isinstance(timing, list) or not timing or len(timing) > 2:
                raise ValueError(f"{key}: invalid timing")
            previous_end = 0
            for window in timing:
                if not isinstance(window, list) or len(window) != 2:
                    raise ValueError(f"{key}: invalid interval")
                start, end = map(float, window)
                if not (math.isfinite(start) and math.isfinite(end) and
                        0 <= start < end <= duration_ms + 1 and end-start <= 2000 and start >= previous_end):
                    raise ValueError(f"{key}: invalid or overlapping press/release interval")
                previous_end = end
            down_count += 1
            required.discard(key)
            if len(timing) == 2:
                up_count += 1
        if required:
            raise ValueError(f"incomplete core keyboard coverage: {sorted(required)}")
        config["audio_file"] = "sound.wav"
        config["definition_method"] = "single"
        (folder / "config.json").write_text(json.dumps(config, indent=2))
        licenses = [i for i in members if PurePosixPath(i.filename).name.lower() in {"license.txt", "license.md", "license"}]
        if licenses:
            (folder / "LICENSE.txt").write_bytes(archive.read(licenses[0]))
        (folder / "SOURCE.txt").write_text(
            "Personal use only. Do not redistribute.\n"
            "https://mechvibes.com/sound-packs/orange-deluxe-press-release-separated\n"
        )
        previous = Path(tmp) / "previous"
        if TARGET.exists():
            TARGET.rename(previous)
        try:
            folder.rename(TARGET)
        except OSError:
            if previous.exists():
                previous.rename(TARGET)
            raise
        print(f"Installed private Orange Deluxe: {down_count} press, {up_count} release mappings. Restart Lumen.")

if __name__ == "__main__":
    main()
