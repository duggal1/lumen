# UI map — every screen, where style comes from (read, no edits yet)

Screens read line-by-line for style sources. Colors: all `Tok.*` in `DesignSystem.swift` (single source; grep finds no `Color(hex` outside it except `Tok` defs + `DebugHarness` red/yellow tags + `AppModel` HUD cursor). Padding: `Space.s1..s16` + `Metrics.pagePad=32/cardPad=20/pageBar=52`; hardcoded `.padding(12/16/20/24/32)`, `.padding(.horizontal,12/10)` remain in Components/Library/Inspector/LiveCaptions/ExportInspector (violations to normalize to the shared container). Type: `AppType` (system + `page/onboarding` serif-italic only for Library/Editor titles); timeline ruler/scale use `.system.monospacedDigit()` direct. Icons: SF Symbols via `Image(systemName:)` everywhere; `PixelLens/Pixel*` in `PixelMarks.swift` is the only pixel-art source (New recording header `PixelLens`, activity dots, HUD waveform). Scroll: `ScrollView`s in Library/Inspector/Export — indicators not explicitly hidden (grep: no `scrollIndicators`).

## Window setup (`LumenApp.swift:1-36`)

`Window("Lumen") defaultSize 1280x820 hiddenTitleBar contentMinSize` + `Editor WindowGroup(for: URL) defaultSize 1280x820`. No `setFrame` clamp to visible frame on launch; SwiftUI restores saved frame. Root cause for Fix 1 (top-right/off-screen): restored frame is only valid if fully on-screen; code never validates. Editor now has `defaultSize` (was missing per older audit).

## Shell / sidebar (`Shell.swift`)

`LumenShell`: HStack sidebar (220) + detail on `Tok.bg`, overlay `SidebarToggle` at `leading 72 top 12`. Sidebar: `SidebarMaterial` (NSVisualEffect sidebar/behindWindow — the only translucent surface, picks wallpaper per shot 6) + rows 32pt, pill `Tok.washStrong`. Toggle 28pt `sidebar.left` 12pt. Traffic lights are window chrome (hidden titlebar), toggle in overlay not in toolbar → overlap when open/closed.

## Library (`LibraryView.swift`, `LibraryCards.swift`, `MonthGraph.swift`)

`LibrarySurface` inside `LibraryRoot`. `PageBar(title: "Library")` serif `AppType.page` + orange `Record` (primary `Tok.accent`) + `Import`. Body: stats card (Recorded/Projects/Exported/Streak), `ActivityCard` (MonthGraph single row 45 dots Nov 2026), Recent rows (`ProjectThumb`, `PixelBadge`), `Where you record`. Inset: `PageBar` uses `Metrics.pagePad=32` horizontally, body uses its own inner `padding(Metrics.pagePad)` + `frame(maxWidth:960)` + `frame(maxWidth:.infinity)` double-frame (left-pinned, dead right — A1-b). Stats row: `HStack(alignment:.top)` + `minimumScaleFactor(0.7)` (A1-c). Failed row still shows duration/output (A3). Orange dot after `Library.` is `Tok.accent` text accent in `PageTitle` (Fix 3).

## New recording dialog (`AppModel.swift` NewRecordingSheet)

`LDialog` 480 wide, `Tok.surface`, `PixelLens` + title/subtitle. Tabs Capture/Audio `LSegmented`. Capture: Display/Window/Area segmented + display `LDropdown` + Frame rate segmented 30/60/120 (120 offered unconditionally — no probe check; Fix 8). Audio tab: mic row (default-mic single line "Using the system default microphone." only), System audio / Webcam toggles (`LToggle`), Microphone test glyph (generic plus, not SF semantic). Scroll filtering vertical in dialog; indicators not hidden, toggles clip at trailing edge (shot 2). Selected segmented thumb `Tok.control` low contrast. Header icon is `PixelLens` jagged pixel icon (Fix: SF Symbol one weight).

## Editor (`EditorView.swift`, `PreviewView.swift`, `Inspector.swift`, `TimelineStrip.swift`)

`EditorView`: VStack `PageBar(title: displayName)` (serif + orange dot) + undo/redo/`sidebar.right` + `Export` primary orange. Body HStack: preview `GeometryReader` aspect-fitted + `PreviewView` clip `Radius.card` (white card = exported backdrop style, leave alone) + `transport` row (`Play/Pause`, `fmt(playhead)/fmt(duration)` monospaced, `Cut`/`Add zoom`/`Tools` with `ViewThatFits`) + `TimelineStrip` 128 tall. Preview padding 16, inspector fixed 320 `Inspector` dropdown tab selector (default `.look`). White backdrop card: `BackgroundStyle`/`PhotoBackground` exported style, not chrome. Title says `Screen recording.` → Fix 4 renames to `Lumen Studio`, no dot. Right edge: preview `padding(16)` + inspector 320 inside `GeometryReader` — no shared page inset; Export vs inspector overlap in shot 5 (export panel fullscreen, cards run past container width — container bug in `ExportInspector`, not timeline).

## Inspector (`Inspector.swift` 879 lines, `ExportInspector.swift`, `LiveCaptions.swift`)

`Inspector` tab selector (Look/Tools/Cursor/Camera/Audio/Webcam/Captions/Export), rows `Row/SliderRow/ToggleRow`, `LSlider`, `LDropdown`, `LActionMenuButton`. Transcript panel `LiveCaptions`: Model picker, `Render captions...` toggle (off default), Model files Installed/Import, word count, timestamp rows (active row full-bleed orange-tint fill, first row clipped under header, `So does work.`/`work.` duplicates in shot 4). Tools panel `Inspector.Tab.tools` (Add loupe/tap, Import clip...) — inherits theme only.

## Export panel (`ExportInspector.swift`)

Quality/Audio/Also 1:1/Transparent/Separate cursor/WAV stems/Location/Filename/Estimate. Shot 5: Quality/Location cards to right edge, Estimate short — ScrollView/content wider than container, no clamp to visible frame; window is fullscreen (no traffic lights) so width comes from content. Fix at container, not per-card padding.

## HUD + capture (`AppModel.swift` HUDController/HUDView, `LivePreview.swift`)

Borderless panel, `fitToContent` sizes (countdown vs controls). Timer 78pt tabular, Pause/Discard/Stop, `LiveWaveform` 160pt. Discard already removed in earlier pass. Input Monitoring prompt at `RecordingSession.start`. Waveform HUD driven by live levels (see PixelMarks).

## Timeline (see `timeline-today.md`)

Single 128 Canvas, absolute y, orange pills, colliding labels, aliased waveform — root causes documented there.

## Hardcoded-style count (grep, pre-redesign)

`.padding(<num literal>)` outside `Space/Metrics`: ~28 hits (Components 6, EditorView 2, Inspector 3, LiveCaptions 3, LibraryView 5, ExportInspector 1, PixelMarks 1, Settings 1, DebugHarness rest). `Color(` literals outside `Tok`: 2 (DebugHarness red/yellow). `Image(systemName:` always SF except `PixelLens` uses shapes. This is the before baseline for the bar.
