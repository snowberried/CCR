const { app, BrowserWindow, clipboard, dialog, ipcMain, nativeImage, screen } = require("electron");
const { createHash } = require("node:crypto");
const { mkdir, readdir, readFile, rmdir, unlink, writeFile } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

process.env.CCR_PHASE23_QA = "1";
const root = process.cwd();
app.setAppPath(root);
const forceRgba = process.env.CCR_FORCE_RGBA === "1";
const holdMs = Number(process.env.CCR_QA_HOLD_MS ?? 0);
const saveDirectory = path.join(root, "temp", "한글 내보내기 QA");
const savePath = path.join(saveDirectory, "한글 결과.png");
const reportPath = path.join(root, "temp", `phase4b1-export-qa${forceRgba ? "-rgba" : ""}.json`);
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
  throw new Error(`PHASE4B1_TIMEOUT_${label}`);
}

function drag(window, start, end) {
  window.webContents.sendInputEvent({ type: "mouseMove", ...start });
  window.webContents.sendInputEvent({ type: "mouseDown", button: "left", clickCount: 1, ...start });
  window.webContents.sendInputEvent({ type: "mouseMove", ...end });
  window.webContents.sendInputEvent({ type: "mouseUp", button: "left", clickCount: 1, ...end });
}

function click(window, point) {
  window.webContents.sendInputEvent({ type: "mouseMove", ...point });
  window.webContents.sendInputEvent({ type: "mouseDown", button: "left", clickCount: 1, ...point });
  window.webContents.sendInputEvent({ type: "mouseUp", button: "left", clickCount: 1, ...point });
}

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const clipboardPng = () => clipboard.readImage().toPNG();

