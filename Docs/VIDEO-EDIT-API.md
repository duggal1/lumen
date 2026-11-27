# Lumen video-edit API (authoritative MCP contract)

This file is the normative contract for agent-driven editing. `Tests/LumenTests/MCPContractTests.swift`
parses the machine-readable blocks below and fails when they drift from the live registry built by
`registerAllTools()` in `Sources/LumenControl/Daemon.swift`. If code and prose disagree, the registry
wins and this file must be corrected in the same change.

Companion guide: `Docs/AGENT-MCP-EDITING.md` (authorization, workflow, error handling, verification).

---

## 1. Transport and protocol

MCP is JSON-RPC 2.0 over newline-delimited JSON. Two transports are supported: `lumen mcp` (stdio,
proxied to the daemon) and the private Unix socket at `~/.lumen/run/agent.sock` (0700 dir, 0600
socket). The daemon is the only process that opens the capture and edit seams; client-supplied names
are untrusted.

Negotiation: `initialize` returns the highest mutually supported protocol version.

<!-- M5:PROTOCOL:BEGIN -->
```text
protocolVersion=2025-11-25
supportedProtocolVersions=2025-03-26,2025-06-18,2025-11-25
methods=initialize,ping,tools/list,tools/call,resources/list,resources/read,prompts/list,prompts/get
```
<!-- M5:PROTOCOL:END -->

`tools/list` returns each spec with `name`, `title`, `description`, `annotations`
(`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`), `inputSchema`, and
`outputSchema` when one is declared. `tools/call` returns
`{ content: [{type:"text", text:<json>}...], isError: bool, structuredContent?: object }`.
`structuredContent` is present only when the call succeeded, produced no image blocks, and the tool
declares an `outputSchema`. Preview and screenshot pixels arrive as separate
`{type:"image", data:<base64>, mimeType}` content blocks, not as JSON text.

Resources: `lumen://schema/timeline`, `lumen://project/<id>/timeline`, `lumen://project/<id>/markers`.
Prompt: `make_demo_video` (arguments `app_bundle_id`, `brief`).

---

## 2. Capabilities and approval

Capabilities are per client and granted by a human. The default grant is `read` only; `actuate` and
`network` are never granted by default. A call needing an ungranted capability triggers a native
alert inside the signed Lumen app (Allow once / Always allow / Deny, 60 s timeout → Deny). Denial
returns `CAPABILITY_DENIED`. Headless clients must be pre-granted in `agent-policy.json` because a
daemon has no window to answer the prompt.

<!-- M5:CAPABILITIES:BEGIN -->
```text
read | yes | read your projects
record | no | record your screen
actuate | no | control other apps
edit | no | edit your projects
export | no | export videos
network | no | use the network
```
<!-- M5:CAPABILITIES:END -->

Two further allow-lists are enforced inside the tools, not by the capability gate:
an app **bundle allow-list** for every `actuate` tool and for `screen_look`, and a **path allow-list**
for every path argument (`PathGuard`; the Movies/Lumen library is always writable). macOS
permissions (Screen Recording, Input Monitoring, Accessibility, Microphone, Camera) are checked at
call time and reported with a System Settings deep link.

The `approval` column below is the set of capabilities that must already be granted for the call
(sorted alphabetically; `-` means read-only). `produce_demo` additionally requires `network` when
`narration` is `from_script`, because script narration makes a network call.

---

## 3. Complete tool catalog

Format of the machine-readable table (also parsed by the contract tests):

`name | capability | approval | required | mutating | idempotent | destructive | longRunning | customDryRun | outputSchema | additional`

`required` and `additional` are comma-separated and sorted; `-` means empty. `mutating` tools accept
`dry_run` (injected into the input schema). Only tools with `customDryRun` implement a tool-specific
dry-run result; all other mutating tools receive the generic envelope
`{dry_run:true, tool, would_run_with, note:"Nothing was changed."}`. `idempotent` is `true` for every
non-mutating tool and for the six mutating tools where repeating an identical call is the same edit:
`add_music`, `remove_music`, `reorder_clips`, `set_speed`, `set_zoom`, `trim_clip`. Every other
mutating tool is `false`.

