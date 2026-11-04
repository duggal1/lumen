# Agentic Backend Pipeline: Build Spec

Goal: agents that reliably solve **hard backend work** (migrations, concurrency,
money, auth, data integrity) with as few moving parts as possible.

## The one idea

A model doesn't need a smarter process. It needs an **oracle**: a frozen,
executable definition of "done" written *before* any code exists. Everything
else is a loop that runs until the oracle says yes. Plan mode, tests, and spec
clarity all come out of that single mechanism.

## Principles

- KISS. Boring, proven tools. If a step doesn't catch a real failure, delete it.
- Orchestrator is plain code (a few hundred lines). No state machine library, no framework.
- LLMs only for judgment: plan, implement, review.
- Plan mode for non-trivial work, then **execute without asking permission**.
- Humans are pulled in only at the escalation points below, plus the merge gate for risky changes.

## Pipeline

```
Spec -> Plan + Oracle -> Implement loop -> Review -> Ship
        (full mode)      (until green)    (full)
```

One run = one `runs/<id>.json` file (mode, plan path, oracle results per
iteration, review output, tokens, time, outcome). That is the entire
observability story.

## 0. Mode

Two modes. No scoring.

- `quick`: single-file or obvious fix, UI tweak, copy change. Implement, run checks, ship. **No plan.**
- `full`: everything else. Plan + Oracle, review, the works.

The agent picks the mode. **Risk paths force `full` + `gated`.** List them once
in `pipeline.config` as globs: `migrations/**`, `**/auth/**`, `**/billing/**`,
webhook handlers, anything touching money or PII. One glob match, no heuristics.
Over-picking `full` costs tokens only. Under-picking is what the risk-path rule prevents.

## 1. Plan + Oracle (full mode)

One call to the strongest model. Output `plans/<id>.md` (target under ~600
tokens) plus **acceptance test files**.

### Plan template

```
# Plan: <title>
## Goal (2-3 lines)
## Non-goals
## Invariants (must always be true)
## Failure modes (retry, concurrent request, partial failure, bad input) and expected behavior
## Approach (a few lines, not a restatement of the spec)
## Steps (ordered; each has a Verify command)
## Files
```

### Backend prompt checklist (content for the planner, not extra stages)

The planner must explicitly address, where relevant:
- transaction boundaries and isolation level
- idempotency keys and safe retries
- locking / race conditions between concurrent requests
- ordering guarantees and partial-failure behavior
- timeouts and external call failure
- migration safety: lock time, backfill, rollback
- indexes and query plans for new queries (no N+1, no unbounded reads)
- authz checked on every path, not just the happy one

### Oracle rules

- Acceptance tests are written **now**, from the spec, before implementation.
- Orchestrator runs them first and confirms they **fail (red)**. A test that passes before any code exists is vacuous or the work is already done. Flag it.
- Every invariant and every failure mode gets at least one test.
- Concurrency and idempotency get a **real parallel test** (N simultaneous requests), not a comment or a mock.
- Run against **real Postgres**, ephemeral per run (Neon branch or local container). Do not mock the database for backend logic.
- Migrations: test forward on a realistic populated snapshot, and test rollback.
- Once committed, these files are **frozen**. The orchestrator rejects any implementer diff that touches them.
- If a requirement can't be expressed as a test, the **spec is ambiguous**. That's escalation trigger #1.

After this step passes, **execute without asking permission**.

## 2. Implement loop

- Isolated git worktree and branch: `agent/<id>`.
- Input: spec, plan, oracle test paths, `AGENTS.md` (conventions), curated relevant files. Never the whole repo.
- Loop: edit -> run oracle + typecheck + lint + existing suite -> read **trimmed** failure output -> fix. Repeat until green.
- Run each plan step's Verify command as you go so errors surface early, not at the end.
- Frozen tests are read-only. Plan deviations are allowed only inside Goal and Non-goals; log one line per deviation.
- `quick` mode: same loop, no oracle, just the existing checks.

### Stuck rule (the only retry logic)

If the same failure signature appears twice in a row, stop that approach and
**replan once** (fresh planner call with the failure output). If it gets stuck
again, escalate. No other retry counters.

## 3. Review (full mode only)

- One reviewer, **fresh context**: spec + plan + diff only, never the implementer's reasoning. Different model than the implementer if available.
- Scope: only what tests can't prove. Security, authz gaps, data-loss paths, race conditions the oracle didn't cover, perf traps, and scope creep against Non-goals.
- Output structured JSON: `{ verdict, issues: [{severity, file, line, problem, fix}] }`.
- `blocker` or `major` goes back to the implementer **once**. Still failing => escalate.

Automatic flags (plain code, no LLM), sent to the reviewer as blockers to justify:
- any attempt to change a frozen test
- any deleted or weakened existing test
- any new dependency
- any file changed outside the plan's Files list

## 4. Ship

- Fetch and rebase on base. If base moved, re-run all checks.
- Ungated (`quick`, non-risk `full`): auto-merge when green and review is clean.
- **Gated (risk paths): open a PR, do not merge.** PR contains the plan, oracle results, review output, and a 5-line "what to check" summary. A human merges. Autonomy covers execution. Humans own irreversible merges.
- Git rules, non-negotiable (shared repo, multiple agents):
  - commit after every task, messages 6-12 words, direct and human
  - check status and pull before pushing
  - never `git reset` or `git restore` without explicit human permission
  - if no repo or remote is configured, ask before committing

## Guardrails

- **One budget per run:** max tokens and max wall-clock. Hit either => stop, save state, escalate.
- Writes only inside the worktree. Destructive commands blocked.
- Never connect to a real production database. The oracle DB is always ephemeral.
- Secrets never logged or committed.

## Escalation (the only times a human is asked)

1. A requirement can't be turned into a test (ambiguous spec).
2. Budget hit, or the stuck rule failed twice.
3. Irreversible action needed (dropping data, force-push, real-data migration).

Escalation output: what was tried, current state, the one specific question,
and a recommended default answer.

## Evals (what separates a design from a system)

`evals/` holds **15-20 real past tasks**: spec, repo commit, and **held-out
acceptance tests the pipeline never sees**.

- `bun run evals` runs the pipeline on all of them and reports pass rate, tokens, time, escalations.
- Rerun on any change to prompts, models, or rules. A change that lowers the pass rate doesn't ship.
- Include a few genuinely hard backend cases: a race condition, a migration on a populated table, an idempotent webhook, a query perf regression.

## Build order

1. Orchestrator skeleton: run.json, worktree, check runner (trimmed failures), ship. `quick` mode end to end.
2. Implement loop with budget and stuck rule.
3. Plan + Oracle: red check, frozen-file enforcement, ephemeral Postgres.
4. **First 3 eval tasks now**, before going further.
5. Reviewer + automatic flags.
6. Gated PR path.
7. Fill out evals to 15-20.

Add nothing new until evals show a failure class that it would fix.