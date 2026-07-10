import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  FfmpegCliProbeProvider,
  FfmpegCliProbeProviderError,
} from "../electron/adapters/FfmpegCliProbeProvider";
import { runProcess } from "../electron/adapters/process/runProcess";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const toolsAvailable = existsSync(ffmpegPath) && existsSync(ffprobePath);

async function runFfmpeg(args: readonly string[]): Promise<void> {
  await runProcess({
    executablePath: ffmpegPath,
    args,
    timeoutMs: 15_000,
    maxOutputBytes: 10 * 1024 * 1024,
  });
}

test(
  "probes synthetic media across Unicode, spaces, special characters, and invalid inputs",
  { skip: !toolsAvailable },
  async () => {
    const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-ffprobe-integration-"));
    try {
      const videoPath = path.join(tempDirectory, "synthetic 영상 (A) #1.mp4");
      await runFfmpeg([
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=160x120:rate=5",
        "-t",
        "1",
        "-an",
        "-c:v",
        "mpeg4",
        "-q:v",
        "5",
        "-y",
        videoPath,
      ]);

      const provider = new FfmpegCliProbeProvider({ ffprobePath });
      const result = await provider.probe({ filePath: videoPath });
      assert.equal(result.stream.width, 160);
      assert.equal(result.stream.height, 120);
      assert.equal(result.frames.length, 5);
      assert.equal(result.validation.contiguousFrameIndex, true);
      assert.equal(result.validation.completePts, true);

      const audioPath = path.join(tempDirectory, "audio only (한글).m4a");
      await runFfmpeg([
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=1000:sample_rate=44100",
        "-t",
        "0.5",
        "-vn",
        "-c:a",
        "aac",
        "-y",
        audioPath,
      ]);
      await assert.rejects(
        provider.probe({ filePath: audioPath }),
        (error) =>
          error instanceof FfmpegCliProbeProviderError &&
          error.code === "FFPROBE_INVALID_OUTPUT",
      );

      const corruptPath = path.join(tempDirectory, "corrupt sample.mp4");
      await writeFile(corruptPath, Buffer.from("not a media file"));
      await assert.rejects(
        provider.probe({ filePath: corruptPath }),
        (error) =>
          error instanceof FfmpegCliProbeProviderError &&
          error.code === "FFPROBE_EXIT_FAILED",
      );
    } finally {
      await rm(tempDirectory, { recursive: true, force: true });
    }
  },
);
