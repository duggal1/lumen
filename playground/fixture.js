// Fixture box logger for T4 coverage ground truth.
// Logs every [data-secret] / [data-identity] element's on-screen box per frame.
window.__fixtureLog = [];
function __logBoxes() {
  const t = performance.now() / 1000;
  document.querySelectorAll('[data-secret], [data-identity]').forEach((el) => {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return;
    window.__fixtureLog.push({
      t: Number(t.toFixed(3)), kind: el.dataset.secret ? 'secret' : 'identity',
      name: el.name || el.id || el.textContent.slice(0, 24),
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height)
    });
  });
}
setInterval(__logBoxes, 100); // 10 Hz ground-truth sampler (test harness reads window.__fixtureLog)