**One catalog, 53 tools.** There is exactly one canonical verb per operation. The typed edit verbs
(`cut_span`, `split_clip`, `trim_clip`, `reorder_clips`, `set_speed`, `add_music`, `remove_music`,
`add_caption`, `set_zoom`, `get_edit`, `render_preview`, `export_final`) are the only editing
vocabulary. The older overlapping verbs they replaced (`cut_range`, `speed_ramp_set`, `zoom_add`,
`audio_import`, `timeline_get`, `preview_frame`, `preview_sheet`, `export_start`) are retired: the
registry does not expose them, and re-registering any of them is a contract failure. Registering a
tool without a row below, or documenting a row the registry does not expose, is also a contract
failure.

<!-- M5:CONTRACT:BEGIN -->
```text
add_caption | edit | edit | project_id,text | yes | no | no | no | yes | yes | -
add_music | edit | edit | path,project_id | yes | yes | no | no | yes | yes | -
audio_edit_v2 | edit | edit | ops,project_id,revision | yes | no | yes | no | yes | no | -
audio_mix_set | edit | edit | project_id | yes | no | no | no | no | no | -
background_list | read | - | - | no | yes | no | no | no | no | -
background_set | edit | edit | project_id | yes | no | no | no | no | no | -
captions_generate | edit | edit | project_id | yes | no | no | yes | no | no | -
captions_set | edit | edit | project_id | yes | no | no | no | no | no | -
clip_import | edit | edit | path,project_id | yes | no | no | no | no | no | -
crop_set | edit | edit | project_id | yes | yes | no | no | yes | yes | -
cursor_set | edit | edit | project_id | yes | yes | no | no | yes | yes | -
cut_span | edit | edit | end,project_id,start | yes | no | yes | no | yes | yes | -
edit_apply | edit | edit | ops,project_id | yes | no | yes | no | yes | yes | -
export_cancel | export | export | job_id | yes | no | yes | no | no | no | -
export_final | export | export | output,project_id | yes | no | no | yes | no | yes | -
export_presets | read | - | - | no | yes | no | no | no | no | -
get_edit | read | - | project_id | no | yes | no | no | no | yes | -
job_status | read | - | job_id | no | yes | no | no | no | yes | -
list_apps | read | - | - | no | yes | no | no | no | no | -
list_displays | read | - | - | no | yes | no | no | no | no | -
list_windows | read | - | - | no | yes | no | no | no | no | -
lumen_status | read | - | - | no | yes | no | no | no | yes | -
post_process | edit | edit | project_id | no | yes | no | no | no | yes | -
privacy_apply | edit | edit | project_id | yes | no | no | no | no | no | -
privacy_scan | edit | edit | project_id | yes | no | no | yes | no | no | -
produce_demo | actuate | actuate,edit,export,record | bundle_id,export,script | yes | no | yes | yes | no | no | edit,export,record
project_close | read | - | project_id | yes | no | no | no | no | no | -
project_list | read | - | - | no | yes | no | no | no | no | -
project_open | read | - | path | no | yes | no | no | no | no | -
qa_report | read | - | project_id | no | yes | no | no | no | yes | -
record_marker | record | record | id | yes | no | no | no | no | no | -
record_pause | record | record | - | yes | no | no | no | no | no | -
record_resume | record | record | - | yes | no | no | no | no | no | -
record_start | record | record | target | yes | no | no | no | no | no | -
record_stop | record | record | - | yes | no | no | no | no | no | -
remove_music | edit | edit | project_id | yes | yes | yes | no | yes | yes | -
render_preview | read | - | project_id | no | yes | no | no | no | yes | -
reorder_clips | edit | edit | project_id | yes | yes | no | no | yes | yes | -
run_script | actuate | actuate | bundle_id,script | yes | no | no | no | no | no | -
screen_look | actuate | actuate | - | no | yes | no | no | no | yes | -
set_speed | edit | edit | end,project_id,start | yes | yes | no | no | yes | yes | -
set_zoom | edit | edit | project_id | yes | yes | no | no | yes | yes | -
split_clip | edit | edit | at,project_id | yes | no | no | no | yes | yes | -
style_set | edit | edit | project_id | yes | no | no | no | no | no | -
timeline_patch | edit | edit | ops,project_id | yes | no | yes | no | yes | no | -
trim_clip | edit | edit | clip_id,project_id | yes | yes | no | no | yes | yes | -
ui_act | actuate | actuate | actions,bundle_id | yes | no | no | no | no | no | -
ui_snapshot | actuate | actuate | bundle_id | no | yes | no | no | no | no | -
ui_wait_for | actuate | actuate | bundle_id | no | yes | no | no | no | no | -
undo | edit | edit | project_id | yes | no | yes | no | no | no | -
voiceover_generate | network | edit,network | project_id,text | yes | no | no | no | no | no | edit
zoom_remove | edit | edit | id,project_id | yes | no | yes | no | no | no | -
zoom_replan | edit | edit | project_id | yes | no | no | no | no | no | -
```
<!-- M5:CONTRACT:END -->

