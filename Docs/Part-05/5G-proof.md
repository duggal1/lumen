# 5G — Target hardware evidence harness (first slice)

Run from a clean checkout after merging all Part 5 code: `bash Tools/part5-proof.sh /path/to/40s-project.lumen /new/output-directory`.

Supply a real approximately 40-second, 16:9 Lumen project with representative text/camera/cursor/audio/overlays. The wrapper records actual commit, macOS, chip and RAM, uses a release build, copies the project to temporary storage and clears only the copied derived cache. The original is never modified. Measure open/analysis/audio preparation/derive independently, export 1080p60 and 4K60 H.264 twice, inspect real output frame counts, timestamps, dimensions, durations and required audio track, retain all four media files and JSON. No network upload. A missing report or failed verification is not success.

The first export includes first-use export work after separate project preparation; subsequent runs can reuse prepared audio. The 5s threshold is only evaluated for approximately exact 40s content (within 50ms); 4K 3x factor is computed from actual duration. These are stretch metrics, not thresholds weakened or claimed met. RSS is process-lifetime peak and not physical footprint. A/V content sync, actual hardware-encoder telemetry, presented-frame cadence, thermal soak, subjective audio and real capture/crash validation remain separate. Use existing Tools/prove with evidence for every release gate before declaring Part 5 complete.

The environment here cannot run this macOS test or supply an authorized real user recording. No target-device proof or benchmark speed is claimed. This branch stacks on #49; merge #49 before #54.
