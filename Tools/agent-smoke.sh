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
CLI="$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")"
TARGET_BUNDLE="com.apple.TextEdit"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export LUMEN_SMOKE_DIR="$WORK"

echo "== lumen agent smoke =="

# AGENT: kernel peer identity replaces spoofable initialize names, so grant the CLI's signing id or executable path.
CLIENT_ID="$(/usr/bin/codesign -dv --verbose=4 "$CLI" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')"
[ -n "$CLIENT_ID" ] || CLIENT_ID="$CLI"
# AGENT: the final reset is scoped to this identity, so refuse to erase grants that existed before the smoke run.
PRIOR_GRANTS="$("$CLI" agent status --client "$CLIENT_ID")"
if printf '%s\n' "$PRIOR_GRANTS" | /usr/bin/grep -Eq 'granted (actuate|record|edit|export|network)'; then
    echo "refusing to replace existing grants for $CLIENT_ID" >&2
    exit 1
fi
if printf '%s\n' "$PRIOR_GRANTS" | /usr/bin/grep -Fq 'bundle ids: ' \
    && ! printf '%s\n' "$PRIOR_GRANTS" | /usr/bin/grep -Fq 'bundle ids: (none)'; then
    echo "refusing to replace existing app approvals for $CLIENT_ID" >&2
    exit 1
fi
if printf '%s\n' "$PRIOR_GRANTS" | /usr/bin/grep -Fq 'folders: ' \
    && ! printf '%s\n' "$PRIOR_GRANTS" | /usr/bin/grep -Fq 'folders: (library only)'; then
    echo "refusing to replace existing folder approvals for $CLIENT_ID" >&2
    exit 1
fi
for capability in actuate record edit export; do
    "$CLI" agent grant --client "$CLIENT_ID" --capability "$capability" \
        --bundle-id "$TARGET_BUNDLE" --path "$WORK" >/dev/null
done

python3 - "$CLI" "$WORK" "$CLIENT_ID" <<'PY'
import json, subprocess, sys, time, os, wave, struct, math

cli, work, client_id = sys.argv[1], sys.argv[2], sys.argv[3]

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

def tool_reply(name, args=None, timeout=300):
    return call("tools/call", {"name": name, "arguments": args or {}}, timeout)

def tool(name, args=None, timeout=300):
    reply = tool_reply(name, args, timeout)
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

# 1. initialize with an untrusted display name; policy uses the kernel peer instead.
call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "smoke"}})
status = tool("lumen_status")
print("status:", json.dumps(status))
check("status returns permissions", "permissions" in status)
check("screen recording granted", bool(status["permissions"]["screen_recording"]),
      "grant it in System Settings > Privacy & Security > Screen Recording")

# 2. launch TextEdit and find its window
tool("ui_act", {"bundle_id": TARGET_BUNDLE, "actions": [{"op": "launch"}]})
window = None
for _ in range(20):
    time.sleep(0.5)
    windows = tool("list_windows", {"bundle_id": TARGET_BUNDLE})
    rows = windows.get("windows") or []
    if rows:
        window = rows[0]
        break
print("windows:", json.dumps(windows)[:400])
check("found the TextEdit window", window is not None)

# 3. record it
tool("record_start", {"target": "window", "bundle_id": TARGET_BUNDLE,
                      "fps": 30, "microphone": False, "privacy_auto_mask": True})
print("recording started")

# 4. drive it: type a line, so the video has something in it
try:
    tool("run_script", {"mode": "virtual", "bundle_id": TARGET_BUNDLE, "script": {
        "version": 1,
        "app": {"bundle_id": TARGET_BUNDLE},
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
if stopped.get("privacy_scan_job"):
    scan = wait_job(stopped["privacy_scan_job"])
    check("privacy scan finished", scan["state"] == "done", json.dumps(scan)[:300])

# AGENT: cover the empty-target, path-confinement, dry-run, and image-block guarantees.
empty_target = tool_reply("ui_act", {"bundle_id": "", "actions": []})
check("empty bundle_id is rejected", bool(empty_target.get("result", {}).get("isError")))

outside_path = os.path.join(os.path.expanduser("~"), "Documents", "lumen-smoke-outside.jpg")
outside_path_reply = tool_reply("style_set", {"project_id": project_id,
    "background_image_path": outside_path})
check("style_set rejects paths outside approved folders",
      bool(outside_path_reply.get("result", {}).get("isError")))

before_dry_run = tool("timeline_get", {"project_id": project_id})
dry_run = tool("style_set", {"project_id": project_id, "padding": 0.123, "dry_run": True})
after_dry_run = tool("timeline_get", {"project_id": project_id})
check("dry_run leaves revision unchanged",
      dry_run.get("dry_run") is True and before_dry_run.get("revision") == after_dry_run.get("revision"))

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
    frame_reply = tool_reply("preview_frame", {"project_id": project_id, "time": 0.5, "max_width": 480})
    blocks = frame_reply.get("result", {}).get("content", [])
    check("preview_frame returned an image content block",
          any(block.get("type") == "image" for block in blocks))
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
_sp.run([cli, "agent", "reset", "--client", client_id], capture_output=True)

print()
if failures:
    print("FAILED: " + ", ".join(failures))
    raise SystemExit(1)
print("All smoke checks passed.")
PY
status=$?
exit $status