---

## 4. Arguments and result shapes

All argument names use `snake_case`. Every property has a default, so partial JSON decodes; required
properties are still enforced by the registry before defaults are applied. `project_id` comes from
`record_stop`, `project_open` or `project_list`. Times are seconds; `basis` is `source` (raw
recording clock) or `output` (after cuts and ramps). Anchor edits and audio to **markers** wherever
possible: a second is a guess, a marker is a fact.

### 4.1 Status and discovery

| Tool | Arguments | Result (JSON text) |
|---|---|---|
| `lumen_status` | none | `phase`, `paused`, `recording`, `permissions{screen_recording,accessibility,input_monitoring,microphone,camera}`, `permission_links{...}`, `library`, `projects`, `active_project`, `version` |
| `list_apps` | none | `apps:[{bundle_id,name,pid,frontmost}]` |
| `list_windows` | `bundle_id?`, `include_offscreen?=false` | `windows:[{window_id,app,bundle_id,title,layer}]` |
| `list_displays` | none | `displays:[{display_id,name,x,y,width,height}]` |
| `screen_look` | `bundle_id?` (frontmost when omitted) | image block `image/jpeg` + `{bundle_id,width,height,bytes}`; needs `actuate` and a bundle grant |
| `background_list` | none | `backgrounds:[...]`, `gradients:[...]` |
| `export_presets` | none | `presets:[...]`, `default:"1080p30-h264"` |

### 4.2 Recording

| Tool | Arguments | Result |
|---|---|---|
| `record_start` | `target` (display\|window\|region), `display_id?=0`, `bundle_id?`, `window_id?=0`, `region_x/y/width/height?` (0...1 fractions), `fps?=60`, `microphone?=true`, `system_audio?=false`, `webcam?=false`, `privacy_auto_mask?=true` | `{recording:true,target,privacy_auto_mask}`. **Advertised** `fps` schema minimum is 15, but the runtime clamps to **24...120**; a request below 24 silently becomes 24. Region fractions must describe a nonempty rectangle inside the display or the call fails. |
| `record_pause` | none | `{paused:true}`; the paused span is removed from the output |
| `record_resume` | none | `{paused:false}` |
| `record_marker` | `id` (unique per recording), `label?` | `{marker_id,host_seconds}` |
| `record_stop` | none | `{project_id,path,privacy_scan_job?}`; the project is opened and an automatic privacy scan starts when the recording was auto-masked |

### 4.3 Projects and timeline

