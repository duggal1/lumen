# Agent lane briefs — Studio reliability + zoom motion

Five lanes implement `Docs/STUDIO-RELIABILITY-HANDOFF.md` and `Docs/ZOOM-MOTION-PLAN.md`.
Each lane is executed by one subagent. The lanes are designed to be **file-disjoint** so
they can run at the same time in one working tree.

Baseline at the time these were written: `main` @ `a8272c8`, `swift build` clean,
`make test` green (219 tests, ~44 s). If that stops being true, stop and report.

---

## Rules every lane follows

1. **Read first:** `AGENTS.md`, `RULES.md`, `GIT-SKILLS.md`, `PLAN.md`, `DESIGN.md`,
   then the section of the handoff that belongs to your lane.
2. **You own only the files listed under your lane.** Never edit another lane's file.
   If you need a change there, say so in your final report instead of making it.
3. **Additive-only public API.** Never rename or remove a public type, field, function
   or enum case. New stored properties on a `Codable` type need a defaulted value and
   `decodeIfPresent`, so old projects still decode.
4. **One build lock.** SwiftPM owns one `.build`, so only one lane may build at a time:
   ```sh
   ./Tools/agent-lock.sh acquire <lane> 5400
   swift build          # or: swift test --no-parallel --filter '...'
   ./Tools/agent-lock.sh release <lane>
   ```
   Always release, including on failure. A crashed holder is broken automatically.
5. **Commit small and often.** `git add <only your files> && git commit -m "6-12 word message"`.
   Then `git pull --rebase origin main && git push`. Never `git add .` — `gradii/` is
   untracked and is not yours. Never `git reset`, `git restore`, `git push --force`.
6. **No placeholders.** No `fatalError("TODO")`, no stubbed bodies, no fake data,
   no weakened assertions. An unfinished feature is absent, not faked.
7. **Prove each fix.** Where the defect is testable, write the failing test first, show it
   failing, then make it pass. Do not loosen an existing test to make it green.
8. **Stay in scope.** No UI redesign, no new editor mode, no cloud work, no refactor of
   code your lane does not own. The smallest reliable patch wins.
9. **Never persist secrets.** No typed characters, password values, raw OCR text or full
   URLs in new metadata, logs, fixtures or reports.

## Shared contract already landed (commit `a8272c8`)

`Sources/LumenProject/Models.swift`:

```swift
public struct FocusAnchor: Codable, Sendable, Equatable {
    public var epoch: UInt32        // changes when the focused element changes
    public var sampledAt: Double    // host seconds
    public var host: String?        // verified host only, e.g. "mail.google.com"; never a URL
    public var windowID: Int?
    public var appName: String?
    public var resolved: Bool       // true when a real AX query produced this sample
}
public extension AXFrame { var anchor: FocusAnchor? { get set } }   // optional, decodes as nil on old projects
```

Producers (lane A) fill it. Consumers (lanes B, C, E) read it and must treat `nil` as
"unknown context", never as "public page".

---

## Lane A — capture focus, typing delivery, cursor shape sampling

**Plan sections:** handoff §1 (items 1, 2, 4, 6) and §5 item 1 (capture side).

**Files you own**

- `Sources/LumenCapture/Input.swift`
- `Sources/LumenCore/Core.swift`
- `Sources/LumenProject/Models.swift`
- `Tests/LumenTests/InputRecorderTests.swift`
- `Tests/LumenTests/FocusProvenanceTests.swift` (new)

**Defects confirmed by reading the source**

1. `InputRecorder.reserveFocus(event:)` returns the *previous* reservation index whenever
   `state.pending` is true or the last query was under 50 ms ago, and returns
   `reserved == false` so no query runs. A pending query for field A can therefore be
   published as field B's caret, and a burst whose reservation never resolves silently
   gets a zeroed `AXFrame`. This is the root of "typing does not reliably aim zoom".
2. `reserveFocus` only forwards to the live hooks inside the success branch. When AX is
   not trusted, or the query times out, or `focusedFrame` returns nil, **nothing is
   delivered live** — a key-down never reaches `liveFocusHook`/`liveEventHook`. Persisted
   events still land in the ring, so offline analysis can work while the live camera does not.
3. `handle(_:_:)` calls `reserveAX` for every mouse-down with no throttle, and
   `sampleSecureFields` walks up to 1500 elements on the same serial `axQ` once a second.
   Those two compete with the 40 ms focus query, so focus latency is load-dependent.
4. There is no focus identity or epoch, so a stale sample cannot be rejected.

