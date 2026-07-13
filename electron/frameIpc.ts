import { app, dialog, ipcMain } from "electron";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FrameRequestCoordinator } from "../src/application/FrameRequestCoordinator.js";
import { SessionGenerationGuard } from "../src/application/SessionGenerationGuard.js";
import { createFrameCachePolicy } from "../src/domain/frameCachePolicy.js";
import type { Rational } from "../src/domain/videoProbe.js";
import { FfmpegCliProbeProvider } from "./adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "./adapters/FfmpegRawFrameDecoder.js";
import {
  FfmpegSegmentFrameProvider,
  FrameProviderError,
} from "./adapters/FfmpegSegmentFrameProvider.js";
import { resolveFfmpegRuntimePaths } from "./runtimePaths.js";

const SUPPORTED_EXTENSIONS = new Set([".mp4", ".mov", ".avi", ".mkv"]);

type ActiveFrameSession = {
  sessionId: string;
  generation: number;
  frameCount: number;
  provider: FfmpegSegmentFrameProvider;
  coordinator: FrameRequestCoordinator<Buffer>;
};

const generationGuard = new SessionGenerationGuard();
let openingController: AbortController | null = null;
let activeSession: ActiveFrameSession | null = null;

function rationalValue(rational: Rational | null): number | null {
  if (!rational || rational.denominator === 0) {
    return null;
  }
  return rational.numerator / rational.denominator;
}

function serializeFrame(
  session: ActiveFrameSession,
  coordinated: Awaited<ReturnType<FrameRequestCoordinator<Buffer>["request"]>>,
  requestMs: number,
) {
  if (!coordinated.accepted || !coordinated.result || activeSession !== session) {
    return { accepted: false as const };
  }
  const result = coordinated.result;
  return {
    accepted: true as const,
    descriptor: result.descriptor,
    pixels: Uint8Array.from(result.payload),
    cache: result.cache,
    requestMs,
    cacheStatus: session.provider.getCacheStatus(),
    diagnostics: {
      session: session.sessionId.slice(0, 8),
      generation: session.generation,
      requestId: result.request.requestId,
    },
  };
}

async function closeSession(session: ActiveFrameSession | null): Promise<void> {
  if (!session) {
    return;
  }
  session.coordinator.cancel();
  await session.provider.closeSession(session.sessionId);
  if (activeSession === session) {
    activeSession = null;
  }
}

