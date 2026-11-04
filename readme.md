<p align="center">
  <img src="App/public/assets/brand/logo/lumen.svg" alt="" width="320" />
</p>

# Screen work, shaped into a clear story

Lumen is a macOS screen recording product for demos, walkthroughs, and product stories. It captures the work as it happens, then uses cursor movement and interaction timing to guide focus and pace.

## Made for clear communication

A useful recording keeps the viewer oriented. Lumen captures a display, window, or selected region, along with the timing and input events that explain what happened on screen. Optional microphone, system audio, and webcam tracks keep the full session together.

From that source, Lumen can derive cursor motion, zoom focus, pacing changes, click cues, and webcam framing. You can keep automatic direction or preserve manual edits in the timeline.

## One source of truth

Each recording lives in a `.lumen` project bundle. The bundle keeps the original media, event data, and project timeline together. The timeline stores creative choices separately from the captured source, so those choices can be adjusted without losing the recording they came from.

The architecture follows that boundary:

- **Capture** records screen media and session signals.
- **Project** stores source details, timeline settings, and derived tracks.
- **Director** turns interaction events into cursor, camera, and pacing guidance.
- **Render and export** are separate stages for composing and delivering the finished recording.

## Product principles

- Keep the original session intact.
- Make automatic direction predictable and editable.
- Keep camera movement, cursor treatment, and pacing in service of the story.
- Preserve a clear path from captured source to finished video.

## Project status

The current source includes screen capture, session input tracking, project models, and the director pipeline. Rendering, audio finishing, export, and the app interface are planned as separate product stages; their implementation files are not present in this checkout yet.
