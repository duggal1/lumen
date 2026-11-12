# Plan: Crash recovery reliability

## Goal
Make crash recovery durable across process termination, partial writes, and repeated recovery attempts. Keep recording capture responsive while persistence and recovery I/O run outside latency-sensitive work.

## Non-goals
Change video encoding, audio processing, recovery UI design, or recording formats.

## Invariants
- A failed journal write is observable and leaves the previous atomic checkpoint intact.
- Checkpoints validate before use; corrupt or unsupported journals remain available for explicit discard.
- Finalization waits for any journal write before saving the finished project and removing the journal.
- Recovery saves the project before clearing the journal and safely returns an already-published project on retry.
- Recovery and discard file operations do not block the main actor or run twice concurrently for one bundle.

## Failure modes and expected behavior
- Disk full or permission failure: retain the prior checkpoint, report/log the failure, and fail startup if its initial checkpoint cannot be established.
- Process termination during recovery: the atomic project file or original journal remains, allowing retry.
- Corrupt journal: recovery reports a readable error; the recovery card remains so the user can discard the bundle.
- Duplicate recover/discard action: ignore while that bundle already has an operation in flight.

## Approach
Harden journal validation and result handling, make recovery idempotent, order journal lifetime with capture/finalization, and move recovery bundle I/O off the UI actor.

## Steps
1. Harden journal validation, atomic writes, clear semantics, and recovery retries. Verify with `swift build -c release`.
2. Establish a checkpoint before capture, persist snapshots away from actor-critical work, and await journal shutdown before final publication. Verify with `swift build -c release`.
3. Run recovery/discard off the main actor with per-bundle duplicate suppression and surfaced errors. Verify with `swift build -c release`.

## Files
- `Sources/LumenProject/Composition.swift`
- `Sources/LumenCapture/Session.swift`
- `Sources/LumenUI/AppModel.swift`