async function closeActiveSession(): Promise<void> {
  await closeSession(activeSession);
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

function validVideoPath(filePath: unknown): filePath is string {
  return typeof filePath === "string" &&
    path.isAbsolute(filePath) &&
    SUPPORTED_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function beginOpenGeneration(): number {
  const generation = generationGuard.begin();
  openingController?.abort();
  openingController = null;
  return generation;
}

async function openVideoPath(filePath: string, existingGeneration?: number) {
  const generation = existingGeneration ?? beginOpenGeneration();
  if (!generationGuard.isCurrent(generation)) {
    return { canceled: false as const, error: "OPEN_SUPERSEDED" };
  }
  const controller = new AbortController();
  openingController = controller;
  await closeActiveSession();

  const { ffprobePath, ffmpegPath } = resolveFfmpegRuntimePaths({
    isPackaged: app.isPackaged,
    appPath: app.getAppPath(),
    resourcesPath: process.resourcesPath,
  });
  let session: ActiveFrameSession | null = null;

  try {
    const probeStartedAt = performance.now();
    const probe = await new FfmpegCliProbeProvider({ ffprobePath }).probe({
      filePath,
      signal: controller.signal,
    });
    const probeMs = performance.now() - probeStartedAt;
    if (!generationGuard.isCurrent(generation)) {
      return { canceled: false as const, error: "OPEN_SUPERSEDED" };
    }

    const sessionId = randomUUID();
    const cachePolicy = createFrameCachePolicy(probe.stream.width, probe.stream.height);
    const decoder = new FfmpegRawFrameDecoder({
      ffmpegPath,
      sourcePath: filePath,
      frames: probe.frames,
      width: probe.stream.width,
      height: probe.stream.height,
      timeoutMs: 30_000,
    });
    const provider = new FfmpegSegmentFrameProvider({
      sessionId,
      frameCount: probe.frames.length,
      decoder,
      width: probe.stream.width,
      height: probe.stream.height,
      cachePolicy,
      directional: true,
    });
    const coordinator = new FrameRequestCoordinator(provider);
    coordinator.beginSession();
    session = { sessionId, generation, frameCount: probe.frames.length, provider, coordinator };
    activeSession = session;

    const startedAt = performance.now();
    const first = await coordinator.request(sessionId, 0);
    if (!generationGuard.isCurrent(generation) || activeSession !== session) {
      await closeSession(session);
      return { canceled: false as const, error: "OPEN_SUPERSEDED" };
    }
    return {
      canceled: false as const,
      sessionId,
      generation,
      metadata: {
        frameCount: probe.frames.length,
        width: probe.stream.width,
        height: probe.stream.height,
        codecName: probe.stream.codecName,
        fps: rationalValue(probe.stream.averageFrameRate) ?? rationalValue(probe.stream.nominalFrameRate),
        durationSeconds: probe.stream.durationSeconds,
        rotationDegrees: probe.stream.rotationDegrees,
        probeMs,
        cachePolicy,
      },
      frame: serializeFrame(session, first, performance.now() - startedAt),
    };
  } catch (error) {
    if (session) {
      await closeSession(session);
    }
    return {
      canceled: false as const,
      error: generationGuard.isCurrent(generation) ? errorCode(error) : "OPEN_SUPERSEDED",
    };
  } finally {
    if (generationGuard.isCurrent(generation)) {
      openingController = null;
    }
  }
}

export function openFramePathForQa(filePath: string) {
  return validVideoPath(filePath)
    ? openVideoPath(filePath)
    : Promise.resolve({ canceled: false as const, error: "INVALID_VIDEO_SOURCE" });
}

export function registerFrameIpc(): void {
  ipcMain.handle("frame:open", async () => {
    const generation = beginOpenGeneration();
    const selection = await dialog.showOpenDialog({
      properties: ["openFile"],
      filters: [{ name: "Video", extensions: ["mp4", "mov", "avi", "mkv"] }],
    });
    if (selection.canceled || selection.filePaths.length !== 1) {
      return { canceled: true as const };
    }
    return openVideoPath(selection.filePaths[0], generation);
  });

  ipcMain.handle("frame:openDropped", async (_event, input: unknown) => {
    if (
      typeof input !== "object" || input === null ||
      !("filePath" in input) || !validVideoPath((input as { filePath: unknown }).filePath)
    ) {
      return { canceled: false as const, error: "INVALID_VIDEO_SOURCE" };
    }
    return openVideoPath((input as { filePath: string }).filePath);
  });

  ipcMain.handle("frame:get", async (_event, input: unknown) => {
    const session = activeSession;
    if (
      !session || typeof input !== "object" || input === null ||
      !("sessionId" in input) || !("frameIndex" in input) ||
      (input as { sessionId: unknown }).sessionId !== session.sessionId ||
      !Number.isInteger((input as { frameIndex: unknown }).frameIndex)
    ) {
      return { accepted: false as const, error: "INVALID_FRAME_REQUEST" };
    }

    const frameIndex = (input as { frameIndex: number }).frameIndex;
    const startedAt = performance.now();
    try {
      const coordinated = await session.coordinator.request(session.sessionId, frameIndex);
      return serializeFrame(session, coordinated, performance.now() - startedAt);
    } catch (error) {
      return { accepted: false as const, error: errorCode(error) };
    }
  });

  ipcMain.handle("frame:cancel", () => {
    openingController?.abort();
    activeSession?.coordinator.cancel();
  });

  ipcMain.handle("frame:close", async () => {
    generationGuard.invalidate();
    openingController?.abort();
    openingController = null;
    await closeActiveSession();
  });
}

export async function shutdownFrameIpcResources(): Promise<void> {
  generationGuard.invalidate();
  openingController?.abort();
  openingController = null;
  await closeActiveSession();
}
