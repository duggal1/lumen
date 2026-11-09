You're working in the Lumen repository: a native macOS screen recorder with automatic studio polish (auto zoom, smooth cursor and camera, masking, captions, audio cleanup). Most of the backend exists, but I used it by hand and five fundamental things are wrong: the cursor and zoom are inaccurate, privacy masking is unreliable and ugly, captions are upside down and ugly, the click effect is ugly, and the typing motion is rough. These are basic. Fix them properly, keep it simple, and prove each fix by recording a real video of a test page and looking at it yourself.

GROUND RULES

1. Keep every existing backend feature. Extend in place. If something can't be done without removing one, stop and tell me.
2. The code is the truth about what exists. This prompt is the truth about what must be true afterward. If they conflict, adapt the code with the smallest change that delivers the outcome.
3. Swift and Metal only, no Python, no new libraries, no network. System frameworks (Vision, Core Image, MPS, AVFoundation) are fine. Bundled fonts are fine.
4. Every user action goes through the existing command path. Views never mutate the project. No stubs, no fake data.
5. Media is immutable, edits are non-destructive. Preview and export use the same renderer, one code path.
6. Don't over-engineer. If a layer, heuristic or abstraction isn't needed to meet the targets below, delete it. The smallest correct change wins.
7. DESIGN.md and DESIGN_RULES.md bind all app chrome. The mask, caption card and click effect are content: they render in the Metal compositor and belong in Compositor* files, which is the only place DESIGN.md allows blur, gradients and shadows.
8. Never claim a pass you didn't observe. If a test misses its target, keep working. Do not loosen the threshold, delete the test, or call it good enough. If you can't reach a target, say exactly what is blocking.

WHAT THE SCREENSHOTS SHOW

- Captions are flipped vertically in the Studio preview (0:20.0, 0:15.2, 0:09.7): glyphs upside down, and the two lines in reverse order. That is a coordinate-system flip of the whole caption layer, not a font problem. I haven't checked whether the export is flipped too. The caption card is a flat gray rounded rectangle with no blur.
- Masks are unreliable. The same static account-chooser page has all five emails readable at 0:15.2 and 0:20.0, and covered at 0:16.5. The covers are flat color slabs (blue, purple, blue, near-black, near-black), not a mosaic.
- Zoom and cursor: at 0:09.7 the 2.5x zoom is active and the "Continue with Google" button is clipped at the left edge of the frame while the cursor sits in empty space mid-frame. The click tick is at about 0:10.1, so this frame is 0.4 s before the click and does not prove an offset by itself. I am telling you from hand use that clicks land wrong. The test must measure at click frames.
- Also visible, fix while you're there: zoom blocks are purple and a click tick is blue (DESIGN.md allows one hue, signal orange). In the Background tab the inspector overflows the right edge and overlaps the timeline and Tools button. Wallpaper rows are labeled with raw file paths.

PHASE 0: REPRODUCE

Before the full read, build the playground (Part 6), record it, and reproduce each failure below with numbers: cursor error in pixels at click frames, which frames leak which secrets, caption orientation in preview and export. Write down the root cause of each in the code before changing anything. In Phase 1, also write a short report on how captions work today: audio to Moonshine streaming to timing to line breaking to where the text is drawn, and where the flip enters.

PART 1: CURSOR AND ZOOM ACCURACY

Zoom lands in the wrong place, the clicked position is off, and typing zoom is off. My hypothesis, which you must verify and not assume: an extra layer re-derives the cursor position instead of using the real macOS cursor position. Redrawing the cursor from logged events is legitimate (smoothing needs it), so don't delete the drawn cursor. Make the logged position exact, and remove anything between it and the frame that can move a click.

