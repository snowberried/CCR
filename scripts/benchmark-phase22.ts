import { createHash } from "node:crypto";
import { readdir, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FfmpegQuickProbeProvider } from "../electron/adapters/FfmpegQuickProbeProvider.js";
import { FfmpegYuvDecoder } from "../electron/adapters/FfmpegYuvDecoder.js";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession.js";

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-cache-benchmark.json");
const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
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

function percentile(values: number[], fraction: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))] ?? 0;
}

async function hashFile(filePath: string): Promise<string> {
  const { readFile } = await import("node:fs/promises");
  return createHash("sha256").update(await readFile(filePath)).digest("hex");
}

const files = await mediaFiles(root);
if (files.length < 2) throw new Error(`PHASE22_NEEDS_MULTIPLE_SAMPLES_GOT_${files.length}`);
const hashes = await Promise.all(files.map(hashFile));
const duplicateGroups = new Map<string, string>();
let duplicateGroup = 1;
for (const hash of new Set(hashes)) {
  if (hashes.filter((candidate) => candidate === hash).length > 1) duplicateGroups.set(hash, `Duplicate Group ${duplicateGroup++}`);
}

const quickProvider = new FfmpegQuickProbeProvider(ffprobePath);
const results = [];
for (let sampleIndex = 0; sampleIndex < files.length; sampleIndex += 1) {
  const filePath = files[sampleIndex];
  const label = `Sample ${String.fromCharCode(65 + sampleIndex)}`;
  const quick = await quickProvider.probe(filePath);
  const firstFrameRuns: number[] = [];
  for (let run = 0; run < 5; run += 1) {
    const firstSession = await YuvCacheSession.open({ ffmpegPath, ffprobePath }, filePath);
    firstFrameRuns.push(firstSession.firstFrameMs);
    firstSession.close();
  }

  const blockComparisons = [];
  for (const blockFrames of [32, 64]) {
    const decoder = new FfmpegYuvDecoder({
      ffmpegPath,
      sourcePath: filePath,
      width: quick.width,
      height: quick.height,
      blockFrames,
      timeoutMs: 180_000,
    });
    let blockCount = 0;
    const stats = await decoder.decodeSequential({ onBlock: () => { blockCount += 1; } });
    blockComparisons.push({ blockFrames, blockCount, elapsedMs: stats.elapsedMs });
  }

  global.gc?.();
  const rssBeforeSession = process.memoryUsage().rss;
  const session = await YuvCacheSession.open({ ffmpegPath, ffprobePath }, filePath);
  const backgroundStartedAt = performance.now();
  session.startBackground(() => undefined);
  await session.waitForCache();
  const fullCacheMs = performance.now() - backgroundStartedAt;
  await session.waitForBackground();
  const frameCount = session.metadata().frameCount;
  const forwardLatencies: number[] = [];
  const reverseLatencies: number[] = [];
  const interestLatencies: number[] = [];
  const homeEndLatencies: number[] = [];
  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    forwardLatencies.push(performance.now() - startedAt);
  }
  for (let frameIndex = frameCount - 1; frameIndex >= 0; frameIndex -= 1) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    reverseLatencies.push(performance.now() - startedAt);
  }
  const interest = Math.floor(frameCount / 2);
  for (let request = 0; request < 1000; request += 1) {
    const delta = request % 41 - 20;
    const frameIndex = Math.max(0, Math.min(frameCount - 1, interest + delta));
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    interestLatencies.push(performance.now() - startedAt);
  }
  for (const frameIndex of [0, frameCount - 1, 0]) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    homeEndLatencies.push(performance.now() - startedAt);
  }
  const status = session.status();
  const rssAfterCache = process.memoryUsage().rss;
  const allLatencies = [...forwardLatencies, ...reverseLatencies, ...interestLatencies, ...homeEndLatencies];
  results.push({
    sample: label,
    duplicate: duplicateGroups.get(hashes[sampleIndex]) ?? "Unique",
    media: {
      durationSeconds: quick.durationSeconds,
      frameCount,
      width: quick.width,
      height: quick.height,
      codec: quick.codecName,
      pixelFormat: quick.pixelFormat,
    },
    firstFrame: {
      runs: firstFrameRuns.length,
      p50Ms: percentile(firstFrameRuns, 0.5),
      p95Ms: percentile(firstFrameRuns, 0.95),
      maxMs: Math.max(...firstFrameRuns),
    },
    blockComparisons,
    fullCacheMs,
    cachedNavigation: {
      requests: allLatencies.length,
      p50Ms: percentile(allLatencies, 0.5),
      p95Ms: percentile(allLatencies, 0.95),
      maxMs: Math.max(...allLatencies),
      forwardP95Ms: percentile(forwardLatencies, 0.95),
      reverseP95Ms: percentile(reverseLatencies, 0.95),
      interestP95Ms: percentile(interestLatencies, 0.95),
      homeEndMaxMs: Math.max(...homeEndLatencies),
    },
    cache: status,
    memory: {
      rssBeforeSession,
      rssAfterCache,
      rssGrowthBytes: rssAfterCache - rssBeforeSession,
      rssGrowthBeyondPayloadBytes: rssAfterCache - rssBeforeSession - status.byteLength,
      payloadBytesPerBlockObject: status.blockCount > 0 ? status.byteLength / status.blockCount : 0,
    },
  });
  session.close();
  global.gc?.();
  process.stdout.write(`${label} complete\n`);
}

const summary = {
  sampleCount: results.length,
  firstFrameP95Ms: percentile(results.flatMap((result) => [result.firstFrame.p95Ms]), 0.95),
  fullCacheP95Ms: percentile(results.map((result) => result.fullCacheMs), 0.95),
  cachedNavigationP95Ms: percentile(results.map((result) => result.cachedNavigation.p95Ms), 0.95),
  maxCacheBytes: Math.max(...results.map((result) => result.cache.byteLength)),
  maxRssBytes: Math.max(...results.map((result) => result.memory.rssAfterCache)),
  maxRssGrowthBeyondPayloadBytes: Math.max(...results.map((result) => result.memory.rssGrowthBeyondPayloadBytes)),
  totalSeekDecodes: results.reduce((total, result) => total + result.cache.seekDecodeCount, 0),
};
const output = { generatedAt: new Date().toISOString(), summary, results };
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