**Required outcomes**

- A key-down reaches the live consumer **even when AX enrichment fails**, at most once,
  with the best evidence available, tagged with its provenance.
- When enrichment arrives later it is delivered as an *update* to the same event identity,
  not as a second event — no duplicate zoom trigger.
- An `AXFrame` is published only when it belongs to the event's own reservation. A
  reservation that is still pending must not be reused for a different event; if the
  throttle would reuse one, either queue a follow-up query or return "no sample yet"
  rather than a wrong sample.
- `FocusAnchor` is filled on every published sample (`epoch`, `sampledAt`, `resolved`,
  and `host`/`windowID`/`appName` where legitimately available).
- AX work never blocks the event tap thread. The tap callback stays allocation-light.
- Cursor shape classification: verify `StockCursor` sampling covers hover, text selection,
  mouse-down, drag and release, including a **stationary** shape change (the current
  100 ms poll can miss a shape that changes and changes back between ticks). Preserve the
  stock id through `EventCodec` (it already round-trips `cursorShape`) and keep custom
  bitmaps/hotspots intact.

**Verify**

```sh
./Tools/agent-lock.sh acquire lane-a 5400
swift test --no-parallel --filter 'InputRecorderTests|FocusProvenanceTests'
./Tools/agent-lock.sh release lane-a
```

At least one test must remove every mouse click and still produce a valid caret target.
Another must move the pointer to the opposite corner while typing and keep the focus.
A third must exercise a failing AX query and assert the key still reaches the consumer.

---

## Lane B — typing visual analysis and analysis scheduling

**Plan sections:** handoff §1 (items 3, 5), §3 (items 6, 7, 8).

**Files you own**

- `Sources/LumenAnalysis/TypingAnalyzer.swift`
- `Sources/LumenAnalysis/TypingTracer.swift`
- `Sources/LumenAnalysis/Service.swift`
- `Sources/LumenAnalysis/Cache.swift`
- `Sources/LumenAnalysis/DirtyRects.swift`
- `Sources/LumenProject/AnalysisTypes.swift`
- `Tests/LumenTests/ZoomTypingVerifyTests.swift`
- `Tests/LumenTests/TypingTraceTests.swift` (new)

**Defects confirmed by reading the source**

1. `TypingAnalyzer` opens **one `AVAssetReader` per burst** and walks bursts sequentially.
   A recording with many short bursts decodes the same seconds of video repeatedly.
2. Sampling is ~10 Hz. At 10 Hz a fast typist's caret moves several glyphs between
   samples, and the tracer cannot tell a caret step from a line wrap.
3. `TypingTracer` picks a line-height-change component, then tracks a **fixed vertical
   band** and the rightmost changed column. It has no notion of the caret blinking, a
   backspace, a newline, a scroll, or a second text field animating elsewhere.
4. `Planner.fixes` prefers any nonempty AX result for the whole burst and only falls back
   to traces when *no* key in the burst had an AX frame. One good AX sample therefore
   suppresses good pixel evidence for the rest of the burst.
5. `AnalysisService.run` awaits `runTyping` **before** starting OCR/face/activity/transcript,
   and the "at most 2 concurrent analyzers" comment is not enforced by any scheduler.

**Required outcomes**

- One decode pass over the source for all typing bursts, with overlapping windows merged.
- A trace per burst that covers: typing at the very start and very end of a recording,
  line wrap, backspace, scrolling, caret blink, and a second unrelated animation on screen.
- Visual tracking restricted to plausible text regions; unrelated page animation is
  rejected; the tracker recovers when the line or field changes.
- `TypingTrace` carries enough provenance for the planner to judge freshness (sample time
  and confidence per sample), without storing characters.
- `Service.run` uses a bounded, measured scheduler: first frame + first audible window +
  typing focus go first; OCR/face/activity/transcript fill the remaining capacity.
  Cancellation is cooperative inside decode chunks. Cache keys include media identity,
  analyzer version, relevant settings and context policy.
- `DirtyRects.lumaTiles` profiled; move a demonstrated pixel-reduction hot spot to
  GPU/Accelerate only if it is faster end to end. Do not claim GPU work from utilisation.

**Verify**

```sh
./Tools/agent-lock.sh acquire lane-b 5400
swift test --no-parallel --filter 'TypingTraceTests|ZoomTypingVerifyTests'
./Tools/agent-lock.sh release lane-b
```

---

## Lane C — camera and planner motion (both documents' motion core)

