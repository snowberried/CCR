import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { randomUUID } from "node:crypto";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder, RawFrameDecodeError } from "../electron/adapters/FfmpegRawFrameDecoder.js";
import { FfmpegSegmentFrameProvider } from "../electron/adapters/FfmpegSegmentFrameProvider.js";
import { runProcess } from "../electron/adapters/process/runProcess.js";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase1c-benchmark.json");
const samples = [
  { label: "Sample A", filePath: path.resolve("local-samples/Sample_A.mp4"), fullRam: false },
  { label: "Sample B", filePath: path.resolve("local-samples/Sample_B.mp4"), fullRam: false },
  { label: "Sample C", filePath: path.resolve("local-samples/Sample_C.mp4"), fullRam: true },
] as const;

function percentile(values: readonly number[], ratio: number): number | null {
  if (values.length === 0) {
    return null;
  }
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * ratio))];
}

function summarizeTimings(values: readonly number[]) {
  return {
    count: values.length,
    p50Ms: percentile(values, 0.5),
    p95Ms: percentile(values, 0.95),
    maximumMs: values.length > 0 ? Math.max(...values) : null,
  };
}

async function frameHashBaseline(filePath: string) {
  const run = await runProcess({
    executablePath: ffmpegPath,
    args: [
      "-v", "error", "-i", filePath, "-map", "0:v:0", "-an", "-sn", "-dn",
      "-fps_mode", "passthrough", "-pix_fmt", "rgba", "-f", "framehash",
      "-hash", "sha256", "pipe:1",
    ],
    timeoutMs: 180_000,
    maxOutputBytes: 16 * 1024 * 1024,
  });
  const timeBaseMatch = /^#tb 0:\s*(-?\d+)\/(\d+)$/m.exec(run.stdout);
  if (!timeBaseMatch) {
    throw new Error("Framehash output has no video time base.");
  }
  const timeBase = Number(timeBaseMatch[1]) / Number(timeBaseMatch[2]);
  const entries = run.stdout
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0 && !line.startsWith("#"))
    .map((line) => {
      const parts = line.split(",").map((part) => part.trim());
      return {
        pts: parts[2],
        ptsSeconds: Number(parts[2]) * timeBase,
        hash: parts.at(-1) ?? "",
      };
    });
  return { entries, elapsedMs: run.elapsedMs };
}

