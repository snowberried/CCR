const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("node:path");

const frameBytes = 406 * 720 * 4;
const payload = new Uint8Array(frameBytes);

ipcMain.handle("benchmark:frame", () => payload);

ipcMain.once("benchmark:complete", (_event, result) => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
  app.quit();
});

app.whenReady().then(async () => {
  const window = new BrowserWindow({
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "electron-ipc-benchmark-preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  await window.loadURL("data:text/html,<html><body></body></html>");
});