| Tool | Arguments | Result |
|---|---|---|
| `project_list` | none | `projects:[{project_id,path,complete,unfinished}]` |
| `project_open` | `path` (inside an approved folder) | `{project_id,path}` |
| `project_close` | `project_id` | `{project_id,closed}` (read capability, but mutating: releases cached media) |
| `get_edit` | `project_id` | output schema: `revision`, `duration`, `composition_duration`, `output_duration`, `time_basis`, `zoom[]`, `cuts[]`, `ramps[]`, `clips[]`, `style`, `cursor`, `audio`, `captions`, `privacy` |
| `clip_import` | `project_id`, `path` (video), `at?` (output seconds; append when omitted) | engine edit result |
| `cut_span` | `project_id`, `start`, `end`, `basis?="output"` | engine edit result; destructive. Closed source/output span, merged with any overlapping cut. |
| `split_clip` | `project_id`, `at` (output seconds) | engine edit result; partitions the clip at the playhead without changing duration |
| `trim_clip` | `project_id`, `clip_id`, `start?`, `end?`, `duration?` | engine edit result; moves only the named edges, idempotent |
| `reorder_clips` | `project_id`, `ordered_ids?` or `clip_id` + `to_index` | engine edit result; magnetic order survives the rebuild, idempotent |
| `set_speed` | `project_id`, `start`, `end`, `speed?=2` (0.25...16), `basis?` | engine edit result; rejected when the ramp runs backwards, overlaps another ramp or has a non-finite speed, idempotent |
| `set_zoom` | `project_id`, `start`, `end`, `scale?=2` (1.1...4), `focus_mode?=follow` (follow\|fixed\|element), `focus_x/y?=0.5`, `basis?` | engine edit result; manual zooms survive auto replan, idempotent |
| `zoom_remove` | `project_id`, `id` (zoom UUID) | engine edit result; suppresses the auto planner for that zoom; destructive |
| `zoom_replan` | `project_id` | engine edit result; keeps manual zooms |
| `style_set` | `project_id`, optional `padding` (0...0.2), `corner_radius` (0...80), `shadow` (0...1), `aspect` (>0.2,<5), `wallpaper_blur` (0...60), `background`, `background_image_path` | engine edit result |
| `crop_set` | `project_id`, optional `enabled`, `uncrop` (chromeTyping\|anyTyping\|never), `inset_px` (0...40), `hold_after_typing`/`hold_after_ui_click`/`min_dwell` (0...10) | engine edit result; browser auto-crop tuning, idempotent |
| `cursor_set` | `project_id`, optional `pack` (a `CursorPack.rawValue`), `size` (0.25...4), `smoothing_sigma` (0...0.5), `glide` (0...2), `constant_size`, `click_effect` (none\|ripple\|pulse\|burst\|glass) | engine edit result; cursor artwork and click effect, idempotent |
| `background_set` | `project_id`, `background?` or `image_path?` (at least one) | engine edit result |
| `captions_generate` | `project_id`, `locale?="en-US"`, `wait?=false` | `{job_id}` or the completed job result when `wait` |
| `captions_set` | `project_id`, `enabled?=true`, `locale?` | engine edit result |
| `privacy_scan` | `project_id`, `wait?=false` | `{job_id}` or completed job result; `export_final` refuses while a scan is unresolved |
| `privacy_apply` | `project_id`, `decisions:{maskUUID: bool}` (approve keeps, reject removes) | engine edit result |
| `undo` | `project_id` | engine undo result; destructive |
| `timeline_patch` | `project_id`, `ops:[PatchOp]`, `revision?` (compare-and-swap; omit to skip) | `{project_id,revision,dry_run?,diff:[{field,before,after}],warnings:[...]}`; destructive, custom dry run. See §5. |
| `edit_apply` | same as `timeline_patch` | same edit result; destructive, custom dry run. **Declared output schema** (unlike `timeline_patch`), so only `edit_apply` gets `structuredContent`. |

### 4.4 Audio

| Tool | Arguments | Result |
|---|---|---|
| `add_music` | `project_id`, `path` (mp3/wav/m4a/aac/flac/aiff/caf), `at` (output seconds, default 0), `gain_db?=0`, `duration?` | engine edit result; idempotent, so re-adding the same bed at the same place does not stack it |
| `remove_music` | `project_id`, `id?` or `path?` (the bed to remove; every bed when both are omitted) | engine edit result; idempotent |
| `audio_mix_set` | `project_id`, optional `target_lufs` (-24...-10), `music_gain_db`/`mic_gain_db`/`output_gain_db` (-60...12), `duck_depth_db` (0...36), `normalize` | engine edit result |
| `voiceover_generate` | `project_id`, `text`, `voice?`, `model?`, `at_marker?`, `at_output?`, `offset_ms?=0`, `gain_db?=0` | engine edit result + `network` (disclosure string) + `audio_path`. Requires `network` and `edit`. |