**Plan sections:** all of `Docs/ZOOM-MOTION-PLAN.md`; handoff §2.

**Files you own**

- `Sources/LumenDirector/Camera.swift`
- `Sources/LumenDirector/Planner.swift`
- `Sources/LumenDirector/Director.swift`
- `Sources/LumenDirector/Accuracy.swift`
- `Sources/LumenDirector/LiveCamera.swift`
- `Sources/LumenCore/Motion.swift`
- `Sources/LumenProject/Derived.swift`
- `Tests/LumenTests/CameraMotionTests.swift`
- `Tests/LumenTests/ZoomEasingTests.swift`
- `Tests/LumenTests/MotionTraceTests.swift`
- `Tests/LumenTests/ZoomPrecisionTests.swift`
- `Tests/LumenTests/ZoomTransformTests.swift`
- `Tests/LumenTests/AutoZoomRegressionTests.swift`
- `Tests/LumenTests/MotionAccuracyTests.swift`
- `Tests/LumenTests/ZoomCropTests.swift`
- `Tests/LumenTests/ZoomReportTests.swift`

**Defects confirmed by reading the source**

1. **Acceleration arrays are never produced.** `CameraTrack.init` fills `ax/ay/az` with
   zero. `CameraSolver` sets `vx/vy/vz` from `tangent(...)` and leaves acceleration at 0.
   `Director.qhm` then builds a `QuinticMove` between every pair of 240 Hz samples with
   `a0 = a1 = 0`, which is **not** the curve that generated the samples. Sample the
   trajectory between ticks and the acceleration steps at every sample boundary. This is
   the leading suspect for "robotic, stepped" motion.
2. **Double easing on the follow path.** `Planner.follow` already smooths the caret path
   (`zeroPhaseSmooth(omega: 9, ...)` and hold-then-jump), then `CameraSolver.followStep`
   runs a first-order follower at `omega: 8` with a dead zone **after** the quintic has
   arrived. An unconstrained first-order step at that omega needs ~290 ms to cover 90 % of
   a gap. The camera therefore trails the caret and then catches up.
3. **Target publication is gated at 2.4 s.** `Planner.follow` only moves the camera when
   `s.t - lastMove >= 2.4`, producing exactly the stop→lurch the report describes.
4. **Timing is not the documented curve.** `preferredDuration = max(5.5 / zoomIn, 0.6 *
   panDuration)`, zoom-out `6.5 / zoomOut`, `omegaZoom` doubling as both a spring frequency
   and a duration divisor. The zoom-motion plan asks for 500–650 ms in, 650–850 ms out,
   250–450 ms for a nearby reframe, mapped through the existing `CameraParams` contract —
   not new preferences.
5. **Moves get crushed.** `duration = min(preferredDuration, available)` with
   `arrivalLead = 1/60` squeezes a large move into a tiny gap rather than merging the
   scene or keeping a wider framing. That is explicitly disallowed.
6. **The 2.6 planner cap.** `let hi = clamp(p.maxScale, 1.3, 2.6)` in `Planner.plan`.
   Investigate why the cap exists before changing it.

**Required outcomes**

- One owner of the final camera pose: the planner decides targets and timing, one
  evaluator produces pan and log-scale. No downstream filter eases an already-eased camera.
- `CameraTrack` publishes derivatives consistent with the trajectory the evaluator
  actually produced, and `qhm` reproduces that trajectory between samples. Do not
  manufacture zero-acceleration endpoints at every stored sample.
- Interrupted moves seed the next `QuinticMove` from the sampled position, velocity and
  acceleration — C2 across every handoff, including zoom-out.
- Typing keeps the active line framed with reading room, moves before the caret runs out
  of room, and does not chase every keystroke.
- Zoom-out is one finite curve that reaches scale 1 and stays there: no snap, no crawl,
  no bounce, no immediate re-zoom when a related action is imminent.
- Reach ≥ 95 % of planned log-scale by the event within one output frame when there is
  lead-in; the explicit fallback applies at clip start or in dense action.

**Verify**

```sh
./Tools/agent-lock.sh acquire lane-c 5400
swift test --no-parallel --filter 'ZoomEasingTests|ZoomPrecisionTests|MotionTraceTests|ZoomTransformTests|AutoZoomRegressionTests|MotionAccuracyTests|ZoomCropTests|ZoomReportTests|CameraMotionTests'
./Tools/agent-lock.sh release lane-c
```

Add a real bounded-motion assertion. `maxJerk` in `MotionTraceTests.swift` exists but is
never asserted; its presence is not coverage.