1. One source of truth: the OS cursor position (mouse move, down, up, drag, scroll), sampled at capture time with host timestamps on the same clock as the video frames, stored raw and untouched in the project.
2. One transform from raw position to frame pixel, as a single pure function with unit tests. It must handle display scale (points vs pixels), global coordinate origin and flipped y between Quartz and Cocoa, secondary displays including negative origins, window and area capture offsets, a window that moves mid-recording, and cropping.
3. Smoothing may shape motion between clicks. At every click-down, the drawn cursor, the click effect and the zoom anchor equal the raw position through the transform, within 1 source pixel.
4. Time alignment: the effect appears on the correct frame, within half a frame of the event time. Measure it, don't assume it.
5. Zoom framing: at the click frame the click target is inside the zoom viewport with margin, and the camera has arrived. Typing zoom anchors to the last click position. Don't add caret tracking unless the click anchor fails the playground test, and if it does, tell me.
6. Remove any second tracking layer, vision-based tracking or repositioning heuristic you find. Report what you removed.
7. Typing motion: the camera must not chase individual keystrokes. Use a dead zone and a hold, then ease with a critically damped spring. No overshoot, no hunting.

Calibration fixture: a page with a grid of targets at known screen coordinates, and a script that moves and clicks to them with CGEvent. Record in display, window and area modes, on a 1x and a 2x display if available, on a secondary display, and with the window moved mid-recording. Assert cursor error in pixels at every click frame, zoom center against target, and time alignment.

PART 2: PRIVACY MASKING

What I see by hand: masks are sometimes there and sometimes not, passwords aren't hidden, an account dropdown that lists my email on a mail page isn't hidden, and credit cards aren't handled. The look is also wrong. Hiding is done with an ugly flat color slab.

Look. Replace slabs with a pixelated blur (mosaic): crisp square cells, a grid anchored in source space so it never swims when content moves, and no gradients or soft edges. Render it in the compositor's final pass by mapping each output pixel to source space, so the cells stay crisp squares at any zoom. The snippet at the end is the starting point.

Security. Pixelation made from the secret's own pixels leaks its coarse shape, ink density and length. That matters most for short low-entropy secrets and for small cells. So there are two kinds:
- identity (emails, names, phone numbers, URLs): cells sampled from the source, starting cell of about 0.9x the text height, with luminance quantized.
- secret (passwords, card numbers, CVC, expiry, API keys and tokens): cells carry no information from the field. Colors come from the surrounding background plus a per-cell hash. It looks like the same mosaic and leaks nothing. Mask the whole field box, not the text box, so the region size doesn't reveal the length.
The cell sizes are my starting values and are untested. Tune them by looking, then prove them with the tests below.

Detection. Every exported frame must have every sensitive region covered. Use layers, and verify which already exist:
- Vision OCR with patterns: emails, card numbers (13-19 digits with spaces or dashes, Luhn-checked), CVC and expiry next to their labels, phone numbers, API key and token formats.
- Field semantics from Accessibility at capture time: secure text fields, and fields labeled password, card number or CVC. Verify what the browsers you test actually expose.
- Typing: while the user types into a field flagged secret, that field is masked for as long as it is focused, even if the password is visible as plain text.
- Overlays: account switchers and autofill popups are in the composited frame, so detection must run on the composited frame, not only on page content.
- Time: run on every changed region of every changed frame, not a fixed 1 Hz. A dropdown can appear in under 150 ms. Add hysteresis: hold a mask through detection dropouts, start it at least 2 frames before the content first appears, and end it at least 2 frames after it leaves. You have lookahead, so use it.
- The flicker has a cause: detector dropouts, confidence gating, per-mask time ranges, lost tracking, or a coordinate bug. Find it and say which.

Order. Apply the mask to the source frame before camera zoom, upscaling, motion blur and the cursor overlay. No downstream stage may ever see unmasked pixels. Never draw the mask as an overlay on an unmasked frame. Mask geometry derives from the same transform as the content so it never lags. Never smooth mask rectangle edges with a spring (overshoot or lag exposes text).

Motion. The only animation is a cell-stepped resolve over about 120 ms, and only while no sensitive content is on screen. Strength is never animated while content is visible.

Manual and auto masks are the same object. Manual ones survive re-analysis.

PART 3: CAPTIONS