### 4.5 Verification, export and jobs

| Tool | Arguments | Result |
|---|---|---|
| `render_preview` | `project_id`, `time?=0`, `frames?=1` (1...12), `duration?`, `max_width?=960` (160...1920), `png?=false` | image block (JPEG default, PNG when requested) + `{name,time,width,height,bytes}`; `frames>1` returns a contact sheet `{frames,width,height,bytes}` |
| `qa_report` | `project_id` | output schema: `project_id`, `checks:[{name,ok,detail}]`, `zoom_accuracy` |
| `post_process` | `project_id`, optional `revision`, `include_qa?=true` | output schema: `project_id`, `revision`, `duration`, `canvas`, `checks`, `post_processed`; read-only derived-state finalization. Returns `REVISION_CONFLICT` when `revision` is stale. |
| `export_final` | `project_id`, `output` (required), `preset?="1080p30-h264"`, `include_audio?=true`, `export_stems?=false`, `overwrite?=false`, `wait?=true` | `{job_id,output}`; with `wait`, the completed job result plus `output`. An existing output fails with `EXPORT_OUTPUT_EXISTS` unless `overwrite=true`; overwriting is destructive and approval-gated. |
| `job_status` | `job_id`, `wait_ms?=0` (0...25000) | output schema: `job_id`, `kind`, `state` (queued\|running\|done\|failed\|cancelled), `progress` (0...1), `message`, `result`, `error` |
| `export_cancel` | `job_id` | `{job_id,cancelled}`; destructive |

### 4.6 UI actuation and one-shot workflow

| Tool | Arguments | Result |
|---|---|---|
| `ui_snapshot` | `bundle_id`, `max_depth?=6` (1...12) | `{tree: AXNode}`; secure fields redacted; every node has `ref` and icon-only nodes have `description` |
| `ui_act` | `bundle_id`, `actions:[Action]` | `{markers:[{id,label,host_start,host_end}]}`; needs Accessibility |
| `ui_wait_for` | `bundle_id`, `role?`, `title?`, `identifier?`, `timeout_s?=8` | `{found:bool}` |
| `run_script` | `bundle_id`, `script:{version?,app?,steps:[{id,say?,do:[Action],pad_after_s?}]}`, `mode?=physical` (physical\|virtual) | `{markers:[...]}`; one marker per step, the anchor for edits and audio |
| `produce_demo` | `bundle_id`, `script`, `export:{preset?,output}`, `background?`, `music?`, `narration?=none` (none\|from_script), `mode?=virtual`, `wait?=false` | `{job_id,state:"queued"}`; with `wait`, the job result `{project_id,output,qa,markers}`. Composite: needs actuate + record + edit + export (and network for `from_script`). |

`Action.op` is one of `launch`, `wait_for`, `click`, `drag`, `type`, `paste`, `key`, `sleep`, `move`,
`scroll`, `screenshot`. Coordinates are fractions 0...1 of the target; `key` accepts
`return/tab/space/delete/escape/left/right/up/down` with `modifiers:[cmd,ctrl,opt,shift]`.

---

## 5. Timeline patch operations

`timeline_patch` and `edit_apply` share one input schema. The authoritative `op` set is the schema
enum (20 values). The `timeline_patch` description text in the source advertises only 13 of them;
this document is authoritative. Each op is validated by the editor command reducer, not by field
sentinels.

<!-- M5:PATCH-OPS:BEGIN -->
```text
zoom_add
zoom_set
zoom_remove
cut_add
cut_remove
ramp_set
ramp_remove
style_set
audio_lane_add
audio_lane_remove
music_set
captions_set
privacy_set
split_clip
split_recording
delete_clip
duplicate_clip
join_clips
add_clip
paste_clip
```
<!-- M5:PATCH-OPS:END -->

---

## 6. Errors