---

## Lane D — Studio open latency and first-play audio

**Plan sections:** handoff §3 (items 1–5, 8) and §9 (smoothness/playback).

**Files you own**

- `Sources/LumenUI/EditorModel.swift`
- `Sources/LumenUI/AppModel.swift`
- `Sources/LumenUI/PreviewView.swift`
- `Sources/LumenExport/ProjectSession.swift`
- `Sources/LumenAudio/Mixer.swift`
- `Sources/LumenAudio/AudioIO.swift`
- `Sources/LumenAudio/AudioMapped.swift`
- `Sources/LumenAudio/ProcessedVoice.swift`
- `Sources/LumenRender/FrameSource.swift`
- `Tests/LumenTests/PlayInstantTests.swift`
- `Tests/LumenTests/PerformanceTests.swift`
- `Tests/LumenTests/AudioStudioTests.swift`

**Defects confirmed by reading the source**

1. `ProjectSession.open` reads **every** complete mic/system/additional-mic track, runs VAD
   over all of them, computes the waveform envelope, loads the transcript, and opens the
   video sources before returning. `EditorModel.open` awaits it. That is the 5–10 s open.
2. `EditorModel.play()` starts the clock at `HostClock.now() + 0.08` when the player is not
   loaded and calls `player.warm()` plus a background `remix()`. Video starts immediately
   with **no audio at all**; the mix later joins at the current position. The first played
   frames are therefore silent, and the click/typing cues that belong to them are skipped.
3. The late-join path schedules `player.play(from: tNow, atHostSeconds: now + latency)` from
   a video position sampled at a different instant — a separate synchronisation defect.
4. `AudioMixer.voiceChain` takes one lock and holds it across cache-key generation, disk
   cache read and the whole DSP render. Background `prepareVoice` and the timeline mix
   serialise on it.
5. `seek` uses a different lead when the player is not loaded (`+0.08` vs
   `latency + 0.03`), so the first seek and every later seek land differently.

**Required outcomes**

- Minimal open: the persisted project and the first frame are usable without complete
  audio reads, VAD, waveform, neural cleanup, transcription or privacy scanning.
  Cached waveform/VAD load immediately; missing data is prepared incrementally.
- First playback has its audio. Either a bounded ready-audio prefix/read-ahead covering
  the first audible window (including enabled click and typing cues), or an exact valid mix
  cache. One output time map, shared DSP semantics, so preview and export agree.
- Video and ready audio start against the same future host instant, after measured device
  latency compensation. If preparation genuinely cannot meet the budget, show a truthful
  preparing state with the clock stopped. Never call a silent start success.
- Readiness is defined for silent, audio-disabled, missing-source and analysis-failure
  cases. A silent project must not block on audio that does not exist.
- The mixer lock covers cache publication only. Voice work is single-flight, keyed by
  immutable source + settings. Cancellation is cooperative inside DSP/decode chunks;
  cancelling an awaiting wrapper must not leave detached work running.
- Caches are keyed by media identity, algorithm version, relevant settings/events, time
  map and context policy; written atomically; only affected work invalidated.

**Verify**

```sh
./Tools/agent-lock.sh acquire lane-d 5400
swift test --no-parallel --filter 'PlayInstantTests|PerformanceTests|AudioStudioTests'
./Tools/agent-lock.sh release lane-d
```

Measure first-paint, first-video-frame, first-audible-sample and full-processing times
separately, warm and cold. Report numbers; do not assert a gate you did not measure.

---

## Lane E — privacy context, cursor states, click ripple

**Plan sections:** handoff §4 and §5.

**Files you own**

- `Sources/LumenProject/Overlays.swift`
- `Sources/LumenAnalysis/OCR.swift`
- `Sources/LumenDirector/MaskTracks.swift`
- `Sources/LumenDirector/Cursor.swift`
- `Sources/LumenRender/CursorAtlas.swift`
- `Sources/LumenRender/ClickEffects.swift`
- `Sources/LumenRender/Renderer.swift`
- `Sources/LumenRender/PrivacyMaskGeometry.swift`
- `Sources/LumenRender/Shaders/Shaders.metal`
- `Tests/LumenTests/PrivacyMaskGeometryTests.swift`
- `Tests/LumenTests/MaskOCRTests.swift`
- `Tests/LumenTests/ClickEffectTests.swift`
- `Tests/LumenTests/CursorStylePersistenceTests.swift`
- `Tests/LumenTests/MoveTapTests.swift`

**Defects confirmed by reading the source**

