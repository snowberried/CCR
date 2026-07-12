import { existsSync } from "node:fs";
import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../electron/adapters/FfmpegRawFrameDecoder.js";
import { FfmpegSegmentFrameProvider } from "../electron/adapters/FfmpegSegmentFrameProvider.js";
import { createFrameCachePolicy } from "../src/domain/frameCachePolicy.js";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase2-directional-cache.json");
const sampleRoot = path.resolve("local-samples");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

async function mediaFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right));
}

type Pattern = { name: string; indexes: number[] };

function percentile(values: number[], fraction: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))] ?? 0;
}

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

if (!existsSync(ffmpegPath) || !existsSync(ffprobePath)) {
  throw new Error("PHASE2_LOCAL_INPUTS_NOT_READY");
}

const sampleFiles = await mediaFiles(sampleRoot);
if (sampleFiles.length < 2) throw new Error(`PHASE2_NEEDS_MULTIPLE_SAMPLES_GOT_${sampleFiles.length}`);
const samples = sampleFiles.map((filePath, index) => ({
  label: `Sample ${String.fromCharCode(65 + index)}`,
  filePath,
}));

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
  const comparison: Record<string, {
    fixed: Awaited<ReturnType<typeof runPattern>>;
    directional: Awaited<ReturnType<typeof runPattern>>;
  }> = {};
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

const summary = {
  sampleCount: results.length,
  directionalForwardPatternP95Ms: percentile(results.map((result) =>
    result.comparison.forward.directional.elapsedMs), 0.95),
  directionalReversePatternP95Ms: percentile(results.map((result) =>
    result.comparison.reverse.directional.elapsedMs), 0.95),
  directionalAlternatingPatternP95Ms: percentile(results.map((result) =>
    result.comparison.alternating.directional.elapsedMs), 0.95),
  maximumPeakCacheBytes: Math.max(...results.flatMap((result) =>
    Object.values(result.comparison).map((pattern) =>
      pattern.directional.peakCacheBytes))),
  totalAccuracyErrors: results.reduce((sampleTotal, result) =>
    sampleTotal + Object.values(result.comparison).reduce((patternTotal, pattern) => {
      return patternTotal + pattern.fixed.accuracyErrors + pattern.directional.accuracyErrors;
    }, 0), 0),
};
const output = { generatedAt: new Date().toISOString(), summary, results };
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