Machine-readable failures are `{error:{code,hint,deep_link?}}` in the text content with
`isError:true`. `UNKNOWN_TOOL` and `INVALID_ARGUMENTS` are JSON-RPC `-32602`; unknown methods are
`-32601`; parse errors are `-32700`; resource read failures are `-32000`. Every failure says what
to do next; every destructive operation has an undo path.

<!-- M5:ERROR-CODES:BEGIN -->
```text
UNKNOWN_TOOL | call tools/list for the catalog
INVALID_ARGUMENTS | fix the named argument and retry
REVISION_CONFLICT | get_edit again, re-apply the edit
NOT_RECORDING | call record_start first
PERMISSION_SCREEN RECORDING | open the System Settings deep link, then retry
CAPABILITY_DENIED | ask the human to grant the capability in Lumen > Settings > Agents
PATH_NOT_ALLOWED | grant the folder first
FAILED | read the hint, correct the cause, retry
PARSE_ERROR | -32700
INVALID_PARAMS | -32602
METHOD_NOT_FOUND | -32601
INTERNAL_ERROR | -32000
```
<!-- M5:ERROR-CODES:END -->

Additional ad-hoc codes encountered in the wild: `BUNDLE_NOT_ALLOWED`, `WINDOW_NOT_FOUND`,
`EXPORT_OUTPUT_EXISTS`, `PRIVACY_SCAN_REQUIRED`, `PRIVACY_SCAN_RUNNING`, `PRIVACY_SCAN_PENDING`,
`PRIVACY_SCAN_FAILED`, `PROJECT_UNFINISHED`, `PROJECT_NOT_FOUND`, `RECORDING_ACTIVE`,
`APP_NOT_FOUND`, `APP_LAUNCH_FAILED`, `TARGET_WINDOW_NOT_FOUND`, `QA_FAILED`, `DAEMON_UNREACHABLE`,
`DAEMON_NOT_FOUND`, `DAEMON_NOT_RUNNING`.

---

## 7. Worked sequence: cut a sentence → add music → export

Each line is `step | tool | purpose`. The contract test checks that every tool exists and that the
order constraints hold (preflight first, cut before music, music before export, QA before export,
export before job polling).

<!-- M5:SEQUENCE:BEGIN -->
```text
1 | lumen_status | read-only preflight: permissions and library
2 | record_start | record grant; window target with privacy_auto_mask on
3 | run_script | actuate grant; step ids are markers at sentence boundaries
4 | record_stop | returns project_id, opens the project, starts privacy scan
5 | captions_generate | transcribe with wait=true; read the result and markers
6 | get_edit | read revision, cuts, captions and marker clock
7 | cut_span | destructive edit: cut the sentence span in source seconds
8 | add_music | add music anchored to a marker; `remove_music` drops it after export
9 | audio_mix_set | duck music under voice, normalize loudness
10 | render_preview | read: look at the edited frames
11 | qa_report | read: fail if any check is not ok, then fix
12 | export_final | export grant; returns job_id
13 | job_status | poll to done; retry or recover on failure
14 | project_close | release the session
```
<!-- M5:SEQUENCE:END -->

Marker and time semantics: `run_script` (or `record_marker`) writes a marker per beat; the marker
resource `lumen://project/<id>/markers` reveals its host time. `cut_span` takes numeric output
seconds; `get_edit` reads the current time basis back so the span lands on the marked sentence.
`timeline_patch` `cut_add` is the batch equivalent. `add_music` anchors by `at` (output seconds) —
reading the marker time from `get_edit` first, because a marker host time is a different clock.

## Revisioned audio editing (v2)
Read `get_edit.audio_lanes` and `revision`. `audio_edit_v2` takes an ordered batch of up to 64 add/update/split/remove operations. Source trims are in asset seconds; placement and split are in output seconds. New finite clips default to non-looping, with stable client-supplied UUIDs; legacy beds keep looping. The server probes audio assets before adding. The same batch validator is used for dry run. Trim updates may shrink the selected source excerpt; full asset relinking and durable retry receipts are future work. See `lumen://skills/audio-edit`.
