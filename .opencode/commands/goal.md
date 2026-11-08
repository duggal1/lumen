---
description: Autonomous goal loop with real proof
agent: goal
---

Follow goal.yaml exactly. It is binding. Read goal.yaml, .proof/criteria.md, .proof/progress.md, .proof/budget.json FIRST (rebuild state if missing or unreadable per goal.yaml state.rule). Start immediately. Do not recap the contract.

OBJECTIVE: $ARGUMENTS

If OBJECTIVE is empty, use goal.objective from goal.yaml. If it starts with resume, keep .proof/criteria.md frozen and continue from .proof/progress.md.

Long objectives: if the objective text is over 3000 characters, write the full text to .proof/objective.md FIRST, then run the loop with OBJECTIVE pointing at that file (read it in full) plus a short summary inline. Never paste tens of thousands of characters inline as the objective.
