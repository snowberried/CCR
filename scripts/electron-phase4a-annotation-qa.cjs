const { app, BrowserWindow, ipcMain } = require("electron");
const { mkdir, readdir, writeFile } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE23_QA = "1";
const root = process.cwd();
app.setAppPath(root);
const forceRgba = process.env.CCR_FORCE_RGBA === "1";
const interactive = process.env.CCR_QA_SHOW === "1";
const outputPath = path.join(root, "temp", `phase4a-annotation-qa${forceRgba ? "-rgba" : ""}.json`);
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
  throw new Error(`PHASE4A_TIMEOUT_${label}`);
}

function mouseClick(window, point, button = "left") {
  window.webContents.sendInputEvent({ type: "mouseMove", ...point });
  window.webContents.sendInputEvent({ type: "mouseDown", button, clickCount: 1, ...point });
  window.webContents.sendInputEvent({ type: "mouseUp", button, clickCount: 1, ...point });
}

function mouseDrag(window, start, end, button = "left") {
  window.webContents.sendInputEvent({ type: "mouseMove", ...start });
  window.webContents.sendInputEvent({ type: "mouseDown", button, clickCount: 1, ...start });
  for (let index = 1; index <= 5; index += 1) {
    window.webContents.sendInputEvent({
      type: "mouseMove",
      x: Math.round(start.x + (end.x - start.x) * index / 5),
      y: Math.round(start.y + (end.y - start.y) * index / 5),
    });
  }
  window.webContents.sendInputEvent({ type: "mouseUp", button, clickCount: 1, ...end });
}

function sendShortcut(window, keyCode, modifiers = []) {
  window.webContents.sendInputEvent({ type: "keyDown", keyCode, modifiers });
  window.webContents.sendInputEvent({ type: "keyUp", keyCode, modifiers });
}

