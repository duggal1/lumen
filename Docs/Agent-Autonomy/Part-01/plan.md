# Part 1 — Durable job recovery

Read Engine, Jobs, Daemon, export staging, policy and MCP contracts before changes. Preserve source media, UI, privacy, revision checks and tool names. Never replay recording, narration billing or ambiguous exports automatically.

- Versioned single-writer journal for composite demo and export jobs, private local directory, atomic receipts.
- Persist queued/running/terminal states and stage checkpoints, not high-frequency progress.
- Mark interrupted jobs failed on restart; reopen saved project using existing tools.
- Fail closed if journal cannot be written; retain receipts for seven days.
- Test interrupted recovery, exclusive writer and terminal receipt.

Acceptance: exact-head macOS CI and actual forced termination. This is process-restart recovery evidence, not automatic resumption, power-loss durability or exactly-once provider billing.
