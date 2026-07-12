import { BrowserWindow, ipcMain, type IpcMainInvokeEvent } from "electron";
import { targetFullscreen } from "../src/application/fullscreenPolicy.js";

function senderWindow(event: IpcMainInvokeEvent): BrowserWindow {
  const window = BrowserWindow.fromWebContents(event.sender);
  if (!window || window.isDestroyed()) throw new Error("INVALID_FULLSCREEN_SENDER");
  return window;
}

export function attachFullscreenEvents(window: BrowserWindow): void {
  window.on("enter-full-screen", () => window.webContents.send("window:fullscreenChanged", true));
  window.on("leave-full-screen", () => window.webContents.send("window:fullscreenChanged", false));
}

export function registerFullscreenIpc(): void {
  ipcMain.handle("window:getFullscreen", (event) => senderWindow(event).isFullScreen());
  ipcMain.handle("window:setFullscreen", (event, value: unknown) => {
    if (typeof value !== "boolean") throw new Error("INVALID_FULLSCREEN_VALUE");
    const window = senderWindow(event);
    window.setFullScreen(targetFullscreen(window.isFullScreen(), value ? "enter" : "exit"));
    return window.isFullScreen();
  });
  ipcMain.handle("window:toggleFullscreen", (event) => {
    const window = senderWindow(event);
    window.setFullScreen(targetFullscreen(window.isFullScreen(), "toggle"));
    return window.isFullScreen();
  });
}

export function unregisterFullscreenIpc(): void {
  ipcMain.removeHandler("window:getFullscreen");
  ipcMain.removeHandler("window:setFullscreen");
  ipcMain.removeHandler("window:toggleFullscreen");
}
