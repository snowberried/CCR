import { contextBridge, ipcRenderer, webUtils } from "electron";

contextBridge.exposeInMainWorld("ccr", {
  getRuntimeStatus: () => ipcRenderer.invoke("runtime:getStatus"),
  getFullscreen: () => ipcRenderer.invoke("window:getFullscreen"),
  setFullscreen: (value: boolean) => ipcRenderer.invoke("window:setFullscreen", value),
  toggleFullscreen: () => ipcRenderer.invoke("window:toggleFullscreen"),
  onFullscreenChanged: (callback: (value: boolean) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: boolean) => callback(value);
    ipcRenderer.on("window:fullscreenChanged", listener);
    return () => ipcRenderer.removeListener("window:fullscreenChanged", listener);
  },
  openVideo: () => ipcRenderer.invoke("frame:open"),
  savePng: (bytes: Uint8Array, defaultFileName: string) =>
    ipcRenderer.invoke("export:savePng", { bytes, defaultFileName }),
  copyPng: (bytes: Uint8Array) => ipcRenderer.invoke("export:copyPng", { bytes }),
  openDroppedVideo: (file: File) =>
    ipcRenderer.invoke("frame:openDropped", { filePath: webUtils.getPathForFile(file) }),
  ...(process.env.CCR_PHASE23_QA === "1" ? {
    openQaVideo: (sampleIndex: number) => ipcRenderer.invoke("frame:openQa", { sampleIndex }),
  } : {}),
  getFrame: (sessionId: string, frameIndex: number, displayFormat?: "i420" | "rgba") =>
    ipcRenderer.invoke("frame:get", { sessionId, frameIndex, displayFormat }),
  ackFirstFrame: (sessionId: string) => ipcRenderer.invoke("frame:cacheAckFirst", { sessionId }),
  onCacheMetadata: (callback: (value: unknown) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: unknown) => callback(value);
    ipcRenderer.on("frame:cacheMetadata", listener);
    return () => ipcRenderer.removeListener("frame:cacheMetadata", listener);
  },
  cancelFrame: () => ipcRenderer.invoke("frame:cancel"),
  closeVideo: () => ipcRenderer.invoke("frame:close"),
});
