#!/usr/bin/env python3
"""Original retro UI tones, derived from the user's 800 Hz linear-decay recipe.
Keyboard sounds are never generated here. Only three approved candidate slots.
"""
import math
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "App/public/assets/cursor-clicks"
RATE = 48000
SPECS = (
    ("crisp", 800, .015, .40, 0, 0),
    ("soft", 620, .020, .36, .14, 1.7),
    ("mechanical", 1050, .011, .36, .18, 2.1),
)
OUT.mkdir(parents=True, exist_ok=True)
for name, frequency, decay, gain, harmonic, ratio in SPECS:
    pcm = []
    for i in range(1200):
        t = i / RATE
        envelope = max(0, 1 - t / decay)
        value = gain * envelope * (math.sin(2 * math.pi * frequency * t)
                  + harmonic * math.sin(2 * math.pi * frequency * ratio * t)) / (1 + harmonic)
        pcm.append(math.floor(32767 * value + .5))
    with wave.open(str(OUT / f"{name}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))
