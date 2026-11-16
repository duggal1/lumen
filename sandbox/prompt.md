Intelligent crop for Area capture mode in Lumen.

When the user selects "Area" on the floating recorder bar and presses Record,
today Lumen records a hard static crop (ScreenCaptureKit `sourceRect`). The
user wants a full infrastructure + backend for an "intelligent crop":

- Capture the whole window/display at full resolution, not a dead crop.
- In preview and export, show a tight dynamic crop on the page content, so
  browser chrome (tabs, address bar) is not visible.
- The moment the user interacts with chrome (typing in the address bar,
  clicking a tab), the crop smoothly "uncrops" to reveal that chrome.
- After the interaction ends, it smoothly returns to the tight content crop.
- The motion must be extremely smooth and cinematic and work deterministically
  at export time (60/120/240 fps), reusing the existing camera/director
  machinery where possible.

Deliver a plan only, grounded in this repository. No production code changes.
