import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runProcess } from "../electron/adapters/process/runProcess";
import { YuvCacheSession } from "../electron/cache/YuvCacheSession";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");

async function createSynthetic(sourcePath: string, durationSeconds: number): Promise<void> {
  await runProcess({
    executablePath: ffmpegPath,
    args: [
      "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12",
      "-t", String(durationSeconds), "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", sourcePath,
    ],
    timeoutMs: 30_000,
    maxOutputBytes: 1024 * 1024,
  });
}

test("opens first I420 frame before filling a full cache session", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-spike-session-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await createSynthetic(sourcePath, 1);
    const session = await YuvCacheSession.open({ ffmpegPath, ffprobePath }, sourcePath);
    assert.equal(session.metadata().productCache, true);
    assert.equal(session.metadata().colorSource, "candidate-bt601-limited");
    assert.equal(session.metadata().cacheMode, "full");
    assert.equal(session.firstFrame().pixelFormat, "i420");
    session.startBackground(() => undefined);
    await session.waitForBackground();
    assert.equal(session.status().backgroundComplete, true);
    assert.equal((await session.requestFrame(11)).cache, "hit");
    assert.equal(session.status().seekDecodeCount, 0);
    session.close();
    assert.equal(session.status().byteLength, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("uses the existing RGBA segment cache when the YUV policy falls back", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-spike-fallback-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await createSynthetic(sourcePath, 1);
    const session = await YuvCacheSession.open(
      { ffmpegPath, ffprobePath },
      sourcePath,
      undefined,
      { totalMemoryBytes: 1024 ** 3, availableMemoryBytes: 128 * 1024 ** 2 },
    );
    assert.equal(session.metadata().cacheMode, "fallback");
    assert.equal(session.firstFrame().pixelFormat, "i420");
    session.startBackground(() => undefined);
    await session.waitForBackground();
    const first = await session.requestFrame(11);
    const second = await session.requestFrame(11);
    assert.equal(first.pixelFormat, "rgba");
    assert.equal(first.cache, "miss");
    assert.equal(second.cache, "hit");
    assert.equal(session.status().backgroundDecodeCount, 0);
    session.close();
    assert.equal(session.status().byteLength, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("evicts and reloads blocks under a forced LRU budget", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-spike-lru-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await createSynthetic(sourcePath, 10);
    const session = await YuvCacheSession.open(
      { ffmpegPath, ffprobePath },
      sourcePath,
      undefined,
      { cacheBudgetBytes: 600_000 },
    );
    assert.equal(session.metadata().cacheMode, "lru");
    session.startBackground(() => undefined);
    await session.waitForBackground();
    assert.ok(session.status().evictions > 0);
    assert.equal((await session.requestFrame(0)).cache, "miss");
    assert.equal(session.status().seekDecodeCount, 1);
    assert.equal((await session.requestFrame(0)).cache, "hit");
    assert.equal(session.status().seekDecodeCount, 1);
    session.applyMemoryPressure(1024 ** 2);
    assert.equal(session.status().cacheMode, "lru");
    session.close();
    assert.equal(session.status().byteLength, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
