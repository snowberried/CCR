import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../electron/adapters/FfmpegRawFrameDecoder.js";
import { FfmpegSegmentFrameProvider } from "../electron/adapters/FfmpegSegmentFrameProvider.js";
import { createFrameCachePolicy } from "../src/domain/frameCachePolicy.js";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase2-directional-cache.json");
const samples = ["Sample_A.mp4", "Sample_B.mp4", "Sample_C.mp4"]
  .map((fileName, index) => ({ label: `Sample ${String.fromCharCode(65 + index)}`, filePath: path.resolve("local-samples", fileName) }));

type Pattern = { name: string; indexes: number[] };

function patterns(frameCount: number): Pattern[] {
  const forwardCount = Math.min(1000, frameCount - 1);
  const reverseCount = Math.min(1000, frameCount - 1);
  const center = Math.floor(frameCount / 2);
  return [
    { name: "forward", indexes: Array.from({ length: forwardCount + 1 }, (_, index) => index) },
    { name: "reverse", indexes: Array.from({ length: reverseCount + 1 }, (_, index) => frameCount - 1 - index) },
    { name: "alternating", indexes: Array.from({ length: 1000 }, (_, index) => center + (index % 2 === 0 ? -1 : 1)) },
  ];
}

async function runPattern(
  mode: "fixed" | "directional",
  label: string,
  frameCount: number,
  decoder: FfmpegRawFrameDecoder,
  policy: ReturnType<typeof createFrameCachePolicy>,
  pattern: Pattern,
  baseline: readonly string[],
) {
  const sessionId = `${label}-${mode}-${pattern.name}`;
  const provider = new FfmpegSegmentFrameProvider({
    sessionId,
    frameCount,
    decoder,
    cachePolicy: policy,
    directional: mode === "directional",
    ...(mode === "fixed" ? { backwardFrames: 20, forwardFrames: 40 } : {}),
  });
  let requestId = 0;
  let accuracyErrors = 0;
  let peakCacheBytes = 0;
  const startedAt = performance.now();
  for (const frameIndex of pattern.indexes) {
    const result = await provider.requestFrame({ sessionId, requestId: ++requestId, frameIndex });
    if (result.descriptor.fingerprint !== baseline[frameIndex]) {
      accuracyErrors += 1;
    }
    peakCacheBytes = Math.max(peakCacheBytes, provider.getCacheStatus().byteLength);
  }
  const elapsedMs = performance.now() - startedAt;
  const status = provider.getCacheStatus();
  await provider.closeSession(sessionId);
  return {
    elapsedMs,
    requests: pattern.indexes.length,
    hits: status.hits,
    misses: status.misses,
    hitRate: status.hits / Math.max(1, status.hits + status.misses),
    direction: status.direction,
    reusedFrames: status.reusedFrames,
    decodedFrames: status.decodedFrames,
    peakCacheBytes,
    accuracyErrors,
  };
}

if (!existsSync(ffmpegPath) || !existsSync(ffprobePath) || samples.some((sample) => !existsSync(sample.filePath))) {
  throw new Error("PHASE2_LOCAL_INPUTS_NOT_READY");
}

const probeProvider = new FfmpegCliProbeProvider({ ffprobePath, timeoutMs: 180_000 });
const results = [];
for (const sample of samples) {
  const probe = await probeProvider.probe({ filePath: sample.filePath });
  const decoder = new FfmpegRawFrameDecoder({
    ffmpegPath,
    sourcePath: sample.filePath,
    frames: probe.frames,
    width: probe.stream.width,
    height: probe.stream.height,
    timeoutMs: 180_000,
  });
  const baselineDecoded = await decoder.decodeRange(0, probe.frames.length, { retainPixels: false });
  const baseline = baselineDecoded.descriptors.map((frame) => frame.fingerprint);
  const policy = createFrameCachePolicy(probe.stream.width, probe.stream.height);
  const comparison: Record<string, unknown> = {};
  for (const pattern of patterns(probe.frames.length)) {
    comparison[pattern.name] = {
      fixed: await runPattern("fixed", sample.label, probe.frames.length, decoder, policy, pattern, baseline),
      directional: await runPattern("directional", sample.label, probe.frames.length, decoder, policy, pattern, baseline),
    };
  }
  results.push({
    sample: sample.label,
    media: {
      frameCount: probe.frames.length,
      width: probe.stream.width,
      height: probe.stream.height,
      codec: probe.stream.codecName,
    },
    policy,
    comparison,
  });
}

const output = { generatedAt: new Date().toISOString(), results };
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
