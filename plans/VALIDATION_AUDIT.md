# Lumen backend fix — validation audit (brutally honest)

**Date:** 2026-11-21 · **Branch:** `wip/backend-fixes-handoff` · **HEAD audited:** `9464dd5`
**Audit method:** three independent read-only sub-agents (camera, perf/scaling, audio/integrity), plus the main agent's test execution. No sub-agent changed source, tests, config or git state. Their raw reports are in `.proof/audit-camera.md`, `.proof/audit-perf.md`, `.proof/audit-audio.md`.

## Executive verdict — RED

`git push -u origin wip/backend-fixes-handoff` **failed**: the repository's pre-push hook runs `make test`, and the suite exited 1 with **117 issues over 736 tests in 63 suites (1701.7 s)**. The WIP commit `df84f1c` and my `9464dd5` exist locally but are **not pushed**.

Nothing in P1–P6 can honestly be marked PASS for the full acceptance set. The focused camera fixtures pass, but the broad camera invariant suite is red because my pivot implementation is a regression. The audio and perf fixes were audited in an uncompiled state and contain definite bugs. Several tests failed for environmental reasons (`Missing default.metallib and Shaders.metal`) and need triage, not excuses.

| Audit | Scope | Raw report | Blunt result |
|---|---|---|---|
| cw-audit-camera | P1/P4/P5 camera + test integrity | `.proof/audit-camera.md` | Pivot geometry correct for one clean shot; implementation is a regression (8 red tests) |
| cw-audit-perf | P2/P3 benchmark + upscaling | `.proof/audit-perf.md` | P2 live path unmeasured; P3 golden/SSIM absent; upscale A/B vacuous |
| cw-audit-audio | P6 audio + scope/integrity | `.proof/audit-audio.md` | Headline +1.6 dB test sign-inverted; one test still asserts -16; "no modes" only partial |

---

## 1. Camera audit (P1 / P4 / P5)

### Per-failure attribution from `.proof/full-after-p1.log`

| Test | Failing assertion | Caused by my pivot change? |
|---|---|---|
| `fuzzInvariantsHold` | 9 teleports, dx/dy up to 0.085/tick | YES — direct `panX/panY` assignment |
| `fiveHundredSeedHostileMixedSessionsHoldEveryInvariant` | 6 pan teleports | YES — same |
| `twoHundredSessionsHoldEveryCameraInvariant` | teleport + jerk 1.22e6–3.67e6 | YES — same; determinism intact |
| `motionTracesAreSmooth` | pan x jerk 5.67e8 vs 1e7 bound | YES — published v/a mismatch |
| `bakedTrackHasBoundedJerkAcrossScriptedClicks` | identical 5.67e8 jerk | YES — same |
| `cameraTrackPublishesAcceleration` | `ax -190.39` vs finite-diff `-303.61` | YES — spring `ax` with analytic `vx` |
| `evaluatedAccelerationHasNoTickBoundaryStep` | boundary step 733 vs bound 579 | YES — Hermite consumes v/a pair |
| `handoffsKeepAccelerationContinuous` | spike 801312 vs bound 731099 | YES — same |
| `floatAndSeedKnobsCannotChangeTheBake` | bake changes with `panThroughGap` | NO — live knob, pre-existing |
| `retiredFloatKnobsAreInertAcrossAllSeeds` | seeds 1–9 change bake | NO — same knob leak |
| `chainedShotsReturnToFullFrameAndNeverHoldForTenSeconds` | zoomed run ≥ 7 s | NO — scale domain; likely tail/chain |
| `arrivalIsSettledBeforeEventAcrossScalesEasingsAndLeadIns` | snappy 2.4× short by 0.0017 | NO — scale-domain omega cap |
| `revealEntranceDiffersFromSettledAndIsDeterministic` | lean==reveal GPU render | NO — render path |
| `arrivalIsExactAndSettledBeforeTheClick` | — | PASSED (snap fix worked) |

### Camera findings