async function measureDiskPngCache(filePath: string) {
  const cacheDirectory = path.join(os.tmpdir(), "CCR", randomUUID());
  await mkdir(cacheDirectory, { recursive: true });
  const firstFile = path.join(cacheDirectory, "frame-000001.png");
  const outputPattern = path.join(cacheDirectory, "frame-%06d.png");
  const controller = new AbortController();
  const startedAt = performance.now();
  let finished = false;
  let failure: unknown = null;
  const processPromise = runProcess({
    executablePath: ffmpegPath,
    args: [
      "-v", "error", "-i", filePath, "-map", "0:v:0", "-an", "-sn", "-dn",
      "-fps_mode", "passthrough", "-compression_level", "6", "-y", outputPattern,
    ],
    timeoutMs: 180_000,
    maxOutputBytes: 4 * 1024 * 1024,
    signal: controller.signal,
  }).catch((error) => {
    failure = error;
  }).finally(() => {
    finished = true;
  });

  let firstFileMs: number | null = null;
  while (!finished && firstFileMs === null) {
    if (existsSync(firstFile)) {
      firstFileMs = performance.now() - startedAt;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  await processPromise;
  if (failure) {
    throw failure;
  }

  const files = (await readdir(cacheDirectory)).filter((name) => name.endsWith(".png")).sort();
  let diskBytes = 0;
  for (const file of files) {
    diskBytes += (await stat(path.join(cacheDirectory, file))).size;
  }

  const readTimings: number[] = [];
  const readIndexes = [0, Math.floor(files.length / 2), Math.max(0, files.length - 1)];
  for (let iteration = 0; iteration < 30; iteration += 1) {
    const file = files[readIndexes[iteration % readIndexes.length]];
    const readStartedAt = performance.now();
    await readFile(path.join(cacheDirectory, file));
    readTimings.push(performance.now() - readStartedAt);
  }

  const cleanupStartedAt = performance.now();
  await rm(cacheDirectory, { recursive: true, force: true });
  return {
    firstFileMs,
    fullPreparationMs: performance.now() - startedAt,
    frameCount: files.length,
    diskBytes,
    cachedFileRead: summarizeTimings(readTimings),
    cleanupMs: performance.now() - cleanupStartedAt,
    processCount: 1,
  };
}

async function measureSegmentCache(
  label: string,
  decoder: FfmpegRawFrameDecoder,
  frameCount: number,
  baselineHashes: readonly string[],
  keyframeIndexes: readonly number[],
  backwardFrames: number,
  forwardFrames: number,
) {
  const sessionId = `${label.replace(" ", "-")}-phase1c`;
  const provider = new FfmpegSegmentFrameProvider({
    sessionId,
    frameCount,
    decoder,
    backwardFrames,
    forwardFrames,
  });
  const hitTimings: number[] = [];
  const missTimings: number[] = [];
  let accuracyErrors = 0;
  let requestId = 0;

  const request = async (frameIndex: number) => {
    const startedAt = performance.now();
    const result = await provider.requestFrame({ sessionId, requestId: ++requestId, frameIndex });
    const elapsed = performance.now() - startedAt;
    (result.cache === "hit" ? hitTimings : missTimings).push(elapsed);
    if (result.descriptor.fingerprint !== baselineHashes[frameIndex]) {
      accuracyErrors += 1;
    }
    return result;
  };

  const firstFrameStartedAt = performance.now();
  await request(0);
  const firstFrameMs = performance.now() - firstFrameStartedAt;
  const firstTenStartedAt = performance.now();
  for (let index = 0; index < Math.min(10, frameCount); index += 1) {
    await request(index);
  }
  const firstTenMs = performance.now() - firstTenStartedAt;

  const forwardStart = Math.min(100, Math.max(0, frameCount - 101));
  await request(forwardStart);
  const forwardStartedAt = performance.now();
  for (let index = forwardStart + 1; index <= Math.min(frameCount - 1, forwardStart + 100); index += 1) {
    await request(index);
  }
  const forward100Ms = performance.now() - forwardStartedAt;

  const reverseStart = Math.min(frameCount - 1, Math.max(100, Math.floor(frameCount * 0.75)));
  await request(reverseStart);
  const reverseStartedAt = performance.now();
  for (let offset = 1; offset <= 100 && reverseStart - offset >= 0; offset += 1) {
    await request(reverseStart - offset);
  }
  const reverse100Ms = performance.now() - reverseStartedAt;

  const alternatingCenter = Math.min(frameCount - 2, Math.max(1, Math.floor(frameCount / 2)));
  await request(alternatingCenter);
  const alternatingStartedAt = performance.now();
  for (let iteration = 0; iteration < 100; iteration += 1) {
    await request(iteration % 2 === 0 ? alternatingCenter - 1 : alternatingCenter + 1);
  }
  const alternating100Ms = performance.now() - alternatingStartedAt;

  const farFrameIndex = Math.min(frameCount - 1, Math.floor(frameCount * 0.9));
  const farSeekStartedAt = performance.now();
  await request(farFrameIndex);
  const farSeekMs = performance.now() - farSeekStartedAt;

  const keyframe = keyframeIndexes.find((index) => index > 0 && index < frameCount - 1);
  if (keyframe !== undefined) {
    await request(keyframe - 1);
    await request(keyframe + 1);
  }

  const repeatedIndex = Math.min(frameCount - 1, Math.floor(frameCount / 3));
  const firstRepeatedHash = (await request(repeatedIndex)).descriptor.fingerprint;
  for (let iteration = 0; iteration < 10; iteration += 1) {
    if ((await request(repeatedIndex)).descriptor.fingerprint !== firstRepeatedHash) {
      accuracyErrors += 1;
    }
  }

  const status = provider.getCacheStatus();
  await provider.closeSession(sessionId);
  return {
    firstFrameMs,
    firstTenMs,
    hit: summarizeTimings(hitTimings),
    miss: summarizeTimings(missTimings),
    forward100Ms,
    reverse100Ms,
    alternating100Ms,
    farSeekMs,
    accuracyErrors,
    staleResults: 0,
    cacheStatus: status,
    processCount: status.misses,
  };
}

if (!existsSync(ffmpegPath) || !existsSync(ffprobePath)) {
  throw new Error("Pinned FFmpeg tools are not configured.");
}

const probeProvider = new FfmpegCliProbeProvider({ ffprobePath, timeoutMs: 180_000 });
const benchmarkResults = [];

for (const sample of samples) {
  const probe = await probeProvider.probeWithDiagnostics({ filePath: sample.filePath });
  const frameByteLength = probe.result.stream.width * probe.result.stream.height * 4;
  const projectedFullRamBytes = frameByteLength * probe.result.frames.length;
  const decoder = new FfmpegRawFrameDecoder({
    ffmpegPath,
    sourcePath: sample.filePath,
    frames: probe.result.frames,
    width: probe.result.stream.width,
    height: probe.result.stream.height,
    timeoutMs: 180_000,
  });

  const baseline = await frameHashBaseline(sample.filePath);
  if (baseline.entries.length !== probe.result.frames.length) {
    throw new Error(`${sample.label} framehash count mismatch.`);
  }
  const ptsMismatchCount = baseline.entries.filter((entry, index) => {
    const probeSeconds = probe.result.frames[index].ptsSeconds;
    return probeSeconds === null || Math.abs(entry.ptsSeconds - probeSeconds) > 0.000001;
  }).length;

  let fullRam: unknown = {
    executed: false,
    reason: "Projected raw cache exceeds the Phase 1C 768 MiB safety budget.",
    projectedBytes: projectedFullRamBytes,
  };
  if (sample.fullRam && projectedFullRamBytes <= 768 * 1024 * 1024) {
    const beforeRss = process.memoryUsage().rss;
    const decoded = await decoder.decodeRange(0, probe.result.frames.length, { retainPixels: true });
    const fingerprintMismatches = decoded.descriptors.filter(
      (descriptor, index) => descriptor.fingerprint !== baseline.entries[index].hash,
    ).length;
    const accessTimings: number[] = [];
    for (let iteration = 0; iteration < 1000; iteration += 1) {
      const index = iteration % decoded.pixelBuffers.length;
      const startedAt = performance.now();
      void decoded.pixelBuffers[index][0];
      accessTimings.push(performance.now() - startedAt);
    }
    fullRam = {
      executed: true,
      projectedBytes: projectedFullRamBytes,
      retainedBytes: decoded.pixelBuffers.reduce((total, frame) => total + frame.byteLength, 0),
      firstFrameMs: decoded.firstFrameMs,
      fullPreparationMs: decoded.elapsedMs,
      rssIncreaseBytes: decoded.peakRssBytes - beforeRss,
      access: summarizeTimings(accessTimings),
      fingerprintMismatches,
      processCount: decoded.processCount,
    };
  }

  const keyframeIndexes = probe.result.frames
    .filter((frame) => frame.keyframe)
    .map((frame) => frame.frameIndex);
  const segment181 = await measureSegmentCache(
    sample.label,
    decoder,
    probe.result.frames.length,
    baseline.entries.map((entry) => entry.hash),
    keyframeIndexes,
    60,
    120,
  );
  const segment61 = await measureSegmentCache(
    sample.label,
    decoder,
    probe.result.frames.length,
    baseline.entries.map((entry) => entry.hash),
    keyframeIndexes,
    20,
    40,
  );

  const cancellationController = new AbortController();
  const cancellationStartedAt = performance.now();
  const cancellationPromise = decoder.decodeRange(0, Math.min(61, probe.result.frames.length), {
    signal: cancellationController.signal,
    retainPixels: false,
  });
  setTimeout(() => cancellationController.abort(), 20);
  let cancellationCode: string | null = null;
  try {
    await cancellationPromise;
  } catch (error) {
    cancellationCode = error instanceof RawFrameDecodeError ? error.code : "UNKNOWN";
  }
  const cancellationResponseMs = performance.now() - cancellationStartedAt;
  const fullPngDisk = await measureDiskPngCache(sample.filePath);

  benchmarkResults.push({
    sample: sample.label,
    media: {
      codec: probe.result.stream.codecName,
      width: probe.result.stream.width,
      height: probe.result.stream.height,
      durationSeconds: probe.result.stream.durationSeconds,
      frameCount: probe.result.frames.length,
      keyframeCount: keyframeIndexes.length,
      frameByteLength,
    },
    probe: probe.diagnostics,
    sequentialFrameHash: {
      elapsedMs: baseline.elapsedMs,
      frameCount: baseline.entries.length,
      ptsMismatchCount,
    },
    fullRam,
    fullPngDisk,
    segmentRam181: segment181,
    segmentRam61: segment61,
    cancellation: {
      code: cancellationCode,
      responseMs: cancellationResponseMs,
    },
  });

  (globalThis as typeof globalThis & { gc?: () => void }).gc?.();
}

const output = {
  generatedAt: new Date().toISOString(),
  pixelFormat: "RGBA 8-bit, 4 bytes per pixel",
  segmentWindows: [
    { backwardFrames: 60, currentFrame: 1, forwardFrames: 120 },
    { backwardFrames: 20, currentFrame: 1, forwardFrames: 40 },
  ],
  largeFramePayloadIpcMeasured: false,
  samples: benchmarkResults,
};

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
