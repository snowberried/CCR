import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runProcess } from "../electron/adapters/process/runProcess";
import { YuvSpikeSession } from "../electron/spike22/YuvSpikeSession";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");

test("opens first I420 frame before filling a full cache session", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-spike-session-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await runProcess({
      executablePath: ffmpegPath,
      args: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12", "-t", "1", "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", sourcePath],
      timeoutMs: 30_000,
      maxOutputBytes: 1024 * 1024,
    });
    const session = await YuvSpikeSession.open({ ffmpegPath, ffprobePath }, sourcePath);
    assert.equal(session.firstFrame().pixelFormat, "i420");
    session.startBackground(() => undefined);
    await session.waitForBackground();
    assert.equal(session.status().backgroundComplete, true);
    assert.equal((await session.requestFrame(11)).cache, "hit");
    assert.equal(session.status().seekDecodeCount, 0);
    session.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
