import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import {
  FfmpegCliProbeProvider,
  FfmpegCliProbeProviderError,
} from "../electron/adapters/FfmpegCliProbeProvider";
import { ProcessRunError, type ProcessRunner } from "../electron/adapters/process/runProcess";

const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-provider-test-"));
const sourcePath = path.join(tempDirectory, "source.mp4");
await writeFile(sourcePath, "fixture");

after(async () => {
  await rm(tempDirectory, { recursive: true, force: true });
});

const validOutput = JSON.stringify({
  format: { format_name: "mov,mp4" },
  streams: [
    { index: 0, codec_type: "video", codec_name: "h264", width: 406, height: 720 },
    { index: 1, codec_type: "audio", codec_name: "aac" },
  ],
  frames: [
    {
      media_type: "video",
      stream_index: 0,
      key_frame: 1,
      best_effort_timestamp: "0",
      best_effort_timestamp_time: "0",
    },
  ],
});

test("runs ffprobe with fixed array arguments and returns diagnostics", async () => {
  let capturedArgs: readonly string[] = [];
  const runner: ProcessRunner = async (request) => {
    capturedArgs = request.args;
    return { stdout: validOutput, elapsedMs: 12.5 };
  };
  const provider = new FfmpegCliProbeProvider(
    { ffprobePath: process.execPath, timeoutMs: 1_000, maxOutputBytes: 1_000_000 },
    runner,
  );

  const probed = await provider.probeWithDiagnostics({ filePath: sourcePath });

  assert.deepEqual(capturedArgs.slice(0, -1), [
    "-v",
    "error",
    "-print_format",
    "json",
    "-show_format",
    "-show_streams",
    "-show_frames",
  ]);
  assert.equal(capturedArgs.at(-1), sourcePath);
  assert.equal(probed.result.frames.length, 1);
  assert.equal(probed.diagnostics.executionMs, 12.5);
  assert.equal(probed.diagnostics.jsonBytes, Buffer.byteLength(validOutput));
  assert.equal(probed.diagnostics.audioStreamCount, 1);
});

test("maps process exit, timeout, cancellation, and output limit errors", async () => {
  const cases = [
    ["PROCESS_EXIT_FAILED", "FFPROBE_EXIT_FAILED"],
    ["PROCESS_TIMEOUT", "FFPROBE_TIMEOUT"],
    ["PROCESS_CANCELLED", "FFPROBE_CANCELLED"],
    ["PROCESS_OUTPUT_LIMIT", "FFPROBE_OUTPUT_LIMIT"],
  ] as const;

  for (const [processCode, providerCode] of cases) {
    const runner: ProcessRunner = async () => {
      throw new ProcessRunError(processCode, processCode === "PROCESS_EXIT_FAILED" ? 7 : null);
    };
    const provider = new FfmpegCliProbeProvider({ ffprobePath: process.execPath }, runner);
    await assert.rejects(
      provider.probe({ filePath: sourcePath }),
      (error) =>
        error instanceof FfmpegCliProbeProviderError &&
        error.code === providerCode &&
        (providerCode !== "FFPROBE_EXIT_FAILED" || error.exitCode === 7),
    );
  }
});

test("rejects invalid configuration and missing sources without exposing paths", async () => {
  assert.throws(
    () => new FfmpegCliProbeProvider({ ffprobePath: "relative\\ffprobe.exe" }),
    (error) =>
      error instanceof FfmpegCliProbeProviderError && error.code === "FFPROBE_PATH_INVALID",
  );

  const provider = new FfmpegCliProbeProvider({ ffprobePath: process.execPath });
  await assert.rejects(
    provider.probe({ filePath: path.join(tempDirectory, "missing.mp4") }),
    (error) =>
      error instanceof FfmpegCliProbeProviderError &&
      error.code === "SOURCE_NOT_FOUND" &&
      !error.message.includes(tempDirectory),
  );
});
