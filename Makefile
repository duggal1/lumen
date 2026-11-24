.PHONY: build test test-heavy test-all test-a6 verify app probe hooks capture-e2e reap-helpers

build:
	swift build

# An interrupted SwiftPM test run leaves swiftpm-testing-helper parented to
# launchd; it keeps .build/.lock and makes the next build/push look hung.
# Reap only those orphans, then run the suite the same way CI does.
reap-helpers:
	@for pid in $$(pgrep -f 'swiftpm-testing-helper.*LumenTests' || true); do \
		[ "$$(ps -o ppid= -p $$pid | tr -d ' ')" = "1" ] && kill -9 $$pid || true; \
	done

# ---------------------------------------------------------------------------
# TEST SPLIT (CI contract)
#
# make test        Fast gate. Every unit suite plus the A6 headless synthetic
#                  recording E2E. Target < 2 min wall. Skips only HEAVY below.
# make test-heavy  The skipped suites: real-video end-to-end, GPU/benchmark/
#                  visual-accuracy, and large-seed / brutal / fuzz / stress /
#                  long-running audio and export checks. Same tests, same
#                  assertions - moved, never deleted or weakened.
# make test-all    Everything in a single run (what `make test` used to do).
#                  Use for release verification, not for the fast CI gate.
#
# A test is in HEAVY only if it is slow by construction (large seeds, real
# video, GPU rendering, or multi-minute profiling). Unit coverage stays in
# `make test`; both lanes together are exactly the old full suite.
# ---------------------------------------------------------------------------
HEAVY := 'RealVideo|VideoExportPipeline|fullEditingPipeline|cutPositionSweep|cutBoundaryShowsExactSourceFrameAtAllFPS|Brutal|brutal|[Ff]uzz|[Ss]tress|[Ff]iveHundred|[Tt]woHundred|[Ss]ixtySeed|[Tt]housand|GPUTests|RenderVisualAccuracy|A3PerformanceBenchmark|cacheNeverServesAStalePlan|profileStudioOpenStages|warmReopenReusesPreparedAudio|cancelledPreparationLeavesNoDetachedWork|speedRampSamplesIntendedFrames|clipInsertLandsOnIntendedOutputFrame|editorOpenReturnsBeforeHeavyPreparationFinishes|firstAudibleWindowCarriesMicAndCueAudio|KeyboardAudio|visualSequenceVerifier|exportFrameCountMatchesDuration|upscalerBeatsPlainSampling|independentWavStemPreservesRampedOutputTiming|additionalMicrophoneIsMixedAndExportedAsIsolatedStem|burstTypingNeverClipsTheBus|offlineAudioIsRepeatableAndLimited|dereverbChainWithSuppressorStaysBounded|deepFilterNetBeatsSpectralGateOnStationaryNoise|residualSuppressorPreservesLengthAndQuietsTail|studioMicRemainsWithinPeakCeiling|gentleEchoReductionImprovesSyntheticSpeechWithoutLargeChange|voiceWorkIsSingleFlightAndNotSerialised|retiredFloatKnobsAreInertAcrossAllSeeds|longCaptureStaysWithinTimeAndMemoryBudget|export4K60FasterThanRealtime|export1080P60FasterThanRealtime|exportVideoFramesAreEvenlySpacedAtPresetFPS|exportedAudioAndVideoAreInSync|renderBenchmark|cropIsContinuousAndInsideSource|crossfadeBlendsBothSidesAtClipJoin|fixtureFrameIDsAreUniqueOrderedAndDecodable|rendererAndExportRoundTrip|audioStaysInSyncAfterCut|playStartsVideoAndAudioTogether|exportFinalWritesARealMP4|cleanupPreservesContinuousVoiceAndReducesQuietNoise|finalMixRaisesVoiceProminenceAndStaysBelowTruePeakCeiling|stageACacheIsWrittenAndReused'

test: reap-helpers
	swift test --no-parallel --skip $(HEAVY)

test-heavy: reap-helpers
	swift test --no-parallel --filter $(HEAVY)

test-all: reap-helpers
	swift test --no-parallel

# Fast A6 lane: just the harness gates, crash-safety checks and the headless
# synthetic-recording E2E (no permissions, no window, no real screen).
test-a6: reap-helpers
	swift test --no-parallel --filter 'A6'

app:
	bash Tools/make-app.sh

hooks:
	git config core.hooksPath Tools/hooks

verify: test app
	.build/Lumen.app/Contents/MacOS/Lumen --help >/dev/null 2>&1 & pid=$$!; sleep 2; kill -0 $$pid; kill $$pid
	@echo 'Build, integration tests, packaging and launch passed. Hardware capture/sync/performance checks remain separate.'

probe: build
	swift run --skip-build lumen-cli probe

capture-e2e: build
	swift run --skip-build lumen-cli capture-matrix --check-gate