(async () => {
  const files = await mediaFiles(path.join(root, "local-samples"));
  if (!files.length) throw new Error("PHASE4B1_NEEDS_SAMPLE");
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
  let dialogMode = "save";
  let saveDialogOptions = null;
  dialog.showSaveDialog = async (...args) => {
    saveDialogOptions = args.at(-1);
    if (dialogMode === "cancel") return { canceled: true, filePath: undefined };
    return { canceled: false, filePath: dialogMode === "fail" ? saveDirectory : savePath };
  };

  await mkdir(saveDirectory, { recursive: true });
  await unlink(savePath).catch(() => undefined);
  await app.whenReady();
  const recordStage = (stage) => writeFile(reportPath, `${JSON.stringify({ stage })}\n`, "utf8");
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

  try {
    await window.loadFile(path.join(root, "dist", "index.html"));
    await recordStage("loaded");
    await waitFor(window, `Boolean(window.ccr?.copyPng) && Boolean(document.querySelector(".export-panel"))`, 10_000, "bridge");
    await window.webContents.executeJavaScript(`window.dispatchEvent(new CustomEvent("ccr:qaOpen", { detail: 0 }))`, true);
    const ready = forceRgba
      ? `Boolean(document.querySelector(".status-ready"))`
      : `document.documentElement.dataset.qaBackgroundComplete === "true"`;
    await waitFor(window, ready, 20_000, "open");
    const baseline = await window.webContents.executeJavaScript(`(() => {
      const canvas=document.querySelector(".frame-canvas").getBoundingClientRect();
      const surface=document.querySelector(".viewer-surface").getBoundingClientRect();
      return {
        image:[document.querySelector(".frame-canvas").width,document.querySelector(".frame-canvas").height],
        canvas:canvas.toJSON(), surface:surface.toJSON(), dpr:window.devicePixelRatio,
        seek:Number(document.documentElement.dataset.qaSeekDecodeCount),
        uploads:Number(document.documentElement.dataset.qaTextureUploads),
        frame:document.querySelector('[aria-label="프레임 번호"]').value,
        view:[document.documentElement.dataset.qaViewZoom,document.documentElement.dataset.qaViewCenter],
        display:document.documentElement.dataset.qaDisplayState
      };
    })()`, true);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rectangle 도구"]').click()`, true);
    drag(window,
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .2), y: Math.round(baseline.canvas.top + baseline.canvas.height * .2) },
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .55), y: Math.round(baseline.canvas.top + baseline.canvas.height * .55) });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "1"`, 5_000, "annotation");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Arrow 도구"]').click()`, true);
    drag(window,
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .15), y: Math.round(baseline.canvas.top + baseline.canvas.height * .7) },
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .45), y: Math.round(baseline.canvas.top + baseline.canvas.height * .58) });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "2"`, 5_000, "arrow");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Ellipse 도구"]').click()`, true);
    drag(window,
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .58), y: Math.round(baseline.canvas.top + baseline.canvas.height * .18) },
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .82), y: Math.round(baseline.canvas.top + baseline.canvas.height * .42) });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "3"`, 5_000, "ellipse");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Text 도구"]').click()`, true);
    click(window, { x: Math.round(baseline.canvas.left + baseline.canvas.width * .22), y: Math.round(baseline.canvas.top + baseline.canvas.height * .78) });
    await waitFor(window, `Boolean(document.querySelector(".annotation-text-editor"))`, 5_000, "text-editor");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector(".annotation-text-editor"); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"한글 내보내기"); input.dispatchEvent(new InputEvent("input",{bubbles:true,data:"한글 내보내기"})); input.dispatchEvent(new KeyboardEvent("keydown",{bubbles:true,key:"Enter"})); })()`, true);
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "4"`, 5_000, "text");
    await recordStage("annotations");

    await window.webContents.executeJavaScript(`document.querySelector('[title="다음 프레임"]').click()`, true);
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "2"`, 10_000, "other-frame");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Rectangle 도구"]').click()`, true);
    drag(window,
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .3), y: Math.round(baseline.canvas.top + baseline.canvas.height * .3) },
      { x: Math.round(baseline.canvas.left + baseline.canvas.width * .4), y: Math.round(baseline.canvas.top + baseline.canvas.height * .4) });
    await waitFor(window, `document.documentElement.dataset.qaAnnotationCount === "5"`, 5_000, "other-frame-annotation");
    await window.webContents.executeJavaScript(`document.querySelector('[title="이전 프레임"]').click()`, true);
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1"`, 10_000, "return-first");
    await window.webContents.executeJavaScript(`(() => {
      const input=document.querySelector('[aria-label="화면 보정 감마"]');
      const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set;
      setter.call(input,"1.5"); input.dispatchEvent(new Event("input",{bubbles:true}));
    })()`, true);
    await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).gamma === 1.5`, 5_000, "display");

    const exportBaseline = await window.webContents.executeJavaScript(`({seek:Number(document.documentElement.dataset.qaSeekDecodeCount),uploads:Number(document.documentElement.dataset.qaTextureUploads)})`, true);
    const copy = async (expectedAnnotations, label, expectedFrame = 0) => {
      await waitFor(window, `!document.querySelector(".export-buttons button:nth-child(2)").disabled`, 15_000, `${label}-ready`);
      await window.webContents.executeJavaScript(`document.querySelector(".export-buttons button:nth-child(2)").click()`, true);
      let qa;
      try {
        qa = await waitFor(window, `(() => { const q=document.documentElement.dataset.qaExport; if(!q)return null; const v=JSON.parse(q); return v.annotationCount===${expectedAnnotations} && v.frameIndex===${expectedFrame} && !document.querySelector(".export-buttons button").disabled ? v : null; })()`, 10_000, label);
      } catch (error) {
        const actual = await window.webContents.executeJavaScript(`document.documentElement.dataset.qaExport ?? "missing"`, true);
        await recordStage({ label, expectedAnnotations, expectedFrame, actual });
        throw error;
      }
      const png = clipboardPng();
      const image = nativeImage.createFromBuffer(png);
      const bitmap = image.toBitmap();
      const rawSize = image.getSize();
      const clipboardScale = screen.getDisplayMatching(window.getBounds()).scaleFactor;
      const size = { width: Math.round(rawSize.width / clipboardScale), height: Math.round(rawSize.height / clipboardScale) };
      return { qa, hash: hash(png), pixelHash: hash(bitmap), cornerBlack: bitmap[0] <= 2 && bitmap[1] <= 2 && bitmap[2] <= 2, rawSize, size };
    };

    const fullWith = await copy(4, "full-with");
    await window.webContents.executeJavaScript(`document.querySelector(".export-annotation-option input").click()`, true);
    const fullWithout = await copy(0, "full-without");
    await window.webContents.executeJavaScript(`document.querySelector(".export-annotation-option input").click()`, true);
    const fullRepeat = await copy(4, "full-repeat");
    await recordStage("full-copies");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector('[aria-label="화면 보정 감마"]'); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"1"); input.dispatchEvent(new Event("input",{bubbles:true})); })()`, true);
    await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).gamma === 1`, 5_000, "display-original");
    const originalDisplay = await copy(4, "original-display");
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector('[aria-label="화면 보정 감마"]'); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,"1.5"); input.dispatchEvent(new Event("input",{bubbles:true})); })()`, true);
    await waitFor(window, `JSON.parse(document.documentElement.dataset.qaDisplayState).gamma === 1.5`, 5_000, "display-restored");

    await window.webContents.executeJavaScript(`document.querySelector('input[value="current-view"]').click(); document.querySelector('[title^="화면 맞춤"]').click()`, true);
    const fitCurrent = await copy(4, "current-fit");
    await window.webContents.executeJavaScript(`document.querySelector('.zoom-value-button').click()`, true);
    const actualCurrent = await copy(4, "current-actual");
    await window.webContents.executeJavaScript(`(() => { const plus=document.querySelector('[title="10%p 확대 (+)"]'); for(let i=0;i<10;i+=1)plus.click(); document.querySelector('[aria-label="Pan 도구"]').click(); })()`, true);
    const panGeometry = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector(".viewer-surface").getBoundingClientRect(); return {a:{x:Math.round(r.left+r.width*.5),y:Math.round(r.top+r.height*.65)},b:{x:Math.round(r.left+r.width*.5),y:Math.round(r.top+r.height*.45)}}; })()`, true);
    drag(window, panGeometry.a, panGeometry.b);
    const current = await copy(4, "current-view");
    await recordStage("current-copies");
    const beforeSave = await window.webContents.executeJavaScript(`({seek:Number(document.documentElement.dataset.qaSeekDecodeCount),uploads:Number(document.documentElement.dataset.qaTextureUploads),view:[document.documentElement.dataset.qaViewZoom,document.documentElement.dataset.qaViewCenter],display:document.documentElement.dataset.qaDisplayState,annotations:document.documentElement.dataset.qaAnnotationCount})`, true);

    await window.webContents.executeJavaScript(`document.querySelector('input[value="full-frame"]').click(); document.querySelector(".export-buttons button:first-child").click()`, true);
    await waitFor(window, `document.querySelector(".export-result").textContent.includes("저장 완료")`, 10_000, "save");
    const savedBytes = await readFile(savePath);
    const savedImage = nativeImage.createFromBuffer(savedBytes);
    const savedSize = savedImage.getSize();
    const messageBeforeCancel = await window.webContents.executeJavaScript(`document.querySelector(".export-result").textContent`, true);
    dialogMode = "cancel";
    await window.webContents.executeJavaScript(`document.querySelector(".export-buttons button:first-child").click()`, true);
    await new Promise((resolve) => setTimeout(resolve, 100));
    const messageAfterCancel = await window.webContents.executeJavaScript(`document.querySelector(".export-result").textContent`, true);
    dialogMode = "fail";
    await window.webContents.executeJavaScript(`document.querySelector(".export-buttons button:first-child").click()`, true);
    await waitFor(window, `document.querySelector(".export-result").textContent.includes("저장하지 못")`, 10_000, "save-failure");
    const writeFailureReported = await window.webContents.executeJavaScript(`document.querySelector(".export-result").textContent.includes("저장하지 못")`, true);
    const afterSave = await window.webContents.executeJavaScript(`({seek:Number(document.documentElement.dataset.qaSeekDecodeCount),uploads:Number(document.documentElement.dataset.qaTextureUploads),view:[document.documentElement.dataset.qaViewZoom,document.documentElement.dataset.qaViewCenter],display:document.documentElement.dataset.qaDisplayState,annotations:document.documentElement.dataset.qaAnnotationCount})`, true);
    await recordStage("save-cancel-failure");

    await window.webContents.executeJavaScript(`document.querySelector('input[value="current-view"]').click(); document.querySelector(".export-buttons button:nth-child(2)").click(); document.querySelector('[title="다음 프레임"]').click()`, true);
    const coherent = await waitFor(window, `(() => { const q=document.documentElement.dataset.qaExport; return q && document.querySelector('[aria-label="프레임 번호"]').value === "2" && !document.querySelector(".export-buttons button").disabled ? JSON.parse(q) : null; })()`, 15_000, "coherence");
    await recordStage("coherence");

    const timeline = await window.webContents.executeJavaScript(`document.querySelector(".timeline-track").getBoundingClientRect().toJSON()`, true);
    click(window, { x: Math.round(timeline.left + timeline.width / 2), y: Math.round(timeline.top + timeline.height / 2) });
    const middleUiFrame = await waitFor(window, `(() => { const v=Number(document.querySelector('[aria-label="프레임 번호"]').value); const max=Number(document.querySelector('[aria-label="프레임 번호"]').max); const expected=Math.round((max-1)/2)+1; return v===expected?v:0; })()`, 15_000, "middle-frame");
    await window.webContents.executeJavaScript(`document.querySelector('input[value="full-frame"]').click()`, true);
    const middle = await copy(0, "middle-export", middleUiFrame - 1);
    await recordStage("middle");
    await window.webContents.executeJavaScript(`document.querySelector('[title="마지막 프레임"]').click()`, true);
    const lastUiFrame = await waitFor(window, `(() => { const i=document.querySelector('[aria-label="프레임 번호"]'); return i.value===i.max?Number(i.value):0; })()`, 15_000, "last-frame");
    const last = await copy(0, "last-export", lastUiFrame - 1);
    await recordStage("last");
    await window.webContents.executeJavaScript(`document.querySelector('[title="첫 프레임"]').click()`, true);
    await waitFor(window, `document.querySelector('[aria-label="프레임 번호"]').value === "1"`, 15_000, "first-return");
    const firstAgain = await copy(4, "first-export", 0);

    window.setContentSize(720, 600);
    const compact = await waitFor(window, `(() => ({width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,panel:getComputedStyle(document.querySelector(".inspection-panel")).display,exportWidth:document.querySelector(".export-panel").getBoundingClientRect().width}))()`, 5_000, "compact");
    const after = await window.webContents.executeJavaScript(`({
      seek:Number(document.documentElement.dataset.qaSeekDecodeCount),
      uploads:Number(document.documentElement.dataset.qaTextureUploads),
      view:[document.documentElement.dataset.qaViewZoom,document.documentElement.dataset.qaViewCenter],
      display:document.documentElement.dataset.qaDisplayState,
      annotations:document.documentElement.dataset.qaAnnotationCount,
      privacy:!document.documentElement.innerText.includes(${JSON.stringify(root)})
    })`, true);

    const result = {
      mode: forceRgba ? "rgba" : "webgl",
      fullSize: fullWith.size,
      sourceSize: { width: baseline.image[0], height: baseline.image[1] },
      currentSize: current.size,
      currentExpected: { width: Math.round(baseline.surface.width * baseline.dpr), height: Math.round(baseline.surface.height * baseline.dpr) },
      currentModes: { fit: fitCurrent.size, actual: actualCurrent.size, zoomPan: current.size, zoomPanCornerBlack: current.cornerBlack },
      dpr: baseline.dpr,
      annotationsChangePixels: fullWith.hash !== fullWithout.hash,
      displayChangesPixels: fullRepeat.pixelHash !== originalDisplay.pixelHash,
      deterministicRepeat: fullWith.hash === fullRepeat.hash,
      frameCoverage: { first: firstAgain.qa.frameIndex, middle: middle.qa.frameIndex, last: last.qa.frameIndex, dimensionsStable: [firstAgain, middle, last].every((item) => item.size.width === baseline.image[0] && item.size.height === baseline.image[1]) },
      annotationCoverage: { exportedOnCurrentFrame: fullWith.qa.annotationCount, totalAcrossFrames: 5, otherFrameExcluded: fullWith.qa.annotationCount === 4 },
      save: { size: savedSize, decodes: !savedImage.isEmpty(), unicodePath: true, overwriteConfirmation: saveDialogOptions?.properties?.includes("showOverwriteConfirmation") === true, cancelPreservedStatus: messageBeforeCancel === messageAfterCancel, writeFailureReported },
      coherence: { snapshottedFrame: coherent.frameIndex, fingerprintCaptured: typeof coherent.fingerprint === "string" && coherent.fingerprint.length > 0, displayedAfter: 2 },
      decoderInvariant: { seekBefore: exportBaseline.seek, seekAfterExports: afterSave.seek, uploadsBefore: exportBaseline.uploads, uploadsAfterExports: afterSave.uploads, exportUploadDelta: current.qa.textureUploadDelta, uploadsAfterNavigation: after.uploads },
      stateInvariant: { saveCopyPreserved: JSON.stringify(beforeSave) === JSON.stringify(afterSave), finalView: after.view, finalDisplay: after.display, annotations: after.annotations },
      compact,
      privacy: after.privacy,
    };
    await writeFile(reportPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(result)}\n`);
    await new Promise((resolve) => setTimeout(resolve, 50));
    if (holdMs > 0) await new Promise((resolve) => setTimeout(resolve, holdMs));
  } finally {
    await window.webContents.executeJavaScript(`window.ccr?.closeVideo?.()`, true).catch(() => undefined);
    window.destroy();
    await unlink(savePath).catch(() => undefined);
    await rmdir(saveDirectory).catch(() => undefined);
    app.quit();
  }
})().catch((error) => {
  console.error(error instanceof Error ? (error.stack ?? error.message) : "PHASE4B1_QA_FAILED");
  app.exit(1);
});
