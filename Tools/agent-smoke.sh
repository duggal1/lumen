#!/usr/bin/env bash
# One end-to-end smoke test: an agent drives Lumen over MCP, from a blank
# session to an exported, QA'd video. No Lumen window, no human in the loop.
#
#   Tools/agent-smoke.sh [app-path]
#
# It speaks MCP over stdio to `lumen-cli mcp`, which proxies to the daemon.
set -uo pipefail

cd "$(dirname "$0")/.."
APP="${1:-$PWD/.build/Lumen.app}"
CLI="$APP/Contents/MacOS/lumen-cli"
[ -x "$CLI" ] || { echo "missing $CLI — run 'make app' first"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export LUMEN_SMOKE_DIR="$WORK"

echo "== lumen agent smoke =="

# The human approves actuation for this run: the actuate capability and the
# app allow-list are denied until somebody grants them.
"$CLI" agent grant --capability actuate --bundle-id com.apple.calculator --path "$WORK" >/dev/null

python3 - "$CLI" "$WORK" <<'PY'
import json, subprocess, sys, time, os, wave, struct, math

cli, work = sys.argv[1], sys.argv[2]

args = [cli, "mcp"]
if os.environ.get("LUMEN_SMOKE_NO_LAUNCH") == "1":
    args.append("--no-launch")
proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=None, text=True, bufsize=1)
_id = [0]

def call(method, params=None, timeout=300):
    _id[0] += 1
    msg = {"jsonrpc": "2.0", "id": _id[0], "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("daemon closed the connection")
        try:
            reply = json.loads(line)
        except json.JSONDecodeError:
            continue
        if reply.get("id") == _id[0]:
            return reply
    raise SystemExit("timeout waiting for " + method)

def tool(name, args=None, timeout=300):
    reply = call("tools/call", {"name": name, "arguments": args or {}}, timeout)
    result = reply.get("result", {})
    content = result.get("content", [{}])
    text = content[0].get("text", "{}") if content else "{}"
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = {"raw": text}
    if result.get("isError"):
        raise SystemExit(f"{name} failed: {text}")
    return payload

def wait_job(job_id, timeout=600):
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = tool("job_status", {"job_id": job_id})
        if job["state"] in ("done", "failed", "cancelled"):
            return job
        time.sleep(1.0)
    raise SystemExit("job timed out: " + job_id)

failures = []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ((" — " + detail) if detail else ""))
    if not ok:
        failures.append(name)

# 1. initialize (this is how the daemon learns which client it is talking to)
call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "stdio"}})
status = tool("lumen_status")
print("status:", json.dumps(status))
check("status returns permissions", "permissions" in status)
check("screen recording granted", bool(status["permissions"]["screen_recording"]),
      "grant it in System Settings > Privacy & Security > Screen Recording")

# 2. launch TextEdit and find its window
tool("ui_act", {"bundle_id": "com.apple.calculator", "actions": [{"op": "launch"}]})
window = None
for _ in range(20):
    time.sleep(0.5)
    windows = tool("list_windows", {"bundle_id": "com.apple.calculator"})
    rows = windows.get("windows") or []
    if rows:
        window = rows[0]
        break
print("windows:", json.dumps(windows)[:400])
check("found the Calculator window", window is not None)

# 3. record it
tool("record_start", {"target": "window", "bundle_id": "com.apple.calculator",
                      "fps": 30, "microphone": False, "privacy_auto_mask": True})
print("recording started")

# 4. drive it: type a line, so the video has something in it
try:
    tool("run_script", {"mode": "virtual", "bundle_id": "com.apple.calculator", "script": {
        "version": 1,
        "app": {"bundle_id": "com.apple.calculator"},
        "steps": [
            {"id": "type", "say": "Lumen records this.",
             "do": [{"op": "type", "text": "Lumen records this.", "cps": 12}],
             "pad_after_s": 0.4}
        ]}})
    check("run_script produced a marker", True)
except SystemExit as failure:
    check("run_script produced a marker", False, str(failure))

time.sleep(1)

# 5. stop
stopped = tool("record_stop")
project_id = stopped["project_id"]
print("project:", project_id)
check("stop returned a project", bool(project_id))

# 6. import a short wav
wav_path = os.path.join(work, "tone.wav")
with wave.open(wav_path, "w") as w:
    # Stereo, 48 kHz: the mixer reads music as a stereo pair.
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    # Two seconds: the mixer ignores music shorter than one second.
    frames = b"".join(struct.pack("<hh", int(6000 * math.sin(i * 0.02)), int(6000 * math.sin(i * 0.02)))
                    for i in range(96000))
    w.writeframes(frames)
try:
    tool("audio_import", {"project_id": project_id, "path": wav_path, "role": "music",
                          "at_output": 0.0, "gain_db": -20})
    check("audio_import accepted the clip", True)
except SystemExit as failure:
    check("audio_import accepted the clip", False, str(failure))

# 7. replan the zooms
try:
    tool("zoom_replan", {"project_id": project_id})
    check("zoom_replan ran", True)
except SystemExit as failure:
    check("zoom_replan ran", False, str(failure))

# 8. render a frame
try:
    frame = tool("preview_frame", {"project_id": project_id, "time": 0.5, "max_width": 480})
    check("preview_frame returned a PNG", bool(frame.get("image_base64")))
except SystemExit as failure:
    check("preview_frame returned a PNG", False, str(failure))

# 9. export
output = os.path.join(work, "smoke.mp4")
try:
    job = tool("export_start", {"project_id": project_id, "preset": "1080p30-h264", "output": output})
    final = wait_job(job["job_id"])
    check("export finished", final["state"] == "done", json.dumps(final)[:300])
    check("export wrote a file", os.path.exists(output) and os.path.getsize(output) > 0)
except SystemExit as failure:
    check("export finished", False, str(failure))

# 10. qa report
try:
    report = tool("qa_report", {"project_id": project_id})
    print("qa_report:", json.dumps(report, indent=2)[:1500])
    check("qa_report returned checks", bool(report.get("checks")))
except SystemExit as failure:
    check("qa_report returned checks", False, str(failure))

# Leave the machine as we found it: actuation is revoked again.
proc.stdin.close()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()

import subprocess as _sp
_sp.run([cli, "agent", "revoke", "--capability", "actuate"], capture_output=True)

print()
if failures:
    print("FAILED: " + ", ".join(failures))
    raise SystemExit(1)
print("All smoke checks passed.")
PY
status=$?
exit $status
