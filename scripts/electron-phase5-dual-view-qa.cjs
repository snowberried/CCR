const { app, BrowserWindow, clipboard, ipcMain } = require("electron");
const { createHash } = require("node:crypto");
const { mkdir, readdir, rm, writeFile } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE23_QA = "1";
const root = process.cwd();
app.setAppPath(root);
const forceRgba = process.env.CCR_FORCE_RGBA === "1";
const holdMs = Number(process.env.CCR_QA_HOLD_MS ?? 0);
const soakMinutes = Number(process.env.CCR_QA_MINUTES ?? 0.5);
const reportPath = path.join(root, "temp", `phase5-dual-view-qa${forceRgba ? "-rgba" : ""}.json`);
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

async function mediaFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((a, b) => a.localeCompare(b));
}

async function waitFor(window, expression, timeoutMs = 15_000, label = "unknown") {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await window.webContents.executeJavaScript(expression, true);
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`PHASE5_TIMEOUT_${label}`);
}

async function waitForMain(predicate, timeoutMs = 5_000, label = "main") {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`PHASE5_TIMEOUT_${label}`);
}

function click(window, point) {
  window.webContents.sendInputEvent({ type: "mouseMove", ...point });
  window.webContents.sendInputEvent({ type: "mouseDown", button: "left", clickCount: 1, ...point });
  window.webContents.sendInputEvent({ type: "mouseUp", button: "left", clickCount: 1, ...point });
}

function drag(window, start, end, button = "left") {
  window.webContents.sendInputEvent({ type: "mouseMove", ...start });
  window.webContents.sendInputEvent({ type: "mouseDown", button, clickCount: 1, ...start });
  window.webContents.sendInputEvent({ type: "mouseMove", ...end });
  window.webContents.sendInputEvent({ type: "mouseUp", button, clickCount: 1, ...end });
}

function key(window, keyCode, type = "keyDown", isAutoRepeat = false) {
  window.webContents.sendInputEvent({ type, keyCode, isAutoRepeat });
}

function percentile(values, fraction) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function slope(samples) {
  if (samples.length < 4) return 0;
  const half = samples.slice(Math.floor(samples.length / 2));
  const xMean = half.reduce((sum, value) => sum + value.minutes, 0) / half.length;
  const yMean = half.reduce((sum, value) => sum + value.rssMiB, 0) / half.length;
  const numerator = half.reduce((sum, value) => sum + (value.minutes - xMean) * (value.rssMiB - yMean), 0);
  const denominator = half.reduce((sum, value) => sum + (value.minutes - xMean) ** 2, 0);
  return denominator ? numerator / denominator : 0;
}

