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
const execFileAsync = promisify(execFile);
const outputPath = path.join(root, "temp", "phase3a-view-qa.json");
const minutesArgument = process.argv.find((value) => value.startsWith("--minutes="));
const minutes = Number(minutesArgument?.split("=")[1] ?? 0);
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);
const forceRgba = process.env.CCR_FORCE_RGBA === "1";

function openReadyExpression(sampleIndex) {
  const opened = `document.documentElement.dataset.qaSampleIndex === "${sampleIndex}"`;
  return forceRgba ? `${opened} && Boolean(document.querySelector(".status-ready"))` : `${opened} && document.documentElement.dataset.qaBackgroundComplete === "true"`;
}

async function mediaFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right));
}

async function waitFor(window, expression, timeoutMs = 15_000, label = "unknown") {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await window.webContents.executeJavaScript(expression, true);
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`PHASE3A_TIMEOUT_${label}`);
}

async function waitForMain(predicate, timeoutMs = 15_000, label = "unknown") {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`PHASE3A_MAIN_TIMEOUT_${label}`);
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

function percentile(values, ratio) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * ratio))] ?? 0;
}

function slope(samples) {
  const values = samples.slice(Math.floor(samples.length / 2));
  if (values.length < 2) return 0;
  const meanX = values.reduce((sum, value) => sum + value.minutes, 0) / values.length;
  const meanY = values.reduce((sum, value) => sum + value.rssMiB, 0) / values.length;
  const denominator = values.reduce((sum, value) => sum + (value.minutes - meanX) ** 2, 0);
  return denominator === 0 ? 0 : values.reduce(
    (sum, value) => sum + (value.minutes - meanX) * (value.rssMiB - meanY),
    0,
  ) / denominator;
}

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (files.length < 3) throw new Error("PHASE3A_NEEDS_THREE_SAMPLES");
  const actualSampleCount = files.length;
  const syntheticDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-phase3a-"));
  const ffmpegPath = path.join(root, "tools", "ffmpeg", "bin", "ffmpeg.exe");
  for (const [name, size] of [["landscape.mp4", "640x360"], ["hd.mp4", "1920x1080"]]) {
    const target = path.join(syntheticDirectory, name);
    await execFileAsync(ffmpegPath, [
      "-v", "error", "-f", "lavfi", "-i", `testsrc2=size=${size}:rate=24`, "-t", "0.5",
      "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", target,
    ], { windowsHide: true });
    files.push(target);
  }

  const frameModule = forceRgba
    ? await import(pathToFileURL(path.join(root, "dist-electron", "electron", "frameIpc.js")).href)
    : await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
  const fullscreenModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "fullscreenIpc.js")).href);
  if (forceRgba) frameModule.registerFrameIpc();
  else frameModule.registerCacheFrameIpc();
  fullscreenModule.registerFullscreenIpc();
  ipcMain.handle("frame:openQa", async (event, input) => {
    const sampleIndex = input && Number.isInteger(input.sampleIndex) ? input.sampleIndex : -1;
    if (sampleIndex < 0 || sampleIndex >= files.length) return { canceled: false, error: "QA_SAMPLE_INDEX_INVALID" };
    const opened = forceRgba
      ? await frameModule.openFramePathForQa(files[sampleIndex])
      : await frameModule.openCachePathForQa(files[sampleIndex], event.sender);
    return { ...opened, qaSampleIndex: sampleIndex };
  });

  await app.whenReady();
  const window = new BrowserWindow({
    width: 1120,
    height: 760,
    show: true,
    webPreferences: {
      preload: path.join(root, "dist-electron", "electron", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });
  fullscreenModule.attachFullscreenEvents(window);

  try {
    await window.loadFile(path.join(root, "dist", "index.html"));
    window.focus();
    await waitFor(window, `Boolean(window.ccr?.openQaVideo) && Boolean(document.querySelector(".app-shell"))`, 10_000, "bridge");
    await sendQaOpen(window, 0);
    await waitFor(window, openReadyExpression(0), 20_000, "first-open");

    const initial = await window.webContents.executeJavaScript(`(() => {
      const canvas = document.querySelector("canvas");
      const rect = canvas.getBoundingClientRect();
      const anchor = { x: rect.left + rect.width * 0.5, y: rect.top + rect.height * 0.4 };
      return {
        zoom: Number(document.documentElement.dataset.qaViewZoom),
        center: document.documentElement.dataset.qaViewCenter.split(",").map(Number),
        tool: document.documentElement.dataset.qaViewTool,
        gesture: document.documentElement.dataset.qaPointerGesture,
        uploads: Number(document.documentElement.dataset.qaTextureUploads),
        seek: Number(document.documentElement.dataset.qaSeekDecodeCount),
        anchor,
        anchorImage: [(anchor.x - rect.left) / rect.width * canvas.width, (anchor.y - rect.top) / rect.height * canvas.height],
        aspectError: Math.abs(rect.width / rect.height - canvas.width / canvas.height),
      };
    })()`, true);

    const zoomDrawMs = await window.webContents.executeJavaScript(`(async () => {
      const startedAt = performance.now();
      const surface = document.querySelector(".viewer-surface");
      surface.dispatchEvent(new WheelEvent("wheel", {
        deltaY: -120, ctrlKey: true, clientX: ${initial.anchor.x}, clientY: ${initial.anchor.y}, bubbles: true, cancelable: true,
      }));
      await new Promise((resolve) => setTimeout(resolve, 0));
      document.querySelector("canvas").getBoundingClientRect();
      return performance.now() - startedAt;
    })()`, true);
    const wheelUpOne = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewZoom`, true));
    await window.webContents.executeJavaScript(`document.querySelector(".viewer-surface").dispatchEvent(new WheelEvent("wheel", { deltaY:-120, ctrlKey:true, clientX:${initial.anchor.x}, clientY:${initial.anchor.y}, bubbles:true, cancelable:true }))`, true);
    const wheelUpTwo = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewZoom`, true));
    await window.webContents.executeJavaScript(`document.querySelector(".viewer-surface").dispatchEvent(new WheelEvent("wheel", { deltaY:120, ctrlKey:true, clientX:${initial.anchor.x}, clientY:${initial.anchor.y}, bubbles:true, cancelable:true }))`, true);
    const wheelDownOne = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewZoom`, true));
    const zoomed = await window.webContents.executeJavaScript(`(() => {
      const canvas = document.querySelector("canvas");
      const rect = canvas.getBoundingClientRect();
      const anchor = ${JSON.stringify(initial.anchor)};
      return {
        zoom: Number(document.documentElement.dataset.qaViewZoom),
        center: document.documentElement.dataset.qaViewCenter.split(",").map(Number),
        anchorImage: [(anchor.x - rect.left) / rect.width * canvas.width, (anchor.y - rect.top) / rect.height * canvas.height],
      };
    })()`, true);
    const anchorError = Math.hypot(
      zoomed.anchorImage[0] - initial.anchorImage[0],
      zoomed.anchorImage[1] - initial.anchorImage[1],
    );

    const surface = await window.webContents.executeJavaScript(`(() => {
      const rect = document.querySelector(".viewer-surface").getBoundingClientRect();
      return { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2), left:Math.round(rect.left), top:Math.round(rect.top), right:Math.round(rect.right), bottom:Math.round(rect.bottom) };
    })()`, true);
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "left", clickCount: 1 });
    await new Promise((resolve) => setTimeout(resolve, 30));
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x + 80, y: surface.y + 50 });
    await new Promise((resolve) => setTimeout(resolve, 30));
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x + 80, y: surface.y + 50, button: "left", clickCount: 1 });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const panned = await window.webContents.executeJavaScript(`({
      zoom: Number(document.documentElement.dataset.qaViewZoom),
      center: document.documentElement.dataset.qaViewCenter.split(",").map(Number),
      revision: Number(document.documentElement.dataset.qaViewRevision),
    })`, true);

    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="Zoom 도구"]').click()`, true);
    await waitFor(window, `document.documentElement.dataset.qaViewTool === "zoom"`, 5_000, "zoom-tool");
    const zoomToolStart = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewZoom`, true));
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "left", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x + 120, y: surface.y - 100 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x + 120, y: surface.y - 100, button: "left", clickCount: 1 });
    const zoomToolUp = await waitFor(window, `Number(document.documentElement.dataset.qaViewZoom) > ${zoomToolStart} && document.documentElement.dataset.qaPointerGesture === "none" ? Number(document.documentElement.dataset.qaViewZoom) : 0`, 5_000, "zoom-drag-up");
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "left", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x - 120, y: surface.y + 100 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x - 120, y: surface.y + 100, button: "left", clickCount: 1 });
    const zoomToolDown = await waitFor(window, `Number(document.documentElement.dataset.qaViewZoom) < ${zoomToolUp} && document.documentElement.dataset.qaPointerGesture === "none" ? Number(document.documentElement.dataset.qaViewZoom) : 0`, 5_000, "zoom-drag-down");

    const displayBeforeZoomRight = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaDisplayState`, true);
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "right", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x + 60, y: surface.y - 30 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x + 60, y: surface.y - 30, button: "right", clickCount: 1 });
    const displayAfterZoomRight = await waitFor(window, `document.documentElement.dataset.qaDisplayState !== ${JSON.stringify(displayBeforeZoomRight)} ? document.documentElement.dataset.qaDisplayState : ""`, 5_000, "zoom-right-display");
    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="Pan 도구"]').click()`, true);
    await waitFor(window, `document.documentElement.dataset.qaViewTool === "pan"`, 5_000, "pan-tool");
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "right", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x - 40, y: surface.y + 20 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x - 40, y: surface.y + 20, button: "right", clickCount: 1 });
    const displayAfterPanRight = await waitFor(window, `document.documentElement.dataset.qaDisplayState !== ${JSON.stringify(displayAfterZoomRight)} ? document.documentElement.dataset.qaDisplayState : ""`, 5_000, "pan-right-display");

    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="Zoom 도구"]').click()`, true);
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "left", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x, y: surface.y - 40 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.left - 2, y: surface.top - 2, button: "left", clickCount: 1 });
    await waitFor(window, `document.documentElement.dataset.qaPointerGesture === "none"`, 5_000, "outside-release");

    await window.webContents.executeJavaScript(`document.querySelector('.viewer-tool-rail button[aria-label="화면 맞춤"]').click()`, true);
    const fitCommand = await window.webContents.executeJavaScript(`({ zoom:Number(document.documentElement.dataset.qaViewZoom), tool:document.documentElement.dataset.qaViewTool })`, true);
    await window.webContents.executeJavaScript(`document.querySelector('.viewer-tool-rail button[aria-label="원본 픽셀 100%"]').click()`, true);
    const actualCommand = await window.webContents.executeJavaScript(`(() => { const canvas=document.querySelector("canvas"); const rect=canvas.getBoundingClientRect(); return { zoom:Number(document.documentElement.dataset.qaViewZoom), tool:document.documentElement.dataset.qaViewTool, effectiveScale:rect.width/canvas.width }; })()`, true);
    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="Pan 도구"]').click()`, true);
    const toolPanBefore = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewCenter`, true);
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "left", clickCount: 1 });
    await waitFor(window, `document.documentElement.dataset.qaPointerGesture === "pan"`, 5_000, "pan-owned");
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x + 30, y: surface.y + 50 });
    await waitFor(window, `document.documentElement.dataset.qaViewCenter !== ${JSON.stringify(toolPanBefore)}`, 5_000, "pan-transform");
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x + 30, y: surface.y + 50, button: "left", clickCount: 1 });
    await waitFor(window, `document.documentElement.dataset.qaPointerGesture === "none"`, 5_000, "pan-released");
    const toolPanAfter = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewCenter`, true);
    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="Zoom 도구"]').click()`, true);

    const inputMetrics = await window.webContents.executeJavaScript(`({ uploads:Number(document.documentElement.dataset.qaTextureUploads), seek:Number(document.documentElement.dataset.qaSeekDecodeCount) })`, true);
    const beforeFrame = await window.webContents.executeJavaScript(`({
      transform: [document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter, document.documentElement.dataset.qaViewTool, document.documentElement.dataset.qaDisplayState],
      frame: Number(document.querySelector(".primary-readout strong").textContent.replaceAll(",", "").split("/")[0]),
    })`, true);
    await window.webContents.executeJavaScript(`document.querySelector(".viewer-surface").dispatchEvent(new WheelEvent("wheel", { deltaY: 120, bubbles: true, cancelable: true }))`, true);
    await waitFor(window, `Number(document.querySelector(".primary-readout strong").textContent.replaceAll(",", "").split("/")[0]) === ${beforeFrame.frame + 1}`, 5_000, "ordinary-wheel");
    await new Promise((resolve) => setTimeout(resolve, 50));
    const afterFrameTransform = await window.webContents.executeJavaScript(`[document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter, document.documentElement.dataset.qaViewTool, document.documentElement.dataset.qaDisplayState]`, true);

    const beforeFallback = await window.webContents.executeJavaScript(`[document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter]`, true);
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
    sendKey(window, "RIGHT");
    await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "context-fallback");
    const afterFallback = await window.webContents.executeJavaScript(`[document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter]`, true);

    const beforeResize = await window.webContents.executeJavaScript(`({ center:document.documentElement.dataset.qaViewCenter.split(",").map(Number), revision:Number(document.documentElement.dataset.qaViewRevision) })`, true);
    window.setSize(940, 660);
    await waitFor(window, `Number(document.documentElement.dataset.qaViewRevision) > ${beforeResize.revision}`, 5_000, "resize-revision");
    const afterResize = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaViewCenter.split(",").map(Number)`, true);

    await window.webContents.executeJavaScript(`document.querySelector('button[title="전체화면 (F)"]').click()`, true);
    await waitForMain(() => window.isFullScreen(), 5_000, "fullscreen-enter");
    sendKey(window, "F");
    await waitForMain(() => !window.isFullScreen(), 5_000, "fullscreen-exit");

    await window.webContents.executeJavaScript(`document.querySelector('button[title="10%p 확대 (+)"]').click()`, true);
    await sendQaOpen(window, 1);
    await waitFor(window, openReadyExpression(1), 20_000, "new-session");
    const reset = await window.webContents.executeJavaScript(`({ zoom: Number(document.documentElement.dataset.qaViewZoom), center: document.documentElement.dataset.qaViewCenter.split(",").map(Number), tool:document.documentElement.dataset.qaViewTool })`, true);

    const synthetic = [];
    for (const sampleIndex of [actualSampleCount, actualSampleCount + 1]) {
      await sendQaOpen(window, sampleIndex);
      await waitFor(window, openReadyExpression(sampleIndex), 20_000, "synthetic");
      synthetic.push(await window.webContents.executeJavaScript(`(() => {
        const canvas = document.querySelector("canvas");
        const rect = canvas.getBoundingClientRect();
        return { width: canvas.width, height: canvas.height, aspectError: Math.abs(rect.width / rect.height - canvas.width / canvas.height) };
      })()`, true));
    }

    const drawSamples = [zoomDrawMs];
    const memorySamples = [];
    let cycles = 0;
    let errors = 0;
    let maxSeekDecodeCount = 0;
    const soakStartedAt = performance.now();
    const soakDeadline = soakStartedAt + minutes * 60_000;
    while (performance.now() < soakDeadline) {
      const sampleIndex = cycles % 3;
      await sendQaOpen(window, sampleIndex);
      await waitFor(window, openReadyExpression(sampleIndex), 20_000, "soak-open");
      drawSamples.push(await window.webContents.executeJavaScript(`(async () => {
        const startedAt = performance.now();
        document.querySelector('button[title="확대 (+)"]').click();
        await new Promise((resolve) => setTimeout(resolve, 0));
        document.querySelector("canvas").getBoundingClientRect();
        return performance.now() - startedAt;
      })()`, true));
      for (let index = 0; index < 5; index += 1) sendKey(window, "RIGHT");
      await window.webContents.executeJavaScript(`document.querySelector('button[title="화면 맞춤 (0)"]').click()`, true);
      if (cycles % 10 === 0) {
        await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
        sendKey(window, "RIGHT");
        await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "soak-fallback");
      }
      if (cycles % 20 === 0) {
        await window.webContents.executeJavaScript(`document.querySelector('button[title="전체화면 (F)"]').click()`, true);
        await waitForMain(() => window.isFullScreen(), 5_000, "soak-fullscreen-enter");
        await window.webContents.executeJavaScript(`document.querySelector('button[title="전체화면 (F)"]').click()`, true);
        await waitForMain(() => !window.isFullScreen(), 5_000, "soak-fullscreen-exit");
      }
      const state = await window.webContents.executeJavaScript(`({ error: document.querySelector(".error-message")?.textContent ?? null, seek: Number(document.documentElement.dataset.qaSeekDecodeCount ?? 0) })`, true);
      if (state.error) errors += 1;
      maxSeekDecodeCount = Math.max(maxSeekDecodeCount, state.seek);
      const browser = app.getAppMetrics().find((metric) => metric.type === "Browser");
      memorySamples.push({ minutes: (performance.now() - soakStartedAt) / 60_000, rssMiB: (browser?.memory.workingSetSize ?? 0) / 1024 });
      cycles += 1;
      if (cycles % 20 === 0) process.stdout.write(`phase3a soak ${memorySamples.at(-1).minutes.toFixed(1)}m ${cycles} cycles\n`);
    }

    const result = {
      initial,
      zoom: { steps: [wheelUpOne, wheelUpTwo, wheelDownOne], zoom: zoomed.zoom, anchorErrorImagePixels: anchorError, drawMs: zoomDrawMs },
      pan: { centerBefore: toolPanBefore, centerAfter: toolPanAfter, changed: toolPanBefore !== toolPanAfter },
      tools: {
        zoomDrag: { start: zoomToolStart, up: zoomToolUp, down: zoomToolDown },
        rightDisplayChanged: displayBeforeZoomRight !== displayAfterZoomRight && displayAfterZoomRight !== displayAfterPanRight,
        outsideRelease: true,
        fitCommand,
        actualCommand,
      },
      inputMetrics: { before: { uploads: initial.uploads, seek: initial.seek }, after: inputMetrics },
      frameTransform: { before: beforeFrame.transform, after: afterFrameTransform },
      frameTransformPreserved: JSON.stringify(beforeFrame.transform) === JSON.stringify(afterFrameTransform),
      fallbackTransformPreserved: String(beforeFallback) === String(afterFallback),
      resizeCenterError: Math.hypot(afterResize[0] - beforeResize.center[0], afterResize[1] - beforeResize.center[1]),
      newSessionReset: reset,
      synthetic,
      fullscreenPassed: true,
      soak: {
        minutes: (performance.now() - soakStartedAt) / 60_000,
        cycles,
        errors,
        maxSeekDecodeCount,
        drawP95Ms: percentile(drawSamples, 0.95),
        secondHalfBrowserRssSlopeMiBPerMinute: slope(memorySamples),
      },
    };
    result.passed = initial.zoom === 1
      && initial.tool === "pan"
      && initial.gesture === "none"
      && initial.aspectError < 1e-4
      && wheelUpOne === 1.1
      && wheelUpTwo === 1.2
      && wheelDownOne === 1.1
      && anchorError <= 0.5
      && result.pan.changed
      && zoomToolUp > zoomToolStart
      && zoomToolDown < zoomToolUp
      && result.tools.rightDisplayChanged
      && fitCommand.zoom === 1
      && fitCommand.tool === "zoom"
      && Math.abs(actualCommand.effectiveScale - 1) <= 1e-4
      && actualCommand.tool === "zoom"
      && inputMetrics.seek === initial.seek
      && inputMetrics.uploads === initial.uploads
      && result.frameTransformPreserved
      && result.fallbackTransformPreserved
      && result.resizeCenterError <= 0.5
      && reset.zoom === 1
      && reset.tool === "pan"
      && synthetic.every((value) => value.aspectError < 1e-4)
      && result.soak.errors === 0
      && result.soak.maxSeekDecodeCount === 0
      && result.soak.drawP95Ms <= 16
      && (minutes < 2 || result.soak.secondHalfBrowserRssSlopeMiBPerMinute <= 10);

    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.passed) process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    process.exitCode = 1;
  } finally {
    if (window.isFullScreen()) window.setFullScreen(false);
    if (forceRgba) await frameModule.shutdownFrameIpcResources();
    else await frameModule.shutdownCacheFrameIpcResources();
    ipcMain.removeHandler("frame:openQa");
    fullscreenModule.unregisterFullscreenIpc();
    await rm(syntheticDirectory, { recursive: true, force: true });
  }
  app.exit(process.exitCode ?? 0);
})().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  app.exit(1);
});