1. **Guessed neighbouring regions.** `OCR.swift` scans for a label matching
   `password|passcode|cvv|card number|ssn`, takes the nearest observation as "the field"
   and, when there is none, **invents** a region below the label, then emits a
   `.envSecret` detection at `confidence: 1`. A "Password" label on a public page therefore
   masks an area that was never shown to contain a secret.
2. **Email is detected with no context.** `SensitivePatterns.scan` flags any address, and
   `PrivacyPlan.autoApply` includes `email`, so a landing-page `hello@…` is masked.
3. **Dot-only password fields are masked.** The scan pattern `[•●]{4,}` classifies
   concealment glyphs as `.envSecret`. Masking dots adds no protection.
4. **No context record exists.** Nothing links a detection to the app, window or verified
   host, so no policy can tell a private mail surface from public page text.
5. **Masks bridge too much.** `MaskTracks.bridge = 1.6 s`, same-hash movement up to
   `0.4 * diagonal`, `lead = tail = 0.6 s`. Scrolling, navigation or a repeated address
   elsewhere lets one mask slide across unrelated content.
6. **Cursor identity is lost in rendering.** `CursorAtlas` draws `pointingHand`,
   `openHand` and `closedHand` with the *same* hand glyph and 256-unit path, and its
   `default:` branch draws the arrow for everything else — including `iBeam`, which the
   switch never names. Capture defines ten distinct stock shapes; the atlas renders two.
7. **Ripple.** `ClickPulses.active` uses a linear `progress`; `Renderer`/`Shaders.metal`
   consume it. Onset, expansion and fade need to read as one continuous motion at the true
   hotspot with no pop and no residual distortion after completion.

**Required outcomes**

- Detection, geometry, confidence and context are separate facts. A nearby "Password"
  label, or a field named "email", is not proof of exposed secret pixels.
- Automatic policy, using `FocusAnchor`:

  | Context / content | Behaviour |
  |---|---|
  | Verified private Google mail/account host with a visible address | Pixelate the address substring only |
  | Public landing page, footer/contact address, date, ordinary copy | Leave visible |
  | Unknown host, or legacy/imported footage with no context | No automatic mask; keep manual/proposed |
  | Password field showing only `••••••` | No extra pixelation |
  | Password revealed as readable text | Mask the exposed value; track reveal/hide |
  | Existing high-confidence key/token or explicit manual mask | Preserve as-is |

  Approved private hosts start at `mail.google.com` and `accounts.google.com`. A host is
  approved only on an exact registrable-domain match: `mail.google.com.example.test` is
  not private. A title, logo or substring match is not evidence.
- `MaskTracks` resets at navigation, cuts, focus/window/context change or incompatible
  geometry, and no longer bridges the same address across unrelated pages.
- Masks stay in source pixels and source time, burned before mips and zoom sampling.
  Manual masks and layered-export coverage survive regeneration.
- Cursor atlas renders distinct art for `arrow`, `iBeam`, `pointingHand`, `openHand`,
  `closedHand`, `crosshair`, `resizeLeftRight`, `resizeUpDown`, `notAllowed`,
  `contextMenu` for shape-preserving packs. Hotspots align under zoom and size
  compensation. An explicit stylized dot/ring override remains the user's choice.
- Ripple: onset at the source click after time mapping, centred on the true hotspot,
  continuous expansion and fade, no startup pop, no hard cutoff, no residual distortion.
  Bounded capture-region work and buffer reuse. Overlapping clicks stay correct in
  preview and export.

**Verify**

```sh
./Tools/agent-lock.sh acquire lane-e 5400
swift test --no-parallel --filter 'PrivacyMaskGeometryTests|MaskOCRTests|ClickEffectTests|CursorStylePersistenceTests|MoveTapTests'
./Tools/agent-lock.sh release lane-e
```

Build a synthetic corpus: public landing page, private mail page, unknown host, spoofed
host (`mail.google.com.example.test`), public→mail→public navigation, a repeated address in
two places, a password field toggling reveal/hide. Assert **zero** automatic masks in the
public/dot-only negatives and full coverage on the in-policy positives. Track precision and
recall separately.

---

## What "done" means for the whole job

- `swift build` clean, `make test` green, `make verify` green.
- Every lane's filtered tests pass, and each new regression test fails on the pre-fix code
  (record the evidence).
- Each lane reports: root cause, fix, changed files, failing→passing evidence, measured
  numbers where the plan asks for them, and anything it could not verify.
- Everything committed to `main` and pushed.