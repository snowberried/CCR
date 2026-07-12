import { app, dialog, ipcMain, type WebContents } from "electron";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { resolveFfmpegRuntimePaths } from "../runtimePaths.js";
import { YuvSpikeSession, type SpikeFrame } from "./YuvSpikeSession.js";

const SUPPORTED_EXTENSIONS = new Set([".mp4", ".mov", ".avi", ".mkv"]);
let activeSession: YuvSpikeSession | null = null;
let openingController: AbortController | null = null;
let activeGeneration = 0;

function validVideoPath(filePath: unknown): filePath is string {
  return typeof filePath === "string" && path.isAbsolute(filePath) && SUPPORTED_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function serializeFrame(frame: SpikeFrame, session: YuvSpikeSession, generation: number) {
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
    diagnostics: { session: session.sessionId.slice(0, 8), generation, requestId: frame.frameIndex + 1 },
  };
}

async function openPath(filePath: string, sender: WebContents) {
  const generation = ++activeGeneration;
  openingController?.abort();
  const controller = new AbortController();
  openingController = controller;
  activeSession?.close();
  activeSession = null;
  const runtimePaths = resolveFfmpegRuntimePaths({
    isPackaged: app.isPackaged,
    appPath: app.getAppPath(),
    resourcesPath: process.resourcesPath,
  });
  try {
    const session = await YuvSpikeSession.open(runtimePaths, filePath, controller.signal);
    if (generation !== activeGeneration) {
      session.close();
      return { canceled: false as const, error: "OPEN_SUPERSEDED" };
    }
    activeSession = session;
    return {
      canceled: false as const,
      sessionId: session.sessionId,
      generation,
      metadata: session.metadata(),
      frame: serializeFrame(session.firstFrame(), session, generation),
    };
  } catch (error) {
    return { canceled: false as const, error: error instanceof Error ? error.message : "SPIKE_OPEN_FAILED" };
  } finally {
    if (openingController === controller) openingController = null;
  }
}

export function openSpikePathForQa(filePath: string, sender: WebContents) {
  if (process.env.CCR_PHASE22_QA !== "1" || !validVideoPath(filePath)) {
    return Promise.resolve({ canceled: false as const, error: "QA_VIDEO_SOURCE_DISABLED" });
  }
  return openPath(filePath, sender);
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
    const generation = activeGeneration;
    session.startBackground((metadata) => {
      if (activeSession === session && activeGeneration === generation) {
        event.sender.send("frame:spikeMetadata", { sessionId: session.sessionId, metadata, cacheStatus: session.status() });
      }
    });
  });
  ipcMain.handle("frame:get", async (_event, input: unknown) => {
    const startedAt = performance.now();
    const session = activeSession;
    if (!session || typeof input !== "object" || input === null) return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    const request = input as { sessionId?: unknown; frameIndex?: unknown; displayFormat?: unknown };
    if (request.sessionId !== session.sessionId || !Number.isInteger(request.frameIndex)) return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    try {
      const frame = await session.requestFrame(request.frameIndex as number, request.displayFormat === "rgba" ? "rgba" : "i420");
      const response = serializeFrame(frame, session, activeGeneration);
      return { ...response, requestMs: performance.now() - startedAt };
    } catch (error) {
      return { accepted: false as const, error: error instanceof Error ? error.message : "FRAME_OPERATION_FAILED" };
    }
  });
  ipcMain.handle("frame:cancel", () => {
    if (openingController) {
      activeGeneration += 1;
      openingController.abort();
      openingController = null;
    }
  });
  ipcMain.handle("frame:close", () => {
    activeGeneration += 1;
    openingController?.abort();
    openingController = null;
    activeSession?.close();
    activeSession = null;
  });
}

export async function shutdownSpikeFrameIpcResources(): Promise<void> {
  activeGeneration += 1;
  openingController?.abort();
  activeSession?.close();
  activeSession = null;
}
