import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession.js";

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-lru-benchmark.json");
const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const budgetBytes = 128 * 1024 * 1024;
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
    const afterFirst = session.status();
    const second = await session.requestFrame(0);
    const final = session.status();
    results.push({
      sample: `Sample ${String.fromCharCode(65 + index)}`,
      cacheMode: session.metadata().cacheMode,
      budgetBytes,
      byteLengthAfterBackground: afterBackground.byteLength,
      evictionsAfterBackground: afterBackground.evictions,
      firstRevisit: first.cache,
      firstRevisitSeekDelta: afterFirst.seekDecodeCount - afterBackground.seekDecodeCount,
      secondRevisit: second.cache,
      secondRevisitSeekDelta: final.seekDecodeCount - afterFirst.seekDecodeCount,
      fingerprintMatches: first.fingerprint === second.fingerprint,
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
  totalEvictions: results.reduce((sum, result) => sum + result.evictionsAfterBackground, 0),
  firstRevisitMissCount: results.filter((result) => result.firstRevisit === "miss").length,
  secondRevisitHitCount: results.filter((result) => result.secondRevisit === "hit").length,
  fingerprintErrors: results.filter((result) => !result.fingerprintMatches).length,
};
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify({ summary, results }, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
