# 4A recovery changes

- Existing MOV writers use 1-second movie fragment intervals; existing journal cadence remains one second. The last valid checkpoint is preserved; source media is never copied.
- Preserve actual mic/system/webcam/extra mic origins and event unit; unknown new origins do not produce fictitious tracks. Legacy journals retain compatibility.
- Screen stop drains video and audio callback queues, closes audio writers even on writer failure, and accepts only completed video output. Requested webcam is exact.
- Concurrent stop/finalize callers share tasks. The final checkpoint survives a crash during post-processing. Final duration is read from the finalized video track rather than host wall time.
- Added three disk-backed regression tests. CI, forced process termination and target-device latency measurements pending. No claim of two-second actual recovery, and audio container durability still requires proof.

Follow-up: stopping a paused take never reopens capture; reject duplicate/regressing video timestamps, release recording power activity on failure, retain failed-start journal, and check existing project duration against available footage before clearing recovery evidence.
