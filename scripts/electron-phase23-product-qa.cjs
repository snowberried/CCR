const { app, BrowserWindow, ipcMain } = require("electron");
const { execFile } = require("node:child_process");
const { mkdir, mkdtemp, readdir, rm, writeFile } = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE23_QA = "1";

const root = process.cwd();
app.setAppPath(root);
const outputPath = path.join(root, "temp", "phase23-product-ui-qa.json");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);
const execFileAsync = promisify(execFile);
const soakArgument = process.argv.find((value) => value.startsWith("--soak-minutes="));
const soakMinutes = Number(soakArgument?.split("=")[1] ?? 0);
process.stdout.write(`phase23 product QA start (soak ${soakMinutes}m)\n`);

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

function sendKey(window, keyCode) {
  window.webContents.sendInputEvent({ type: "keyDown", keyCode });
  window.webContents.sendInputEvent({ type: "keyUp", keyCode });
}

function memorySlope(samples) {
  const relevant = samples.slice(Math.floor(samples.length / 2));
  if (relevant.length < 2) return 0;
  const meanX = relevant.reduce((sum, sample) => sum + sample.minutes, 0) / relevant.length;
  const meanY = relevant.reduce((sum, sample) => sum + sample.browserMiB, 0) / relevant.length;
  const numerator = relevant.reduce((sum, sample) => sum + (sample.minutes - meanX) * (sample.browserMiB - meanY), 0);
  const denominator = relevant.reduce((sum, sample) => sum + (sample.minutes - meanX) ** 2, 0);
  return denominator === 0 ? 0 : numerator / denominator;
}

