# Lumen reliability console

A compact static dashboard for reliability triage of the **duggal1/lumen** macOS screen-recording app.

## Source boundaries

- Ships under \`lumen-tracker/\` and does not modify the macOS recording app.
- Current GitHub main uses \`Sources/\` paths. No rename to \`studio/\` is performed. If the native app is later moved to \`studio/\`, update evidence paths after inspecting the actual commit.
- A merged PR is not equivalent to a passing CI run; a CI pass is not proof of hardware/runtime behavior.
- Initial issue entries are explicitly a GitHub-backed snapshot of Nov 6, 2026; inferred causes are labeled tentative/unknown.
- The "paste" entry is a scope check, not a confirmed Lumen feature.

## Features

Searchable priority issue map; precise reproduction and suspected causes; modules and source links; build gate; quick next-three queue; coding-agent work orders; regression notes; local export/import; live GitHub PR/CI verification.

## Persistence and privacy

Only the user’s browser localStorage stores edits and regression entries. There is **no shared database, login or server write endpoint**. Export JSON to back up or move records. GitHub public REST endpoints are used read-only from the browser; rate limits and offline use are handled by keeping snapshot data clearly marked.

## Deployment

Link this repository to Vercel with **Root Directory: \`lumen-tracker\`** and Framework Preset **Other**. The site is pure HTML/CSS/JS, so no build command, runtime secrets, or package install is needed.

## Testing

Desktop and mobile browse smoke test, search/filter, issue selection, work-order copy, save evidence note, regression add/export/import and GitHub synchronization. Verify the URL returns HTTP 200. CI results always link to the actual GitHub workflow.