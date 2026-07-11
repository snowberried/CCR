import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { createI420Layout } from "../../src/domain/i420.js";
import type { YuvCacheBlock } from "./YuvBlockCache.js";

export type YuvDecodeStats = {
  frameCount: number;
  elapsedMs: number;
  firstFrameMs: number | null;
};

export type SequentialYuvDecodeOptions = {
  startFrameIndex?: number;
  startPtsSeconds?: number;
  frameCount?: number;
  signal?: AbortSignal;
  onFirstFrame?: (frame: Buffer) => void | Promise<void>;
  onBlock: (block: YuvCacheBlock) => void | Promise<void>;
};

function terminate(child: ReturnType<typeof spawn>): void {
  if (!child.killed) child.kill();
}

export class FfmpegYuvDecoder {
  readonly frameByteLength: number;

  constructor(private readonly options: {
    ffmpegPath: string;
    sourcePath: string;
    width: number;
    height: number;
    blockFrames: number;
    timeoutMs?: number;
  }) {
    this.frameByteLength = createI420Layout(options.width, options.height).byteLength;
  }

  static decodeFirstRaw(ffmpegPath: string, sourcePath: string, signal?: AbortSignal): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const child = spawn(ffmpegPath, [
        "-v", "error", "-noautorotate", "-i", sourcePath, "-map", "0:v:0",
        "-an", "-sn", "-dn", "-frames:v", "1", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1",
      ], { shell: false, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
      const chunks: Buffer[] = [];
      let stderrBytes = 0;
      const onAbort = () => terminate(child);
      signal?.addEventListener("abort", onAbort, { once: true });
      child.stdout.on("data", (chunk: Buffer) => chunks.push(Buffer.from(chunk)));
      child.stderr.on("data", (chunk: Buffer) => { stderrBytes += chunk.byteLength; if (stderrBytes > 1024 * 1024) terminate(child); });
      child.once("error", () => reject(new Error("YUV_FIRST_FRAME_START_FAILED")));
      child.once("close", (code) => {
        signal?.removeEventListener("abort", onAbort);
        if (signal?.aborted) reject(new Error("DECODE_CANCELLED"));
        else if (code !== 0 || stderrBytes > 1024 * 1024) reject(new Error("YUV_FIRST_FRAME_FAILED"));
        else resolve(Buffer.concat(chunks));
      });
    });
  }

  decodeSequential(options: SequentialYuvDecodeOptions): Promise<YuvDecodeStats> {
    const startFrameIndex = options.startFrameIndex ?? 0;
    const args = ["-v", "error"];
    if (options.startPtsSeconds !== undefined) args.push("-ss", String(options.startPtsSeconds));
    args.push("-noautorotate", "-i", this.options.sourcePath, "-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough");
    if (options.frameCount !== undefined) args.push("-frames:v", String(options.frameCount));
    args.push("-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1");

    return new Promise((resolve, reject) => {
      const startedAt = performance.now();
      const child = spawn(this.options.ffmpegPath, args, { shell: false, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
      let slab: Buffer<ArrayBufferLike> = Buffer.allocUnsafe(this.frameByteLength * this.options.blockFrames);
      let slabOffset = 0;
      let decodedFrames = 0;
      let firstFrameMs: number | null = null;
      let stderrBytes = 0;
      let chain = Promise.resolve();
      let settled = false;
      const timeout = setTimeout(() => terminate(child), this.options.timeoutMs ?? 30_000);
      const onAbort = () => terminate(child);
      options.signal?.addEventListener("abort", onAbort, { once: true });

      const emitBlock = (slabFrames: number) => {
        if (slabFrames === 0) return;
        const firstIndex = startFrameIndex + decodedFrames;
        const payload = slabFrames === this.options.blockFrames
          ? slab
          : Buffer.from(slab.subarray(0, slabFrames * this.frameByteLength));
        const block: YuvCacheBlock = {
          blockIndex: Math.floor(firstIndex / this.options.blockFrames),
          startFrameIndex: firstIndex,
          frameCount: slabFrames,
          frameByteLength: this.frameByteLength,
          payload,
        };
        chain = chain.then(() => options.onBlock(block));
        decodedFrames += slabFrames;
        slab = Buffer.allocUnsafe(this.frameByteLength * this.options.blockFrames);
        slabOffset = 0;
      };

      child.stdout.on("data", (chunk: Buffer) => {
        let chunkOffset = 0;
        while (chunkOffset < chunk.byteLength) {
          const copyBytes = Math.min(chunk.byteLength - chunkOffset, slab.byteLength - slabOffset);
          chunk.copy(slab, slabOffset, chunkOffset, chunkOffset + copyBytes);
          slabOffset += copyBytes;
          chunkOffset += copyBytes;
          if (firstFrameMs === null && decodedFrames === 0 && slabOffset >= this.frameByteLength) {
            firstFrameMs = performance.now() - startedAt;
            if (options.onFirstFrame) {
              const firstFrame = Buffer.from(slab.subarray(0, this.frameByteLength));
              chain = chain.then(() => options.onFirstFrame?.(firstFrame));
            }
          }
          if (slabOffset === slab.byteLength) emitBlock(this.options.blockFrames);
        }
      });
      child.stderr.on("data", (chunk: Buffer) => { stderrBytes += chunk.byteLength; if (stderrBytes > 1024 * 1024) terminate(child); });
      child.once("error", () => { settled = true; reject(new Error("YUV_DECODE_START_FAILED")); });
      child.once("close", (code) => {
        if (settled) return;
        clearTimeout(timeout);
        options.signal?.removeEventListener("abort", onAbort);
        const partialFrames = slabOffset / this.frameByteLength;
        if (!Number.isInteger(partialFrames)) {
          reject(new Error("YUV_DECODE_PARTIAL_FRAME"));
          return;
        }
        emitBlock(partialFrames);
        void chain.then(() => {
          if (options.signal?.aborted) reject(new Error("DECODE_CANCELLED"));
          else if (code !== 0 || stderrBytes > 1024 * 1024) reject(new Error("YUV_DECODE_FAILED"));
          else resolve({ frameCount: decodedFrames, elapsedMs: performance.now() - startedAt, firstFrameMs });
        }, reject);
      });
    });
  }
}
