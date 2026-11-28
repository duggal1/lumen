# Part 3 — Physical hardware and presentation proof

Read existing Director replay, target-hardware export proof, Metal renderer, display-link pipeline and packaging. Do not synthesize real user footage, fake metrics or equate encoded FPS with presentation cadence.

- Reuse annotated actual Chrome replay and 40-second target-hardware export test; run on base M1/8 GiB with a clean exact checkout.
- Measure actual Metal presented timestamps during one uninterrupted >=10 s playback generation, not render submission. Opt-in bounded collector; no ordinary playback overhead beyond a nil optional.
- Publish local evidence only; require real artifacts, matching commit, all four export trials and explicit 8x/3x throughput and cadence thresholds. Missing or skipped evidence fails.
- Test cadence accounting, generation separation and late intervals.
- Separately run authorized forced daemon interruption and three actual unattended recording-to-export jobs; human/agent review actual video, narration and composition. No artificial quality guarantee.

Acceptance requires actual hardware reports, integrated macOS CI, crash and unattended runs, and external visual review. This PR supplies tools, not measurements. No score increase until proof exists.