| ID | Sev | Claim | Evidence | Verdict | Action |
|---|---|---|---|---|---|
| F1 | BLOCKER | Published pan acceleration is the derivative of published pan velocity | `Camera.swift:557-558` vs `:579-580`; log ax -190 vs FD -303 | FAIL | Publish analytic `ax/ay = K·e^-lz·(az - scaleVel²)` |
| F2 | BLOCKER | Near-equal-scale division is stable | guard `1e-3` → denominator ~1e-3 → ~1000× amplification; log dx 0.085 | FAIL | Replace with bounded C2 blend; no 1/(1-s0/s1) amplification |
| F3 | MAJOR | Snap leaves coherent derivatives | snap sets `scaleVel=0` but not `velX/velY` | FAIL | Joint snap; recompute pan velocity |
| F4 | MAJOR | Same-scale fallback is continuous | `if abs(...)<=1e-3` switches generating law | FAIL | Continuous/hysteretic blend |
| F5 | OK | P1 pivot geometry correct for single shot | identity verified; drift 37.77 → 0.36 px | PASS | Keep geometry, replace derivative plumbing |
| F6 | OK | Determinism intact | `bakeIsByteIdenticalUnderChurn` etc. pass | PASS | Preserve |
| F7 | MAJOR | Test integrity of envelope replacement | frozen test replaced, new one checks x only, no v/a/jerk | FAIL | Restore old test as superseded contract; keep both |
| F8 | OK | 1e-4 float tolerance is tightening, not weakening | sibling uses 1e-3 | PASS | none |
| F9 | MINOR | `typingBurstProducesOneShot` OR assertion can pass vacuously | `AutoZoomFixtureTests:82` | FAIL | Assert `withField.zoom.count == 1` |
| F10 | MAJOR | `CameraPathTests` falsely green on smoothness | `maxStep < 40` misses 5.67e8 jerk | FAIL | Add jerk + derivative-consistency checks |
| F11 | MAJOR | `panThroughGap` is still a live knob | `Camera.swift:64,214,459`; `Models.swift:243,261,270` | FAIL (pre-existing) | Retire knob or fix test premise |
| F12 | MAJOR | Chained shots hold zoom ≥7 s | `CameraAccuracyTests:217` | FAIL (pre-existing) | Investigate chain/finishAutomaticZoom |
| F13 | MAJOR | Snappy 2.4× arrival short by 0.0017 | `CinematicZoomStressTests:128` | FAIL (pre-existing) | Check `safeZoomOmega` cap |
| F14 | MINOR | Reveal render identical to lean | `CinematicRender3DGPUTests:158` | FAIL (unrelated) | Separate render investigation |
| F15 | OK | `finishAutomaticZoom` derivatives analytically correct | `Camera.swift:96-114` | PASS | Leave alone |
| F16 | INFO | No A/B run possible during audit (SwiftPM lock) | auditor `ps` output | UNVERIFIED | Re-run focused after rebuild |

**Blunt:** the pivot *idea* is right; the implementation is not. Analytic velocity paired with spring acceleration and a ~1000× near-equal-scale amplification breaks 8 existing tests. The passing new fixtures cover only clean single shots and do not license a P1 PASS.

---

## 2. Performance / scaling audit (P2 / P3)

| ID | Sev | Claim | Evidence | Verdict | Action |
|---|---|---|---|---|---|
| F1 | HIGH | P2 "steady 60 fps at click" measured on live path | bench renders synthetic pixel buffer offscreen at `quality:.export`, no display/decode/audio | FAIL (needs-hardware for live) | Instrument live preview; offscreen is supporting evidence only |
| F2 | HIGH | `clicks:true` re-derives Director at click time | events prebuilt at 2 s spacing; `Director.derive` once before timed loop | FAIL | Move derive/signpost into loop or restate claim |
| F3 | HIGH | Upscale A/B valid | no zoom without clicks → blend 0 → upscaler never engages; `delta<1ms` is noise | FAIL (vacuous) | Force scale ≥1.2, assert engagement, warm trials |
| F4 | HIGH | Golden images at 2x/3x/4x vs 2x-supersampled reference with SSIM | no PNG goldens, no SSIM; only analytic laplacian/edge vs bilinear | FAIL for stated acceptance | Add goldens + SSIM; keep analytic guard |
| F5 | MED | Strict gate rejects misses | policy tests feed 17/34/NaN/16.6; `worst<=33` dead under `over==0` | PASS (policy only) | Keep; add boundary case |
| F6 | HIGH | 3600-frame test passes reliably | full suite: p99 **72.5 ms**, **644/3600** over budget | FAIL | Fix workload or move gate to manual CLI |
| F7 | MED | Zero dropped frames measured | wraps `render()` + semaphore; no present/vsync observation | UNVERIFIED | Gate on present timestamps |
| F8 | MED | Four live stall candidates measured/fixed | FrameSource unchanged; no timing gate in PreviewView | needs-hardware / FAIL | Measure on hardware before claiming |
| F9 | INFO | Focused tests validate new code | no run (lock, stale scratch binary) | UNVERIFIED | Rebuild and rerun |
| F10 | LOW | CLI can reproduce P3 A/B | `--clicks` exists, no `--upscale` flag | FAIL (gap) | Add flag |

**Blunt:** P2 is FAIL/needs-hardware — the gate is real but measures an offscreen synthetic render; the actual click test failed at 72.5 ms p99 with 644 dropped frames. P3 fails the stated golden/SSIM acceptance and its frame-cost A/B never engages the upscaler.

---

## 3. Audio audit (P6 + integrity)

