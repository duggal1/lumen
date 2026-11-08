---
description: Autonomous goal loop with real proof
agent: goal
---

Follow goal.yaml exactly. It is binding. Read goal.yaml, .proof/criteria.md, .proof/progress.md, .proof/budget.json FIRST (rebuild state if missing or unreadable per goal.yaml state.rule). Start immediately. Do not recap the contract.

OBJECTIVE: $ARGUMENTS

If OBJECTIVE is empty, use goal.objective from goal.yaml. If it starts with resume, keep .proof/criteria.md frozen and continue from .proof/progress.md.
