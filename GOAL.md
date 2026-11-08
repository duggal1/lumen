# /goal — autonomous loop with real proof

`/goal <objective>` runs the binding contract in `goal.yaml` via the `goal` agent
(`.opencode/agents/goal.md`) and the `.opencode/commands/goal.md` command.
The `goal-continue` plugin (`.opencode/plugins/goal-continue/`) re-prompts the
session on `session.idle` until DONE, BLOCKED, or BUDGET.

```sh
/goal fix the billing worker. Criteria: failed jobs retry 3x with backoff, a job is never charged twice, restart mid-job loses nothing
```

Typing `@goal.yaml <task>` still works too (attach the file via the composer).

## Before you run

- **Write criteria in the command.** The YAML derives them if you don't, but yours
  are sharper. They get frozen into `.proof/criteria.md` (never loosened).
- **Run on a clean git branch.** The stamp fingerprint and scope-diff check
  only mean something against a known starting point.
- **Dry-run tiny first.** Check `Tools/budget` and `Tools/prove` write `.proof/`
  correctly (e.g. `GOAL_PROOF_DIR=/tmp/goal-dryrun` + `PROVE_SKIP_PROJECT_CHECKS=1`)
  before pointing `/goal` at something big.
- **Don't add this to `AGENTS.md`.** That loads the contract every session and
  turns every small chat into a proof ritual.

## If it stops early

```
/goal resume the existing objective
```

State lives on disk (`.proof/criteria.md`, `.proof/progress.md`,
`.proof/budget.json`), so the agent resumes from it. If the `agent:` field
in the command ever gives trouble, delete that line and `.opencode/agents/goal.md`
— you still get the command.

## Costs and limits

- `goal.yaml` budget: 60 turns / 90 minutes / 3 approaches, enforced by
  `Tools/budget` (counts, not memory). Hitting one is a valid stop (BUDGET),
  not a failure. Mark terminal state with `Tools/budget stop done|blocked|budget`
  before the final `STATUS:` report.
- Agent cost wall: `steps: 300` in `.opencode/agents/goal.md`. On the final
  step OpenCode removes tools and asks for a text summary; new input resets the
  allowance. Tune `steps` after your first real run.
- Stronger reviewer: add a subagent file in `.opencode/agents/` with a different
  `model:`, then name it in `goal.yaml`'s independent-review prompt instead of
  "spawn a fresh-context subagent".

## Auto-continue

`goal.yaml` writes `tools/` lowercase; on macOS `tools/` and `Tools/` are the
same directory — scripts live in `Tools/` (existing repo convention).

`goal-continue` subscribes to `session.idle` and re-prompts goal sessions with
an active `.proof/budget.json`. It stops on terminal `STATUS:`, inactive
budget, limit hit, or 30s cooldown. Tune the cooldown or disable by removing
`.opencode/plugins/goal-continue/` (command/agent still work without it).
