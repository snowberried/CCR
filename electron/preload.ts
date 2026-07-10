import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("ccr", {
  getRuntimeStatus: () => ipcRenderer.invoke("runtime:getStatus"),
  openVideo: () => ipcRenderer.invoke("frame:open"),
  getFrame: (sessionId: string, frameIndex: number) =>
    ipcRenderer.invoke("frame:get", { sessionId, frameIndex }),
  cancelFrame: () => ipcRenderer.invoke("frame:cancel"),
  closeVideo: () => ipcRenderer.invoke("frame:close"),
});
