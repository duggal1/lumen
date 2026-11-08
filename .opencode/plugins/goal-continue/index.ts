import { Plugin } from "@opencode/plugin"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

const CONTINUE_TEXT =
  "Continue the goal loop. Re-read goal.yaml, .proof/criteria.md, .proof/progress.md, .proof/budget.json (rebuild state if missing per goal.yaml state.rule). Run Tools/budget tick first, then do exactly one loop cycle (plan/build/run_for_real/verify/fix), append one line to .proof/progress.md, and stop only on DONE, BLOCKED, or BUDGET per goal.yaml. Only emit a final STATUS report on DONE, BLOCKED, or BUDGET."

function extractLastAssistantText(messages: unknown): string {
  if (!Array.isArray(messages) || messages.length === 0) return ""
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i] as any
    if (!m || m.type !== "assistant" || !Array.isArray(m.content)) continue
    const texts = m.content
      .filter((c: any) => c?.type === "text" && typeof c?.text === "string")
      .map((c: any) => c.text)
    if (texts.length > 0) return texts.join("\n")
  }
  // Fallback for shape drift: search stringified tail.
  try {
    return JSON.stringify(messages.slice(-3))
  } catch {
    return ""
  }
}

export default Plugin.define({
  id: "goal-continue",
  setup(ctx) {
    const controller = new AbortController()
    const lastPrompt = new Map<string, number>()

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: ["session.idle"],
          signal: controller.signal,
        })) {
          const ev: any = event as any
          const sessionID: string | undefined = ev?.data?.sessionID ?? ev?.properties?.sessionID
          if (!sessionID) continue
          try {
            // Only goal-agent sessions auto-continue.
            const session = (await ctx.session.get({ sessionID })) as any
            if (session?.agent !== "goal") continue

            // No active goal budget => not a goal run.
            const budgetPath = join(ctx.location.directory, ".proof", "budget.json")
            if (!existsSync(budgetPath)) continue
            let budget: any
            try {
              budget = JSON.parse(readFileSync(budgetPath, "utf8"))
            } catch {
              continue
            }
            if (budget?.status && budget.status !== "active") continue

            const limits = budget?.limits ?? {}
            const maxTurns = limits.max_turns ?? 60
            const maxMinutes = limits.max_minutes ?? 90
            const maxApproaches = limits.max_distinct_approaches ?? 3
            if (typeof budget?.turn === "number" && budget.turn >= maxTurns) continue
            if (typeof budget?.approaches === "number" && budget.approaches >= maxApproaches) continue
            if (typeof budget?.start_epoch === "number") {
              const elapsed = Math.floor((Date.now() / 1000 - budget.start_epoch) / 60)
              if (elapsed >= maxMinutes) continue
            }

            // Terminal final report already emitted => stop.
            const messages = (await ctx.session.context({ sessionID }).catch(() => [])) as unknown
            const text = extractLastAssistantText(messages)
            if (/STATUS:\s*(DONE|BLOCKED|BUDGET)/.test(text)) continue

            // Cooldown to avoid tight re-prompt loops on fast failures.
            const now = Date.now()
            if (now - (lastPrompt.get(sessionID) ?? 0) < 30_000) continue
            lastPrompt.set(sessionID, now)

            await ctx.session.prompt({ sessionID, text: CONTINUE_TEXT, delivery: "queue" })
          } catch {
            // Ignore per-event errors; never break the subscription loop.
          }
        }
      } catch {
        // Subscription ended (unload/shutdown).
      }
    })()

    return () => controller.abort()
  },
})
