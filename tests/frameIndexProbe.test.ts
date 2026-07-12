import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider";
import { FfmpegFrameIndexProvider } from "../electron/adapters/FfmpegFrameIndexProvider";
import { runProcess } from "../electron/adapters/process/runProcess";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");

test("matches the full probe frame index and PTS with a smaller payload", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-frame-index-"));
  const sourcePath = path.join(directory, "synthetic.mp4");
  try {
    await runProcess({
      executablePath: ffmpegPath,
      args: [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12",
        "-t", "1", "-an", "-c:v", "libopenh264", "-g", "4", "-pix_fmt", "yuv420p", "-y", sourcePath,
      ],
      timeoutMs: 30_000,
      maxOutputBytes: 1024 * 1024,
    });
    const full = await new FfmpegCliProbeProvider({ ffprobePath }).probeWithDiagnostics({ filePath: sourcePath });
    const index = await new FfmpegFrameIndexProvider(ffprobePath).probe(sourcePath);
    assert.equal(index.issueCount, 0);
    assert.ok(index.jsonBytes < full.diagnostics.jsonBytes);
    assert.deepEqual(
      index.frames.map((frame) => [frame.frameIndex, frame.pts, frame.ptsSeconds, frame.keyframe]),
      full.result.frames.map((frame) => [frame.frameIndex, frame.pts, frame.ptsSeconds, frame.keyframe]),
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("matches presentation order for B-frame and VFR packet indexes", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-packet-order-"));
  try {
    const cases = [
      {
        name: "b-frame.mp4",
        args: [
          "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-t", "2",
          "-an", "-c:v", "mpeg4", "-bf", "2", "-g", "15",
        ],
      },
      {
        name: "vfr.mp4",
        args: [
          "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-t", "2",
          "-vf", "setpts='if(lt(N,30),N/(30*TB),1/TB+(N-30)/(15*TB))'", "-fps_mode", "vfr",
          "-an", "-c:v", "mpeg4", "-q:v", "4",
        ],
      },
    ];
    for (const item of cases) {
      const sourcePath = path.join(directory, item.name);
      await runProcess({
        executablePath: ffmpegPath,
        args: [...item.args, "-y", sourcePath],
        timeoutMs: 30_000,
        maxOutputBytes: 1024 * 1024,
      });
      const full = await new FfmpegCliProbeProvider({ ffprobePath }).probe({ filePath: sourcePath });
      const index = await new FfmpegFrameIndexProvider(ffprobePath).probe(sourcePath);
      assert.equal(index.issueCount, 0);
      assert.deepEqual(
        index.frames.map((frame) => [frame.pts, frame.ptsSeconds, frame.keyframe]),
        full.frames.map((frame) => [frame.pts, frame.ptsSeconds, frame.keyframe]),
      );
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
