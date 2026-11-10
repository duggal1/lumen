#!/usr/bin/env python3
"""Reject shipping DeepFilterNet unless this Apple Silicon host runs it in realtime."""
import json
import math
import platform
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import wave

if platform.machine() != 'arm64':
    raise SystemExit('DeepFilterNet shipping check requires Apple Silicon')
binary = Path(__file__).resolve().parents[1] / 'Sources/LumenAudio/Resources/DeepFilterNet/deep-filter'
seconds = 5
with tempfile.TemporaryDirectory() as temporary:
    source = Path(temporary) / 'voice.wav'
    with wave.open(str(source), 'wb') as audio:
        audio.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(i * 2 * math.pi * 170 / 48000))) for i in range(seconds * 48000)))
    started = time.monotonic()
    subprocess.run([str(binary), '--compensate-delay', '--output-dir', temporary + '/out', str(source)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=seconds)
    elapsed = time.monotonic() - started
    print(json.dumps({'audio_seconds': seconds, 'elapsed_seconds': elapsed, 'faster_than_realtime': elapsed < seconds}))
    if elapsed >= seconds:
        raise SystemExit('DeepFilterNet failed the shipping speed gate')
