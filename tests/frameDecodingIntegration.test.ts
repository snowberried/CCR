import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider";
import { FfmpegRawFrameDecoder, RawFrameDecodeError } from "../electron/adapters/FfmpegRawFrameDecoder";
import { FfmpegSegmentFrameProvider, FrameProviderError } from "../electron/adapters/FfmpegSegmentFrameProvider";
import { runProcess } from "../electron/adapters/process/runProcess";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const toolsAvailable = existsSync(ffmpegPath) && existsSync(ffprobePath);

async function generate(args: readonly string[]): Promise<void> {
  await runProcess({
    executablePath: ffmpegPath,
    args,
    timeoutMs: 30_000,
    maxOutputBytes: 10 * 1024 * 1024,
  });
}

test(
  "decodes presentation-order RGBA frames and maintains an exact bounded segment cache",
  { skip: !toolsAvailable, timeout: 60_000 },
  async () => {
    const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-frame-decode-"));
    try {
      const h264Path = path.join(tempDirectory, "세로 H264 sample (A).mp4");
      await generate([
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=120x160:rate=12",
        "-t", "5", "-an", "-c:v", "libopenh264", "-g", "12", "-pix_fmt", "yuv420p",
        "-y", h264Path,
      ]);

      const probeProvider = new FfmpegCliProbeProvider({ ffprobePath });
      const probe = await probeProvider.probe({ filePath: h264Path });
      const decoder = new FfmpegRawFrameDecoder({
        ffmpegPath,
        sourcePath: h264Path,
        frames: probe.frames,
        width: probe.stream.width,
        height: probe.stream.height,
        timeoutMs: 30_000,
      });

      const full = await decoder.decodeRange(0, probe.frames.length, { retainPixels: false });
      assert.equal(full.descriptors.length, probe.frames.length);
      assert.deepEqual(
        full.descriptors.map((frame) => frame.frameIndex),
        probe.frames.map((frame) => frame.frameIndex),
      );

      const middle = await decoder.decodeRange(17, 5, { retainPixels: false });
      assert.deepEqual(
        middle.descriptors.map((frame) => frame.fingerprint),
        full.descriptors.slice(17, 22).map((frame) => frame.fingerprint),
      );
      const last = await decoder.decodeRange(probe.frames.length - 1, 1, { retainPixels: false });
      assert.equal(last.descriptors[0].fingerprint, full.descriptors.at(-1)?.fingerprint);

      const segment = new FfmpegSegmentFrameProvider({
        sessionId: "synthetic-h264",
        frameCount: probe.frames.length,
        decoder,
        backwardFrames: 3,
        forwardFrames: 6,
      });
      const miss = await segment.requestFrame({
        sessionId: "synthetic-h264",
        requestId: 1,
        frameIndex: 17,
      });
      assert.equal(miss.cache, "miss");
      assert.equal(miss.descriptor.fingerprint, full.descriptors[17].fingerprint);

      const previous = await segment.requestFrame({
        sessionId: "synthetic-h264",
        requestId: 2,
        frameIndex: 16,
      });
      assert.equal(previous.cache, "hit");
      assert.equal(previous.descriptor.fingerprint, full.descriptors[16].fingerprint);

      const far = await segment.requestFrame({
        sessionId: "synthetic-h264",
        requestId: 3,
        frameIndex: 40,
      });
      assert.equal(far.cache, "miss");
      assert.equal(far.descriptor.fingerprint, full.descriptors[40].fingerprint);
      assert.ok(segment.getCacheStatus().frameCount <= 10);

      for (let index = 0; index < 100; index += 1) {
        const frameIndex = index % 2 === 0 ? 39 : 40;
        const repeated = await segment.requestFrame({
          sessionId: "synthetic-h264",
          requestId: 4 + index,
          frameIndex,
        });
        assert.equal(repeated.descriptor.fingerprint, full.descriptors[frameIndex].fingerprint);
      }

      const controller = new AbortController();
      controller.abort();
      await assert.rejects(
        decoder.decodeRange(0, probe.frames.length, { signal: controller.signal }),
        (error) => error instanceof RawFrameDecodeError && error.code === "DECODE_CANCELLED",
      );
      await assert.rejects(
        segment.requestFrame({ sessionId: "synthetic-h264", requestId: 200, frameIndex: -1 }),
        (error) => error instanceof FrameProviderError && error.code === "FRAME_INDEX_OUT_OF_RANGE",
      );
      await segment.closeSession("synthetic-h264");
      await assert.rejects(
        segment.requestFrame({ sessionId: "synthetic-h264", requestId: 201, frameIndex: 0 }),
        (error) => error instanceof FrameProviderError && error.code === "SESSION_CHANGED",
      );

      const bFramePath = path.join(tempDirectory, "B frame sample.mp4");
      await generate([
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10",
        "-t", "2", "-an", "-c:v", "mpeg4", "-bf", "2", "-g", "10", "-y", bFramePath,
      ]);
      const bProbe = await probeProvider.probe({ filePath: bFramePath });
      const bDecoder = new FfmpegRawFrameDecoder({
        ffmpegPath,
        sourcePath: bFramePath,
        frames: bProbe.frames,
        width: bProbe.stream.width,
        height: bProbe.stream.height,
      });
      const bDecoded = await bDecoder.decodeRange(0, bProbe.frames.length, { retainPixels: false });
      assert.equal(bDecoded.descriptors.length, bProbe.frames.length);
      assert.equal(bDecoded.descriptors[0].frameIndex, 0);
      assert.equal(bDecoded.descriptors.at(-1)?.frameIndex, bProbe.frames.length - 1);
    } finally {
      await rm(tempDirectory, { recursive: true, force: true });
    }
  },
);
