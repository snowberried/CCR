import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession.js";

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-active-navigation.json");
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

const files = await mediaFiles(root);
if (files.length < 2) throw new Error(`PHASE22_NEEDS_MULTIPLE_SAMPLES_GOT_${files.length}`);

const results = [];
for (let index = 0; index < files.length; index += 1) {
  const sample = `Sample ${String.fromCharCode(65 + index)}`;
  const session = await YuvCacheSession.open({ ffmpegPath, ffprobePath }, files[index]);
  const backgroundStartedAt = performance.now();
  session.startBackground(() => undefined);
  while (!session.status().analysisReady && !session.status().backgroundComplete) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }

  const readyForSeekMs = performance.now() - backgroundStartedAt;
  const beforeSeek = session.status();
  const targetFrame = session.metadata().frameCount - 1;
  const activeStartedAt = performance.now();
  const activeFrame = await session.requestFrame(targetFrame);
  const activeRequestMs = performance.now() - activeStartedAt;
  const afterSeek = session.status();

  await session.waitForBackground();
  const postCacheLatencies = [];
  const seekCountBeforePostCache = session.status().seekDecodeCount;
  const cachedTarget = await session.requestFrame(targetFrame);
  for (const frameIndex of [0, targetFrame, Math.floor(targetFrame / 2), 0]) {
    const startedAt = performance.now();
    await session.requestFrame(frameIndex);
    postCacheLatencies.push(performance.now() - startedAt);
  }
  const finalStatus = session.status();
  results.push({
    sample,
    frameCount: session.metadata().frameCount,
    firstFrameMs: session.firstFrameMs,
    readyForSeekMs,
    backgroundWasCompleteAtSeek: beforeSeek.backgroundComplete,
    backgroundFramesAtSeek: beforeSeek.backgroundDecodedFrames,
    activeRequest: {
      frame: "last",
      cache: activeFrame.cache,
      requestMs: activeRequestMs,
      seekDecodeDelta: afterSeek.seekDecodeCount - beforeSeek.seekDecodeCount,
    },
    fullCacheMs: finalStatus.backgroundCacheMs,
    postCacheMaximumMs: Math.max(...postCacheLatencies),
    activeFingerprintMatchesCache: activeFrame.fingerprint === cachedTarget.fingerprint,
    postCacheSeekDecodeDelta: finalStatus.seekDecodeCount - seekCountBeforePostCache,
    finalStatus,
  });
  session.close();
  global.gc?.();
  process.stdout.write(`${sample} active navigation complete\n`);
}

const summary = {
  sampleCount: results.length,
  activeUncachedSeekCount: results.filter((result) => result.activeRequest.cache === "miss").length,
  maximumActiveRequestMs: Math.max(...results.map((result) => result.activeRequest.requestMs)),
  maximumPostCacheRequestMs: Math.max(...results.map((result) => result.postCacheMaximumMs)),
  totalPostCacheSeekDecodes: results.reduce((total, result) => total + result.postCacheSeekDecodeDelta, 0),
  fingerprintMismatchCount: results.filter((result) => !result.activeFingerprintMatchesCache).length,
};

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify({ summary, results }, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
