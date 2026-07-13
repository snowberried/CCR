const { app, BrowserWindow, clipboard, dialog, Menu } = require("electron");
const { readdir } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const root = path.resolve(__dirname, "..");
const sampleDirectory = path.join(root, "local-samples");
const expectedToolOrder = [
  "Pan 도구",
  "Zoom 도구",
  "연결 십자선",
  "Select 도구",
  "Arrow 도구",
  "Text 도구",
  "Ellipse 도구",
  "Rectangle 도구",
];

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function mediaFiles() {
  const entries = await readdir(sampleDirectory, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile() && [".mp4", ".mov", ".avi", ".mkv"].includes(path.extname(entry.name).toLowerCase()))
    .map((entry) => path.join(sampleDirectory, entry.name));
}

async function waitForMain(predicate, timeoutMs, label) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = predicate();
    if (value) return value;
    await delay(25);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function waitFor(window, expression, timeoutMs, label) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await window.webContents.executeJavaScript(expression, true);
    if (value) return value;
    await delay(25);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function shortcut(window, keyCode, modifiers = []) {
  window.webContents.sendInputEvent({ type: "keyDown", keyCode, modifiers });
  await delay(25);
  window.webContents.sendInputEvent({ type: "keyUp", keyCode, modifiers });
  await delay(50);
}

function click(window, point) {
  window.webContents.sendInputEvent({ type: "mouseMove", ...point });
  window.webContents.sendInputEvent({ type: "mouseDown", button: "left", clickCount: 1, ...point });
  window.webContents.sendInputEvent({ type: "mouseUp", button: "left", clickCount: 1, ...point });
}

const annotationCountExpression = `new Set([...document.querySelectorAll("[data-annotation-id]")].map((node) => node.dataset.annotationId)).size`;

