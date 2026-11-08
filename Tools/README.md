# Goal tools

Two mandatory tools for `goal.yaml` runs, plus task-specific helpers on demand.

## `Tools/budget`

Owns `.proof/budget.json` (never hand-edit). Run this **first every turn**.

```sh
Tools/budget init                       # fresh run: record start (date -u), zero counters, status=active
Tools/budget tick                       # every turn: turn+=1, print 'turns X/Y, minutes A/B', STOP+exit 1 over limit
Tools/budget approach "reason"          # log one abandoned approach; STOP+exit 1 when count reaches max
Tools/budget status                     # print .proof/budget.json
Tools/budget stop done|blocked|budget   # mark terminal status (call before final STATUS report)
```

- Limits frozen at `init`: `GOAL_MAX_TURNS` (60), `GOAL_MAX_MINUTES` (90), `GOAL_MAX_APPROACHES` (3) — matching `goal.yaml`. Change defaults via env at `init` only.
- Proof dir override: `GOAL_PROOF_DIR=.proof` (e.g. `/tmp/goal-dryrun` for dry-runs).
- `status` is `active` until `stop` or a limit hits (`budget`). The `goal-continue` plugin only auto-continues `active` budgets.
- Same-failure (3×) counts as one abandoned approach; two no-progress turns stop — the agent judges, `approach` records.
- `init` resets the budget. For resume, do **not** re-init; the existing budget continues.

Example:

```sh
Tools/budget init          # once, on a fresh objective
Tools/budget tick          # FIRST every turn
# ... one loop cycle ...
echo "- turn 1: tried X / happened Y / next Z" >> .proof/progress.md   # LAST every turn
Tools/budget approach "tried X, reason Y"   # when abandoning an approach
Tools/budget stop done     # before the final STATUS: DONE report
```

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
