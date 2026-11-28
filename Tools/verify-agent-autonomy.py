"""Fail-closed local evidence gate. No claims of artistic or crash signoff."""
import json
import math
import pathlib
import re
import sys

def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def require(condition, label):
    if not condition:
        raise ValueError(label)

def validate(root, commit):
    require(re.fullmatch(r"[a-f0-9]{40}", commit) is not None, "invalid commit")
    def read(path):
        result = json.loads((root / path).read_text())
        require(result.get("commit") == commit, f"stale commit: {path}")
        return result
    director = read("director/report.json")
    hardware = read("hardware/report.json")
    cadence = read("cadence.json")
    machine = (root / "hardware/machine.txt").read_text()
    require(re.search(r"^chip=Apple M1$", machine, re.M) is not None, "requires base Apple M1")
    require(hardware.get("physicalMemoryBytes") == 8 * 1024**3, "requires 8 GiB RAM")
    require(cadence.get("physicalMemoryBytes") == hardware["physicalMemoryBytes"], "cadence hardware memory mismatch")
    frames = director.get("frames", [])
    exports = director.get("exports", [])
    require(len(frames) >= 6 and len(exports) == 2, "missing annotated replay evidence")
    for row in frames + exports:
        name = row.get("file", "")
        require(name and pathlib.Path(name).name == name and (root / "director" / name).is_file(), "missing replay artifact")
    runs = hardware.get("runs", [])
    require(len(runs) == 4 and {(r["height"], r["trial"]) for r in runs} == {(1080, 1), (1080, 2), (2160, 1), (2160, 2)}, "missing export trials")
    require(all(r.get("stretchTargetMet") is True and number(r.get("realtimeFactor")) and r["realtimeFactor"] >= (8 if r["height"] == 1080 else 3) for r in runs), "export targets not met")
    for row in runs:
        name = row.get("file", "")
        require(name and pathlib.Path(name).name == name and (root / "hardware" / name).is_file(), "missing export artifact")
    c = cadence["cadence"]
    fields = ["samples", "elapsedSeconds", "sourceAdvanceSeconds", "presentedFPS", "expectedFPS", "p95Milliseconds", "p99Milliseconds", "worstMilliseconds", "lateFraction"]
    require(all(number(c.get(k)) for k in fields), "missing/nonfinite presentation measurement")
    require(c["samples"] >= 300 and c["elapsedSeconds"] >= 10 and c["expectedFPS"] >= 59, "insufficient 60 Hz playback evidence")
    require(abs(c["sourceAdvanceSeconds"] - c["elapsedSeconds"]) <= 0.3, "playback clock drift")
    require(0 <= c["lateFraction"] <= 0.01 and c["presentedFPS"] >= c["expectedFPS"] * 0.98, "presentation cadence missed")
    require(0 < c["p95Milliseconds"] <= c["p99Milliseconds"] <= c["worstMilliseconds"] and c["p99Milliseconds"] <= 2000 / c["expectedFPS"], "presentation interval budget missed")

if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3, "usage: verify-agent-autonomy.py proof-dir commit")
        validate(pathlib.Path(sys.argv[1]), sys.argv[2])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    print("PASS: local replay, export speed and presentation evidence. Not cinematic, forced-crash or unattended workflow certification.")