1. Fix the flip. Find the root cause (a bottom-left vs top-left origin between the text drawing and the texture sampling is the usual one, but verify). Add a golden-image test with asymmetric text such as "Ry 123" that checks orientation in both the preview and the export, and keep one coordinate convention.
2. Card material. The card needs a thin Apple-style blur material. NSVisualEffectView and SwiftUI materials blur the live window backdrop and don't exist in an exported video, and preview and export must match, so build it in the Metal compositor: blur the already-composited frame under the card (MPSImageGaussianBlur or a separable Gaussian), boost saturation about 1.6-1.8x, apply a thin tint, and use a continuous-corner rounded rectangle with radius about 0.5x line height. No border. These are starting values; tune them by looking.
3. White text on a light blur fails contrast on bright pages. A pure white page (screenshot 4) is the stress case. The tint must adapt: measure the blurred backdrop luminance under the card, low-pass it over time so it never flickers, and raise the tint so white text on the card is at least 4.5:1 everywhere on the card.
4. Fonts: a dropdown through MenuHost with SF Pro (default), SF Pro Rounded, New York (serif), Inter (bundled Regular, Medium, SemiBold, with its OFL license text included), and SF Mono. All render through the same path in preview and export.
5. Colors: text is white. Word highlight keeps its toggle. Default highlight is the spoken word at full white and other words at about 60%, with a color swatch the user can change (orange is one of the options, not the default).
6. Motion: blur-in and blur-out of the whole caption block. Opacity follows an ease, and position, scale and blur follow a critically damped spring. No overshoot, no bounce. It must be a pure function of time, because the export is offline and deterministic. The snippet is below. Word color changes crossfade over about 80 ms.
7. Inspector: about six controls (on/off, Font, Size, Lines, Animation with Blur as default plus Fade and None, Highlight color). Position, Language and the rest go under Advanced.

PART 4: CLICK EFFECT

Replace the orange dot. Build a ripple: a wave that expands from the exact click pixel and refracts the video under it (a small radial displacement), plus a faint highlight on the crest, with no flat fill color by default. Render it in the Metal compositor so the export matches. The inspector's preview tile can be SwiftUI. Customizable: style (Ripple default, Ring, Pulse, None), size, intensity, tint color (off by default), duration. Motion: front radius eases out over about 600-700 ms and amplitude decays, critically damped, no overshoot. A double click gives two ripples, and rapid clicks cap the number alive at once. The cursor gets a small press scale (about 0.9 back to 1) on the same spring. The ripple center uses the exact corrected click position from Part 1.
Research how Screen Studio does it. I checked its public cursor and masking guides: they list cursor options but don't describe the click effect, and its masks are manual and don't follow scrolling. Look further if you can, but don't assume, and design from this spec.

PART 5: INSPECTOR AND TIMELINE FIXES VISIBLE IN THE SCREENSHOTS

Purple zoom blocks and the blue click tick go to the Ramp tokens. Fix the Background tab overflow and overlap, and give wallpaper rows readable names instead of paths. Use only Tok and Ramp, never a hex.

PART 6: THE PLAYGROUND, AND TESTING UNTIL IT PASSES

Build a local HTML, CSS and JavaScript test site. No network, no form submission, a visible "test fixture" label, and fictional brands ("Acme Mail", "Acme Pay"). Do not imitate Google, Gmail or Stripe branding or layout. What matters is the content patterns. Pages:
- Sign-in with an email field and a password field (type=password, plus a show-password toggle that reveals plain text) and an account chooser listing 5 accounts.
- A mail page with a top-right account dropdown that slides in within 150 ms and lists emails, an inbox with senders, and message bodies containing emails and phone numbers.
- A checkout with the card number as one field and as four split fields, expiry, CVC, name, zip, billing email, and a saved-card list.
- A settings page with API keys (sk_test_..., AKIA...).
Variants: light and dark theme, browser zoom 80-200%, text inside an image, an email in the tab title and in the URL query (?login_hint=), scrolling and animated content. Include autocomplete attributes so I can trigger a real browser autofill popup by hand.
Data: fake accounts at example.com and example.org, plus a few gmail.com-style strings to test the pattern. Cards: only publicly documented test numbers (4242 4242 4242 4242, 4111 1111 1111 1111, 5555 5555 5555 4444, 3782 822463 10005, 6011 1111 1111 1117), in spaced, dashed, unspaced and split formats. Realistic-looking fake passwords.

