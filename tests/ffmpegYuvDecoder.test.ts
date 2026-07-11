import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { FfmpegYuvDecoder } from "../electron/adapters/FfmpegYuvDecoder";
import type { YuvCacheBlock } from "../electron/adapters/YuvBlockCache";
import { runProcess } from "../electron/adapters/process/runProcess";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");

test("decodes I420 frames into contiguous block slabs", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-yuv-test-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await runProcess({
      executablePath: ffmpegPath,
      args: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=10", "-t", "1", "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", sourcePath],
      timeoutMs: 30_000,
      maxOutputBytes: 1024 * 1024,
    });
    const first = await FfmpegYuvDecoder.decodeFirstRaw(ffmpegPath, sourcePath);
    const decoder = new FfmpegYuvDecoder({ ffmpegPath, sourcePath, width: 64, height: 48, blockFrames: 4 });
    const blocks: YuvCacheBlock[] = [];
    const result = await decoder.decodeSequential({ onBlock: (block) => { blocks.push(block); } });
    assert.equal(first.byteLength, decoder.frameByteLength);
    assert.equal(result.frameCount, 10);
    assert.deepEqual(blocks.map((block) => block.frameCount), [4, 4, 2]);
    assert.equal(blocks.reduce((total, block) => total + block.payload.byteLength, 0), decoder.frameByteLength * 10);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