| ID | Sev | Claim | Evidence | Verdict | Action |
|---|---|---|---|---|---|
| F1 | CRITICAL | +1.6 dB A/B legitimate | `old.outputGainDb = -12 - (-14) = +2` → target **-10**, inverted sign | FAIL | Use `-2`; measure real delta |
| F2 | CRITICAL | All old-target tests updated | `CoreFeatureValidationTests:217` still asserts `back.targetLUFS == -16` | FAIL | Change to `AudioPlan.studioTargetLUFS` |
| F3 | HIGH | One always-on chain, no modes/toggles | DSP shape fixed, but `micClean`, `dereverb`, `declick`, `voiceBoostDb`, `normalize`, `micMode==.off` all branch; UI still exposes Studio mode/Voice/Noise sliders | FAIL (partial) | Remove toggles or report honestly |
| F4 | MED | Loudness API coherent | MCP `target_lufs` now a silent no-op; stale -16 comments and migration keys | FAIL | Remove/grey control; fix comments/migration |
| F5 | HIGH | -12 LUFS + ≤-1 dBTP achievable | archived chain -12.49 LUFS at -0.90 dBTP ⇒ PLR ≈ 11.6 dB ⇒ ceiling ≈ -12.6 LUFS; correction loop runs once and final peak trim does not re-normalize | UNVERIFIED (high fail risk) | Measure every fixture; report real numbers |
| F6 | MED | ~9 test rewrites are honest | 6 honest supersessions; mode/gap tests delete assertions; `requiresDeepFilterNet` guards return green | PARTIAL | Restore positive evidence; mark skips explicitly |
| F7 | INFO | StudioGrade gap ≥50 will pass | old `studio=0.5` ⇒ old depth = 48, same as new fixed 48 | PASS (predicted) | Verify after rebuild |
| F8 | HIGH | Branch/commit scope | 19 modified + 3 untracked paths, many from other agents; zero P6 commits | FAIL (hygiene) | Never `git add .`; commit P6 files individually |
| F9 | LOW | Logical compile check | `tone(_:)` only one caller, updated; `finish` signature unchanged | PASS (static) | Compile to confirm |
| F10 | LOW | Owner told about target conflict | no owner-facing note of -12 choice | UNVERIFIED | Put in final report |

### Per-test failure prediction (after clean rebuild)

| Test | Prediction | Reason |
|---|---|---|
| `CoreFeatureValidationTests.voiceProcessingDefaultsAndPodcastMode` | **FAIL** | literal -16 vs -12 (F2) |
| `StudioAudioAcceptanceTests.studioChainIsAtLeastOnePointSixDbLouderThanOldProgram` | **FAIL** | sign inversion (F1) + ceiling (F5) |
| `StudioAudioAcceptanceTests.sixFixturesStayLoudCleanAndBelowTruePeak` | UNVERIFIED | ±0.95 clamp lowers PLR |
| `StudioAudioAcceptanceTests.studioChainReducesNoiseFloorAndIsDeterministic` | likely PASS | 31 dB baseline drop vs 10 dB gate |
| `StudioGradeTests.studioChainReachesPodcastNoiseFloorTarget` | likely PASS | F7 |
| `AudioStudioQualityTests.voiceBoostLiftsOwnVoiceTwoToThreeDbInLufs` | likely PASS/vacuous | model guard |
| Integration/Migration/Typing/StudioVoice/CoreCapture | likely PASS | pure-tone normalization |
| Full suite | **FAIL** | camera + perf red before P6 |

**Blunt:** P6 is not verifiable as delivered. The headline test is sign-inverted, one missed test asserts -16, -12 LUFS at ≤-1 dBTP is physically doubtful, and "no modes" is only partly true. Nothing was compiled or run; all P6 work is uncommitted.

---

## 4. Overall acceptance table (honest, at audit time)

| Criterion | Verdict | Evidence |
|---|---|---|
| P1 no drift/overshoot/teleport on general camera paths | FAIL | 8 pivot-caused red tests, jerk 5.67e8 |
| P1 single-shot fixed pivot ≤0.5 px | PASS | 37.77 → 0.36 px measured |
| P2 p99<16.6 ms, 0 drops, max≤33 ms @60 s clicks | FAIL | p99 72.5 ms, 644/3600 over budget |
| P2 live-path root cause measured | needs-hardware / FAIL | nothing instrumented |
| P3 golden images + SSIM at 2x/3x/4x | FAIL | absent |
| P3 frame-time cost measured honestly | FAIL | A/B vacuous |
| P4 idle page produces no zoom | PASS | 10 fixtures pass, deterministic idle |
| P5 all fixtures return to full frame | PASS | 4 original + 2 new regressions pass |
| P6 ≥+1.6 dB vs old, ≤-1 dBTP, no clipping | FAIL | sign-inverted A/B; unverified |
| P6 one chain no modes | FAIL (partial) | DSP shape fixed; toggles/UI remain |
| No weakened/deleted tests | FAIL | frozen envelope test replaced; gap assertions deleted |
| Full suite green | FAIL | 117 issues / 736 tests |
| Push to WIP branch | FAIL | pre-push hook rejected red suite |
| Source media untouched / shared render+audio paths | PASS | code inspection; no media edits |
| New dependencies | PASS | none added |

---

## 5. Blunt conclusion

The handoff's "make all pass" is **not achieved**. My camera pivot fix traded 37.8 px of swim for 8 broken invariants; the perf test fails its own strict gate; P3 lacks the mandated goldens; and P6 has a sign-inverted A/B plus a missed -16 assertion. The three audits agree: the passing focused fixtures are real but far too narrow to sign off. Fix the blockers in this order: (1) camera derivative plumbing + C2 blend, (2) audio F1/F2 and measure, (3) P2/P3 honest scope, then rerun the full suite before any push.