function processMemory() {
  const metrics = app.getAppMetrics();
  const toMiB = (values) => values.reduce((sum, metric) => sum + (metric.memory.workingSetSize ?? 0), 0) / 1024;
  return {
    totalRssMiB: toMiB(metrics),
    browserRssMiB: toMiB(metrics.filter((metric) => metric.type === "Browser")),
    rendererRssMiB: toMiB(metrics.filter((metric) => metric.type === "Tab")),
    gpuRssMiB: toMiB(metrics.filter((metric) => metric.type === "GPU")),
  };
}

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const paneFrameReady = (frameIndex) => `(() => { const q=JSON.parse(document.documentElement.dataset.qaPaneFrames || "{}"); return q.a?.frameIndex===${frameIndex} && q.b?.frameIndex===${frameIndex} && q.a.fingerprint===q.b.fingerprint && q.sharedPixels ? q : null; })()`;

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (!files.length) throw new Error("PHASE5_NEEDS_SAMPLE");
  const frameModule = forceRgba
    ? await import(pathToFileURL(path.join(root, "dist-electron", "electron", "frameIpc.js")).href)
    : await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
  const exportModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "exportIpc.js")).href);
  const fullscreenModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "fullscreenIpc.js")).href);
  if (forceRgba) frameModule.registerFrameIpc();
  else frameModule.registerCacheFrameIpc();
  exportModule.registerExportIpc();
  fullscreenModule.registerFullscreenIpc();
  ipcMain.handle("frame:openQa", async (event) => {
    const opened = forceRgba
      ? await frameModule.openFramePathForQa(files[0])
      : await frameModule.openCachePathForQa(files[0], event.sender);
    return { ...opened, sourceBaseName: "qa-source", qaSampleIndex: 0 };
  });

  await app.whenReady();
  const window = new BrowserWindow({
    width: 1440,
    height: 900,
    show: false,
    webPreferences: {
      preload: path.join(root, "dist-electron", "electron", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });

  try {
    await window.loadFile(path.join(root, "dist", "index.html"));
    await waitFor(window, `Boolean(window.ccr?.copyPng) && Boolean(document.querySelector('[title*="동일 프레임"]'))`, 10_000, "bridge");
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 0 }))`, true);
    const ready = forceRgba ? `Boolean(document.querySelector(".status-ready"))` : `document.documentElement.dataset.qaBackgroundComplete === "true"`;
    await waitFor(window, ready, 30_000, "open");

    const measureNavigation = async (count, dual) => {
      const samples = [];
      const render = [];
      const cached = [];
      for (let index = 0; index < count; index += 1) {
        const before = dual
          ? Number(await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneFrames).a.frameIndex`, true))
          : Number(await window.webContents.executeJavaScript(`document.querySelector('[aria-label="프레임 번호"]').value`, true)) - 1;
        const startedAt = performance.now();
        key(window, "RIGHT");
        key(window, "RIGHT", "keyUp");
        const next = before + 1;
        if (dual) {
          try {
            await waitFor(window, paneFrameReady(next), 10_000, "nav-dual");
            await waitFor(window, `Number(document.querySelector('[aria-label="프레임 번호"]').value)===${next + 1}`, 5_000, "nav-dual-ui");
          } catch (error) {
            const actual = await window.webContents.executeJavaScript(`({ ui:document.querySelector('[aria-label="프레임 번호"]').value, frames:document.documentElement.dataset.qaPaneFrames, status:document.querySelector('[class*="status-"]')?.textContent })`, true);
            throw new Error(`${error.message}_${JSON.stringify({ before, expectedInternal: next, actual })}`);
          }
        } else await waitFor(window, `Number(document.querySelector('[aria-label="프레임 번호"]').value)===${next + 1}`, 10_000, "nav-single");
        samples.push(performance.now() - startedAt);
        render.push(Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaDisplayDrawMs || 0`, true)));
        cached.push(Number(await window.webContents.executeJavaScript(`document.documentElement.dataset.qaRequestMs || 0`, true)));
      }
      return { p95Ms: percentile(samples, 0.95), cachedRequestP95Ms: percentile(cached, 0.95), renderP95Ms: percentile(render, 0.95) };
    };

    const singleMetrics = await measureNavigation(12, false);
    key(window, "HOME");
    key(window, "HOME", "keyUp");
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1"`, 10_000, "home");

    const singleMemory = processMemory();
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="비교 보기"]').click()`, true);
    await waitFor(window, `document.querySelectorAll(".viewer-pane").length===2 && document.documentElement.dataset.qaDualView==="true"`, 5_000, "dual-on");
    const initialFrames = await waitFor(window, paneFrameReady(0), 5_000, "initial-sync");
    await new Promise((resolve) => setTimeout(resolve, 100));
    const initialDualMemory = processMemory();
    const initialStates = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates)`, true);
    const paneRects = await window.webContents.executeJavaScript(`[...document.querySelectorAll(".viewer-pane")].map((pane) => { const r=pane.getBoundingClientRect(); return { left:r.left,top:r.top,width:r.width,height:r.height,center:{x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)} }; })`, true);

    click(window, paneRects[1].center);
    await waitFor(window, `document.documentElement.dataset.qaActivePane === "b"`, 5_000, "active-b");
    await window.webContents.executeJavaScript(`(() => { const pane=document.querySelectorAll(".viewer-pane")[1]; const r=pane.getBoundingClientRect(); for(let i=0;i<4;i+=1)pane.dispatchEvent(new WheelEvent("wheel",{deltaY:-120,ctrlKey:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,bubbles:true,cancelable:true})); })()`, true);
    const bZoomed = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaPaneStates); return s.b.viewTransform.zoom>1 && s.a.viewTransform.zoom===1?s:null; })()`, 5_000, "b-zoom");

    click(window, paneRects[0].center);
    await waitFor(window, `document.documentElement.dataset.qaActivePane === "a"`, 5_000, "active-a");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector('[aria-label="화면 보정 감마"]'); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"1.5"); input.dispatchEvent(new Event("input",{bubbles:true})); })()`, true);
    const aDisplay = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaPaneStates); return s.a.display.gamma===1.5 && s.b.display.gamma===1?s:null; })()`, 5_000, "a-display");

    click(window, paneRects[1].center);
    const bDisplayBefore = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates).b.display`, true);
    drag(window, paneRects[1].center, { x: paneRects[1].center.x + 55, y: paneRects[1].center.y - 30 }, "right");
    const bDisplayAfter = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaPaneStates); return s.b.display.revision>${bDisplayBefore.revision} && s.a.display.gamma===1.5?s:null; })()`, 5_000, "b-display");

    key(window, "O");
    const originalHold = await waitFor(window, `(() => { const s=JSON.parse(document.documentElement.dataset.qaPaneStates); return s.b.comparingOriginal===true && s.a.comparingOriginal===false?s:null; })()`, 5_000, "original-hold");
    key(window, "O", "keyUp");
    await waitFor(window, `JSON.parse(document.documentElement.dataset.qaPaneStates).b.comparingOriginal===false`, 5_000, "original-release");
    await window.webContents.executeJavaScript(`new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`, true);

    const metricsBeforeCrosshair = await window.webContents.executeJavaScript(`({ uploads:Number(document.documentElement.dataset.qaTextureUploads||0), frameUploads:Number(document.documentElement.dataset.qaFrameUploads||0), draws:Number(document.documentElement.dataset.qaDrawCount||0), rgba:Number(document.documentElement.dataset.qaRgbaDisplayProcesses||0), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) })`, true);
    const crosshairSamples = await window.webContents.executeJavaScript(`(async () => {
      const pane=document.querySelectorAll(".viewer-pane")[0], r=pane.getBoundingClientRect(), samples=[];
      for(let i=0;i<40;i+=1){
        pane.dispatchEvent(new PointerEvent("pointermove",{pointerId:90,clientX:r.left+r.width*(.35+i/200),clientY:r.top+r.height*(.42+i/400),bubbles:true}));
        await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
        samples.push(Number(document.documentElement.dataset.qaCrosshairUpdateMs||0));
      }
      return samples;
    })()`, true);
    const crosshair = await waitFor(window, `(() => { const q=document.documentElement.dataset.qaCrosshair; return q && q!=="hidden"?JSON.parse(q):null; })()`, 5_000, "crosshair");
    const crosshairError = await window.webContents.executeJavaScript(`(() => { const q=JSON.parse(document.documentElement.dataset.qaCrosshair); const s=JSON.parse(document.documentElement.dataset.qaPaneStates)[q.targetPane].viewTransform; const scale=Math.min(s.viewportSize.width/s.imageSize.width,s.viewportSize.height/s.imageSize.height)*s.zoom; const image={x:s.center.x+(q.targetViewportPoint.x-s.viewportSize.width/2)/scale,y:s.center.y+(q.targetViewportPoint.y-s.viewportSize.height/2)/scale}; return Math.hypot(image.x-q.imagePoint.x,image.y-q.imagePoint.y); })()`, true);
    const metricsAfterCrosshair = await window.webContents.executeJavaScript(`({ uploads:Number(document.documentElement.dataset.qaTextureUploads||0), frameUploads:Number(document.documentElement.dataset.qaFrameUploads||0), draws:Number(document.documentElement.dataset.qaDrawCount||0), rgba:Number(document.documentElement.dataset.qaRgbaDisplayProcesses||0), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) })`, true);
    await window.webContents.executeJavaScript(`(() => { const pane=document.querySelectorAll(".viewer-pane")[0], r=pane.getBoundingClientRect(); pane.dispatchEvent(new PointerEvent("pointermove",{pointerId:91,clientX:r.left+2,clientY:r.top+r.height/2,bubbles:true})); })()`, true);
    const letterboxHidden = await waitFor(window, `document.documentElement.dataset.qaCrosshair === "hidden" && [...document.querySelectorAll(".linked-crosshair")].every((value)=>value.hidden)`, 5_000, "crosshair-letterbox");
    window.webContents.sendInputEvent({ type: "mouseMove", ...paneRects[0].center });
    await waitFor(window, `document.documentElement.dataset.qaCrosshair !== "hidden"`, 5_000, "crosshair-before-cancel");
    await window.webContents.executeJavaScript(`document.querySelectorAll(".viewer-pane")[0].dispatchEvent(new PointerEvent("pointercancel",{pointerId:91,bubbles:true}))`, true);
    const pointerCancelHidden = await waitFor(window, `[...document.querySelectorAll(".linked-crosshair")].every((value)=>value.hidden)`, 5_000, "crosshair-cancel");
    window.webContents.sendInputEvent({ type: "mouseMove", x: 2, y: 2 });
    await waitFor(window, `[...document.querySelectorAll(".linked-crosshair")].every((value)=>value.hidden)`, 5_000, "crosshair-hide");

    click(window, paneRects[0].center);
    await waitFor(window, `document.documentElement.dataset.qaActivePane === "a"`, 5_000, "annotation-active-a");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rectangle 도구"]').click()`, true);
    await waitFor(window, `document.documentElement.dataset.qaViewTool === "rectangle"`, 5_000, "annotation-tool");
    const canvasA = await window.webContents.executeJavaScript(`document.querySelectorAll(".frame-canvas")[0].getBoundingClientRect().toJSON()`, true);
    drag(window,
      { x: Math.round(canvasA.left + canvasA.width * 0.3), y: Math.round(canvasA.top + canvasA.height * 0.3) },
      { x: Math.round(canvasA.left + canvasA.width * 0.55), y: Math.round(canvasA.top + canvasA.height * 0.55) });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "1"`, 5_000, "annotation");
    const annotationParity = await window.webContents.executeJavaScript(`(() => { const panes=[...document.querySelectorAll(".viewer-pane")]; const ids=panes.map((pane)=>[...new Set([...pane.querySelectorAll("[data-annotation-id]")].map((node)=>node.dataset.annotationId))]); return { ids, handles:panes.map((pane)=>pane.querySelectorAll(".annotation-handle,.annotation-selection").length) }; })()`, true);
    click(window, paneRects[1].center);
    await waitFor(window, `document.documentElement.dataset.qaActivePane === "b"`, 5_000, "annotation-inactive-owner");
    annotationParity.inactiveOwnerHandles = await window.webContents.executeJavaScript(`[...document.querySelectorAll(".viewer-pane")].map((pane)=>pane.querySelectorAll(".annotation-handle,.annotation-selection").length)`, true);

    const copyActive = async (paneId, mode) => {
      await waitFor(window, `!document.querySelector(".export-buttons button:nth-child(2)").disabled`, 10_000, `export-ready-${paneId}-${mode}`);
      await window.webContents.executeJavaScript(`delete document.documentElement.dataset.qaExport; document.querySelector('input[value="${mode}"]').click();`, true);
      const paneIndex = paneId === "a" ? 0 : 1;
      const center = await window.webContents.executeJavaScript(`(() => { const r=document.querySelectorAll(".viewer-pane")[${paneIndex}].getBoundingClientRect(); return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}; })()`, true);
      click(window, center);
      await waitFor(window, `document.documentElement.dataset.qaActivePane === "${paneId}"`, 5_000, `export-active-${paneId}`);
      await window.webContents.executeJavaScript(`document.querySelector(".export-buttons button:nth-child(2)").click()`, true);
      const qa = await waitFor(window, `(() => { const q=document.documentElement.dataset.qaExport; return q && JSON.parse(q).paneId==="${paneId}" && !document.querySelector(".export-buttons button:nth-child(2)").disabled?JSON.parse(q):null; })()`, 10_000, `export-${paneId}-${mode}`);
      return { qa, hash: hash(clipboard.readImage().toPNG()) };
    };
    const exportAFull = await copyActive("a", "full-frame");
    const exportBFull = await copyActive("b", "full-frame");
    const exportACurrent = await copyActive("a", "current-view");
    const exportBCurrent = await copyActive("b", "current-view");
    const exportARepeat = await copyActive("a", "current-view");

    const beforeNavigation = await window.webContents.executeJavaScript(`({ uploads:Number(document.documentElement.dataset.qaFrameUploads||0), draws:Number(document.documentElement.dataset.qaDrawCount||0), rgba:Number(document.documentElement.dataset.qaRgbaDisplayProcesses||0), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) })`, true);
    key(window, "RIGHT");
    key(window, "RIGHT", "keyUp");
    const navigatedFrames = await waitFor(window, paneFrameReady(1), 10_000, "frame-sync");
    const afterNavigation = await window.webContents.executeJavaScript(`({ uploads:Number(document.documentElement.dataset.qaFrameUploads||0), draws:Number(document.documentElement.dataset.qaDrawCount||0), rgba:Number(document.documentElement.dataset.qaRgbaDisplayProcesses||0), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) })`, true);
    const dualMetrics = await measureNavigation(12, true);

    let hold = { durationMs: 0, loading: 0, sync: true, seekDelta: 0 };
    if (holdMs > 0) {
      const holdBefore = await window.webContents.executeJavaScript(`({ seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0), loading:0 })`, true);
      await window.webContents.executeJavaScript(`(() => { window.__phase5LoadingInsertions=0; window.__phase5LoadingObserver=new MutationObserver((records)=>{ for(const record of records)for(const node of record.addedNodes)if(node instanceof Element && (node.matches(".loading-label") || node.querySelector?.(".loading-label")))window.__phase5LoadingInsertions+=1; }); window.__phase5LoadingObserver.observe(document.body,{childList:true,subtree:true}); })()`, true);
      key(window, "RIGHT");
      const startedAt = performance.now();
      let repeats = 0;
      while (performance.now() - startedAt < holdMs) {
        key(window, "RIGHT", "keyDown", true);
        repeats += 1;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      key(window, "RIGHT", "keyUp");
      await waitFor(window, `document.querySelector(".status-ready")`, 10_000, "hold-ready");
      const forward = await window.webContents.executeJavaScript(`(() => { const q=JSON.parse(document.documentElement.dataset.qaPaneFrames); return { q, loading:Number(document.querySelectorAll(".loading-label").length), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) }; })()`, true);
      key(window, "LEFT");
      const reverseStartedAt = performance.now();
      while (performance.now() - reverseStartedAt < holdMs) {
        key(window, "LEFT", "keyDown", true);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      key(window, "LEFT", "keyUp");
      await waitFor(window, `document.querySelector(".status-ready")`, 10_000, "reverse-ready");
      const reverse = await window.webContents.executeJavaScript(`(() => { const q=JSON.parse(document.documentElement.dataset.qaPaneFrames); return { q, loading:Number(document.querySelectorAll(".loading-label").length), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0) }; })()`, true);
      const loadingInsertions = await window.webContents.executeJavaScript(`(() => { window.__phase5LoadingObserver?.disconnect(); return window.__phase5LoadingInsertions||0; })()`, true);
      hold = {
        durationMs: holdMs,
        repeats,
        loading: Math.max(forward.loading, reverse.loading, loadingInsertions),
        sync: forward.q.a.frameIndex === forward.q.b.frameIndex && forward.q.a.fingerprint === forward.q.b.fingerprint && forward.q.sharedPixels && reverse.q.a.frameIndex === reverse.q.b.frameIndex && reverse.q.a.fingerprint === reverse.q.b.fingerprint && reverse.q.sharedPixels,
        seekDelta: reverse.seek - holdBefore.seek,
      };
    }

    const beforeToggle = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates)`, true);
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="단일 보기"]').click()`, true);
    await waitFor(window, `document.querySelectorAll(".viewer-pane").length===1`, 5_000, "dual-off");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="비교 보기"]').click()`, true);
    await waitFor(window, `document.querySelectorAll(".viewer-pane").length===2`, 5_000, "dual-restore");
    const afterToggle = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates)`, true);

    const desktop = await window.webContents.executeJavaScript(`({ width:document.documentElement.clientWidth, scrollWidth:document.documentElement.scrollWidth, paneWidths:[...document.querySelectorAll(".viewer-pane")].map((pane)=>pane.getBoundingClientRect().width) })`, true);
    await window.webContents.executeJavaScript(`document.querySelector('button[aria-label="전체 화면"]').click()`, true);
    await waitForMain(() => window.isFullScreen(), 5_000, "fullscreen-enter");
    const fullscreenPoint = await window.webContents.executeJavaScript(`(() => { const r=document.querySelectorAll(".viewer-pane")[0].getBoundingClientRect(); return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}; })()`, true);
    window.webContents.sendInputEvent({ type: "mouseMove", ...fullscreenPoint });
    const fullscreenCrosshair = await waitFor(window, `document.documentElement.dataset.qaCrosshair !== "hidden"`, 5_000, "fullscreen-crosshair");
    key(window, "F");
    key(window, "F", "keyUp");
    await waitForMain(() => !window.isFullScreen(), 5_000, "fullscreen-exit");

    window.setFullScreen(false);
    window.unmaximize();
    await new Promise((resolve) => setTimeout(resolve, 200));
    window.setContentSize(720, 600);
    const compact = await waitFor(window, `(() => { const value={ width:document.documentElement.clientWidth, scrollWidth:document.documentElement.scrollWidth, panes:document.querySelectorAll(".viewer-pane").length, paneWidths:[...document.querySelectorAll(".viewer-pane")].map((pane)=>pane.getBoundingClientRect().width) }; return value.width<=720?value:null; })()`, 5_000, "compact");
    window.setContentSize(1440, 900);
    await new Promise((resolve) => setTimeout(resolve, 100));

    const memory = [];
    let soakCycles = 0;
    const soakStart = performance.now();
    const soakEnd = soakStart + soakMinutes * 60_000;
    while (performance.now() < soakEnd) {
      const panes = await window.webContents.executeJavaScript(`[...document.querySelectorAll(".viewer-pane")].map((pane)=>{const r=pane.getBoundingClientRect();return{x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}})`, true);
      window.webContents.sendInputEvent({ type: "mouseMove", ...panes[soakCycles % 2] });
      key(window, soakCycles % 2 ? "LEFT" : "RIGHT");
      key(window, soakCycles % 2 ? "LEFT" : "RIGHT", "keyUp");
      await new Promise((resolve) => setTimeout(resolve, 30));
      memory.push({ minutes: (performance.now() - soakStart) / 60_000, ...processMemory() });
      soakCycles += 1;
    }
    await waitFor(window, `document.querySelector(".status-ready")`, 10_000, "soak-ready");
    const soakState = await window.webContents.executeJavaScript(`({ frames:JSON.parse(document.documentElement.dataset.qaPaneFrames), seek:Number(document.documentElement.dataset.qaSeekDecodeCount||0), error:document.querySelector(".error-message")?.textContent||null })`, true);

    let fallback = { tested: false, preserved: true, sync: true, crosshairHiddenOnLoss: true };
    if (!forceRgba) {
      const before = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates)`, true);
      const point = await window.webContents.executeJavaScript(`(() => { const r=document.querySelectorAll(".viewer-pane")[0].getBoundingClientRect(); return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}; })()`, true);
      window.webContents.sendInputEvent({ type: "mouseMove", ...point });
      await waitFor(window, `document.documentElement.dataset.qaCrosshair !== "hidden"`, 5_000, "fallback-crosshair-before");
      await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaLoseContext"))`, true);
      const crosshairHiddenOnLoss = await waitFor(window, `[...document.querySelectorAll(".linked-crosshair")].every((value)=>value.hidden)`, 5_000, "fallback-crosshair-hidden");
      key(window, "RIGHT");
      key(window, "RIGHT", "keyUp");
      await waitFor(window, `document.documentElement.dataset.qaPixelFormat === "rgba"`, 10_000, "fallback");
      const after = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneStates)`, true);
      const frames = await window.webContents.executeJavaScript(`JSON.parse(document.documentElement.dataset.qaPaneFrames)`, true);
      fallback = {
        tested: true,
        crosshairHiddenOnLoss: Boolean(crosshairHiddenOnLoss),
        preserved: ["a", "b"].every((id) => before[id].display.level === after[id].display.level && before[id].display.gamma === after[id].display.gamma && before[id].viewTransform.zoom === after[id].viewTransform.zoom && before[id].tool === after[id].tool),
        sync: frames.a.frameIndex === frames.b.frameIndex && frames.a.fingerprint === frames.b.fingerprint && frames.sharedPixels,
      };
    }

    const result = {
      mode: forceRgba ? "rgba" : "webgl",
      initialFrames,
      initialClone: JSON.stringify(initialStates.a) === JSON.stringify(initialStates.b),
      independentView: bZoomed.a.viewTransform.zoom === 1 && bZoomed.b.viewTransform.zoom > 1,
      independentDisplay: aDisplay.a.display.gamma === 1.5 && aDisplay.b.display.gamma === 1 && bDisplayAfter.a.display.gamma === 1.5,
      originalHoldOwned: originalHold.b.comparingOriginal && !originalHold.a.comparingOriginal,
      crosshair: {
        sourcePane: crosshair.sourcePane,
        targetPane: crosshair.targetPane,
        imageErrorPixels: crosshairError,
        updateP95Ms: percentile(crosshairSamples, 0.95),
        metricsBefore: metricsBeforeCrosshair,
        metricsAfter: metricsAfterCrosshair,
        noVideoWork: JSON.stringify(metricsBeforeCrosshair) === JSON.stringify(metricsAfterCrosshair),
        letterboxHidden: Boolean(letterboxHidden),
        pointerCancelHidden: Boolean(pointerCancelHidden),
      },
      annotation: annotationParity,
      export: {
        aFull: exportAFull.qa,
        bFull: exportBFull.qa,
        aCurrent: exportACurrent.qa,
        bCurrent: exportBCurrent.qa,
        displayHashesDiffer: exportAFull.hash !== exportBFull.hash,
        viewHashesDiffer: exportACurrent.hash !== exportBCurrent.hash,
        deterministicActiveA: exportACurrent.hash === exportARepeat.hash,
      },
      navigation: { single: singleMetrics, dual: dualMetrics, before: beforeNavigation, after: afterNavigation, frames: navigatedFrames },
      memory: {
        singleMiB: singleMemory,
        initialDualMiB: initialDualMemory,
        directDeltaMiB: Object.fromEntries(Object.keys(singleMemory).map((key) => [key, initialDualMemory[key] - singleMemory[key]])),
      },
      hold,
      stateRestore: ["a", "b"].every((id) => beforeToggle[id].display.gamma === afterToggle[id].display.gamma && beforeToggle[id].viewTransform.zoom === afterToggle[id].viewTransform.zoom && beforeToggle[id].tool === afterToggle[id].tool),
      desktop,
      fullscreenCrosshair: Boolean(fullscreenCrosshair),
      compact,
      soak: {
        minutes: (performance.now() - soakStart) / 60_000,
        cycles: soakCycles,
        totalRssStartMiB: memory[0]?.totalRssMiB ?? 0,
        totalRssEndMiB: memory.at(-1)?.totalRssMiB ?? 0,
        rendererRssStartMiB: memory[0]?.rendererRssMiB ?? 0,
        rendererRssEndMiB: memory.at(-1)?.rendererRssMiB ?? 0,
        browserRssStartMiB: memory[0]?.browserRssMiB ?? 0,
        browserRssEndMiB: memory.at(-1)?.browserRssMiB ?? 0,
        secondHalfTotalRssSlopeMiBPerMinute: slope(memory.map((value) => ({ minutes: value.minutes, rssMiB: value.totalRssMiB }))),
        secondHalfRendererRssSlopeMiBPerMinute: slope(memory.map((value) => ({ minutes: value.minutes, rssMiB: value.rendererRssMiB }))),
        secondHalfBrowserRssSlopeMiBPerMinute: slope(memory.map((value) => ({ minutes: value.minutes, rssMiB: value.browserRssMiB }))),
        seek: soakState.seek,
        sync: soakState.frames.a.frameIndex === soakState.frames.b.frameIndex && soakState.frames.a.fingerprint === soakState.frames.b.fingerprint && soakState.frames.sharedPixels,
        error: soakState.error,
      },
      fallback,
      privacy: !String(await window.webContents.executeJavaScript(`document.documentElement.innerText`, true)).includes(root),
    };
    result.passed = result.initialClone
      && result.independentView
      && result.independentDisplay
      && result.originalHoldOwned
      && result.crosshair.imageErrorPixels <= 0.25
      && result.crosshair.noVideoWork
      && result.crosshair.letterboxHidden && result.crosshair.pointerCancelHidden
      && JSON.stringify(result.annotation.ids[0]) === JSON.stringify(result.annotation.ids[1])
      && result.annotation.handles[0] > 0 && result.annotation.handles[1] === 0
      && result.annotation.inactiveOwnerHandles.every((count) => count === 0)
      && result.export.displayHashesDiffer
      && result.export.viewHashesDiffer
      && result.export.deterministicActiveA
      && result.navigation.frames.sharedPixels
      && result.navigation.after.seek === result.navigation.before.seek
      && result.hold.loading === 0 && result.hold.sync && result.hold.seekDelta === 0
      && result.stateRestore
      && result.desktop.width === result.desktop.scrollWidth && result.desktop.paneWidths.every((width) => width >= 400)
      && result.fullscreenCrosshair
      && result.compact.width >= 700 && result.compact.width <= 720 && result.compact.width === result.compact.scrollWidth && result.compact.panes === 2
      && result.soak.sync && !result.soak.error
      && (soakMinutes < 2 || (result.soak.secondHalfTotalRssSlopeMiBPerMinute <= 10 && result.soak.secondHalfRendererRssSlopeMiBPerMinute <= 10))
      && result.fallback.preserved && result.fallback.sync && result.fallback.crosshairHiddenOnLoss
      && result.privacy;

    await mkdir(path.dirname(reportPath), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.passed) process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    process.exitCode = 1;
  } finally {
    if (forceRgba) await frameModule.shutdownFrameIpcResources();
    else await frameModule.shutdownCacheFrameIpcResources();
    ipcMain.removeHandler("frame:openQa");
    fullscreenModule.unregisterFullscreenIpc();
    await rm(path.join(root, "temp", "phase5-export"), { recursive: true, force: true });
  }
  app.exit(process.exitCode ?? 0);
})().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  app.exit(1);
});
