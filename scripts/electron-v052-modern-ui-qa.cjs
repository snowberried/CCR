const { app, BrowserWindow, dialog, Menu } = require("electron");
const { mkdir, readdir, writeFile } = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const root = path.resolve(__dirname, "..");
const sampleDirectory = path.join(root, "local-samples");
const outputDirectory = path.join(root, "artifacts", "qa-v052-modern-dark");
const expectedTools = [
  "Pan 도구",
  "Zoom 도구",
  "연결 십자선",
  "Select 도구",
  "Arrow 도구",
  "Text 도구",
  "Ellipse 도구",
  "Rectangle 도구",
];
const expectedNavigation = ["첫 프레임", "5프레임 이전", "이전 프레임", "다음 프레임", "5프레임 다음", "마지막 프레임"];

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function firstMediaFile() {
  const entries = await readdir(sampleDirectory, { withFileTypes: true });
  const entry = entries.find((candidate) => candidate.isFile() && [".mp4", ".mov", ".avi", ".mkv"].includes(path.extname(candidate.name).toLowerCase()));
  if (!entry) throw new Error("No local QA media available");
  return path.join(sampleDirectory, entry.name);
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

async function inspectLayout(window) {
  return window.webContents.executeJavaScript(`(() => {
    const rect=(selector)=>{const value=document.querySelector(selector)?.getBoundingClientRect();return value?{left:value.left,right:value.right,top:value.top,bottom:value.bottom,width:value.width,height:value.height}:null};
    const root=document.documentElement;
    const adjustment=document.querySelector('.inspection-panel');
    const information=document.querySelector('.information-panel');
    const navigation=[...document.querySelectorAll('.precision-controls > button')];
    const allIcons=[...document.querySelectorAll('.ui-icon')];
    const timeline=document.querySelector('.viewer-timeline');
    const time=document.querySelector('.frame-time-readout');
    const footer=document.querySelector('.navigation-footer');
    const controls=document.querySelector('.precision-controls');
    const settingsButton=document.querySelector('.footer-settings-button');
    const footerViewControls=document.querySelector('.footer-view-controls');
    const settingsRect=settingsButton?.getBoundingClientRect();
    const footerViewRect=footerViewControls?.getBoundingClientRect();
    const controlsRect=controls.getBoundingClientRect();
    const dividers=[...footer.querySelectorAll('.footer-section-divider')];
    const dividerCenters=dividers.map((divider)=>{const value=divider.getBoundingClientRect();return (value.left+value.right)/2;});
    const controlChildren=[...controls.children].map((node)=>({tag:node.tagName,className:node.className,rect:{left:node.getBoundingClientRect().left,right:node.getBoundingClientRect().right,width:node.getBoundingClientRect().width}}));
    return {
      viewport:{width:root.clientWidth,height:root.clientHeight,scrollWidth:root.scrollWidth,scrollHeight:root.scrollHeight},
      topbar:rect('.topbar'),
      footer:rect('.navigation-footer'),
      footerUtilityLayout:{
        settingsLabel:settingsButton?.textContent.trim(),
        settingsPressed:settingsButton?.getAttribute('aria-pressed'),
        settingsIconCount:settingsButton?.querySelectorAll('.ui-icon').length??0,
        topbarZoomCount:document.querySelectorAll('.topbar .zoom-control-group').length,
        topbarFitCount:[...document.querySelectorAll('.topbar button')].filter((button)=>button.title.startsWith('화면 맞춤')).length,
        footerZoomCount:footerViewControls?.querySelectorAll('.zoom-control-group').length??0,
        footerFitCount:[...(footerViewControls?.querySelectorAll('button')??[])].filter((button)=>button.title.startsWith('화면 맞춤')).length,
        navigationCenterOffset:Math.abs((controlsRect.left+controlsRect.right)/2-(footer.getBoundingClientRect().left+footer.getBoundingClientRect().right)/2),
        utilityGapDelta:settingsRect&&footerViewRect?Math.abs((controlsRect.left-settingsRect.right)-(footerViewRect.left-controlsRect.right)):null,
        dividerCount:dividers.length,
        dividerMidpointDelta:settingsRect&&footerViewRect&&dividerCenters.length===2?Math.max(
          Math.abs(dividerCenters[0]-(settingsRect.right+controlsRect.left)/2),
          Math.abs(dividerCenters[1]-(controlsRect.right+footerViewRect.left)/2),
        ):null,
        dividersVisible:dividers.every((divider)=>Number.parseFloat(getComputedStyle(divider).width)>0),
        settingsClear:Boolean(settingsRect&&settingsRect.right<=controlsRect.left),
        viewControlsClear:Boolean(footerViewRect&&controlsRect.right<=footerViewRect.left),
      },
      toolRail:rect('.viewer-tool-rail'),
      rightSidebar:rect('.right-sidebar'),
      selectedTab:document.querySelector('.right-panel-tabs [aria-selected="true"]')?.textContent.trim(),
      adjustmentHidden:adjustment.hidden,
      informationHidden:information.hidden,
      redundantPanelHeadings:document.querySelectorAll('.side-panel-heading').length,
      paneLabels:[...document.querySelectorAll('.pane-label')].map((label)=>label.textContent.trim()),
      adjustmentRegion:document.querySelector('.display-panel summary span')?.textContent.trim(),
      displayResetLabel:document.querySelector('.panel-reset-button')?.textContent.trim(),
      duplicateOriginalButtons:[...document.querySelectorAll('.display-buttons button')].filter((button)=>button.textContent.trim()==='원본').length,
      sourceVisible:getComputedStyle(document.querySelector('.source-summary')).display!=='none',
      toolLabelsVisible:[...document.querySelectorAll('.tool-label')].some((label)=>getComputedStyle(label).display!=='none'),
      toolOrder:[...document.querySelectorAll('.viewer-tool-rail button')].map((button)=>button.getAttribute('aria-label')),
      navigationLabels:navigation.map((button)=>button.getAttribute('aria-label')),
      navigationChildCount:controlChildren.length,
      navigationChildren:controlChildren,
      timelineInsideWorkspace:Boolean(timeline&&timeline.parentElement?.classList.contains('viewer-workspace')),
      timeInsideTimeline:Boolean(time&&time.parentElement===timeline),
      footerContainsTimeline:Boolean(footer?.querySelector('.annotated-timeline')),
      mediaControlCount:document.querySelectorAll('.media-controls').length,
      hasCancel:[...document.querySelectorAll('button')].some((button)=>button.textContent.trim()==='취소'||button.title==='디코딩 취소'),
      sideColumns:[...document.querySelectorAll('.inspection-panel,.information-panel')].map((panel)=>panel.getAttribute('aria-label')),
      adjustmentInteractiveCount:document.querySelectorAll('.inspection-panel button,.inspection-panel input,.inspection-panel select').length,
      informationInteractiveCount:document.querySelectorAll('.information-panel button,.information-panel input,.information-panel select').length,
      iconsValid:allIcons.length>0&&allIcons.every((icon)=>getComputedStyle(icon).maskImage!=='none'||getComputedStyle(icon).webkitMaskImage!=='none'),
      frameTimeText:time?.textContent.replace(/\\s/g,''),
    };
  })()`, true);
}

function closeTo(value, expected, tolerance = 2) {
  return Math.abs(value - expected) <= tolerance;
}

async function capturePng(window, outputPath, label) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      window.show();
      window.focus();
      await delay(250);
      await writeFile(outputPath, (await window.webContents.capturePage()).toPNG());
      return;
    } catch (error) {
      lastError = error;
      await delay(300);
    }
  }
  throw new Error(`${label} capture failed: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
}

async function main() {
  const mediaFile = await firstMediaFile();
  await mkdir(outputDirectory, { recursive: true });
  app.setAppPath(root);
  dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [mediaFile] });

  let result;
  try {
    await import(pathToFileURL(path.join(root, "dist-electron", "electron", "main.js")).href);
    await app.whenReady();
    const window = await waitForMain(() => BrowserWindow.getAllWindows()[0], 5_000, "main window");
    if (window.webContents.isLoading()) await new Promise((resolve) => window.webContents.once("did-finish-load", resolve));
    const initialWindowBounds = window.getBounds();

    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="파일 열기"]').click()`, true);
    await waitFor(window, `document.querySelector('.status-ready')&&!document.querySelector('[aria-label="비교 보기"]').disabled`, 30_000, "ready media");
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="비교 보기"]').click()`, true);
    await waitFor(window, `document.querySelectorAll('.viewer-pane').length===2`, 5_000, "dual view");

    const tabContract = await window.webContents.executeJavaScript(`(async () => {
      const informationTab=document.querySelector('#information-tab');
      const settingsButton=document.querySelector('.footer-settings-button');
      const adjustmentPanel=document.querySelector('#adjustment-panel');
      const informationPanel=document.querySelector('#information-panel');
      const state=()=>({
        selected:document.querySelector('.right-panel-tabs [aria-selected="true"]')?.textContent.trim(),
        adjustmentHidden:adjustmentPanel.hidden,
        informationHidden:informationPanel.hidden,
      });
      const initial=state();
      informationTab.click();
      await new Promise((resolve)=>requestAnimationFrame(resolve));
      const information=state();
      settingsButton.click();
      await new Promise((resolve)=>requestAnimationFrame(resolve));
      return {initial,information,restored:state()};
    })()`, true);

    const displayResetContract = await window.webContents.executeJavaScript(`(async () => {
      const gamma=document.querySelector('[aria-label="화면 보정 감마"]');
      const preset=document.querySelector('[aria-label="화면 보정 프리셋"]');
      const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
      setter.call(gamma,'1.5');
      gamma.dispatchEvent(new Event('input',{bubbles:true}));
      await new Promise((resolve)=>requestAnimationFrame(resolve));
      const before={gamma:gamma.value,preset:preset.value};
      document.querySelector('.panel-reset-button').click();
      await new Promise((resolve)=>requestAnimationFrame(resolve));
      return {before,after:{gamma:gamma.value,preset:preset.value}};
    })()`, true);

    const beforeNext = Number(await window.webContents.executeJavaScript(`document.querySelector('[aria-label="프레임 번호"]').value`, true));
    await window.webContents.executeJavaScript(`document.querySelector('[aria-label="다음 프레임"]').click()`, true);
    const afterNext = Number(await waitFor(window, `(() => { const value=Number(document.querySelector('[aria-label="프레임 번호"]').value); return value>${beforeNext}?value:null; })()`, 5_000, "next frame"));

    window.setContentSize(1440, 900);
    await delay(250);
    const desktop = await inspectLayout(window);
    const desktopPath = path.join(outputDirectory, "CCR-modern-dark-1440x900.png");
    await capturePng(window, desktopPath, "1440x900");

    window.setContentSize(720, 600);
    await delay(250);
    const compact = await inspectLayout(window);
    const compactPath = path.join(outputDirectory, "CCR-modern-dark-720x600.png");
    await capturePng(window, compactPath, "720x600");

    const desktopSymmetry = desktop.navigationChildren.length === 7
      && closeTo(desktop.navigationChildren[0].rect.width, desktop.navigationChildren[6].rect.width)
      && closeTo(desktop.navigationChildren[1].rect.width, desktop.navigationChildren[5].rect.width)
      && closeTo(desktop.navigationChildren[2].rect.width, desktop.navigationChildren[4].rect.width);
    const compactSymmetry = compact.navigationChildren.length === 7
      && closeTo(compact.navigationChildren[0].rect.width, compact.navigationChildren[6].rect.width)
      && closeTo(compact.navigationChildren[1].rect.width, compact.navigationChildren[5].rect.width)
      && closeTo(compact.navigationChildren[2].rect.width, compact.navigationChildren[4].rect.width);

    result = {
      windowChrome: {
        applicationMenuRemoved: Menu.getApplicationMenu() === null,
        menuBarHidden: !window.isMenuBarVisible(),
        nativeHandle: window.getNativeWindowHandle().length > 0,
        title: window.getTitle(),
      },
      initialWindowBounds,
      frameNavigation: { beforeNext, afterNext, passed: afterNext > beforeNext },
      tabContract,
      displayResetContract,
      desktop,
      compact,
      desktopSymmetry,
      compactSymmetry,
      screenshots: [desktopPath, compactPath],
    };

    const commonContract = (layout) => layout.viewport.width === layout.viewport.scrollWidth
      && layout.selectedTab === "조정"
      && !layout.adjustmentHidden
      && layout.informationHidden
      && layout.redundantPanelHeadings === 0
      && JSON.stringify(layout.paneLabels) === JSON.stringify(["왼쪽 영역", "오른쪽 영역"])
      && layout.adjustmentRegion === "화면 보정 · 왼쪽 영역"
      && layout.displayResetLabel === "초기 설정"
      && layout.duplicateOriginalButtons === 0
      && layout.footerUtilityLayout.settingsLabel === "설정"
      && layout.footerUtilityLayout.settingsPressed === "true"
      && layout.footerUtilityLayout.settingsIconCount === 1
      && layout.footerUtilityLayout.topbarZoomCount === 0
      && layout.footerUtilityLayout.topbarFitCount === 0
      && layout.footerUtilityLayout.footerZoomCount === 1
      && layout.footerUtilityLayout.footerFitCount === 1
      && layout.footerUtilityLayout.utilityGapDelta <= 1
      && layout.footerUtilityLayout.dividerCount === 2
      && layout.footerUtilityLayout.dividerMidpointDelta <= 1
      && layout.footerUtilityLayout.dividersVisible
      && layout.footerUtilityLayout.settingsClear
      && layout.footerUtilityLayout.viewControlsClear
      && JSON.stringify(layout.toolOrder) === JSON.stringify(expectedTools)
      && JSON.stringify(layout.navigationLabels) === JSON.stringify(expectedNavigation)
      && layout.navigationChildCount === 7
      && layout.timelineInsideWorkspace
      && layout.timeInsideTimeline
      && !layout.footerContainsTimeline
      && layout.mediaControlCount === 0
      && !layout.hasCancel
      && JSON.stringify(layout.sideColumns) === JSON.stringify(["조정", "정보"])
      && layout.adjustmentInteractiveCount > 0
      && layout.informationInteractiveCount === 0
      && layout.iconsValid;

    result.passed = result.windowChrome.applicationMenuRemoved
      && result.windowChrome.menuBarHidden
      && result.windowChrome.nativeHandle
      && result.windowChrome.title === "CT Cine Reviewer"
      && closeTo(result.initialWindowBounds.width, 1360, 1)
      && closeTo(result.initialWindowBounds.height, 820, 1)
      && result.frameNavigation.passed
      && result.tabContract.initial.selected === "조정"
      && !result.tabContract.initial.adjustmentHidden
      && result.tabContract.initial.informationHidden
      && result.tabContract.information.selected === "정보"
      && result.tabContract.information.adjustmentHidden
      && !result.tabContract.information.informationHidden
      && result.tabContract.restored.selected === "조정"
      && result.displayResetContract.before.gamma === "1.5"
      && result.displayResetContract.before.preset === "custom"
      && result.displayResetContract.after.gamma === "1"
      && result.displayResetContract.after.preset === "original"
      && commonContract(desktop)
      && commonContract(compact)
      && desktopSymmetry
      && compactSymmetry
      && closeTo(desktop.topbar.height, 66)
      && closeTo(desktop.footer.height, 84)
      && closeTo(desktop.rightSidebar.width, 294)
      && desktop.sourceVisible
      && desktop.toolLabelsVisible
      && closeTo(compact.topbar.height, 66)
      && closeTo(compact.footer.height, 84)
      && closeTo(compact.rightSidebar.width, 180)
      && !compact.sourceVisible
      && !compact.toolLabelsVisible;

    console.log(JSON.stringify(result, null, 2));
    if (!result.passed) process.exitCode = 1;
  } finally {
    try {
      const cacheModule = await import(pathToFileURL(path.join(root, "dist-electron", "electron", "cache", "cacheFrameIpc.js")).href);
      await cacheModule.shutdownCacheFrameIpcResources();
    } catch {
      // The QA result remains authoritative when startup fails before cache initialization.
    }
    for (const window of BrowserWindow.getAllWindows()) window.destroy();
    app.exit(process.exitCode ?? 0);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? (error.stack ?? error.message) : String(error));
  process.exitCode = 1;
  app.exit(1);
});
