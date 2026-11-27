# Goal tools

Two mandatory tools for `goal.yaml` runs, plus task-specific helpers on demand.

## `Tools/pulse`

Owns `.proof/pulse.json` (never hand-edit). **Not a kill switch** — it forces periodic re-orientation so long runs do not drift or forget. Run this **first every turn**.

```sh
Tools/pulse init                       # fresh run: new run id + start time (date -u)
Tools/pulse tick                       # every turn: turn+=1, print 'turn N, minutes M'; CHECKPOINT every 20 turns / 30 min. Never exits non-zero.
Tools/pulse approach "reason"          # log one abandoned approach; never stops
Tools/pulse status                     # print .proof/pulse.json
```

- There is **no hard budget stop** in v4. The only valid stops are DONE or BLOCKED. Hitting a checkpoint means re-read `criteria.md` + `progress.md`, write a 5-line status, and if the last 2 checkpoints show no criterion changed state, switch approach hard and continue. Same failure 3× means change approach, not stop.
- Proof dir override: `GOAL_PROOF_DIR=.proof` (e.g. `/tmp/goal-dryrun` for dry-runs).
- The `goal-continue` plugin only auto-continues goal sessions with `.proof/pulse.json` present and no terminal `STATUS:` yet.
- `init` starts a fresh pulse. For resume, do **not** re-init; the existing pulse continues.

Example:

```sh
Tools/pulse init          # once, on a fresh objective
Tools/pulse tick          # FIRST every turn
# ... one loop cycle ...
echo "- turn 1: did X / result Y / next Z" >> .proof/progress.md   # LAST every turn
Tools/pulse approach "tried X, abandoned because Y"   # when abandoning an approach; continue
```

`Tools/budget` was removed in v4. The old `.proof/budget.json` kill switch is gone; ignore any stale copy (new runs archive `.proof/` per `goal.yaml` run_start).

## `Tools/prove`

One command that re-runs proof from a clean state. Writes a fresh `.proof/<ts>/`
(`STAMP.txt`, logs, `MANIFEST.md`, screenshots/video as needed). Exit 0 only if
every criterion passes.

```sh
Tools/prove          # full proof run (default)
Tools/prove stamp    # print stamp only
```

- **Stamp**: UTC time + short git HEAD + working-tree fingerprint (tracked diff
  plus untracked files; if no git, a hash of the source files). Recomputed at the
  end; a mismatch means the code changed after the proof (stale → exit 1).
- **Core checks**: project build + test (Makefile `build`/`test` if present,
  else `swift build`/`swift test`), each wrapped with `PROVE_TIMEOUT` (120s).
  Env: `GOAL_PROOF_DIR=.proof`, `PROVE_TIMEOUT=120`,
  `PROVE_SKIP_PROJECT_CHECKS=1` (dry-run only).
- **Criteria**: every `- ` bullet in `.proof/criteria.md` must be annotated `PASS`.
  `FAIL` / `UNVERIFIED` / blank → exit 1. `UNVERIFIED` is never `PASS`.
- **Task steps**: if `.proof/proof-steps.sh` exists it's run (timeout-wrapped)
  and its log saved as `proof-steps.log`. Put task-specific proof steps there.
- Prints the PASS/FAIL table and writes `MANIFEST.md` (one row per artifact +
  one row per criterion). Keep secrets out of artifacts — redact before saving.

## As needed (not built yet — build per task, one job per tool)

- `drive` — real user actions (HTTP/CLI/browser/macOS UI) on the running system
- `seed` — known state in, clean reset out
- `probe` — read state without side effects (DB/queue/logs/process status)
- `assert` — check ONE criterion, print `PASS`/`FAIL` with evidence, exit code
- `shot` — screenshot the relevant window/page/terminal
- `rec` — short video (3–10s) of one key flow

Rules: executable scripts in `./tools/` called via bash, one job per tool,
structured output (JSON preferred), non-zero exit on failure. Document each
new tool here the moment you create it. Hold no secrets; never touch production
or anything outside scope.

## Agent autonomy target-Mac proof

Run `bash Tools/agent-autonomy-proof.sh chrome.lumen truth.json 40s-project.lumen /new/proof-directory` on the target M1/8 GiB Mac. Follow its printed Studio launch command using a build from the exact checkout. Play for at least 12 uninterrupted seconds; then run the printed Python gate. The gate checks local media evidence only. Actual forced-restart and cinematic review remain separate release criteria.
