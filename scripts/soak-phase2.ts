import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../electron/adapters/FfmpegRawFrameDecoder.js";
import { FfmpegSegmentFrameProvider } from "../electron/adapters/FfmpegSegmentFrameProvider.js";
import { createFrameCachePolicy } from "../src/domain/frameCachePolicy.js";

const minutesArgument = process.argv.find((argument) => argument.startsWith("--minutes="));
const durationMinutes = minutesArgument ? Number(minutesArgument.split("=")[1]) : 20;
if (!Number.isFinite(durationMinutes) || durationMinutes <= 0) {
  throw new Error("INVALID_SOAK_DURATION");
}

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase2-soak.json");
const samples = ["Sample_A.mp4", "Sample_B.mp4", "Sample_C.mp4"]
  .map((fileName, index) => ({ label: `Sample ${String.fromCharCode(65 + index)}`, filePath: path.resolve("local-samples", fileName) }));

if (!existsSync(ffmpegPath) || !existsSync(ffprobePath) || samples.some((sample) => !existsSync(sample.filePath))) {
  throw new Error("PHASE2_LOCAL_INPUTS_NOT_READY");
}

type PreparedSample = typeof samples[number] & {
  probe: Awaited<ReturnType<FfmpegCliProbeProvider["probe"]>>;
};

type MemorySample = {
  elapsedMinutes: number;
  rssBytes: number;
  heapUsedBytes: number;
  externalBytes: number;
  cacheBytes: number;
};

function slopeBytesPerMinute(samplesToMeasure: readonly MemorySample[], key: "rssBytes" | "heapUsedBytes" | "externalBytes"): number {
  if (samplesToMeasure.length < 2) {
    return 0;
  }
  const meanX = samplesToMeasure.reduce((sum, sample) => sum + sample.elapsedMinutes, 0) / samplesToMeasure.length;
  const meanY = samplesToMeasure.reduce((sum, sample) => sum + sample[key], 0) / samplesToMeasure.length;
  let numerator = 0;
  let denominator = 0;
  for (const sample of samplesToMeasure) {
    numerator += (sample.elapsedMinutes - meanX) * (sample[key] - meanY);
    denominator += (sample.elapsedMinutes - meanX) ** 2;
  }
  return denominator === 0 ? 0 : numerator / denominator;
}

const probeProvider = new FfmpegCliProbeProvider({ ffprobePath, timeoutMs: 180_000 });
const prepared: PreparedSample[] = [];
for (const sample of samples) {
  prepared.push({ ...sample, probe: await probeProvider.probe({ filePath: sample.filePath }) });
}

let provider: FfmpegSegmentFrameProvider | null = null;
let sessionId = "";
let requestId = 0;
let currentFrame = 0;
let direction = 1;
let activeSampleIndex = -1;
let switches = 0;
let requests = 0;
let accuracyErrors = 0;
let maximumCacheBytes = 0;
const memorySamples: MemorySample[] = [];

async function switchSample(nextIndex: number) {
  if (provider) {
    await provider.closeSession(sessionId);
  }
  const sample = prepared[nextIndex];
  const policy = createFrameCachePolicy(sample.probe.stream.width, sample.probe.stream.height);
  sessionId = `soak-${nextIndex}-${switches}`;
  provider = new FfmpegSegmentFrameProvider({
    sessionId,
    frameCount: sample.probe.frames.length,
    decoder: new FfmpegRawFrameDecoder({
      ffmpegPath,
      sourcePath: sample.filePath,
      frames: sample.probe.frames,
      width: sample.probe.stream.width,
      height: sample.probe.stream.height,
      timeoutMs: 180_000,
    }),
    cachePolicy: policy,
    directional: true,
  });
  currentFrame = 0;
  direction = 1;
  requestId = 0;
  activeSampleIndex = nextIndex;
  switches += 1;
}

const startedAt = performance.now();
const durationMs = durationMinutes * 60_000;
let nextSwitchMs = 0;
let nextMemorySampleMs = 0;
let nextProgressMs = 0;

try {
  while (performance.now() - startedAt < durationMs) {
    const elapsedMs = performance.now() - startedAt;
    if (!provider || elapsedMs >= nextSwitchMs) {
      await switchSample((activeSampleIndex + 1) % prepared.length);
      nextSwitchMs = elapsedMs + 60_000;
    }
    const currentProvider = provider as FfmpegSegmentFrameProvider | null;
    if (!currentProvider) {
      throw new Error("SOAK_PROVIDER_NOT_READY");
    }
    const sample = prepared[activeSampleIndex];
    if (requests > 0 && requests % 200 === 0) {
      currentFrame = (currentFrame + Math.floor(sample.probe.frames.length / 3)) % sample.probe.frames.length;
    } else {
      currentFrame += direction;
      if (currentFrame >= sample.probe.frames.length - 1 || currentFrame <= 0) {
        currentFrame = Math.max(0, Math.min(sample.probe.frames.length - 1, currentFrame));
        direction *= -1;
      }
    }
    const result = await currentProvider.requestFrame({ sessionId, requestId: ++requestId, frameIndex: currentFrame });
    if (result.descriptor.frameIndex !== currentFrame || result.descriptor.fingerprint.length !== 64) {
      accuracyErrors += 1;
    }
    requests += 1;
    const status = currentProvider.getCacheStatus();
    maximumCacheBytes = Math.max(maximumCacheBytes, status.byteLength);
    if (status.byteLength > status.budgetBytes) {
      throw new Error("CACHE_BUDGET_EXCEEDED");
    }

    if (elapsedMs >= nextMemorySampleMs) {
      (globalThis as typeof globalThis & { gc?: () => void }).gc?.();
      const memory = process.memoryUsage();
      memorySamples.push({
        elapsedMinutes: elapsedMs / 60_000,
        rssBytes: memory.rss,
        heapUsedBytes: memory.heapUsed,
        externalBytes: memory.external,
        cacheBytes: status.byteLength,
      });
      nextMemorySampleMs = elapsedMs + 10_000;
    }
    if (elapsedMs >= nextProgressMs) {
      process.stdout.write(`phase2-soak ${Math.floor(elapsedMs / 60_000)}/${durationMinutes} min, requests=${requests}, switches=${switches}\n`);
      nextProgressMs = elapsedMs + 60_000;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
} finally {
  const closingProvider = provider as FfmpegSegmentFrameProvider | null;
  if (closingProvider) {
    await closingProvider.closeSession(sessionId);
  }
}

(globalThis as typeof globalThis & { gc?: () => void }).gc?.();
const measured = memorySamples.filter((sample) => sample.elapsedMinutes >= Math.min(1, durationMinutes / 4));
const summary = {
  durationMinutes: (performance.now() - startedAt) / 60_000,
  requests,
  switches,
  accuracyErrors,
  maximumCacheBytes,
  memorySampleCount: memorySamples.length,
  rssSlopeBytesPerMinute: slopeBytesPerMinute(measured, "rssBytes"),
  heapSlopeBytesPerMinute: slopeBytesPerMinute(measured, "heapUsedBytes"),
  externalSlopeBytesPerMinute: slopeBytesPerMinute(measured, "externalBytes"),
  firstMeasured: measured[0] ?? null,
  lastMeasured: measured.at(-1) ?? null,
};
const output = { generatedAt: new Date().toISOString(), summary, memorySamples };
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
