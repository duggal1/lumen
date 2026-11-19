# Lumen promo (Remotion)

One composition, props in, MP4 out. No template engine, no second animation system.
60 fps. Compositions: `Promo-16x9` (1920×1080) and `Promo-9x16` (1080×1920).
PNG frame format is set in `remotion.config.ts`. All copy comes from props; the
values in `Root.tsx` are documented defaults only.

## Install

All `remotion*` packages are pinned to the exact same version, `4.0.545`.

```
npm install
```

Exact output of the single install performed while building this feature
(Node v26.4.0, npm 12.0.2, network available):

```
added 247 packages, and audited 248 packages in 17s

48 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities
npm warn install-scripts 1 package had install scripts blocked because they are not covered by allowScripts:
npm warn install-scripts   esbuild@0.28.1 (postinstall: node install.js)
npm warn install-scripts
npm warn install-scripts Run `npm install-scripts ls` to review, or `npm install-scripts approve <pkg>` to allow.
```

## Typecheck

```
npx tsc --noEmit     # clean, no diagnostics
./node_modules/.bin/tsc --noEmit   # exit 0, no diagnostics (confirmation)
```

## Files

- `package.json` — pinned deps and the three npm scripts.
- `tsconfig.json`, `remotion.config.ts`, `src/index.ts` — C1.
- `src/Root.tsx` — C2, two compositions, duration derived from props.
- `src/Promo.tsx` — C3, the whole promo (hook → demo → outro).
- `props.json`, `props.9x16.json` — C4.
- `render.sh` — C5, the one render entry point.
- `.gitignore` — `node_modules/`, `out/`, `public/demo.mp4`.

## Commands

```
npm run studio
npm run render:16x9
npm run render:9x16
```

`render.sh` is the single scripted path for a real demo:

```
./render.sh <exported-demo.mp4> <duration-sec> [props.json]
```

It copies the demo to `public/demo.mp4`, writes a temp props file with
`demoDurationSec` patched to the supplied duration, chooses `Promo-9x16` when
the props' `demoAspect` is below 1 and `Promo-16x9` otherwise, renders to
`out/promo-16x9.mp4` or `out/promo-9x16.mp4`, then removes the temp file. Example:

```
ffprobe -v error -show_entries format=duration -of csv=p=0 ~/Movies/lumen-export.mp4
./render.sh ~/Movies/lumen-export.mp4 42.5 props.json
```

Manual equivalent without the script:

```
cp ~/Movies/lumen-export.mp4 public/demo.mp4
# set demoDurationSec in props.json to the probed duration
npm run render:16x9
```

## Adaptations and risks (one line each)

- Pinned all `remotion*` packages to the exact current 4.x release `4.0.545` (confirmed via `npm view`); the spec gave no version.
- `OffthreadVideo` `startFrom`/`endAt` are deprecated in 4.0.545 while `trimBefore`/`durationInFrames` are current (`@deprecated` JSDoc confirmed in installed types); switched to `trimBefore={from} durationInFrames={demoF}` with identical semantics.
- Removed the hard-coded `durationInFrames={600}`: each Composition now uses `timing(defaults).total`, while `calculateMetadata` derives the real duration from the incoming props on every render.
- Added `lib`/`noEmit` and an `include` list to the supplied `tsconfig.json` so `tsc --noEmit` checks exactly the promo sources.
- `render.sh` selects the composition from `demoAspect` and uses a temp props file, so one script serves both aspect ratios; `demoSrc` stays `demo.mp4` in both props files because the script always writes that path.
- `npm` 12 blocked the `esbuild` postinstall (`install-scripts` allowlist); the JS API still works for typechecking, but if a render reports a missing esbuild binary, run `npm install-scripts approve esbuild` and reinstall.
- Added `typescript` and `@types/react` as devDependencies (still within the allowed dependency list); React pinned to 18.3.1.
- Caption sizing is estimated at 0.56 em per glyph (`layoutLines`); check the first real render for clipping or loose fit.
- Lumen masters are Display P3 and Remotion renders sRGB; export the demo as sRGB/BT.709 for this path to avoid desaturation.
- No demo footage was supplied, so no full video render was performed and visual output is unverified.
- Render time is minutes per minute of output at 1080p60 with PNG frames; exact figure depends on the Mac.
