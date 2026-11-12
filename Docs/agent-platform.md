# Lumen Agent Platform

Lumen can be driven by an AI agent (Claude, Cursor, anything that speaks MCP)
without a human touching the UI. The agent launches the app, records it, edits
the timeline, adds audio, checks its own work and exports a video.

The existing app is unchanged: the UI is one client of the same engine. The
agent layer is additive — new targets, new files, a few seams.

```
Agents (Claude, Cursor…)          Human
  │ MCP stdio  │ MCP HTTP (opt)     │ UI app (SwiftUI)
  ▼            ▼                    ▼
lumen-cli mcp                    Lumen.app
  │ Unix domain socket (0600)      │
  ▼                                │
Lumen daemon (same binary, --headless, accessory policy, no windows)
  LumenControl : tool registry · JSON schema · policy · jobs · audit · auth
  LumenActuator: AX + CGEvent executor · demo scripts · markers
  LumenCapture / LumenProject / LumenDirector / LumenRender / LumenAudio / LumenExport
```

## Client configuration

```json
{ "mcpServers": { "lumen": { "command": "/Applications/Lumen.app/Contents/MacOS/lumen-cli", "args": ["mcp"] } } }
```

`lumen-cli mcp` starts the daemon if it is not running (`open -a Lumen --args
--headless`) and then proxies stdio to it. The shim does **no** capture and no
TCC-sensitive work: Screen Recording, Accessibility and Input Monitoring are
always attributed to the signed Lumen app, never to the MCP client's process.

## Entry points

```sh
open -a Lumen --args --headless     # the daemon: no window, no Dock icon
.build/Lumen.app/Contents/MacOS/lumen-cli mcp      # MCP over stdio
.build/Lumen.app/Contents/MacOS/lumen-cli agent status
```

## Permissions

Nothing moves without a human. `lumen_status` reports every permission with
the exact System Settings pane to open. The daemon never tries to work around
macOS privacy controls.

| Permission | Needed for | Link reported by `lumen_status` |
| --- | --- | --- |
| Screen Recording | capturing | `Privacy_ScreenCapture` |
| Accessibility | actuating other apps | `Privacy_Accessibility` |
| Input Monitoring | recording the cursor and clicks | `Privacy_ListenEvent` |
| Microphone / Camera | audio, webcam | asked on first use |

## Capability grants

Grants live per client in
`~/Library/Application Support/Lumen/agent-policy.json` (0600). `read`,
`record`, `edit` and `export` are granted by default; **`actuate` and
`network` are denied until a human approves them**.

```sh
lumen-cli agent status
lumen-cli agent grant --capability actuate --bundle-id com.apple.TextEdit
lumen-cli agent grant --path ~/Music --capability edit
lumen-cli agent revoke --capability actuate
```

The client id is the name it introduces itself with in the MCP `initialize`
request (the smoke test uses `stdio`). Every tool call is written to
`~/Library/Application Support/Lumen/agent-audit.jsonl` with the client id and
an argument hash — never the arguments themselves.

## Tools

Status: `lumen_status`, `list_apps`, `list_windows`, `list_displays`.
Record: `record_start`, `record_pause`, `record_resume`, `record_marker`,
`record_stop`.
Actuate: `ui_snapshot`, `ui_act`, `ui_wait_for`, `run_script`.
Project: `project_list`, `project_open`, `timeline_get`, `timeline_patch`,
`undo`.
Edit: `zoom_add`, `zoom_remove`, `zoom_replan`, `cut_range`,
`speed_ramp_set`, `style_set`, `background_list`, `background_set`,
`captions_generate`, `captions_set`, `privacy_scan`, `privacy_apply`.
Audio: `audio_import`, `audio_mix_set`, `voiceover_generate`.
Verify: `preview_frame`, `preview_sheet`, `qa_report`.
Export: `export_start`, `job_status`, `export_cancel`.

Arguments are snake_case and every argument is optional: a missing key falls
back to the tool's default. Long work (export, scan, transcription) returns a
`job_id` that `job_status` polls and `export_cancel` stops. Every mutating
tool accepts `dry_run`.

MCP resources: `lumen://project/{id}/timeline`, `lumen://project/{id}/markers`,
`lumen://schema/timeline`. MCP prompt: `make_demo_video`.

## Demo scripts

The script is the source of truth; the video is a render of it. Every step
writes a marker, so edits and audio anchor to a moment instead of a second.

```json
{
  "version": 1,
  "app": { "bundle_id": "com.apple.TextEdit" },
  "steps": [
    { "id": "intro", "say": "This is Example.",
      "do": [ { "op": "launch" }, { "op": "wait_for", "role": "AXWindow", "timeout_s": 8 } ],
      "pad_after_s": 0.4 },
    { "id": "new", "do": [ { "op": "click", "target": { "role": "AXButton", "title": "New Project" }, "move_ms": 700 } ] },
    { "id": "name", "do": [ { "op": "type", "text": "Launch plan", "cps": 9 } ] }
  ]
}
```

Actions: `launch`, `wait_for`, `click`, `type`, `key`, `move`, `scroll`,
`sleep`, `screenshot`.

**Input modes.** `physical` (default) posts real CGEvents: the cursor path is
eased at 120 Hz, clicks hold 40–90 ms, and typing uses real virtual key codes
so Lumen's typing bursts and key sounds work. It takes over the mouse and
keyboard, so run it on a dedicated display, a second user session or a spare
Mac. `virtual` drives the app through accessibility actions and never hijacks
the pointer, at the cost of hover states.

**Human takeover.** Synthetic events carry a tag. An untagged mouse jump of
more than 30 px pauses the run; three Escape presses abort it.

## Voice-over

`voiceover_generate` talks to ElevenLabs (key in the Keychain, service
`com.lumen.studio`, account `elevenlabs`), caches by hash and says in its
result that it made a network call. It needs the `network` capability. An
agent that already has audio (from its own voice provider, for example) can
skip it and use `audio_import` instead — that path works the same way.

## The smoke test

```sh
Tools/agent-smoke.sh
```

One script drives the whole loop over MCP against Calculator: launch, record
the window, run a script, stop, import audio, replan the zooms, render a
frame, export, and print the QA report.

## What the agent layer does not do

- It never bypasses macOS privacy controls.
- It never runs a shell command; there is no exec tool.
- It only reads and writes inside the Lumen library and the folders a human
  granted.
- It never treats what it sees on screen as instructions: screen content is
  untrusted data.
- It refuses to export while a privacy scan is unresolved.