const annotationState = `JSON.parse(document.documentElement.dataset.qaAnnotationState)`;

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (files.length < 2) throw new Error("PHASE4A_NEEDS_TWO_SAMPLES");
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
    show: interactive,
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
    await waitFor(window, `Boolean(window.ccr?.openQaVideo) && Boolean(document.querySelector(".app-shell"))`, 10_000, "bridge");
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 0 }))`, true);
    const ready = forceRgba
      ? `document.documentElement.dataset.qaSampleIndex === "0" && Boolean(document.querySelector(".status-ready"))`
      : `document.documentElement.dataset.qaSampleIndex === "0" && document.documentElement.dataset.qaBackgroundComplete === "true"`;
    await waitFor(window, ready, 20_000, "open");

    const geometry = await window.webContents.executeJavaScript(`(() => {
      const canvas = document.querySelector("canvas").getBoundingClientRect();
      const surface = document.querySelector(".viewer-surface").getBoundingClientRect();
      const p = (x, y) => ({ x: Math.round(canvas.left + canvas.width * x), y: Math.round(canvas.top + canvas.height * y) });
      return { p1:p(.2,.2), p2:p(.4,.35), p3:p(.55,.2), p4:p(.8,.45), p5:p(.25,.62), p6:p(.5,.82), surface };
    })()`, true);
    const initial = await window.webContents.executeJavaScript(`({
      uploads:Number(document.documentElement.dataset.qaTextureUploads),
      seek:Number(document.documentElement.dataset.qaSeekDecodeCount),
      display:document.documentElement.dataset.qaDisplayState,
      zoom:Number(document.documentElement.dataset.qaViewZoom)
    })`, true);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Arrow 도구"]').click()`, true);
    mouseDrag(window, geometry.p1, geometry.p2);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "1"`, 5_000, "arrow");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rectangle 도구"]').click()`, true);
    mouseDrag(window, geometry.p3, geometry.p4);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "2"`, 5_000, "rectangle");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Text 도구"]').click()`, true);
    mouseClick(window, geometry.p5);
    await waitFor(window, `Boolean(document.querySelector(".annotation-text-editor"))`, 5_000, "text-editor");
    const imePreserved = await window.webContents.executeJavaScript(`(() => {
      const input = document.querySelector(".annotation-text-editor");
      input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles:true, data:"한" }));
      input.dispatchEvent(new KeyboardEvent("keydown", { bubbles:true, key:"Enter", isComposing:true }));
      const preserved = Boolean(document.querySelector(".annotation-text-editor"));
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      setter.call(input, "한글 주석");
      input.dispatchEvent(new InputEvent("input", { bubbles:true, inputType:"insertText", data:"한글 주석" }));
      input.dispatchEvent(new CompositionEvent("compositionend", { bubbles:true, data:"한글 주석" }));
      input.dispatchEvent(new KeyboardEvent("keydown", { bubbles:true, key:"Enter" }));
      return preserved;
    })()`, true);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "3" && !document.querySelector(".annotation-text-editor")`, 5_000, "text-commit");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Select 도구"]').click()`, true);
    mouseClick(window, { x: Math.round((geometry.p3.x + geometry.p4.x) / 2), y: Math.round((geometry.p3.y + geometry.p4.y) / 2) });
    await waitFor(window, `${annotationState}.selectedId === "annotation-2"`, 5_000, "select-rectangle");
    mouseDrag(window, { x: Math.round((geometry.p3.x + geometry.p4.x) / 2), y: Math.round((geometry.p3.y + geometry.p4.y) / 2) }, { x: Math.round((geometry.p3.x + geometry.p4.x) / 2 + 20), y: Math.round((geometry.p3.y + geometry.p4.y) / 2 + 12) });
    await waitFor(window, `document.documentElement.dataset.qaPointerGesture === "none" && document.documentElement.dataset.qaAnnotationHistory.startsWith("4,")`, 5_000, "move");
    const southeast = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector('[data-annotation-handle="se"]').getBoundingClientRect(); return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}; })()`, true);
    mouseDrag(window, southeast, { x: southeast.x + 18, y: southeast.y + 14 });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationHistory.startsWith("5,")`, 5_000, "resize");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector('[aria-label="Annotation Line Width"]'); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"4"); input.dispatchEvent(new Event("input",{bubbles:true})); })()`, true);
    await waitFor(window, `${annotationState}.annotations.find(a=>a.id==="annotation-2").style.lineWidth === 4`, 5_000, "style");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Arrow 도구"]').click()`, true);
    mouseDrag(window, geometry.p1, geometry.p2, "right");
    const rightDrag = await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).presetId === "custom" ? ({count:document.documentElement.dataset.qaAnnotationCount,tool:document.documentElement.dataset.qaViewTool}) : null`, 5_000, "right-display");
    await window.webContents.executeJavaScript(`document.querySelector(".viewer-surface").dispatchEvent(new WheelEvent("wheel", { deltaY:-120, ctrlKey:true, clientX:${geometry.p2.x}, clientY:${geometry.p2.y}, bubbles:true, cancelable:true }))`, true);
    const wheelZoom = await waitFor(window, `Number(document.documentElement.dataset.qaViewZoom) > ${initial.zoom} ? Number(document.documentElement.dataset.qaViewZoom) : 0`, 5_000, "ctrl-wheel");
    const handleSize = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector(".annotation-handle").getBoundingClientRect(); return [r.width,r.height]; })()`, true);
    const annotationInvariant = await window.webContents.executeJavaScript(`({uploads:Number(document.documentElement.dataset.qaTextureUploads),seek:Number(document.documentElement.dataset.qaSeekDecodeCount)})`, true);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Ellipse 도구"]').click()`, true);
    sendShortcut(window, "Right");
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "2"`, 10_000, "frame-two");
    const frameTwoPoints = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector("canvas").getBoundingClientRect(); return {a:{x:Math.round(r.left+r.width*.25),y:Math.round(r.top+r.height*.62)},b:{x:Math.round(r.left+r.width*.5),y:Math.round(r.top+r.height*.82)}}; })()`, true);
    mouseDrag(window, frameTwoPoints.a, frameTwoPoints.b);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "4"`, 5_000, "frame-two-ellipse");

    sendShortcut(window, "Z", ["control"]);
    const undoFrameTwo = await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "3" ? document.querySelector('[aria-label="프레임 번호"]').value : ""`, 5_000, "undo-frame-two");
    sendShortcut(window, "Z", ["control"]);
    const crossFrameUndo = await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1" ? document.documentElement.dataset.qaAnnotationCount : ""`, 10_000, "cross-frame-undo");
    sendShortcut(window, "Z", ["control", "shift"]);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "3"`, 5_000, "redo");

    const track = await window.webContents.executeJavaScript(`document.querySelector(".timeline-track").getBoundingClientRect().toJSON()`, true);
    mouseClick(window, { x: Math.round(track.left), y: Math.round(track.top + track.height / 2) });
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1"`, 10_000, "timeline-first");
    mouseClick(window, { x: Math.round(track.left + track.width / 2), y: Math.round(track.top + track.height / 2) });
    const middleFrame = await waitFor(window, `Number(document.querySelector('[aria-label="프레임 번호"]').value) > 1 ? Number(document.querySelector('[aria-label="프레임 번호"]').value) : 0`, 10_000, "timeline-middle");
    mouseClick(window, { x: Math.round(track.right - 1), y: Math.round(track.top + track.height / 2) });
    const lastFrame = await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === String(document.querySelector('[aria-label="프레임 번호"]').max) ? Number(document.querySelector('[aria-label="프레임 번호"]').value) : 0`, 10_000, "timeline-last");

    const marker = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector(".timeline-marker").getBoundingClientRect(); return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}; })()`, true);
    mouseClick(window, marker);
    const markerSelection = await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1" && ${annotationState}.selectedId ? ({frame:"1",selected:${annotationState}.selectedId}) : null`, 10_000, "marker-select");

    await window.webContents.executeJavaScript(`document.querySelector('[data-annotation-id="annotation-3"]').dispatchEvent(new MouseEvent("dblclick",{bubbles:true,cancelable:true}))`, true);
    await waitFor(window, `Boolean(document.querySelector(".annotation-text-editor"))`, 5_000, "text-reedit");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector(".annotation-text-editor"); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"한글 수정"); input.dispatchEvent(new InputEvent("input",{bubbles:true,data:"한글 수정"})); input.dispatchEvent(new KeyboardEvent("keydown",{bubbles:true,key:"Enter"})); })()`, true);
    await waitFor(window, `${annotationState}.annotations.find(a=>a.id==="annotation-3").geometry.text === "한글 수정"`, 5_000, "text-reedit-commit");
    sendShortcut(window, "Delete");
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "2"`, 5_000, "delete");
    sendShortcut(window, "Z", ["control"]);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "3" && ${annotationState}.selectedId === "annotation-3"`, 5_000, "delete-undo");

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rectangle 도구"]').click()`, true);
    window.webContents.sendInputEvent({ type: "mouseMove", ...geometry.p1 });
    window.webContents.sendInputEvent({ type: "mouseDown", button: "left", clickCount: 1, ...geometry.p1 });
    window.webContents.sendInputEvent({ type: "mouseMove", x: geometry.p2.x, y: geometry.p2.y });
    await window.webContents.executeJavaScript(`window.dispatchEvent(new Event("blur"))`, true);
    const blurCleanup = await waitFor(window, `document.documentElement.dataset.qaPointerGesture === "none" ? document.documentElement.dataset.qaAnnotationCount : ""`, 5_000, "blur-cleanup");

    window.setContentSize(720, 600);
    const compact = await waitFor(window, `(() => { const root=document.documentElement; return root.clientWidth === 720 ? {width:root.clientWidth,height:root.clientHeight,scrollWidth:root.scrollWidth,scrollHeight:root.scrollHeight,rail:document.querySelectorAll(".viewer-tool-rail button").length,timeline:document.querySelector(".timeline-track").getBoundingClientRect().width} : null; })()`, 5_000, "compact");

    const finalState = await window.webContents.executeJavaScript(`({
      annotations:${annotationState}.annotations,
      history:document.documentElement.dataset.qaAnnotationHistory,
      view:[document.documentElement.dataset.qaViewZoom,document.documentElement.dataset.qaViewCenter],
      display:document.documentElement.dataset.qaDisplayState,
      uploads:Number(document.documentElement.dataset.qaTextureUploads),
      seek:Number(document.documentElement.dataset.qaSeekDecodeCount)
    })`, true);
    if (interactive) {
      window.show();
      window.focus();
      await new Promise((resolve) => setTimeout(resolve, 60_000));
    }
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 1 }))`, true);
    const resetReady = forceRgba
      ? `document.documentElement.dataset.qaSampleIndex === "1" && Boolean(document.querySelector(".status-ready"))`
      : `document.documentElement.dataset.qaSampleIndex === "1" && document.documentElement.dataset.qaBackgroundComplete === "true"`;
    await waitFor(window, resetReady, 20_000, "new-session");
    const newSessionReset = await window.webContents.executeJavaScript(`({
      count:document.documentElement.dataset.qaAnnotationCount,
      history:document.documentElement.dataset.qaAnnotationHistory,
      tool:document.documentElement.dataset.qaViewTool,
      zoom:document.documentElement.dataset.qaViewZoom,
      markers:document.querySelectorAll(".timeline-marker").length,
      display:JSON.parse(document.documentElement.dataset.qaDisplayState).presetId
    })`, true);
    const result = {
      mode: forceRgba ? "rgba" : "webgl",
      imePreserved,
      rightDrag,
      wheelZoom,
      handleSize,
      undoFrameTwo,
      crossFrameUndo,
      middleFrame,
      lastFrame,
      markerSelection,
      blurCleanup,
      compact,
      newSessionReset,
      decoderInvariant: {
        seekBefore: initial.seek,
        seekAfterAnnotations: annotationInvariant.seek,
        seekAfterNavigation: finalState.seek,
        uploadBefore: initial.uploads,
        uploadAfterAnnotations: annotationInvariant.uploads,
        uploadAfterNavigation: finalState.uploads,
      },
      finalState,
    };
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    console.log(JSON.stringify(result));
  } finally {
    await window.webContents.executeJavaScript(`window.ccr?.closeVideo?.()`, true).catch(() => {});
    window.destroy();
    await app.quit();
  }
})().catch((error) => {
  console.error(error);
  app.exit(1);
});
