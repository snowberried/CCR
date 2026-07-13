const { app, BrowserWindow, ipcMain } = require("electron");
const { mkdir, readdir, writeFile } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE23_QA = "1";
const root = process.cwd();
app.setAppPath(root);
const outputPath = path.join(root, "temp", "phase3b-display-qa.json");
const minutes = Number(process.argv.find((value) => value.startsWith("--minutes="))?.split("=")[1] ?? 0);
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

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
  throw new Error(`PHASE3B_TIMEOUT_${label}`);
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

async function selectPreset(window, presetId) {
  await window.webContents.executeJavaScript(`(() => {
    const select = document.querySelector('select[aria-label="Display Preset"]');
    select.value = ${JSON.stringify(presetId)};
    select.dispatchEvent(new Event("change", { bubbles: true }));
  })()`, true);
  return waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).presetId === ${JSON.stringify(presetId)}`, 5_000, `preset-${presetId}`);
}

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (files.length < 3) throw new Error("PHASE3B_NEEDS_THREE_SAMPLES");
  const cacheModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
  const fullscreenModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "fullscreenIpc.js")).href);
  cacheModule.registerCacheFrameIpc();
  fullscreenModule.registerFullscreenIpc();
  ipcMain.handle("frame:openQa", async (event, input) => {
    const sampleIndex = input && Number.isInteger(input.sampleIndex) ? input.sampleIndex : -1;
    if (sampleIndex < 0 || sampleIndex >= files.length) return { canceled: false, error: "QA_SAMPLE_INDEX_INVALID" };
    const opened = await cacheModule.openCachePathForQa(files[sampleIndex], event.sender);
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
    await waitFor(window, `Boolean(window.ccr?.openQaVideo) && Boolean(document.querySelector(".display-panel"))`, 10_000, "bridge");
    await sendQaOpen(window, 0);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "0" && document.documentElement.dataset.qaBackgroundComplete === "true"`, 20_000, "open");

    const initial = await window.webContents.executeJavaScript(`(() => {
      const canvas = document.querySelector("canvas");
      window.__phase3bOriginal = new Uint8Array(canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data);
      return {
        state: JSON.parse(document.documentElement.dataset.qaDisplayState),
        uploads: Number(document.documentElement.dataset.qaTextureUploads),
        seek: Number(document.documentElement.dataset.qaSeekDecodeCount),
        view: [document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter],
      };
    })()`, true);

    await selectPreset(window, "lung-like");
    const preset = await window.webContents.executeJavaScript(`({
      state: JSON.parse(document.documentElement.dataset.qaDisplayState),
      uploads: Number(document.documentElement.dataset.qaTextureUploads),
      seek: Number(document.documentElement.dataset.qaSeekDecodeCount),
      drawMs: Number(document.documentElement.dataset.qaDisplayDrawMs),
      view: [document.documentElement.dataset.qaViewZoom, document.documentElement.dataset.qaViewCenter],
    })`, true);

    await selectPreset(window, "original");
    const originalEquality = await window.webContents.executeJavaScript(`(() => {
      const canvas = document.querySelector("canvas");
      const current = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
      let different = 0;
      for (let index = 0; index < current.length; index += 1) if (current[index] !== window.__phase3bOriginal[index]) different += 1;
      return { different, length: current.length };
    })()`, true);

    const surface = await window.webContents.executeJavaScript(`(() => {
      const rect = document.querySelector(".viewer-surface").getBoundingClientRect();
      return { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) };
    })()`, true);
    window.webContents.sendInputEvent({ type: "mouseDown", x: surface.x, y: surface.y, button: "right", clickCount: 1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: surface.x + 80, y: surface.y - 50 });
    window.webContents.sendInputEvent({ type: "mouseUp", x: surface.x + 80, y: surface.y - 50, button: "right", clickCount: 1 });
    const dragState = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaDisplayState); return s.presetId === "custom" && s.width > 1 && s.level > 0.5 ? s : null; })()`, 5_000, "right-drag");

    await window.webContents.executeJavaScript(`(() => {
      for (const [label,value] of [["Video Gamma","1.5"],["Video Sharp","0.3"]]) {
        const input=document.querySelector('input[aria-label="'+label+'"]'); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(input,value); input.dispatchEvent(new Event("input",{bubbles:true}));
      }
      document.querySelector('.display-buttons button[aria-pressed]')?.click();
    })()`, true);
    const manualControls = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaDisplayState); return s.gamma === 1.5 && s.sharpAmount === 0.3 && s.invert === true ? s : null; })()`, 5_000, "manual-controls");

    window.webContents.sendInputEvent({ type: "keyDown", keyCode: "O" });
    const compareDown = await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).comparingOriginal === true`, 5_000, "compare-down");
    window.webContents.sendInputEvent({ type: "keyUp", keyCode: "O" });
    const compareUp = await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).comparingOriginal === false`, 5_000, "compare-up");
    window.webContents.sendInputEvent({ type: "keyDown", keyCode: "O" });
    await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).comparingOriginal === true`, 5_000, "compare-blur-down");
    await window.webContents.executeJavaScript(`window.dispatchEvent(new Event("blur"))`, true);
    const compareBlur = await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).comparingOriginal === false`, 5_000, "compare-blur-up");
    const afterCompareState = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaDisplayState)`, true);

    const stateBeforeFrame = JSON.stringify(afterCompareState);
    sendKey(window, "RIGHT");
    await waitFor(window, `document.querySelector(".primary-readout strong").textContent.trim().startsWith("2 /")`, 5_000, "frame-two");
    const stateAfterFrame = JSON.stringify(await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaDisplayState)`, true));

    sendKey(window, "LEFT");
    await waitFor(window, `document.querySelector(".primary-readout strong").textContent.trim().startsWith("1 /")`, 5_000, "frame-one");
    await selectPreset(window, "lung-like");
    await window.webContents.executeJavaScript(`(() => {
      const canvas=document.querySelector("canvas");
      window.__phase3bWebgl = new Uint8Array(canvas.getContext("2d").getImageData(0,0,canvas.width,canvas.height).data);
    })()`, true);
    const fallbackStateBefore = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaDisplayState`, true);
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
    sendKey(window, "RIGHT");
    await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "fallback");
    sendKey(window, "LEFT");
    await waitFor(window, `document.querySelector(".primary-readout strong").textContent.trim().startsWith("1 /")`, 5_000, "fallback-frame-one");
    const parity = await window.webContents.executeJavaScript(`(() => {
      const canvas=document.querySelector("canvas");
      const current=canvas.getContext("2d").getImageData(0,0,canvas.width,canvas.height).data;
      const histogram=new Array(256).fill(0); let total=0,max=0,count=0;
      for(let index=0;index<current.length;index+=4){ for(let channel=0;channel<3;channel+=1){ const d=Math.abs(current[index+channel]-window.__phase3bWebgl[index+channel]); histogram[d]+=1; total+=d; max=Math.max(max,d); count+=1; } }
      let cumulative=0,p99=0; for(;p99<256;p99+=1){ cumulative+=histogram[p99]; if(cumulative>=count*0.99)break; }
      return { mean:total/count,p99,max };
    })()`, true);
    const fallbackStateAfter = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaDisplayState`, true);
    const fallbackDrawMs = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaDisplayDrawMs`, true));

    await sendQaOpen(window, 1);
    await waitFor(window, `document.documentElement.dataset.qaSampleIndex === "1" && document.documentElement.dataset.qaBackgroundComplete === "true"`, 20_000, "new-session");
    const reset = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaDisplayState)`, true);
    await window.webContents.executeJavaScript(`document.querySelector('button[title="전체화면 (F)"]').click()`, true);
    await waitFor(window, `document.fullscreenElement === null`, 100, "renderer-alive");
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (!window.isFullScreen()) throw new Error("PHASE3B_FULLSCREEN_ENTER_FAILED");
    window.setFullScreen(false);

    const drawSamples = [preset.drawMs];
    const memorySamples = [];
    let cycles = 0;
    let errors = 0;
    let maxSeekDecodeCount = 0;
    let parameterTextureUploads = 0;
    const soakStartedAt = performance.now();
    const soakDeadline = soakStartedAt + minutes * 60_000;
    const presetIds = ["lung-like", "mediastinum-like", "bone-like", "high-contrast", "inverse", "original"];
    while (performance.now() < soakDeadline) {
      const beforeUploads = Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaTextureUploads`, true));
      await selectPreset(window, presetIds[cycles % presetIds.length]);
      const sample = await window.webContents.executeJavaScript(`({ draw:Number(document.documentElement.dataset.qaDisplayDrawMs), uploads:Number(document.documentElement.dataset.qaTextureUploads), seek:Number(document.documentElement.dataset.qaSeekDecodeCount), error:document.querySelector(".error-message")?.textContent ?? null })`, true);
      drawSamples.push(sample.draw);
      parameterTextureUploads += sample.uploads - beforeUploads;
      maxSeekDecodeCount = Math.max(maxSeekDecodeCount, sample.seek);
      if (sample.error) errors += 1;
      if (cycles % 3 === 0) sendKey(window, "RIGHT");
      if (cycles % 5 === 0) { window.webContents.sendInputEvent({ type: "keyDown", keyCode: "O" }); window.webContents.sendInputEvent({ type: "keyUp", keyCode: "O" }); }
      const browser = app.getAppMetrics().find((metric) => metric.type === "Browser");
      memorySamples.push({ minutes: (performance.now() - soakStartedAt) / 60_000, rssMiB: (browser?.memory.workingSetSize ?? 0) / 1024 });
      cycles += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      if (cycles % 100 === 0) process.stdout.write(`phase3b soak ${memorySamples.at(-1).minutes.toFixed(1)}m ${cycles} cycles\n`);
    }

    const result = {
      initial,
      preset,
      originalEquality,
      dragState,
      manualControls,
      compareLifecycle: { down: Boolean(compareDown), up: Boolean(compareUp), blur: Boolean(compareBlur), restored: stateBeforeFrame === stateAfterFrame },
      frameStatePreserved: stateBeforeFrame === stateAfterFrame,
      fallback: { statePreserved: fallbackStateBefore === fallbackStateAfter, drawMs: fallbackDrawMs, parity },
      newSessionReset: reset,
      fullscreenPassed: true,
      soak: {
        minutes: (performance.now() - soakStartedAt) / 60_000,
        cycles,
        errors,
        maxSeekDecodeCount,
        parameterTextureUploads,
        drawP95Ms: percentile(drawSamples, 0.95),
        secondHalfBrowserRssSlopeMiBPerMinute: slope(memorySamples),
      },
    };
    result.passed = initial.state.presetId === "original"
      && preset.state.presetId === "lung-like"
      && preset.uploads === initial.uploads
      && preset.seek === initial.seek
      && JSON.stringify(preset.view) === JSON.stringify(initial.view)
      && preset.drawMs <= 16
      && originalEquality.different === 0
      && dragState.presetId === "custom"
      && manualControls.gamma === 1.5 && manualControls.sharpAmount === 0.3 && manualControls.invert
      && result.compareLifecycle.restored
      && result.frameStatePreserved
      && result.fallback.statePreserved
      && parity.mean <= 4 && parity.p99 <= 12 && parity.max <= 80
      && reset.presetId === "original" && reset.revision === 0
      && result.soak.errors === 0
      && result.soak.maxSeekDecodeCount === 0
      && result.soak.parameterTextureUploads === 0
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
    await cacheModule.shutdownCacheFrameIpcResources();
    ipcMain.removeHandler("frame:openQa");
    fullscreenModule.unregisterFullscreenIpc();
  }
  app.exit(process.exitCode ?? 0);
})().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  app.exit(1);
});