Loop: drive the playground with CGEvent input, record with Lumen through the real recording path, run the real auto-mask, export through the real export path. Then check:
- Extract every exported frame, not a sample. Run Vision OCR on each at native size, 2x and 3x with a sharpen pass. Fail on any known secret, any email, any 4+ character substring of a card number or password (fuzzy, edit distance up to 2).
- Coverage against ground truth: the fixture logs every sensitive element's on-screen box per frame. 100% of each box must be covered on every frame.
- Structure: inside each mask the output must be piecewise constant per cell and different from the source.
- Stress: fast scroll, window drag, zoom transitions, scrubbing in the preview (preview frames too), export at 9:16, motion blur on, and the first and last frame of every mask interval.
- Cursor calibration from Part 1.
- Captions: orientation golden test, contrast on a dark page, a white page and a busy wallpaper, and transition crops that confirm opacity stays within 0-1 and blur never goes negative.
Screenshot each surface, review it against DESIGN_RULES.md, fix it, screenshot and review again. Look at the frames yourself, and judge them as a designer: clean mosaic, crisp, no slabs, no jitter. Iterate until all of it passes. If you can't drive the UI or record on this machine, say so and mark those items unverified, not pass.

FINAL REPORT

Per requirement: pass or fail with evidence (pixel errors, coverage percentages, OCR hit counts, contrast ratios, frame crops). Include the root causes found for the cursor offset, the caption flip and the mask flicker, anything you removed, anything unverified, and what needs my eyes: the real gmail.com account dropdown, a real browser autofill popup, a Stripe test-mode checkout with test cards, and how the ripple and caption motion feel.

