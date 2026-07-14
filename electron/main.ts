import { app, BrowserWindow, ipcMain, Menu } from "electron";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { selectProductDecoderMode } from "../src/application/productDecoderMode.js";
import { registerFrameIpc, shutdownFrameIpcResources } from "./frameIpc.js";
import { registerCacheFrameIpc, shutdownCacheFrameIpcResources } from "./cache/cacheFrameIpc.js";
import { resolveFfmpegRuntimePaths } from "./runtimePaths.js";
import { attachFullscreenEvents, registerFullscreenIpc } from "./fullscreenIpc.js";
import { registerExportIpc } from "./exportIpc.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const decoderMode = selectProductDecoderMode(process.env.CCR_FORCE_RGBA);
const forceRgba = decoderMode === "rgba-rollback";

function createWindow() {
  const window = new BrowserWindow({
    width: 1360,
    height: 820,
    minWidth: 720,
    minHeight: 600,
    title: "CT Cine Reviewer",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  attachFullscreenEvents(window);

  if (isDev) {
    void window.loadURL(process.env.VITE_DEV_SERVER_URL as string);
    return;
  }

  void window.loadFile(path.join(app.getAppPath(), "dist", "index.html"));
}

ipcMain.handle("runtime:getStatus", () => {
  const appRoot = app.getAppPath();
  const { ffmpegPath, ffprobePath } = resolveFfmpegRuntimePaths({
    isPackaged: app.isPackaged,
    appPath: appRoot,
    resourcesPath: process.resourcesPath,
  });
  return {
    phase: "phase4b1-frame-export",
    decoderMode,
    ffmpegConfigured: existsSync(ffmpegPath) && existsSync(ffprobePath),
  };
});

registerFullscreenIpc();
registerExportIpc();

if (forceRgba) registerFrameIpc();
else registerCacheFrameIpc();

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

let shutdownStarted = false;
app.on("before-quit", (event) => {
  if (shutdownStarted) {
    return;
  }
  event.preventDefault();
  shutdownStarted = true;
  void (forceRgba ? shutdownFrameIpcResources() : shutdownCacheFrameIpcResources()).finally(() => app.quit());
});
