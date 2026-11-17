# Lumen — Core Features

The parts that actually make the difference. Everything else is secondary.

## 1. Focus & Zoom (The Main Event)

Lumen’s defining feature. Zooms are not an afterthought — they are the product.

### Automatic Zoom
- Detects clicks and interactions during recording.
- Automatically places balanced, animated zooms on the moments that matter.
- No need to plan zooms in advance. Record normally; the system analyzes what you did.

### Manual Zoom
- Add a zoom anywhere on the timeline.
- Point it at any region of the screen.
- Full control over start, end, and intensity.

### Zoom Types
- **Classic Zoom** — Standard animated zoom that moves the frame.
- **Loupe Zoom** — Magnifying-glass style that keeps surrounding context visible (especially useful when a full classic zoom would move too much of the screen).

### Smart Framing
- Zooms are balanced so the webcam (when present) never covers the cursor or the important action.
- Zooms re-aim automatically when you change aspect ratio.
- Start animation can begin early so the frame is already settled when the action happens.

### Editing Zooms
- Every zoom appears as a block on the zoom timeline.
- Drag edges to change duration.
- Click a zoom to set level (auto or manual region).
- Disable or remove individual zooms without breaking the rest of the edit.

## 2. Motion That Feels Filmed

Raw screen recordings look mechanical. Lumen treats motion like a camera would.

### Motion Blur
- Optics-based motion blur on fast cursor movement, zooms, and screen movement while zoomed.
- Adjustable strength.
- Separate controls possible for cursor movement, zoom-in/out, and panning while zoomed.

### Cursor Handling
- Raw, jittery cursor paths are smoothed into natural glides.
- Multiple animation styles (Smooth / Medium / Rapid / None).
- Cursor can loop back to its starting position (useful for seamless looping videos).
- Cursor automatically hides when idle and reappears when movement resumes.
- Click effects (ripple) available.
- Cursor style is editable.

Result: movement looks intentional and cinematic instead of captured.

## 3. Layouts & Framing System

One recording can contain multiple camera/screen configurations. Transitions are animated automatically.

Available layouts:
- Fullscreen camera
- Split screen
- Camera overlay (corner)
- Screen only
- Camera cutout (background removed entirely on-device)

### Supporting Systems
- **Face tracking** — Keeps the face centered as you move.
- **Hide during silence** — Camera steps aside when you stop talking and returns when speech resumes.
- **Smart re-framing** — When aspect ratio changes, both screen and camera reposition themselves.

## 4. Aspect Ratio Flexibility

Record once. Output in multiple formats without redoing the work.

Supported:
- Wide (16:9)
- Square (1:1)
- Vertical (9:16)

What adjusts automatically:
- Zoom aim points
- Layout placement of screen + camera
- Caption and shortcut positioning for readability

## 5. Recording Foundation

Built on Apple’s ScreenCaptureKit.

- Record full display, single window, or custom region.
- Webcam + microphone + system audio.
- Continuous crash recovery (saves every ~2 seconds).
- Extremely light on system resources.

## 6. Transcript-Based Editing

Edit the video the way you edit text.

- Delete a sentence → the corresponding video is cut.
- Bulk remove filler words (“um”, “uh”) and long pauses in one pass.
- Speed up or trim remaining sections.

## 7. Voice Processing (On-Device)

- Noise reduction (fans, keyboards, room noise reduced while preserving voice character).
- Podcast mode (optimized for spoken walkthroughs and lessons).
- All processing runs locally. Voice never leaves the Mac unless you explicitly choose cloud transcription.

## 8. Captions

- Generated locally (Whisper or Apple speech recognition).
- Multiple text and animation styles.
- Automatically reposition when aspect ratio or layout changes.

## 9. Visual Style System

- Backgrounds (macOS wallpaper, gradient, custom image, Unsplash).
- Padding, shadow, and inset controls.
- Save as presets for consistent branding across videos and team members.

## 10. Device Recording

- Plug in iPhone or iPad over USB.
- Automatically applies correct device mockup (bezel + color matching the actual model).
- Same editor, same zoom/motion/caption tools as regular screen recordings.

## 11. Privacy & Offline-First Design

Core philosophy: almost everything stays on the Mac.

Runs entirely on-device:
- Recording and project files
- Transcription and captions
- Voice enhancement
- Face tracking and camera cutout
- Enhancements and export

Only leaves the Mac when you explicitly choose:
- Shareable links
- Shared projects
- Optional cloud transcription
- AI voiceover

You are always notified before anything is uploaded.

---

### What This Core Actually Delivers

Most screen recorders capture pixels.  
Lumen’s core is a system that:

1. Understands where attention should go (automatic + manual zoom)
2. Makes motion look intentional (blur + cursor smoothing)
3. Keeps framing intelligent across layouts and aspect ratios
4. Lets you edit at the level of speech instead of frames

That combination is the actual product. Everything else is supporting infrastructure.