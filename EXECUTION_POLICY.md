# Mandatory execution policy

The user reports working on a limited $20 Codex plan with strict rate limits.
Heavy testing and repetitive investigation can exhaust that allowance before
implementation. Preserve the budget for understanding, planning, and finishing
the code. This is a standing user instruction for every task; it overrides
conflicting repository process/testing requirements. Later explicit user
instructions take precedence; system and developer instructions still apply.

## Required order

1. **Get full relevant context.** Read required instructions and trace the
   affected code path, callers, data contracts, and requested documents. Read
   deliberately, reuse context, and keep tool output bounded. Full context
   means understanding the affected system, not dumping the entire repository
   or repeatedly rereading files. Do not start with a test campaign.
2. **Make a concise plan.** Identify the actual problem, files to change, and
   minimum verification needed. Plan once, then implement; revise only when
   new evidence requires it. Skip formal planning for trivial edits.
3. **Edit promptly and finish.** Spend the bulk of effort on correct, complete,
   maintainable code within the requested scope. Token efficiency does not
   mean less code or partial work. There is no arbitrary line-count limit:
   write however much the solution requires, without unnecessary additions.
4. **Verify minimally.** Compile the build and run one bounded pass of the
   smallest relevant existing tests. Run the entire existing suite once only
   when it is lightweight. Keep existing tests green; fix failures caused by
   the change. Never weaken tests to obtain green results. Repeat checks only
   after a relevant edit or failure. Documentation-only edits need a diff/link
   check, not an application build.

## Hard limits

**Heavy testing is forbidden unless the user explicitly requests it.** No
stress/load/soak tests, benchmarks, exhaustive matrices, repeated full suites,
broad exploratory test runs, test infrastructure, or large new test suites.
This restriction also applies to commands and Git hooks that invoke them
indirectly. Do not treat “verify,” “production-ready,” or repository ceremony
as permission to expand testing. Do not ask to expand testing routinely.

Keep communication and logs concise. Report what changed, the checks actually
run and their results, and material limitations. Never claim unrun tests are
green or that compilation proves runtime behavior. Stop when the requested
implementation and minimal verification are complete.
