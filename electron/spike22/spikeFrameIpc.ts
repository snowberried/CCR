import { app, dialog, ipcMain, type WebContents } from "electron";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { resolveFfmpegRuntimePaths } from "../runtimePaths.js";
import { YuvSpikeSession, type SpikeFrame } from "./YuvSpikeSession.js";

const SUPPORTED_EXTENSIONS = new Set([".mp4", ".mov", ".avi", ".mkv"]);
let activeSession: YuvSpikeSession | null = null;
let openingController: AbortController | null = null;

function validVideoPath(filePath: unknown): filePath is string {
  return typeof filePath === "string" && path.isAbsolute(filePath) && SUPPORTED_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function serializeFrame(frame: SpikeFrame, session: YuvSpikeSession) {
  return {
    accepted: true as const,
    descriptor: {
      frameIndex: frame.frameIndex,
      pts: frame.pts,
      ptsSeconds: frame.ptsSeconds,
      width: frame.width,
      height: frame.height,
      pixelFormat: frame.pixelFormat,
      byteLength: frame.pixels.byteLength,
      fingerprint: frame.fingerprint,
    },
    pixels: Uint8Array.from(frame.pixels),
    layout: frame.layout,
    colorSpace: frame.colorSpace,
    cache: frame.cache,
    requestMs: frame.requestMs,
    cacheStatus: session.status(),
    diagnostics: { session: session.sessionId.slice(0, 8), generation: 1, requestId: frame.frameIndex + 1 },
  };
}

async function openPath(filePath: string, sender: WebContents) {
  openingController?.abort();
  openingController = new AbortController();
  activeSession?.close();
  activeSession = null;
  const runtimePaths = resolveFfmpegRuntimePaths({
    isPackaged: app.isPackaged,
    appPath: app.getAppPath(),
    resourcesPath: process.resourcesPath,
  });
  try {
    const session = await YuvSpikeSession.open(runtimePaths, filePath, openingController.signal);
    activeSession = session;
    return {
      canceled: false as const,
      sessionId: session.sessionId,
      generation: 1,
      metadata: session.metadata(),
      frame: serializeFrame(session.firstFrame(), session),
    };
  } catch (error) {
    return { canceled: false as const, error: error instanceof Error ? error.message : "SPIKE_OPEN_FAILED" };
  } finally {
    openingController = null;
  }
}

export function registerSpikeFrameIpc(): void {
  ipcMain.handle("frame:open", async (event) => {
    const selection = await dialog.showOpenDialog({ properties: ["openFile"], filters: [{ name: "Video", extensions: ["mp4", "mov", "avi", "mkv"] }] });
    if (selection.canceled || selection.filePaths.length !== 1) return { canceled: true as const };
    return openPath(selection.filePaths[0], event.sender);
  });
  ipcMain.handle("frame:openDropped", async (event, input: unknown) => {
    const filePath = typeof input === "object" && input !== null && "filePath" in input ? (input as { filePath: unknown }).filePath : null;
    if (!validVideoPath(filePath)) return { canceled: false as const, error: "INVALID_VIDEO_SOURCE" };
    return openPath(filePath, event.sender);
  });
  ipcMain.handle("frame:spikeAckFirst", (event, input: unknown) => {
    const session = activeSession;
    if (!session || typeof input !== "object" || input === null || (input as { sessionId?: unknown }).sessionId !== session.sessionId) return;
    session.startBackground((metadata) => event.sender.send("frame:spikeMetadata", { sessionId: session.sessionId, metadata, cacheStatus: session.status() }));
  });
  ipcMain.handle("frame:get", async (_event, input: unknown) => {
    const startedAt = performance.now();
    const session = activeSession;
    if (!session || typeof input !== "object" || input === null) return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    const request = input as { sessionId?: unknown; frameIndex?: unknown; displayFormat?: unknown };
    if (request.sessionId !== session.sessionId || !Number.isInteger(request.frameIndex)) return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    try {
      const frame = await session.requestFrame(request.frameIndex as number, request.displayFormat === "rgba" ? "rgba" : "i420");
      const response = serializeFrame(frame, session);
      return { ...response, requestMs: performance.now() - startedAt };
    } catch (error) {
      return { accepted: false as const, error: error instanceof Error ? error.message : "FRAME_OPERATION_FAILED" };
    }
  });
  ipcMain.handle("frame:cancel", () => { openingController?.abort(); });
  ipcMain.handle("frame:close", () => { activeSession?.close(); activeSession = null; });
}

export async function shutdownSpikeFrameIpcResources(): Promise<void> {
  openingController?.abort();
  activeSession?.close();
  activeSession = null;
}
