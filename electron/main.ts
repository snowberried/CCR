import { app, BrowserWindow, ipcMain } from "electron";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { registerFrameIpc } from "./frameIpc.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);

function createWindow() {
  const window = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 900,
    minHeight: 620,
    title: "CT Cine Reviewer",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
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
  return {
    phase: "phase1c-frame",
    ffmpegConfigured:
      existsSync(path.join(appRoot, "tools", "ffmpeg", "bin", "ffmpeg.exe")) &&
      existsSync(path.join(appRoot, "tools", "ffmpeg", "bin", "ffprobe.exe")),
    sampleAnalysisReady: existsSync(path.join(appRoot, "local-samples", "Sample_A.mp4")),
  };
});

registerFrameIpc();

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
