# /goal — autonomous loop with real proof

`/goal <objective>` runs the binding contract in `goal.yaml` via the `goal` agent
(`.opencode/agents/goal.md`) and the `.opencode/commands/goal.md` command.
The `goal-continue` plugin (`.opencode/plugins/goal-continue/`) re-prompts the
session on `session.idle` until DONE or BLOCKED.

```sh
/goal fix the billing worker. Criteria: failed jobs retry 3x with backoff, a job is never charged twice, restart mid-job loses nothing
```

Typing `@goal.yaml <task>` still works too (attach the file via the composer).

## The built-in 4000 limit (and why you saw it)

OpenCode ships a built-in `/goal` with a hardcoded objective limit
(`A goal objective is limited to 4000 characters`) compiled into the
`opencode` binary — there is no config option to change it. The project
command above **replaces** it in this repo, so in `studio` there is no
4000 check (verified: a 69931-char objective succeeds via the project
command). You hit the limit only if the built-in ran instead — that
happens when OpenCode is launched outside `studio/` (project
`.opencode/` not loaded) or before a `/reload`. Fix: launch from
`studio/`, run `/reload` if the command list looks stale
(`/goal` shows "Autonomous goal loop with real proof"), and keep
objectives in files (below). You cannot remove the binary limit; you
bypass it by using this project's command.

## Long objectives

Objectives over ~3000 characters belong in a file, not the command line:

1. Write the full text to `.proof/objective.md`.
2. Run `/goal read .proof/objective.md — <short summary> <criteria>`.
3. The agent reads the file in full, freezes criteria from it.

This avoids both the built-in limit and a 69KB inline prompt.

## Before you run

- **Write criteria in the command.** The YAML derives them if you don't, but yours
  are sharper. They get frozen into `.proof/criteria.md` (never loosened).
- **Run on a clean git branch.** The stamp fingerprint and scope-diff check
  only mean something against a known starting point.
- **Dry-run tiny first.** Check `Tools/pulse` and `Tools/prove` write `.proof/`
  correctly (e.g. `GOAL_PROOF_DIR=/tmp/goal-dryrun` + `PROVE_SKIP_PROJECT_CHECKS=1`)
  before pointing `/goal` at something big.
- **Don't add this to `AGENTS.md`.** That loads the contract every session and
  turns every small chat into a proof ritual.

## If it stops early

```
/goal resume the existing objective
```

State lives on disk (`.proof/criteria.md`, `.proof/progress.md`,
`.proof/pulse.json`), so the agent resumes from it. Every other invocation
(without `resume`) is a NEW RUN: `goal.yaml` `run_start` archives `.proof/*`
to `.proof/archive/<UTC-timestamp>/` and starts fresh. If the `agent:` field
in the command ever gives trouble, delete that line and `.opencode/agents/goal.md`
— you still get the command.

## Costs and limits

- v4 has **no hard budget stop**. `Tools/pulse` (`turn N, minutes M` + CHECKPOINT
  every 20 turns / 30 min) only forces re-orientation, never exits non-zero,
  never says stop. The agent knows nothing about token/cost budgets and never
  guesses about them. The only valid stops are DONE or BLOCKED (human-only
  blocker, or a harness/provider error, quoted).
- Agent cost wall: `steps: 2000` in `.opencode/agents/goal.md` (deliberate
  backstop, raised from 300). On the final step OpenCode removes tools and asks
  for a text summary; new input resets the allowance. Tradeoff: with the cost
  cap removed a stuck run can burn credits until you interrupt it — `steps: 2000`
  is the only backstop, picked on purpose instead of left off by accident.
  If the stop was a provider error (rate limit, out of credits), top up or
  switch models; no YAML can override that.
- Stronger reviewer: add a subagent file in `.opencode/agents/` with a different
  `model:`, then name it in `goal.yaml`'s independent-review prompt instead of
  "spawn a fresh-context subagent".

## Auto-continue

`goal.yaml` writes `tools/` lowercase; on macOS `tools/` and `Tools/` are the
same directory — scripts live in `Tools/` (existing repo convention).

`goal-continue` subscribes to `session.idle` and re-prompts goal sessions with
`.proof/pulse.json` present. It stops on terminal `STATUS:` (DONE or BLOCKED)
or 30s cooldown. Tune the cooldown or disable by removing
`.opencode/plugins/goal-continue/` (command/agent still work without it).
