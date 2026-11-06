# Lumen reliability console

This is the standalone, deployed engineering tracker for [duggal1/lumen](https://github.com/duggal1/lumen), living in `lumen-tracker/`. It never renames or modifies native Swift source directories.

## Facts and source-of-truth

- **Live GitHub issues** are fetched from the GitHub Issues REST API and shown separately from source-audit findings.
- **Audit findings** are a labeled Nov 6, 2026 snapshot. They are not fabricated GitHub issue numbers or device test results.
- **Merged**, **CI passed**, and **runtime verified** remain separate states. Github metadata is refreshed on demand.
- The currently inspected native repository uses `Sources/`, not `studio/`. The tracker preserves real paths.
- "Paste" in Lumen is an unverified feature boundary, not a confirmed bug.
- Notes, custom audit entries and regression history are local to your browser. Export JSON to move them; no shared database exists.

## Real GitHub integration

Select **Connect GitHub**, create a fine-grained token scoped to `duggal1/lumen` with **Issues: Read and write**, paste it in the in-app connection dialog, and verify. The token exists only in tab memory (not localStorage or a server database) and is forwarded over HTTPS to GitHub by `api/github.js`. Refreshing the tab disconnects it.

To create a real GitHub issue: **Create issue** → add concrete observations and reproduction → use the manual template or AI → review Markdown → **Publish GitHub issue**. On success the app shows the actual GitHub issue number and canonical link returned by GitHub. It does not create placeholder issues or silently post.

Creating issues is never attempted without the user clicking Publish. GitHub enforces repository permissions, and GitHub may reject duplicates or rate-limit writes.

## Reflection Beam issue writer

`api/ai.js` streams an issue-body draft using `Beam-1.0-501B-A23B`, using the documented OpenAI-compatible Reflection API. No invented files, metrics, root causes or CI status. Generation leaves the draft editable; users must explicitly publish it.

To enable AI choose either:
1. Enter your own `REFLECTION_API_KEY` in the in-app issue composer. It is kept in tab memory only and forwarded through the Vercel function without storage.
2. Configure a production Vercel server environment variable named `REFLECTION_API_KEY` in the project's settings. To prevent anonymous consumption of the owner's credits, server-backed generation requires GitHub authentication as `duggal1`.

**Do not commit secrets or put keys in query strings, localStorage, public Javascript or this README.** The repository and Vercel Git integration do not automatically grant authentication to end-users of the deployed website.

Without a Reflection key, the manual Markdown template and GitHub publishing still work.

## UI

Only sans-serif text with tight tracking. The Lumen wordmark and icon are copied from `App/public/assets/brand/logo`. The GitHub mark is the official Primer Octicon; navigation uses pinned Phosphor web icons. Dark surfaces, orange translucent badges, green field-focus indication, no card borders.

## Verification

`npm run check` performs script syntax checks. Production smoke tests should cover GET /, GET /styles.css, GET /integrations.js, GET /api/github?resource=issues, unauthenticated POST /api/github returns 401, and AI without an API key returns a documented 422/401. Authorized GitHub issue creation and Reflection generation require credentials and should never be simulated as successes.

Linked Vercel root directory: `lumen-tracker/`; production branch: `main`.