async function main() {
  const files = await mediaFiles();
  if (!files.length) throw new Error("No local QA media available");

  app.setAppPath(root);
  let dialogCalls = 0;
  let result;
  const previousClipboard = clipboard.readText();
  dialog.showOpenDialog = async () => {
    dialogCalls += 1;
    return { canceled: false, filePaths: [files[0]] };
  };

  try {
    await import(pathToFileURL(path.join(root, "dist-electron", "electron", "main.js")).href);
    await app.whenReady();
    const window = await waitForMain(() => BrowserWindow.getAllWindows()[0], 5_000, "main window");
    if (window.webContents.isLoading()) {
      await new Promise((resolve) => window.webContents.once("did-finish-load", resolve));
    }

    const windowChrome = {
      applicationMenuRemoved: Menu.getApplicationMenu() === null,
      menuBarHidden: !window.isMenuBarVisible(),
      nativeHandle: window.getNativeWindowHandle().length > 0,
      minimizable: window.isMinimizable(),
      maximizable: window.isMaximizable(),
      closable: window.isClosable(),
      title: window.getTitle(),
    };

    const initialUi = await window.webContents.executeJavaScript(`(() => {
      const topButtons=[...document.querySelectorAll(".topbar-actions button")].map((button)=>button.textContent.trim());
      const modeButtons=[...document.querySelectorAll(".view-mode-control button")];
      const crosshair=document.querySelector('[aria-label="연결 십자선"]');
      return {
        topButtons,
        required:["화면 맞춤","전체 화면","단일 보기","비교 보기"].every((label)=>topButtons.includes(label))&&Boolean(document.querySelector('[aria-label="파일 열기"]')),
        oldLabels:["Fit","전체","비교 뷰","열기"].filter((label)=>topButtons.includes(label)),
        fileHasIcon:document.querySelector('[aria-label="파일 열기"] span[aria-hidden="true"]')?.textContent.length>0,
        mode:[...modeButtons].map((button)=>({label:button.getAttribute("aria-label"),pressed:button.getAttribute("aria-pressed")})),
        toolOrder:[...document.querySelectorAll(".viewer-tool-rail button")].map((button)=>button.getAttribute("aria-label")),
        railHasFitOr100:[...document.querySelectorAll(".viewer-tool-rail button")].some((button)=>button.textContent.includes("Fit")||button.textContent.includes("100%")),
        crosshairDisabled:crosshair.disabled,
        crosshairTitle:crosshair.title,
        zoomValueCommand:Boolean(document.querySelector('.zoom-value-button[title="원본 픽셀 100%로 복귀"]')),
        mediaControlCount:document.querySelectorAll('.media-controls').length,
        hasCancel:[...document.querySelectorAll('button')].some((button)=>button.textContent.trim()==='취소'||button.title==='디코딩 취소'),
        sideColumns:[...document.querySelectorAll('.inspection-panel,.information-panel')].map((panel)=>panel.getAttribute('aria-label')),
        frameTimeText:document.querySelector('.frame-time-readout')?.textContent.replace(/\s/g,''),
        precisionLabels:[...document.querySelectorAll('.precision-controls button')].map((button)=>button.getAttribute('aria-label')),
      };
    })()`, true);

    await shortcut(window, "O", ["control"]);
    await waitFor(window, `document.querySelector(".status-ready") && !document.querySelector('[aria-label="비교 보기"]').disabled`, 30_000, "Ctrl+O open");

    const frameBefore = Number(await window.webContents.executeJavaScript(`document.querySelector('[aria-label="프레임 번호"]').value`, true));
    await shortcut(window, "RIGHT");
    const frameAfter = Number(await waitFor(window, `(() => { const value=Number(document.querySelector('[aria-label="프레임 번호"]').value); return value>${frameBefore}?value:null; })()`, 5_000, "frame shortcut"));

    const crosshairPolicy = await window.webContents.executeJavaScript(`(async () => {
      const click=(label)=>document.querySelector('[aria-label="'+label+'"]').click();
      const state=()=>({
        tool:document.documentElement.dataset.qaViewTool,
        crosshairPressed:document.querySelector('[aria-label="연결 십자선"]').getAttribute("aria-pressed"),
        crosshairDisabled:document.querySelector('[aria-label="연결 십자선"]').disabled,
        dual:document.querySelectorAll(".viewer-pane").length===2,
      });
      click("비교 보기"); await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      const defaultOn=state();
      click("Pan 도구"); click("연결 십자선"); await new Promise((resolve)=>requestAnimationFrame(resolve));
      const panAfterToggle=state();
      click("Select 도구"); click("연결 십자선"); await new Promise((resolve)=>requestAnimationFrame(resolve));
      const selectAfterToggle=state();
      click("연결 십자선"); click("단일 보기"); await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      const single=state();
      click("비교 보기"); await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      const restoredOff=state();
      click("연결 십자선"); click("Pan 도구"); await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      return { defaultOn, panAfterToggle, selectAfterToggle, single, restoredOff, final:state() };
    })()`, true);

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="단일 보기"]').click()`, true);
    await waitFor(window, `document.querySelectorAll(".viewer-pane").length===1`, 5_000, "single view for text");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="Text 도구"]').click()`, true);
    await waitFor(window, `document.querySelector('[aria-label="Text 도구"]').getAttribute("aria-pressed")==="true"`, 5_000, "text tool");
    let textEditorReady = false;
    for (const [xRatio, yRatio] of [[0.45, 0.35], [0.55, 0.45], [0.5, 0.6]]) {
      const canvasPoint = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector(".frame-canvas").getBoundingClientRect(); return {x:Math.round(r.left+r.width*${xRatio}),y:Math.round(r.top+r.height*${yRatio})}; })()`, true);
      click(window, canvasPoint);
      try {
        await waitFor(window, `document.querySelector(".annotation-text-editor")`, 1_500, "text editor attempt");
        textEditorReady = true;
        break;
      } catch {
        // Try another point that is still inside the displayed image.
      }
    }
    if (!textEditorReady) throw new Error("Text annotation editor was not created");

    const imeText = "한글 IME 입력";
    await window.webContents.executeJavaScript(`(() => {
      const input=document.querySelector(".annotation-text-editor");
      input.focus();
      input.dispatchEvent(new CompositionEvent("compositionstart",{bubbles:true,data:"한"}));
      const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set;
      setter.call(input,${JSON.stringify(imeText)});
      input.dispatchEvent(new InputEvent("input",{bubbles:true,data:${JSON.stringify(imeText)},inputType:"insertCompositionText",isComposing:true}));
      input.dispatchEvent(new CompositionEvent("compositionend",{bubbles:true,data:${JSON.stringify(imeText)}}));
      input.dispatchEvent(new InputEvent("input",{bubbles:true,data:${JSON.stringify(imeText)},inputType:"insertText"}));
    })()`, true);
    await waitFor(window, `document.querySelector(".annotation-text-editor").value===${JSON.stringify(imeText)}`, 5_000, "Korean composition");

    await shortcut(window, "A", ["control"]);
    await shortcut(window, "C", ["control"]);
    const copiedText = clipboard.readText();
    await window.webContents.executeJavaScript(`(() => { const input=document.querySelector(".annotation-text-editor"); const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(input,""); input.dispatchEvent(new InputEvent("input",{bubbles:true,inputType:"deleteContentBackward"})); input.focus(); })()`, true);
    await shortcut(window, "V", ["control"]);
    const pastedText = await waitFor(window, `document.querySelector(".annotation-text-editor").value||null`, 5_000, "text paste");
    await shortcut(window, "ENTER");
    await waitFor(window, `!document.querySelector(".annotation-text-editor") && ${annotationCountExpression}===1`, 5_000, "text commit");

    await shortcut(window, "Z", ["control"]);
    const undo = await waitFor(window, `${annotationCountExpression}===0`, 5_000, "Ctrl+Z");
    await shortcut(window, "Y", ["control"]);
    const redoY = await waitFor(window, `${annotationCountExpression}===1`, 5_000, "Ctrl+Y");
    await shortcut(window, "Z", ["control"]);
    await waitFor(window, `${annotationCountExpression}===0`, 5_000, "second Ctrl+Z");
    await shortcut(window, "Z", ["control", "shift"]);
    const redoShiftZ = await waitFor(window, `${annotationCountExpression}===1`, 5_000, "Ctrl+Shift+Z");
    await shortcut(window, "DELETE");
    const deleteKey = await waitFor(window, `${annotationCountExpression}===0`, 5_000, "Delete");
    await shortcut(window, "Z", ["control"]);
    await waitFor(window, `${annotationCountExpression}===1`, 5_000, "undo Delete");
    await shortcut(window, "BACKSPACE");
    const backspaceKey = await waitFor(window, `${annotationCountExpression}===0`, 5_000, "Backspace");

    await shortcut(window, "F");
    await waitForMain(() => window.isFullScreen(), 5_000, "fullscreen shortcut enter");
    const fullscreenLabel = await waitFor(window, `document.querySelector('[aria-label="창 모드"]')?.textContent.trim()`, 5_000, "window mode label");
    await shortcut(window, "F");
    await waitForMain(() => !window.isFullScreen(), 5_000, "fullscreen shortcut exit");

    window.setContentSize(1440, 900);
    await delay(200);
    const desktopLayout = await window.webContents.executeJavaScript(`(() => {
      const root=document.documentElement, inspector=document.querySelector(".inspection-panel"), info=document.querySelector(".information-panel");
      return {width:root.clientWidth,scrollWidth:root.scrollWidth,inspectorWidth:inspector.getBoundingClientRect().width,infoWidth:info.getBoundingClientRect().width,separate:info.getBoundingClientRect().left>inspector.getBoundingClientRect().right,metadataVisible:getComputedStyle(document.querySelector(".source-summary")).display!=="none"};
    })()`, true);
    window.setContentSize(720, 600);
    await delay(200);
    const compactLayout = await window.webContents.executeJavaScript(`(() => {
      const root=document.documentElement, labels=["파일 열기","단일 보기","비교 보기"];
      const controls=labels.map((label)=>{const button=document.querySelector('[aria-label="'+label+'"]'),r=button.getBoundingClientRect();return{label,left:r.left,right:r.right,top:r.top,bottom:r.bottom,visible:getComputedStyle(button).display!=="none"}});
      const inspector=document.querySelector(".inspection-panel"), info=document.querySelector(".information-panel"), topbar=document.querySelector(".topbar").getBoundingClientRect();
      return {width:root.clientWidth,scrollWidth:root.scrollWidth,controls,inspectorWidth:inspector.getBoundingClientRect().width,infoWidth:info.getBoundingClientRect().width,separate:info.getBoundingClientRect().left>inspector.getBoundingClientRect().right,topbarHeight:topbar.height,dpr:devicePixelRatio};
    })()`, true);

    result = {
      windowChrome,
      initialUi,
      shortcuts: {
        ctrlO: dialogCalls === 1,
        frameNavigation: frameAfter > frameBefore,
        copyPaste: copiedText === imeText && pastedText === imeText,
        koreanIme: pastedText === imeText,
        undo: Boolean(undo),
        redoY: Boolean(redoY),
        redoShiftZ: Boolean(redoShiftZ),
        deleteKey: Boolean(deleteKey),
        backspaceKey: Boolean(backspaceKey),
        fullscreen: fullscreenLabel === "창 모드",
      },
      crosshairPolicy,
      desktopLayout,
      compactLayout,
    };
    result.passed = result.windowChrome.applicationMenuRemoved
      && result.windowChrome.menuBarHidden
      && result.windowChrome.nativeHandle
      && result.windowChrome.minimizable
      && result.windowChrome.maximizable
      && result.windowChrome.closable
      && result.windowChrome.title === "CT Cine Reviewer"
      && result.initialUi.required
      && result.initialUi.oldLabels.length === 0
      && result.initialUi.fileHasIcon
      && JSON.stringify(result.initialUi.toolOrder) === JSON.stringify(expectedToolOrder)
      && !result.initialUi.railHasFitOr100
      && result.initialUi.crosshairDisabled
      && result.initialUi.crosshairTitle === "비교 보기에서 사용할 수 있습니다"
      && result.initialUi.zoomValueCommand
      && result.initialUi.mediaControlCount === 0
      && !result.initialUi.hasCancel
      && JSON.stringify(result.initialUi.sideColumns) === JSON.stringify(["조정", "정보"])
      && result.initialUi.frameTimeText === "--:--:--/--:--:--"
      && JSON.stringify(result.initialUi.precisionLabels) === JSON.stringify(["첫 프레임", "5프레임 이전", "5프레임 다음", "마지막 프레임"])
      && Object.values(result.shortcuts).every(Boolean)
      && result.crosshairPolicy.defaultOn.dual
      && result.crosshairPolicy.defaultOn.crosshairPressed === "true"
      && result.crosshairPolicy.panAfterToggle.tool === "pan"
      && result.crosshairPolicy.selectAfterToggle.tool === "select"
      && result.crosshairPolicy.single.crosshairDisabled
      && result.crosshairPolicy.restoredOff.crosshairPressed === "false"
      && result.crosshairPolicy.final.tool === "pan"
      && result.crosshairPolicy.final.crosshairPressed === "true"
      && result.desktopLayout.width === result.desktopLayout.scrollWidth
      && result.desktopLayout.inspectorWidth > 0 && result.desktopLayout.infoWidth > 0 && result.desktopLayout.separate
      && result.desktopLayout.metadataVisible
      && result.compactLayout.width === result.compactLayout.scrollWidth
      && result.compactLayout.inspectorWidth > 0 && result.compactLayout.infoWidth > 0 && result.compactLayout.separate
      && result.compactLayout.topbarHeight <= 44
      && result.compactLayout.controls.every((control) => control.visible && control.left >= 0 && control.right <= result.compactLayout.width);

    console.log(JSON.stringify(result, null, 2));
    if (!result.passed) process.exitCode = 1;
  } finally {
    clipboard.writeText(previousClipboard);
    try {
      const cacheModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
      await cacheModule.shutdownCacheFrameIpcResources();
    } catch {
      // The result above remains authoritative if startup failed before cache initialization.
    }
    for (const window of BrowserWindow.getAllWindows()) window.destroy();
    app.exit(process.exitCode ?? 0);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
  app.exit(1);
});
