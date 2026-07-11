import { app, BrowserWindow, ipcMain } from "electron";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { registerFrameIpc, shutdownFrameIpcResources } from "./frameIpc.js";
import { registerSpikeFrameIpc, shutdownSpikeFrameIpcResources } from "./spike22/spikeFrameIpc.js";
import { resolveFfmpegRuntimePaths } from "./runtimePaths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const spike22 = process.env.CCR_PHASE22_SPIKE === "1";

function createWindow() {
  const window = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 900,
    minHeight: 620,
    title: "CT Cine Reviewer",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

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
    phase: spike22 ? "phase2.2-cache-spike" : "phase2.1-windows-pilot",
    ffmpegConfigured: existsSync(ffmpegPath) && existsSync(ffprobePath),
  };
});

if (spike22) registerSpikeFrameIpc();
else registerFrameIpc();

app.whenReady().then(() => {
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
  void (spike22 ? shutdownSpikeFrameIpcResources() : shutdownFrameIpcResources()).finally(() => app.quit());
});
