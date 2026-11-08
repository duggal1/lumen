# ULTRA-ELITE SHOP PLAN — Partial → Green (Motion, Audio, Mask, Captions, Editing)

## Goal (2-3 lines)
Close every PARTIAL from last table to real GREEN with fresh traces/numbers (not claims). Priority is podcast/studio audio as already landed (keep green), then motion traces, crop proof, 6× OCR masks, caption OCR + stitching, and the magnetic/main-lane + stale-test fight. No new backend features, no deletes except Apple Speech already done.

## Non-goals
- No new DSP libraries, no network, no ML/NN in default path, no UI redesign beyond existing panels.
- No touching cloud WIP files except the one stale oracle (`importedClipsStackInOutputTimeAndTrim`) after agreeing the magnetic-semantics migration.
- No LUFS -16→-14 flip until a frozen-test migration is signed (report, don't break).

## Invariants (must always be true)
- Preview==export: same `mixer.mix(tl)`, same `tl.evaluate(at:)` at same timestamp, motion at ≥60Hz feeds 30fps blur samples.
- Zoom: `start <= click`, settled ≤0.5s after click, scale ∈ [1.0, ≥3.5] continuous, relevant region (AX frame / cluster bbox / text region) + context margin never cropped.
- Cursor & camera same timestamp; log-zoom; no pixel snapping; manual shots survive replans; undo/redo for every segment edit; expander never chops tails (length preserved, no new dropouts).
- Mask: masks in source space/time, no raw OCR text persisted, raw master unchanged, exports only clean.
- Captions: Moonshine only, word timing intact, filler removal works, no mirrored text in any aspect at export.

## Considerations
- Transaction boundaries: timeline edits atomic via existing `reduce(&tl, .cmd, ctx:)`; no partial clip mutation on throw.
- Idempotency / retries: `addClip/moveClip/trimClip/splitClip` are pure reduce — safe to retry; journal/capture writes atomic `.atomic` rename.
- Locking / races: `DerivePipeline` actor serializes replans; mixer lock guards cache; no new shared mutables.
- Ordering / partial failure: export staged file renamed only on success; crash leaves fragmented MOV + journal (never corrupt final).
- Timeouts / external failure: stage timeouts are failure-path only (watchdog), never a hang fix; ModelStore/transcribe failures surface as `.failed`, never block UI.
- Migration safety: `ProjectMeta` capture fields additive with `c.opt` defaults; `AudioPlan` new keys opt-decoded; no lock-time concern (local files).
- Query plans: waveform/motion loops are O(frames) bounded; 5000-event clustering is O(n log n) sorted sweep, no N+1 IPC.
- Authz: n/a (local); keep Input Monitoring + Screen Recording gates as-is.

## Failure modes and expected behavior
- Motion lead too short / overwriting clicks → anchor zoom to click, assert `medianArrival` & `begin <= click`; blur/600Hz grid stays.
- Over-zoom crop → expand zoom rect by context margin (min 8% of frame / 240px), clamp centre inside source, assert AX text fully inside.
- Expander pumping → soft knee +16dB slower release; if gate test fails, lower depth 3dB and keep length exact.
- Mask miss at first frame / scroll → extend tracks back 0.6s (already), bridge gaps ≤1.6s, re-run 6× OCR on rendered PNGs.
- Caption duplicate ("So does work.") → stitch = gap >0.8s OR punctuation + gap; overlapping Moonshine windows must dedupe by word-time hash; assert no duplicate n-gram.
- Magnetic vs legacy clips → migrate stale test to magnetic contiguous expectation (only with frozen-test amendment note).

## Approach (few lines, not a restatement)
- Package `lumen-cli traces` (positions/vel/acc/jerk + %>8Hz energy) + `lumen-cli ocr-frames` (render 6× PNG, run Vision/OCR, assert secret absent + CCW mirror check).
- Scripted fixtures for mask/caption/zoom crop; real-app session only for traces (Gmail chooser typing).
- Patch minimal roots: Planner scale derivation (AX+cluster+text bbox), `Sentences.split` dedupe, stale magnetic test update, blur/no-snap already landed — verify, don't re-architect.

## Steps (ordered; each has a Verify command)
1. Oracles first: `Tests/LumenTests/MotionTraceTests.swift` (discontinuities 0, %>8Hz <1%), `MaskOCRTests.swift` (6× render+OCR recall/FP), `CaptionMirrorTests.swift` (every aspect OCR + no-dup n-gram), `ZoomCropTests.swift`, updated `importedClipsStack` expectation. RED confirm → `swift test --filter MotionTrace\|MaskOCR\|CaptionMirror\|ZoomCrop`.
2. Traces + motion: add `lumen-cli traces`, run on scripted session, fix Planner scale + lead params from trace only. Verify full traces green + `MotionBlur/CameraMotion/ZoomPrecision/AutoZoomRegression`.
3. Crop + lead: widen planner margins + expose `leadIn` param; assert settle ≤0.5s post-click; run `ZoomCropTests` + manual 2-second fix drill through `moveZoom`.
4. Audio lockdown (keep green): run `StudioGradeTests` + full `AudioStudio/StudioVoice/TypingAudio`, publish `Docs/Verification/audio-studiograde.log` with real-sample gaps. Any DSP tweak re-runs oracle; no LUFS flip.
5. Mask harden: ensure AX secure + OCR both paths, back-extend, 6× render sweep; report recall/FP.
6. Captions: Moonshine dedupe + mirror regression (`CaptionMirrorTests` every aspect); filler edit harness passes.
7. Editing: land magnetic `split/ripple/join/duplicate/paste/trim-snap` via existing `reduce` + UI shortcuts (B/Cmd-C/V/D/J already staged); EditorView batch verified; stale test migrated with amendment note; `EditingTests` + full suite green.
8. Final validation: `swift test` (full), Release `lumen-cli render --benchmark` 1080x1920+1:1+16:9, export ADR. Report per-item numbers/frames/traces, conflicts, eyes/ears items.

## Files
- `Plans/ULTRA-ELITE-SHOP.md` (this file)
- `Tests/LumenTests/MotionTraceTests.swift`, `MaskOCRTests.swift`, `CaptionMirrorTests.swift`, `ZoomCropTests.swift`
- `Sources/LumenCLI/LumenCLI.swift` (traces/ocr-frames only), `Sources/LumenDirector/Planner.swift`, `Sources/LumenSpeech/LiveCaptions*` paths as found
- `Sources/LumenProject/Commands.swift`, `Sources/LumenUI/EditorView.swift`, `Sources/LumenUI/TimelineStrip.swift` (already staged by owner — merge, don't rewrite)
- `Docs/Verification/traces/`, `audio-studiograde.log`, `mask-ocr.log`, `captions-ocr.log`
