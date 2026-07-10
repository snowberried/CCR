import { app, dialog, ipcMain } from "electron";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FrameRequestCoordinator } from "../src/application/FrameRequestCoordinator.js";
import { FfmpegCliProbeProvider } from "./adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "./adapters/FfmpegRawFrameDecoder.js";
import {
  FfmpegSegmentFrameProvider,
  FrameProviderError,
} from "./adapters/FfmpegSegmentFrameProvider.js";

type ActiveFrameSession = {
  sessionId: string;
  frameCount: number;
  provider: FfmpegSegmentFrameProvider;
  coordinator: FrameRequestCoordinator<Buffer>;
};

let activeSession: ActiveFrameSession | null = null;

function serializeFrame(
  coordinated: Awaited<ReturnType<FrameRequestCoordinator<Buffer>["request"]>>,
  requestMs: number,
) {
  if (!coordinated.accepted || !coordinated.result) {
    return { accepted: false as const };
  }
  const result = coordinated.result;
  return {
    accepted: true as const,
    descriptor: result.descriptor,
    pixels: Uint8Array.from(result.payload),
    cache: result.cache,
    requestMs,
    cacheStatus: activeSession?.provider.getCacheStatus() ?? null,
  };
}

async function closeActiveSession(): Promise<void> {
  if (!activeSession) {
    return;
  }
  activeSession.coordinator.cancel();
  await activeSession.provider.closeSession(activeSession.sessionId);
  activeSession = null;
}

function errorCode(error: unknown): string {
  if (error instanceof FrameProviderError) {
    return error.code;
  }
  if (typeof error === "object" && error !== null && "code" in error) {
    return String((error as { code: unknown }).code);
  }
  return "FRAME_OPERATION_FAILED";
}

export function registerFrameIpc(): void {
  ipcMain.handle("frame:open", async () => {
    const selection = await dialog.showOpenDialog({
      properties: ["openFile"],
      filters: [{ name: "Video", extensions: ["mp4", "mov", "avi", "mkv"] }],
    });
    if (selection.canceled || selection.filePaths.length !== 1) {
      return { canceled: true as const };
    }

    await closeActiveSession();
    const appRoot = app.getAppPath();
    const ffprobePath = path.join(appRoot, "tools", "ffmpeg", "bin", "ffprobe.exe");
    const ffmpegPath = path.join(appRoot, "tools", "ffmpeg", "bin", "ffmpeg.exe");

    try {
      const probe = await new FfmpegCliProbeProvider({ ffprobePath }).probe({
        filePath: selection.filePaths[0],
      });
      const sessionId = randomUUID();
      const decoder = new FfmpegRawFrameDecoder({
        ffmpegPath,
        sourcePath: selection.filePaths[0],
        frames: probe.frames,
        width: probe.stream.width,
        height: probe.stream.height,
        timeoutMs: 30_000,
      });
      const provider = new FfmpegSegmentFrameProvider({
        sessionId,
        frameCount: probe.frames.length,
        decoder,
        backwardFrames: 20,
        forwardFrames: 40,
      });
      const coordinator = new FrameRequestCoordinator(provider);
      coordinator.beginSession();
      activeSession = { sessionId, frameCount: probe.frames.length, provider, coordinator };

      const startedAt = performance.now();
      const first = await coordinator.request(sessionId, 0);
      return {
        canceled: false as const,
        sessionId,
        metadata: {
          frameCount: probe.frames.length,
          width: probe.stream.width,
          height: probe.stream.height,
          codecName: probe.stream.codecName,
        },
        frame: serializeFrame(first, performance.now() - startedAt),
      };
    } catch (error) {
      await closeActiveSession();
      return { canceled: false as const, error: errorCode(error) };
    }
  });

  ipcMain.handle("frame:get", async (_event, input: unknown) => {
    if (
      !activeSession ||
      typeof input !== "object" ||
      input === null ||
      !("sessionId" in input) ||
      !("frameIndex" in input) ||
      (input as { sessionId: unknown }).sessionId !== activeSession.sessionId ||
      !Number.isInteger((input as { frameIndex: unknown }).frameIndex)
    ) {
      return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    }

    const frameIndex = (input as { frameIndex: number }).frameIndex;
    const startedAt = performance.now();
    try {
      const coordinated = await activeSession.coordinator.request(activeSession.sessionId, frameIndex);
      return serializeFrame(coordinated, performance.now() - startedAt);
    } catch (error) {
      return { accepted: false as const, error: errorCode(error) };
    }
  });

  ipcMain.handle("frame:cancel", () => {
    activeSession?.coordinator.cancel();
  });

  ipcMain.handle("frame:close", async () => {
    await closeActiveSession();
  });
}
