import { contextBridge, ipcRenderer, webUtils } from "electron";

contextBridge.exposeInMainWorld("ccr", {
  getRuntimeStatus: () => ipcRenderer.invoke("runtime:getStatus"),
  openVideo: () => ipcRenderer.invoke("frame:open"),
  openDroppedVideo: (file: File) =>
    ipcRenderer.invoke("frame:openDropped", { filePath: webUtils.getPathForFile(file) }),
  ...(process.env.CCR_PHASE22_QA === "1" ? {
    openQaVideo: (sampleIndex: number) => ipcRenderer.invoke("frame:openQa", { sampleIndex }),
  } : {}),
  getFrame: (sessionId: string, frameIndex: number, displayFormat?: "i420" | "rgba") =>
    ipcRenderer.invoke("frame:get", { sessionId, frameIndex, displayFormat }),
  ackFirstFrame: (sessionId: string) => ipcRenderer.invoke("frame:spikeAckFirst", { sessionId }),
  onSpikeMetadata: (callback: (value: unknown) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: unknown) => callback(value);
    ipcRenderer.on("frame:spikeMetadata", listener);
    return () => ipcRenderer.removeListener("frame:spikeMetadata", listener);
  },
  cancelFrame: () => ipcRenderer.invoke("frame:cancel"),
  closeVideo: () => ipcRenderer.invoke("frame:close"),
});
