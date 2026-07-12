import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession.js";

const minutesArgument = process.argv.find((value) => value.startsWith("--minutes="));
const durationMinutes = Number(minutesArgument?.split("=")[1] ?? 30);
if (!Number.isFinite(durationMinutes) || durationMinutes <= 0) throw new Error("INVALID_SOAK_DURATION");

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-soak.json");
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

function memorySlopeMiBPerMinute(samples: Array<{ elapsedMinutes: number; rssBytes: number }>): number {
  const relevant = samples.slice(Math.floor(samples.length / 2));
  if (relevant.length < 2) return 0;
  const meanX = relevant.reduce((sum, sample) => sum + sample.elapsedMinutes, 0) / relevant.length;
  const meanY = relevant.reduce((sum, sample) => sum + sample.rssBytes, 0) / relevant.length;
  const numerator = relevant.reduce((sum, sample) => sum + (sample.elapsedMinutes - meanX) * (sample.rssBytes - meanY), 0);
  const denominator = relevant.reduce((sum, sample) => sum + (sample.elapsedMinutes - meanX) ** 2, 0);
  return denominator === 0 ? 0 : numerator / denominator / (1024 * 1024);
}

const files = await mediaFiles(root);
if (files.length < 3) throw new Error("PHASE22_SOAK_NEEDS_THREE_SAMPLES");
const startedAt = performance.now();
const deadline = startedAt + durationMinutes * 60_000;
const memorySamples: Array<{ elapsedMinutes: number; rssBytes: number }> = [];
let sessions = 0;
let requests = 0;
let fingerprintErrors = 0;
let frameIndexErrors = 0;
let cachedRedecodes = 0;
let peakRssBytes = process.memoryUsage().rss;
let lastReportedMinute = -1;
let randomState = 0x22c0ffee;

while (performance.now() < deadline) {
  const sampleIndex = sessions % files.length;
  const session = await YuvCacheSession.open({ ffmpegPath, ffprobePath }, files[sampleIndex]);
  try {
    session.startBackground(() => undefined);
    await session.waitForBackground();
    const frameCount = session.metadata().frameCount;
    const seekBefore = session.status().seekDecodeCount;
    for (let index = 0; index < 100; index += 1) {
      randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0;
      const frameIndex = randomState % frameCount;
      const first = await session.requestFrame(frameIndex);
      const second = await session.requestFrame(frameIndex);
      requests += 2;
      if (first.frameIndex !== frameIndex || second.frameIndex !== frameIndex) frameIndexErrors += 1;
      if (first.fingerprint !== second.fingerprint) fingerprintErrors += 1;
    }
    cachedRedecodes += session.status().seekDecodeCount - seekBefore;
  } finally {
    session.close();
    global.gc?.();
  }
  sessions += 1;
  const elapsedMinutes = (performance.now() - startedAt) / 60_000;
  const rssBytes = process.memoryUsage().rss;
  peakRssBytes = Math.max(peakRssBytes, rssBytes);
  memorySamples.push({ elapsedMinutes, rssBytes });
  const wholeMinute = Math.floor(elapsedMinutes);
  if (wholeMinute !== lastReportedMinute) {
    lastReportedMinute = wholeMinute;
    process.stdout.write(`minute ${wholeMinute}: ${sessions} sessions, ${requests} requests\n`);
  }
}

const secondHalfRssSlopeMiBPerMinute = memorySlopeMiBPerMinute(memorySamples);
const result = {
  durationMinutes: (performance.now() - startedAt) / 60_000,
  sampleCount: files.length,
  sessions,
  requests,
  fingerprintErrors,
  frameIndexErrors,
  cachedRedecodes,
  peakRssBytes,
  finalRssBytes: process.memoryUsage().rss,
  secondHalfRssSlopeMiBPerMinute,
  passed: fingerprintErrors === 0
    && frameIndexErrors === 0
    && cachedRedecodes === 0
    && peakRssBytes <= 2 * 1024 ** 3
    && secondHalfRssSlopeMiBPerMinute <= 10,
};
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
if (!result.passed) process.exitCode = 1;
