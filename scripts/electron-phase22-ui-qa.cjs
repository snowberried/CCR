const { app, BrowserWindow, ipcMain } = require("electron");
const { execFile } = require("node:child_process");
const { mkdir, mkdtemp, readdir, rm, writeFile } = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE22_QA = "1";
process.env.CCR_PHASE22_SPIKE = "1";

const root = process.cwd();
app.setAppPath(root);
const outputPath = path.join(root, "temp", "phase22-ui-qa.json");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);
const execFileAsync = promisify(execFile);

async function mediaFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right));
}

async function waitFor(window, expression, timeoutMs = 10_000, label = "unknown") {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await window.webContents.executeJavaScript(expression, true);
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`UI_QA_TIMEOUT_${label}`);
}

function sendQaOpen(window, sampleIndex) {
  return window.webContents.executeJavaScript(
    `window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: ${sampleIndex} }))`,
    true,
  );
}

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (files.length < 3) throw new Error("PHASE22_UI_QA_NEEDS_THREE_SAMPLES");
  const actualSampleCount = files.length;
  const syntheticDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-phase22-ui-"));
  const fallbackSource = path.join(syntheticDirectory, "bt709.mp4");
  await execFileAsync(path.join(root, "tools", "ffmpeg", "bin", "ffmpeg.exe"), [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p",
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-y", fallbackSource,
  ], { windowsHide: true });
  files.push(fallbackSource);
  const spikeModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "spike22", "spikeFrameIpc.js")).href);
  spikeModule.registerSpikeFrameIpc();
  ipcMain.handle("frame:openQa", async (event, input) => {
    const sampleIndex = input && Number.isInteger(input.sampleIndex) ? input.sampleIndex : -1;
    if (sampleIndex < 0 || sampleIndex >= files.length) {
      return { canceled: false, error: "QA_SAMPLE_INDEX_INVALID" };
    }
    const opened = await spikeModule.openSpikePathForQa(files[sampleIndex], event.sender);
    return { ...opened, qaSampleIndex: sampleIndex };
  });

  await app.whenReady();
  const window = new BrowserWindow({
    width: 1120,
    height: 760,
    show: false,
    webPreferences: {
      preload: path.join(root, "dist-electron", "electron", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });

  const peaks = { browserMiB: 0, rendererMiB: 0, gpuMiB: 0 };
  const memoryTimer = setInterval(() => {
    for (const metric of app.getAppMetrics()) {
      const workingSetMiB = metric.memory.workingSetSize / 1024;
      if (metric.type === "Browser") peaks.browserMiB = Math.max(peaks.browserMiB, workingSetMiB);
      if (metric.type === "Tab") peaks.rendererMiB = Math.max(peaks.rendererMiB, workingSetMiB);
      if (metric.type === "GPU") peaks.gpuMiB = Math.max(peaks.gpuMiB, workingSetMiB);
    }
  }, 10);

  try {
    await window.loadFile(path.join(root, "dist", "index.html"));
    await waitFor(window, `Boolean(window.ccr?.openQaVideo)`, 10_000, "bridge");
    await waitFor(window, `Boolean(document.querySelector(".app-shell"))`, 10_000, "react-mount");
    await new Promise((resolve) => setTimeout(resolve, 50));

    const firstOpenStartedAt = performance.now();
    await sendQaOpen(window, 0);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "0" && document.querySelector("canvas")?.width > 0`, 10_000, "first-paint");
    const firstCanvasPaintMs = performance.now() - firstOpenStartedAt;
    await waitFor(window, `document.documentElement.dataset.qaBackgroundComplete === "true"`, 10_000, "background-cache");

    const initial = await window.webContents.executeJavaScript(`(() => {
      window.__phase22Qa = { loadingInsertions: 0, acceptedSamples: [] };
      const surface = document.querySelector(".viewer-surface");
      new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          for (const node of mutation.addedNodes) {
            if (node.nodeType === Node.ELEMENT_NODE && (node.matches?.(".loading-label") || node.querySelector?.(".loading-label"))) {
              window.__phase22Qa.loadingInsertions += 1;
            }
          }
        }
      }).observe(surface, { childList: true, subtree: true });
      new MutationObserver(() => {
        const value = document.documentElement.dataset.qaSampleIndex;
        if (value !== undefined) window.__phase22Qa.acceptedSamples.push(Number(value));
      }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-qa-sample-index"] });
      const text = document.querySelector(".primary-readout strong").textContent.replaceAll(",", "");
      const [displayed, frameCount] = text.split("/").map((part) => Number(part.trim()));
      return { displayed, frameCount, pixelFormat: document.documentElement.dataset.qaPixelFormat };
    })()`, true);

    let repeatCount = 0;
    window.webContents.sendInputEvent({ type: "keyDown", keyCode: "RIGHT" });
    const holdStartedAt = performance.now();
    while (performance.now() - holdStartedAt < 30_000) {
      window.webContents.sendInputEvent({ type: "keyDown", keyCode: "RIGHT", isAutoRepeat: true });
      repeatCount += 1;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    window.webContents.sendInputEvent({ type: "keyUp", keyCode: "RIGHT" });
    const expectedDisplayed = Math.min(initial.frameCount, initial.displayed + repeatCount + 1);
    await waitFor(window, `(() => {
      const text = document.querySelector(".primary-readout strong")?.textContent.replaceAll(",", "") ?? "";
      return text.startsWith("${expectedDisplayed} /") && document.querySelector(".status-indicator")?.textContent === "준비";
    })()`, 10_000, "hold-settle");
    const hold = await window.webContents.executeJavaScript(`(() => {
      const text = document.querySelector(".primary-readout strong").textContent.replaceAll(",", "");
      return {
        finalDisplayed: Number(text.split("/")[0].trim()),
        loadingInsertions: window.__phase22Qa.loadingInsertions,
        seekDecodeCount: Number(document.documentElement.dataset.qaSeekDecodeCount),
        error: document.querySelector(".error-message")?.textContent ?? null,
      };
    })()`, true);

    await window.webContents.executeJavaScript(`window.__phase22Qa.acceptedSamples = []`, true);
    await window.webContents.executeJavaScript(`
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 0 }));
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 1 }));
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 2 }));
    `, true);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "2" && document.querySelector(".status-indicator")?.textContent === "준비"`, 10_000, "switch-final");
    const switchResult = await window.webContents.executeJavaScript(`({
      acceptedSamples: window.__phase22Qa.acceptedSamples,
      finalSample: Number(document.documentElement.dataset.qaSampleIndex),
      error: document.querySelector(".error-message")?.textContent ?? null,
    })`, true);

    await sendQaOpen(window, 0);
    await waitFor(window, `document.querySelector(".status-indicator")?.textContent === "분석 중"`, 10_000, "cancel-probing");
    await window.webContents.executeJavaScript(`document.querySelector('button[title="디코딩 취소"]').click()`, true);
    await waitFor(window, `document.querySelector(".status-indicator")?.textContent === "취소됨"`, 10_000, "cancelled");
    await new Promise((resolve) => setTimeout(resolve, 500));
    const cancelResult = await window.webContents.executeJavaScript(`({
      status: document.querySelector(".status-indicator")?.textContent,
      acceptedAfterCancel: document.documentElement.dataset.qaSampleIndex ?? null,
      error: document.querySelector(".error-message")?.textContent ?? null,
    })`, true);

    await sendQaOpen(window, actualSampleCount);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "${actualSampleCount}" && document.documentElement.dataset.qaPixelFormat === "rgba" && document.querySelector(".status-indicator")?.textContent === "준비"`, 10_000, "rgba-fallback");
    const fallbackResult = await window.webContents.executeJavaScript(`({
      pixelFormat: document.documentElement.dataset.qaPixelFormat,
      error: document.querySelector(".error-message")?.textContent ?? null,
    })`, true);

    const result = {
      sampleCount: actualSampleCount,
      firstCanvasPaintMs,
      firstPixelFormat: initial.pixelFormat,
      hold: {
        durationMs: performance.now() - holdStartedAt,
        repeatCount,
        expectedDisplayed,
        ...hold,
      },
      switchResult,
      cancelResult,
      fallbackResult,
      peakElectronRssMiB: peaks,
      passed: hold.finalDisplayed === expectedDisplayed
        && hold.loadingInsertions === 0
        && hold.seekDecodeCount === 0
        && hold.error === null
        && switchResult.finalSample === 2
        && switchResult.acceptedSamples.every((value) => value === 2)
        && switchResult.error === null
        && cancelResult.status === "취소됨"
        && cancelResult.acceptedAfterCancel === null
        && fallbackResult.pixelFormat === "rgba"
        && fallbackResult.error === null,
    };
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.passed) process.exitCode = 1;
  } finally {
    clearInterval(memoryTimer);
    await spikeModule.shutdownSpikeFrameIpcResources();
    ipcMain.removeHandler("frame:openQa");
    window.destroy();
    await rm(syntheticDirectory, { recursive: true, force: true });
  }
  app.exit(process.exitCode ?? 0);
})().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  app.exit(1);
});
