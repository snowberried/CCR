const { ipcRenderer } = require("electron");

function percentile(values, ratio) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * ratio))];
}

process.once("loaded", async () => {
  const timings = [];
  let validPayloads = 0;
  for (let iteration = 0; iteration < 30; iteration += 1) {
    const startedAt = performance.now();
    const payload = await ipcRenderer.invoke("benchmark:frame");
    timings.push(performance.now() - startedAt);
    if (payload instanceof Uint8Array && payload.byteLength === 406 * 720 * 4) {
      validPayloads += 1;
    }
  }
  ipcRenderer.send("benchmark:complete", {
    payloadBytes: 406 * 720 * 4,
    iterations: timings.length,
    validPayloads,
    p50Ms: percentile(timings, 0.5),
    p95Ms: percentile(timings, 0.95),
    maximumMs: Math.max(...timings),
  });
});
