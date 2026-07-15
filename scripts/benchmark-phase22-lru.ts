import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession.js";

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-lru-benchmark.json");
const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const budgetBytes = 128 * 1024 * 1024;
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

async function waitForPrefetch(session: YuvCacheSession): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (session.status().prefetchInFlight) {
    if (Date.now() >= deadline) throw new Error("LRU_PREFETCH_TIMEOUT");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function mediaFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right));
}

const files = await mediaFiles(root);
if (files.length < 3) throw new Error("PHASE22_LRU_NEEDS_THREE_SAMPLES");
const results = [];
for (let index = 0; index < files.length; index += 1) {
  const session = await YuvCacheSession.open(
    { ffmpegPath, ffprobePath },
    files[index],
    undefined,
    { cacheBudgetBytes: budgetBytes },
  );
  try {
    session.startBackground(() => undefined);
    await session.waitForBackground();
    const afterBackground = session.status();
    const first = await session.requestFrame(0);
    const advanceFrame = Math.min(session.blockFrames, session.metadata().frameCount - 1);
    const advance = await session.requestFrame(advanceFrame);
    await waitForPrefetch(session);
    const beforeBoundary = session.status();
    const boundaryFrame = Math.min(afterBackground.readyFrameCount, session.metadata().frameCount - 1);
    const boundary = await session.requestFrame(boundaryFrame);
    const final = session.status();
    results.push({
      sample: `Sample ${String.fromCharCode(65 + index)}`,
      cacheMode: session.metadata().cacheMode,
      budgetBytes,
      byteLengthAfterBackground: afterBackground.byteLength,
      evictionsAfterBackground: afterBackground.evictions,
      initialFrame: first.cache,
      advanceFrame: advance.cache,
      prefetchDecodeCount: beforeBoundary.prefetchDecodeCount,
      boundaryFrame: boundary.cache,
      boundarySeekDelta: final.seekDecodeCount - beforeBoundary.seekDecodeCount,
      fingerprintPresent: first.fingerprint.length > 0 && boundary.fingerprint.length > 0,
    });
  } finally {
    session.close();
  }
  process.stdout.write(`Sample ${String.fromCharCode(65 + index)} LRU complete\n`);
}

const summary = {
  sampleCount: results.length,
  budgetBytes,
  maximumStoredBytes: Math.max(...results.map((result) => result.byteLengthAfterBackground)),
  backgroundEvictions: results.reduce((sum, result) => sum + result.evictionsAfterBackground, 0),
  initialMissCount: results.filter((result) => result.initialFrame === "miss").length,
  boundaryHitCount: results.filter((result) => result.boundaryFrame === "hit").length,
  boundarySeekDecodes: results.reduce((sum, result) => sum + result.boundarySeekDelta, 0),
  fingerprintErrors: results.filter((result) => !result.fingerprintPresent).length,
};
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify({ summary, results }, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
