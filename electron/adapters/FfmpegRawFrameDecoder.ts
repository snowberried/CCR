import { createHash } from "node:crypto";
import { stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import type { DecodedFrameDescriptor } from "../../src/domain/frameDecoding.js";
import type { FramePoint } from "../../src/domain/frameSequence.js";

export type RawFrameDecodeErrorCode =
  | "DECODER_NOT_FOUND"
  | "SOURCE_NOT_FOUND"
  | "FRAME_INDEX_OUT_OF_RANGE"
  | "FRAME_PTS_MISSING"
  | "DECODE_CANCELLED"
  | "DECODE_TIMEOUT"
  | "DECODE_PROCESS_FAILED"
  | "DECODE_OUTPUT_INVALID";

export class RawFrameDecodeError extends Error {
  constructor(
    public readonly code: RawFrameDecodeErrorCode,
    public readonly exitCode: number | null = null,
  ) {
    super(code);
    this.name = "RawFrameDecodeError";
  }
}

export type RawFrameDecoderOptions = {
  ffmpegPath: string;
  sourcePath: string;
  frames: readonly FramePoint[];
  width: number;
  height: number;
  timeoutMs?: number;
};

export type DecodeRangeOptions = {
  signal?: AbortSignal;
  retainPixels?: boolean;
};

export type RawFrameRangeResult = {
  descriptors: readonly DecodedFrameDescriptor[];
  pixelBuffers: readonly Buffer[];
  firstFrameMs: number | null;
  elapsedMs: number;
  peakRssBytes: number;
  processCount: 1;
};

async function assertFile(filePath: string, code: RawFrameDecodeErrorCode): Promise<void> {
  try {
    const fileStat = await stat(filePath);
    if (!fileStat.isFile()) {
      throw new RawFrameDecodeError(code);
    }
  } catch (error) {
    if (error instanceof RawFrameDecodeError) {
      throw error;
    }
    throw new RawFrameDecodeError(code);
  }
}

export class FfmpegRawFrameDecoder {
  private readonly frameByteLength: number;
  private readonly timeoutMs: number;

  constructor(private readonly options: RawFrameDecoderOptions) {
    this.frameByteLength = options.width * options.height * 4;
    this.timeoutMs = options.timeoutMs ?? 30_000;
  }

  async decodeRange(
    startFrameIndex: number,
    requestedCount: number,
    decodeOptions: DecodeRangeOptions = {},
  ): Promise<RawFrameRangeResult> {
    await assertFile(this.options.ffmpegPath, "DECODER_NOT_FOUND");
    await assertFile(this.options.sourcePath, "SOURCE_NOT_FOUND");

    if (
      !Number.isInteger(startFrameIndex) ||
      !Number.isInteger(requestedCount) ||
      requestedCount <= 0 ||
      startFrameIndex < 0 ||
      startFrameIndex >= this.options.frames.length
    ) {
      throw new RawFrameDecodeError("FRAME_INDEX_OUT_OF_RANGE");
    }

    const frameCount = Math.min(requestedCount, this.options.frames.length - startFrameIndex);
    const startFrame = this.options.frames[startFrameIndex];
    if (startFrameIndex > 0 && startFrame.ptsSeconds === null) {
      throw new RawFrameDecodeError("FRAME_PTS_MISSING");
    }

    if (decodeOptions.signal?.aborted) {
      throw new RawFrameDecodeError("DECODE_CANCELLED");
    }

    const args = ["-v", "error"];
    if (startFrameIndex > 0) {
      args.push("-ss", String(startFrame.ptsSeconds));
    }
    args.push(
      "-noautorotate",
      "-i",
      this.options.sourcePath,
      "-map",
      "0:v:0",
      "-an",
      "-sn",
      "-dn",
      "-fps_mode",
      "passthrough",
      "-frames:v",
      String(frameCount),
      "-pix_fmt",
      "rgba",
      "-f",
      "rawvideo",
      "pipe:1",
    );

    const retainPixels = decodeOptions.retainPixels ?? true;
    const startedAt = performance.now();
    const initialRss = process.memoryUsage().rss;
    let peakRssBytes = initialRss;
    let firstFrameMs: number | null = null;
    let pending: Buffer<ArrayBufferLike> = Buffer.alloc(0);
    let stderrBytes = 0;
    let forcedError: RawFrameDecodeError | null = null;
    const descriptors: DecodedFrameDescriptor[] = [];
    const pixelBuffers: Buffer[] = [];

    return new Promise((resolve, reject) => {
      let settled = false;
      const child = spawn(this.options.ffmpegPath, args, {
        shell: false,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      });

      const cleanup = () => {
        clearTimeout(timeout);
        decodeOptions.signal?.removeEventListener("abort", onAbort);
      };

      const rejectOnce = (error: RawFrameDecodeError) => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };

      const stop = (error: RawFrameDecodeError) => {
        if (forcedError || settled) {
          return;
        }
        forcedError = error;
        child.kill();
      };

      const onAbort = () => stop(new RawFrameDecodeError("DECODE_CANCELLED"));
      decodeOptions.signal?.addEventListener("abort", onAbort, { once: true });
      const timeout = setTimeout(
        () => stop(new RawFrameDecodeError("DECODE_TIMEOUT")),
        this.timeoutMs,
      );

      child.stdout.on("data", (chunk: Buffer) => {
        pending = pending.length === 0 ? chunk : Buffer.concat([pending, chunk]);
        while (pending.length >= this.frameByteLength && descriptors.length < frameCount) {
          const pixels = Buffer.from(pending.subarray(0, this.frameByteLength));
          pending = pending.subarray(this.frameByteLength);
          const frameIndex = startFrameIndex + descriptors.length;
          const frame = this.options.frames[frameIndex];
          descriptors.push({
            frameIndex,
            pts: frame.pts,
            ptsSeconds: frame.ptsSeconds,
            width: this.options.width,
            height: this.options.height,
            pixelFormat: "rgba",
            byteLength: pixels.byteLength,
            fingerprint: createHash("sha256").update(pixels).digest("hex"),
          });
          if (retainPixels) {
            pixelBuffers.push(pixels);
          }
          if (firstFrameMs === null) {
            firstFrameMs = performance.now() - startedAt;
          }
          peakRssBytes = Math.max(peakRssBytes, process.memoryUsage().rss);
        }
      });

      child.stderr.on("data", (chunk: Buffer) => {
        stderrBytes += chunk.byteLength;
        if (stderrBytes > 1024 * 1024) {
          stop(new RawFrameDecodeError("DECODE_OUTPUT_INVALID"));
        }
      });

      child.once("error", () => {
        rejectOnce(forcedError ?? new RawFrameDecodeError("DECODE_PROCESS_FAILED"));
      });

      child.once("close", (exitCode) => {
        if (settled) {
          return;
        }
        if (forcedError) {
          rejectOnce(forcedError);
          return;
        }
        if (exitCode !== 0) {
          rejectOnce(new RawFrameDecodeError("DECODE_PROCESS_FAILED", exitCode));
          return;
        }
        if (descriptors.length !== frameCount || pending.length !== 0) {
          rejectOnce(new RawFrameDecodeError("DECODE_OUTPUT_INVALID"));
          return;
        }

        settled = true;
        cleanup();
        resolve({
          descriptors,
          pixelBuffers,
          firstFrameMs,
          elapsedMs: performance.now() - startedAt,
          peakRssBytes,
          processCount: 1,
        });
      });
    });
  }
}
