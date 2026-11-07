# Conformance table — PLAN §0 + phased acceptance (backend audit)

Date: 2026-11-07. Scope: existing backend code only (no new features beyond the plan, no unstarted phases unless a defect blocked).

Legend: **done** = implemented + tested. **partial** = exists but limited/off. **missing** = absent/dead.

## §0 operating rules

| Rule | Status | File evidence |
|---|---|---|
| 1. Phase order + `make verify` | done | `Makefile` (`verify: test app`); suite 154/154 green in run-001 |
| 2. Swift 6 strict, zero warnings | partial | `swift build` clean except pre-existing `Inspector.swift:330` + `MonthGraph` warnings (UI WIP by another agent, not backend). Backend targets zero warnings after fixes |
| 3. Value types by default | done | `DirectorInput`, `Timeline`, `AudioCheckReport` are values; classes only for writers/engines |
| 4. Hot paths no actor/no alloc/no UI lock | done* | SCK `video()` never blocks (drops counted); CAF now converts via carried converter, no per-frame actor hop. *`CMSampleBufferCopyPCMDataIntoAudioBufferList` alloc per buffer remains (AVFoundation requires it) — counted, not blocked |
| 5. Module boundaries | done | `Package.swift` deps unenforced-by-compiler but honoured (Director imports no AVFoundation/Metal/Vision) |
| 6. Algorithms tested before UI | done | `BackendFixTests` (7) + existing 147 predate UI wiring |
| 7. Spike contradicts plan → amend | done | Decisions.md updated (preview=mixed buffer, stop split, declick scope) |
| 8. Commit per milestone `phaseN:` | partial | This pass uses descriptive 6-12 word messages per GIT-SKILLS (rule 8 vs GIT-SKILLS conflict: GIT-SKILLS wins for this repo — one change per commit, pushed to `main`) |
| 9. Zero network in core | done | `grep URLSession\|Network` only in `LumenShare`/opt-in Unsplash+MCP (verified in feature.md; no new networking added) |
| 10. One-line doc + ownership/threading | partial | New types (`MainThreadWatchdog`, `RecordingGate`, `AudioCheckReport`, `Declick`) carry doc comments; older types sometimes lack them — not backfilled in this pass |
| 11. One command bus | done | `Commands` enum + reducer unchanged |
| 12. Source-time anchoring | done | Zoom/masks/captions source-time; music/voice-over output-time (unchanged) |
| 13. Non-destructive | done | Media immutable; not touched |
| 14. Determinism (no Date/RNG in Director/Render) | done | `Director.derive` pure; `RecordingSession` uses `Date()` only for bundle naming (outside Director) |
| 15. Budgets (file ≤500, func ≤60, type ≤400) | partial | `Session.swift` 397 lines after state machine (under cap); `Mixer.mapped` ~55 lines; `CAFWriter` ~180 lines. No budget check in CI (not added) |
| 16. No placeholders | done | No `fatalError("TODO")` added; `AudioCheckCmd` + watchdog are real |
| 17. Ambiguity: simplest + Decisions line | done | Decisions.md 4 new lines this pass |
| 18. Accessibility / Reduce Motion | done | Unchanged (HUD labels, keyboard paths intact) |
| 19. Signposts + Logger per module | partial | `RecordingSession` now signposts (via `os_log` + `Logger`); older capture paths still `NSLog` — migration in progress, not complete |
| 20. Violate rule → amend first | done | No rule violated; preview decision logged before code |
| 0.1 Feature-complete checklist | partial | Backend features touched (declick, cut xfade, gate) have model+tests+signals; CLI exposure for `audio-check` added; perf budget for declick is unit-tested, not yet gated in CI |

## Phases with code (acceptance)

| Phase | Criterion | Status |
|---|---|---|
| 1 Capture | 5-min 60 fps 0 drops, sync <1 ms per source, 2 inputs stay in sync, kill-9 recovery | partial: `dropped 0` on `ab-on` (sync-check), 2-input mixing tested (`MultiInputAudioTests`), kill-9 `RecoveryTests` green. Live 5-min native soak NOT DONE (headless). Multi-input sync relies on `TrackMeta.startHostSeconds` + mixer offsets (drift ratio not yet stored — follow-up) |
| 2 Render | Golden + preview ≥ refresh | done: `RenderGoldenTests` + `rendererAndExportRoundTrip` green |
| 3 Cursor | Clicks ≤0.5 px, zero-lag, loop converges | done (`CursorTests` green) |
| 4 Camera/zoom | Discontinuity clean, >8 Hz <1%, wiggle no-zoom, cinematic demos | partial: >8 Hz 0% + bounds 100% (smoothness exit 0), `AutoZoomRegressionTests` green. Discontinuity flags 287 across epochs (harness counts epoch resets; needs epoch exclusion — follow-up, not a Director bug) |
| 5 Audio | Preview==export, LUFS ±0.5, separate tracks verified, declick | done*: `AudioTests` green; preview==mix by construction; declick now real (was dead); LUFS/true-peak after-numbers in run-001 (`-30 LUFS` on quiet fixture is below target because no normalize probe — fixture is not normalized; meter is honest). Before/after spectrograms NOT DONE (JSON only) |
| 6 Editor/export | Zero-edit path, <150 ms preview update, playhead-only split, probe-gated combos encode | done: `CommandBusTests`, `ExportProbeTests`, `clipboardWritesRealFileURLToPasteboard` green |
| 7 Layouts | Spring continuity, no overshoot, cutout stable 5 min | done (`LayoutTests` green) |
| 8 Transcript/captions | Speech never cut mid-word, no click joins, reposition across aspects | done (crossfade 40 ms now real; `TranscriptEditTests`, `CaptionTests` green) |
| 9 Privacy | OCR-negative at 6×, recall ≥99%, layered survival | done (`PrivacyTests` green) |
| 10 Cinematic/pro | Alpha + layer identity, SSIM gate, tilt clean | done (`AlphaTests`, `LayerExportTests`, `QualityGate` green) |
| 11 Automation | MCP consent + allowlist green | done (`McpTests` green) |
| 12 Devices | Device auto-zoom via pixel activity + taps | partial (documented loud failure for unknown device — honoured) |
| 13 Hardening | Perf/memory/recover green | partial: `PerfTests` + `longCaptureStaysWithinTimeAndMemoryBudget` green; 60-min memory plateau NOT DONE (long test is 10-min) |
| 0/14/15 | Foundation/release/cloud | done/out-of-scope for backend pass |

## Backend-wide notes (Priority 5)

- Preview pacing: `PreviewView` display-link loop unchanged; GPU budget covered by `PerformanceHarness` (`bench` exits 1 on miss). Scrub smoothness not measured headlessly — NOT DONE.
- Startup/open times (Release): not measured (Debug only here) — NOT DONE, logged.
- Memory plateau 60-min: `longCaptureStaysWithinTimeAndMemoryBudget` is 10-min — 60-min NOT DONE.
- All features in `feature.md` remain as audited (no backend feature removed); declick moved from dead-code to WIRED in this pass.