(async () => {
  await rm(path.join(root, "temp", "phase23-product-ui-qa-error.txt"), { force: true });
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (files.length < 3) throw new Error("PHASE23_UI_QA_NEEDS_THREE_SAMPLES");
  const actualSampleCount = files.length;
  const syntheticDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-phase22-ui-"));
  const fallbackSource = path.join(syntheticDirectory, "bt709.mp4");
  await execFileAsync(path.join(root, "tools", "ffmpeg", "bin", "ffmpeg.exe"), [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p",
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-y", fallbackSource,
  ], { windowsHide: true });
  files.push(fallbackSource);
  const cacheModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
  cacheModule.registerCacheFrameIpc();
  ipcMain.handle("frame:openQa", async (event, input) => {
    const sampleIndex = input && Number.isInteger(input.sampleIndex) ? input.sampleIndex : -1;
    if (sampleIndex < 0 || sampleIndex >= files.length) {
      return { canceled: false, error: "QA_SAMPLE_INDEX_INVALID" };
    }
    const opened = await cacheModule.openCachePathForQa(files[sampleIndex], event.sender);
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
      window.__phase23Qa = { loadingInsertions: 0, acceptedSamples: [] };
      const surface = document.querySelector(".viewer-surface");
      new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          for (const node of mutation.addedNodes) {
            if (node.nodeType === Node.ELEMENT_NODE && (node.matches?.(".loading-label") || node.querySelector?.(".loading-label"))) {
              window.__phase23Qa.loadingInsertions += 1;
            }
          }
        }
      }).observe(surface, { childList: true, subtree: true });
      new MutationObserver(() => {
        const value = document.documentElement.dataset.qaSampleIndex;
        if (value !== undefined) window.__phase23Qa.acceptedSamples.push(Number(value));
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
    const holdDurationMs = performance.now() - holdStartedAt;
    const expectedDisplayed = Math.min(initial.frameCount, initial.displayed + repeatCount + 1);
    await waitFor(window, `(() => {
      const text = document.querySelector(".primary-readout strong")?.textContent.replaceAll(",", "") ?? "";
      return text.startsWith("${expectedDisplayed} /") && document.querySelector(".status-indicator")?.textContent === "준비";
    })()`, 10_000, "hold-settle");
    const hold = await window.webContents.executeJavaScript(`(() => {
      const text = document.querySelector(".primary-readout strong").textContent.replaceAll(",", "");
      return {
        finalDisplayed: Number(text.split("/")[0].trim()),
        loadingInsertions: window.__phase23Qa.loadingInsertions,
        seekDecodeCount: Number(document.documentElement.dataset.qaSeekDecodeCount),
        error: document.querySelector(".error-message")?.textContent ?? null,
      };
    })()`, true);

    let reverseRepeatCount = 0;
    window.webContents.sendInputEvent({ type: "keyDown", keyCode: "LEFT" });
    const reverseHoldStartedAt = performance.now();
    while (performance.now() - reverseHoldStartedAt < 30_000) {
      window.webContents.sendInputEvent({ type: "keyDown", keyCode: "LEFT", isAutoRepeat: true });
      reverseRepeatCount += 1;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    window.webContents.sendInputEvent({ type: "keyUp", keyCode: "LEFT" });
    const reverseHoldDurationMs = performance.now() - reverseHoldStartedAt;
    const reverseExpectedDisplayed = Math.max(1, hold.finalDisplayed - reverseRepeatCount - 1);
    await waitFor(window, `(() => {
      const text = document.querySelector(".primary-readout strong")?.textContent.replaceAll(",", "") ?? "";
      return text.startsWith("${reverseExpectedDisplayed} /") && document.querySelector(".status-indicator")?.textContent === "준비";
    })()`, 10_000, "reverse-hold-settle");
    const reverseHold = await window.webContents.executeJavaScript(`(() => {
      const text = document.querySelector(".primary-readout strong").textContent.replaceAll(",", "");
      return {
        finalDisplayed: Number(text.split("/")[0].trim()),
        loadingInsertions: window.__phase23Qa.loadingInsertions,
        seekDecodeCount: Number(document.documentElement.dataset.qaSeekDecodeCount),
        error: document.querySelector(".error-message")?.textContent ?? null,
      };
    })()`, true);

    await window.webContents.executeJavaScript(`window.__phase23Qa.acceptedSamples = []`, true);
    await window.webContents.executeJavaScript(`
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 0 }));
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 1 }));
      window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 2 }));
    `, true);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "2" && document.querySelector(".status-indicator")?.textContent === "준비"`, 10_000, "switch-final");
    const switchResult = await window.webContents.executeJavaScript(`({
      acceptedSamples: window.__phase23Qa.acceptedSamples,
      finalSample: Number(document.documentElement.dataset.qaSampleIndex),
      error: document.querySelector(".error-message")?.textContent ?? null,
    })`, true);

    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
    window.webContents.sendInputEvent({ type: "keyDown", keyCode: "RIGHT" });
    window.webContents.sendInputEvent({ type: "keyUp", keyCode: "RIGHT" });
    await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba" && document.querySelector(".status-indicator")?.textContent === "준비"`, 10_000, "context-loss-fallback");
    const contextLossResult = await window.webContents.executeJavaScript(`({
      pixelFormat: document.documentElement.dataset.qaPixelFormat,
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

    let soakResult = null;
    if (soakMinutes > 0) {
      const soakStartedAt = performance.now();
      const soakDeadline = soakStartedAt + soakMinutes * 60_000;
      const memorySamples = [];
      let cycles = 0;
      let navigationRequests = 0;
      let fallbackCycles = 0;
      let contextLossCycles = 0;
      let errors = 0;
      let maximumSeekDecodeCount = 0;
      while (performance.now() < soakDeadline) {
        const sampleIndex = cycles % actualSampleCount;
        await sendQaOpen(window, sampleIndex);
        await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "${sampleIndex}"`, 10_000, "soak-open");
        await waitFor(window, `document.documentElement.dataset.qaBackgroundComplete === "true"`, 10_000, "soak-cache");

        const frameCount = await window.webContents.executeJavaScript(`Number(document.querySelector(".primary-readout strong").textContent.replaceAll(",", "").split("/")[1].trim())`, true);
        sendKey(window, "END");
        await waitFor(window, `document.querySelector(".primary-readout strong")?.textContent.replaceAll(",", "").startsWith("${frameCount} /")`, 10_000, "soak-end");
        sendKey(window, "HOME");
        await waitFor(window, `document.querySelector(".primary-readout strong")?.textContent.trim().startsWith("1 /")`, 10_000, "soak-home");
        for (let index = 0; index < Math.min(20, frameCount - 1); index += 1) sendKey(window, "RIGHT");
        await window.webContents.executeJavaScript(`document.querySelector(".viewer-surface").dispatchEvent(new WheelEvent("wheel", { deltaY: 120, bubbles: true, cancelable: true }))`, true);
        navigationRequests += 22;

        if (cycles % 10 === 0) {
          await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
          sendKey(window, "RIGHT");
          await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "soak-context-loss");
          contextLossCycles += 1;
        }
        if (cycles % 3 === 0) {
          await sendQaOpen(window, actualSampleCount);
          await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "${actualSampleCount}" && document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "soak-fallback");
          fallbackCycles += 1;
        }

        const state = await window.webContents.executeJavaScript(`({
          error: document.querySelector(".error-message")?.textContent ?? null,
          seekDecodeCount: Number(document.documentElement.dataset.qaSeekDecodeCount ?? 0),
        })`, true);
        if (state.error) errors += 1;
        maximumSeekDecodeCount = Math.max(maximumSeekDecodeCount, state.seekDecodeCount);
        const browser = app.getAppMetrics().find((metric) => metric.type === "Browser");
        memorySamples.push({
          minutes: (performance.now() - soakStartedAt) / 60_000,
          browserMiB: (browser?.memory.workingSetSize ?? 0) / 1024,
        });
        cycles += 1;
        if (cycles % 10 === 0) process.stdout.write(`soak ${memorySamples.at(-1).minutes.toFixed(1)}m: ${cycles} cycles\n`);
      }
      soakResult = {
        durationMinutes: (performance.now() - soakStartedAt) / 60_000,
        cycles,
        navigationRequests,
        fallbackCycles,
        contextLossCycles,
        errors,
        maximumSeekDecodeCount,
        secondHalfBrowserRssSlopeMiBPerMinute: memorySlope(memorySamples),
      };
    }

    const result = {
      sampleCount: actualSampleCount,
      firstCanvasPaintMs,
      firstPixelFormat: initial.pixelFormat,
      hold: {
        durationMs: holdDurationMs,
        repeatCount,
        expectedDisplayed,
        ...hold,
      },
      reverseHold: {
        durationMs: reverseHoldDurationMs,
        repeatCount: reverseRepeatCount,
        expectedDisplayed: reverseExpectedDisplayed,
        ...reverseHold,
      },
      switchResult,
      contextLossResult,
      cancelResult,
      fallbackResult,
      soakResult,
      peakElectronRssMiB: peaks,
      passed: hold.finalDisplayed === expectedDisplayed
        && hold.loadingInsertions === 0
        && hold.seekDecodeCount === 0
        && hold.error === null
        && reverseHold.finalDisplayed === reverseExpectedDisplayed
        && reverseHold.loadingInsertions === 0
        && reverseHold.seekDecodeCount === 0
        && reverseHold.error === null
        && switchResult.finalSample === 2
        && switchResult.acceptedSamples.every((value) => value === 2)
        && switchResult.error === null
        && contextLossResult.pixelFormat === "rgba"
        && contextLossResult.error === null
        && cancelResult.status === "취소됨"
        && cancelResult.acceptedAfterCancel === null
        && fallbackResult.pixelFormat === "rgba"
        && fallbackResult.error === null
        && (soakResult === null || (
          soakResult.errors === 0
          && soakResult.maximumSeekDecodeCount === 0
          && soakResult.secondHalfBrowserRssSlopeMiBPerMinute <= 10
        )),
    };
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.passed) process.exitCode = 1;
  } catch (error) {
    const message = `${error instanceof Error ? error.stack ?? error.message : String(error)}\n`;
    process.stderr.write(message);
    process.exitCode = 1;
    await mkdir(path.join(root, "temp"), { recursive: true });
    await writeFile(path.join(root, "temp", "phase23-product-ui-qa-error.txt"), message, "utf8");
  } finally {
    clearInterval(memoryTimer);
    await cacheModule.shutdownCacheFrameIpcResources();
    ipcMain.removeHandler("frame:openQa");
    await rm(syntheticDirectory, { recursive: true, force: true });
  }
  app.exit(process.exitCode ?? 0);
})().catch((error) => {
  const message = `${error instanceof Error ? error.stack ?? error.message : String(error)}\n`;
  process.stderr.write(message);
  process.exitCode = 1;
  void writeFile(path.join(root, "temp", "phase23-product-ui-qa-error.txt"), message, "utf8")
    .finally(() => setTimeout(() => app.exit(1), 50));
});
