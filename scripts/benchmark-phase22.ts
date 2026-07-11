import { createHash } from "node:crypto";
import { readdir, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { FfmpegQuickProbeProvider } from "../electron/adapters/FfmpegQuickProbeProvider.js";
import { FfmpegYuvDecoder } from "../electron/adapters/FfmpegYuvDecoder.js";
import { YuvSpikeSession } from "../electron/spike22/YuvSpikeSession.js";

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
if (files.length !== 15) throw new Error(`PHASE22_EXPECTED_15_SAMPLES_GOT_${files.length}`);
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
    const firstSession = await YuvSpikeSession.open({ ffmpegPath, ffprobePath }, filePath);
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

  const session = await YuvSpikeSession.open({ ffmpegPath, ffprobePath }, filePath);
  const backgroundStartedAt = performance.now();
  session.startBackground(() => undefined);
  await session.waitForCache();
  const fullCacheMs = performance.now() - backgroundStartedAt;
  await session.waitForBackground();
  const frameCount = session.metadata().frameCount;
  const latencies: number[] = [];
  const checkpoints = Array.from({ length: Math.min(1000, frameCount) }, (_, index) =>
    Math.floor(index * (frameCount - 1) / Math.max(1, Math.min(1000, frameCount) - 1)));
  for (const frameIndex of checkpoints) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    latencies.push(performance.now() - startedAt);
  }
  for (const frameIndex of [...checkpoints].reverse()) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    latencies.push(performance.now() - startedAt);
  }
  const status = session.status();
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
      requests: latencies.length,
      p50Ms: percentile(latencies, 0.5),
      p95Ms: percentile(latencies, 0.95),
      maxMs: Math.max(...latencies),
    },
    cache: status,
    rssBytes: process.memoryUsage().rss,
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
  totalSeekDecodes: results.reduce((total, result) => total + result.cache.seekDecodeCount, 0),
};
const output = { generatedAt: new Date().toISOString(), summary, results };
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