SNIPPETS (starting points: untested, adapt to the compositor's real structure)

Mosaic, Metal. Call it for every output pixel in the final pass, after mapping output to source pixels.

```metal
#include <metal_stdlib>
using namespace metal;

struct MosaicRegion {            // 64 bytes
    float4 rect;                 // x, y, w, h in SOURCE pixels, snapped outward to the cell grid
    float4 base;                 // background estimate (rgb), taken from a ring OUTSIDE the field
    float  cell;                 // cell edge in source pixels
    float  coverage;             // 0...1 cell-stepped resolve; MUST be 1 whenever content is visible
    float  sampledMix;           // 0 = secret (reads no pixels from the region), 1 = identity
    float  levels;               // luminance quantization steps, 0 = off
    float  dim;                  // 0...0.3
    float  p0, p1, p2;
};

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float4 sampleWithMosaic(texture2d<float> src, sampler s, float2 srcPx, float2 srcSize,
                        constant MosaicRegion* regions, uint count)
{
    for (uint i = 0; i < count; ++i) {
        MosaicRegion r = regions[i];
        float2 lo = r.rect.xy, hi = r.rect.xy + r.rect.zw;
        if (srcPx.x < lo.x || srcPx.y < lo.y || srcPx.x >= hi.x || srcPx.y >= hi.y) continue;

        float2 idx = floor(srcPx / r.cell);                 // grid anchored to SOURCE space
        if (hash12(idx + float(i) * 17.0) >= r.coverage) continue;   // resolve step: only legal while content is off screen

        float n = hash12(idx * 1.37 + 91.0);                // constant per cell, never changes over time
        float3 synth = r.base.rgb * (0.82 + 0.36 * n);      // carries nothing from the region

        float3 sampled = float3(0.0);
        if (r.sampledMix > 0.0) {                           // secrets (0) never read the region
            float2 o = idx * r.cell;
            for (int y = 0; y < 4; ++y)
                for (int x = 0; x < 4; ++x)
                    sampled += src.sample(s, (o + (float2(x, y) + 0.5) * (r.cell * 0.25)) / srcSize).rgb;
            sampled *= (1.0 / 16.0);
            if (r.levels > 0.0) sampled = floor(sampled * r.levels + 0.5) / r.levels;
        }
        return float4(mix(synth, sampled, r.sampledMix) * (1.0 - r.dim), 1.0);
    }
    return src.sample(s, srcPx / srcSize);
}
```

Mosaic, Swift.

```swift
import simd
import CoreGraphics

struct MosaicRegion {                              // must match the Metal struct byte for byte (64)
    var rect: SIMD4<Float>
    var base: SIMD4<Float>
    var cell: Float
    var coverage: Float = 1
    var sampledMix: Float
    var levels: Float
    var dim: Float
    var _pad: (Float, Float, Float) = (0, 0, 0)
}

enum MaskKind { case identity, secret }

enum MosaicPolicy {
    /// Starting values. Tune by eye, then prove with the OCR and coverage tests.
    static func cell(textHeight h: Float, kind: MaskKind) -> Float {
        max(8, (h * (kind == .secret ? 1.25 : 0.9)).rounded())
    }

    /// For .secret pass the WHOLE FIELD box so the region size doesn't reveal length.
    static func region(box: CGRect, textHeight: Float, kind: MaskKind,
                       background: SIMD3<Float>) -> MosaicRegion {
        let cell = cell(textHeight: textHeight, kind: kind)
        let c = CGFloat(cell)
        let p = box.insetBy(dx: -c, dy: -c * 0.5)
        // Snap outward to the source-space grid: no partial cells, no unmasked sliver at an edge.
        let x0 = floor(p.minX / c) * c, y0 = floor(p.minY / c) * c
        let x1 = ceil(p.maxX / c) * c,  y1 = ceil(p.maxY / c) * c
        return MosaicRegion(rect: SIMD4(Float(x0), Float(y0), Float(x1 - x0), Float(y1 - y0)),
                            base: SIMD4(background, 1), cell: cell,
                            sampledMix: kind == .secret ? 0 : 1,
                            levels: kind == .secret ? 0 : 5, dim: 0.10)
    }

    /// Four whole steps. Use only when no sensitive content is on screen. Disappear = 1 - coverage(...).
    static func coverage(at t: Double, start: Double, duration: Double = 0.12) -> Float {
        let k = floor((t - start) / duration * 4) + 1
        return Float(min(max(k, 0), 4) / 4)
    }
}
```

Caption motion, Swift. A pure function of time, with no overshoot.

```swift
/// Critically damped step response, 0 to 1. omega 20 settles to within 1% in about 0.33 s.
@inline(__always) func settle(_ t: Double, omega: Double) -> Double {
    let x = omega * max(t, 0)
    return 1 - exp(-x) * (1 + x)
}

struct CaptionPose { var opacity, blurRadius, lift, scale: Double }

func captionPose(at t: Double, shownAt: Double, hiddenAt: Double, frameHeight: Double) -> CaptionPose {
    let k = settle(t - shownAt, omega: 20) * (1 - settle(t - hiddenAt, omega: 26))  // 0 hidden ... 1 shown
    let e = k * k * (3 - 2 * k)                                                      // ease for opacity
    return CaptionPose(opacity: e,
                       blurRadius: frameHeight * 0.012 * (1 - k),                    // about 13 px at 1080p
                       lift: frameHeight * 0.006 * (1 - k),
                       scale: 0.985 + 0.015 * k)
}
```

Ripple displacement, Metal. Sample the source at p minus this offset.

```metal
float2 rippleOffset(float2 p, float2 center, float R, float lambda, float width, float amp) {
    float2 d = p - center;
    float r = length(d);
    if (r < 1e-3) return float2(0.0);
    float x = (r - R) / width;                       // R = current front radius, eased out over ~650 ms
    return normalize(d) * amp * exp(-x * x) * sin(6.2831853 * (r - R) / lambda);
}
```