import os from "node:os";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { createHash } from "node:crypto";
import { createI420Layout, chooseI420BlockFrames } from "../../src/domain/i420.js";
import { createYuvCachePolicy } from "../../src/domain/yuvCachePolicy.js";
import type { FramePoint } from "../../src/domain/frameSequence.js";
import { FfmpegCliProbeProvider } from "../adapters/FfmpegCliProbeProvider.js";
import { FfmpegQuickProbeProvider, type QuickVideoProbe } from "../adapters/FfmpegQuickProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../adapters/FfmpegRawFrameDecoder.js";
import { FfmpegYuvDecoder } from "../adapters/FfmpegYuvDecoder.js";
import { YuvBlockCache, type YuvCacheBlock } from "../adapters/YuvBlockCache.js";

export type SpikeColorSpace = {
  fullRange: boolean;
  matrix: "bt709" | "smpte170m";
  primaries: "bt709" | "smpte170m";
  transfer: "bt709" | "smpte170m";
  source: "metadata" | "candidate-bt601-limited";
};

export type SpikeFrame = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  width: number;
  height: number;
  pixelFormat: "i420" | "rgba";
  pixels: Buffer;
  layout?: ReturnType<typeof createI420Layout>;
  colorSpace?: SpikeColorSpace;
  fingerprint: string;
  cache: "hit" | "miss";
  requestMs: number;
};

function rationalValue(value: string | null): number | null {
  const match = value?.match(/^(-?\d+)\/(-?\d+)$/);
  if (!match || Number(match[2]) === 0) return null;
  return Number(match[1]) / Number(match[2]);
}

function colorSpaceFor(probe: QuickVideoProbe): SpikeColorSpace {
  const fullRange = probe.colorRange === "pc" || probe.colorRange === "jpeg";
  const is709 = probe.colorSpace === "bt709" || probe.colorPrimaries === "bt709";
  const hasMetadata = Boolean(probe.colorRange || probe.colorSpace || probe.colorPrimaries || probe.colorTransfer);
  return {
    fullRange,
    matrix: is709 ? "bt709" : "smpte170m",
    primaries: is709 ? "bt709" : "smpte170m",
    transfer: is709 ? "bt709" : "smpte170m",
    source: hasMetadata ? "metadata" : "candidate-bt601-limited",
  };
}

export class YuvSpikeSession {
  readonly sessionId = randomUUID();
  readonly layout: ReturnType<typeof createI420Layout>;
  readonly blockFrames: number;
  readonly colorSpace: SpikeColorSpace;
  readonly cache: YuvBlockCache;
  private readonly controller = new AbortController();
  private readonly decoder: FfmpegYuvDecoder;
  private readonly fullProbe: FfmpegCliProbeProvider;
  private frames: readonly FramePoint[] = [];
  private frameCount: number;
  private analysisReady = false;
  private backgroundStarted = false;
  private backgroundPromise: Promise<void> | null = null;
  private cachePromise: Promise<void> | null = null;
  private backgroundComplete = false;
  private backgroundDecodedFrames = 0;
  private backgroundDecodeCount = 0;
  private seekDecodeCount = 0;
  private backgroundCacheMs: number | null = null;
  private fullProbeMs: number | null = null;
  private closed = false;

  private constructor(
    private readonly paths: { ffmpegPath: string; ffprobePath: string },
    private readonly sourcePath: string,
    readonly quickProbe: QuickVideoProbe,
    firstFrame: Buffer,
    readonly firstFrameMs: number,
  ) {
    this.layout = createI420Layout(quickProbe.width, quickProbe.height);
    if (firstFrame.byteLength !== this.layout.byteLength) throw new Error("YUV_FIRST_FRAME_SIZE_INVALID");
    this.frameCount = quickProbe.reportedFrameCount ?? 1;
    this.blockFrames = chooseI420BlockFrames(this.layout.byteLength);
    this.colorSpace = colorSpaceFor(quickProbe);
    const policy = this.createPolicy(this.frameCount);
    this.cache = new YuvBlockCache(policy.budgetBytes || 72 * 1024 * 1024);
    this.cache.insert({
      blockIndex: 0,
      startFrameIndex: 0,
      frameCount: 1,
      frameByteLength: this.layout.byteLength,
      payload: firstFrame,
    });
    this.decoder = new FfmpegYuvDecoder({
      ffmpegPath: paths.ffmpegPath,
      sourcePath,
      width: quickProbe.width,
      height: quickProbe.height,
      blockFrames: this.blockFrames,
      timeoutMs: 180_000,
    });
    this.fullProbe = new FfmpegCliProbeProvider({ ffprobePath: paths.ffprobePath, timeoutMs: 180_000 });
  }

  static async open(paths: { ffmpegPath: string; ffprobePath: string }, sourcePath: string, signal?: AbortSignal) {
    const startedAt = performance.now();
    const quickProvider = new FfmpegQuickProbeProvider(paths.ffprobePath);
    const [quickProbe, firstFrame] = await Promise.all([
      quickProvider.probe(sourcePath, signal),
      FfmpegYuvDecoder.decodeFirstRaw(paths.ffmpegPath, sourcePath, signal),
    ]);
    return new YuvSpikeSession(paths, sourcePath, quickProbe, firstFrame, performance.now() - startedAt);
  }

  metadata() {
    return {
      frameCount: this.frameCount,
      width: this.quickProbe.width,
      height: this.quickProbe.height,
      codecName: this.quickProbe.codecName,
      fps: rationalValue(this.quickProbe.averageFrameRate) ?? rationalValue(this.quickProbe.nominalFrameRate),
      durationSeconds: this.quickProbe.durationSeconds,
      rotationDegrees: this.quickProbe.rotationDegrees,
      probeMs: this.firstFrameMs,
      analysisReady: this.analysisReady,
      spike22: true,
      blockFrames: this.blockFrames,
      colorSource: this.colorSpace.source,
    };
  }

  firstFrame(): SpikeFrame {
    const pixels = this.cache.getFrame(0, this.blockFrames);
    if (!pixels) throw new Error("YUV_FIRST_FRAME_MISSING");
    return this.serializeI420(0, pixels, "hit", this.firstFrameMs);
  }

  startBackground(onMetadata: (metadata: ReturnType<YuvSpikeSession["metadata"]>) => void): void {
    if (this.backgroundStarted || this.closed) return;
    this.backgroundStarted = true;
    const runProbe = () => {
      const probeStartedAt = performance.now();
      return this.fullProbe.probe({ filePath: this.sourcePath, signal: this.controller.signal }).then((probe) => {
      this.frames = probe.frames;
      this.frameCount = probe.frames.length;
      this.analysisReady = true;
      this.fullProbeMs = performance.now() - probeStartedAt;
      onMetadata(this.metadata());
      return probe;
      });
    };
    this.backgroundDecodeCount += 1;
    const cacheStartedAt = performance.now();
    const decodePromise = this.decoder.decodeSequential({
      signal: this.controller.signal,
      onBlock: (block) => {
        this.cache.insert(block);
        this.backgroundDecodedFrames += block.frameCount;
      },
    }).then((stats) => {
      this.backgroundDecodedFrames = stats.frameCount;
      this.backgroundComplete = true;
      this.backgroundCacheMs = performance.now() - cacheStartedAt;
    });
    this.cachePromise = decodePromise;
    this.backgroundPromise = decodePromise.then(runProbe).then((probe) => {
      if (this.backgroundDecodedFrames !== probe.frames.length) {
        this.backgroundComplete = false;
      }
      onMetadata(this.metadata());
    });
  }

  async waitForBackground(): Promise<void> {
    if (!this.backgroundPromise) throw new Error("YUV_BACKGROUND_NOT_STARTED");
    await this.backgroundPromise;
  }

  async waitForCache(): Promise<void> {
    if (!this.cachePromise) throw new Error("YUV_BACKGROUND_NOT_STARTED");
    await this.cachePromise;
  }

  async requestFrame(frameIndex: number, format: "i420" | "rgba" = "i420"): Promise<SpikeFrame> {
    if (this.closed || !Number.isInteger(frameIndex) || frameIndex < 0 || frameIndex >= this.frameCount) {
      throw new Error("FRAME_INDEX_OUT_OF_RANGE");
    }
    const startedAt = performance.now();
    if (format === "rgba") return this.requestRgba(frameIndex, startedAt);
    let pixels = this.cache.getFrame(frameIndex, this.blockFrames);
    let cache: "hit" | "miss" = "hit";
    if (!pixels) {
      if (!this.analysisReady) throw new Error("FRAME_NOT_READY");
      cache = "miss";
      const blockIndex = Math.floor(frameIndex / this.blockFrames);
      const blockStart = blockIndex * this.blockFrames;
      const count = Math.min(this.blockFrames, this.frameCount - blockStart);
      const ptsSeconds = this.frames[blockStart]?.ptsSeconds;
      if (blockStart > 0 && ptsSeconds === null) throw new Error("FRAME_PTS_MISSING");
      await this.cache.getOrLoad(blockIndex, async () => {
        this.seekDecodeCount += 1;
        let loaded: YuvCacheBlock | null = null;
        await this.decoder.decodeSequential({
          startFrameIndex: blockStart,
          startPtsSeconds: blockStart > 0 ? ptsSeconds ?? undefined : undefined,
          frameCount: count,
          signal: this.controller.signal,
          onBlock: (block) => { loaded = block; },
        });
        if (!loaded) throw new Error("YUV_BLOCK_MISSING");
        return loaded;
      });
      pixels = this.cache.getFrame(frameIndex, this.blockFrames);
    }
    if (!pixels) throw new Error("YUV_FRAME_MISSING");
    return this.serializeI420(frameIndex, pixels, cache, performance.now() - startedAt);
  }

  status() {
    const cache = this.cache.status();
    return {
      startFrameIndex: null,
      endFrameIndex: null,
      frameCount: cache.readyFrameCount,
      byteLength: cache.byteLength,
      hits: cache.hits,
      misses: cache.misses,
      direction: "balanced" as const,
      budgetBytes: cache.budgetBytes,
      bytesPerFrame: this.layout.byteLength,
      frameCapacity: Math.floor(cache.budgetBytes / this.layout.byteLength),
      reusedFrames: cache.hits,
      decodedFrames: this.backgroundDecodedFrames,
      blockCount: cache.blockCount,
      readyFrameCount: cache.readyFrameCount,
      evictions: cache.evictions,
      backgroundComplete: this.backgroundComplete,
      backgroundDecodedFrames: this.backgroundDecodedFrames,
      backgroundDecodeCount: this.backgroundDecodeCount,
      seekDecodeCount: this.seekDecodeCount,
      analysisReady: this.analysisReady,
      backgroundCacheMs: this.backgroundCacheMs,
      fullProbeMs: this.fullProbeMs,
    };
  }

  close(): void {
    this.closed = true;
    this.controller.abort();
    this.cache.clear();
  }

  private createPolicy(frameCount: number) {
    return createYuvCachePolicy({
      totalMemoryBytes: os.totalmem(),
      availableMemoryBytes: os.freemem(),
      estimatedPayloadBytes: this.layout.byteLength * frameCount,
      metadataBytes: frameCount * 48,
    });
  }

  private serializeI420(frameIndex: number, pixels: Buffer, cache: "hit" | "miss", requestMs: number): SpikeFrame {
    const frame = this.frames[frameIndex];
    return {
      frameIndex,
      pts: frame?.pts ?? null,
      ptsSeconds: frame?.ptsSeconds ?? null,
      width: this.quickProbe.width,
      height: this.quickProbe.height,
      pixelFormat: "i420",
      pixels,
      layout: this.layout,
      colorSpace: this.colorSpace,
      fingerprint: createHash("sha256").update(pixels).digest("hex"),
      cache,
      requestMs,
    };
  }

  private async requestRgba(frameIndex: number, startedAt: number): Promise<SpikeFrame> {
    if (!this.analysisReady) throw new Error("FRAME_NOT_READY");
    const decoder = new FfmpegRawFrameDecoder({
      ffmpegPath: this.paths.ffmpegPath,
      sourcePath: this.sourcePath,
      frames: this.frames,
      width: this.quickProbe.width,
      height: this.quickProbe.height,
      timeoutMs: 30_000,
    });
    const decoded = await decoder.decodeRange(frameIndex, 1);
    const descriptor = decoded.descriptors[0];
    return {
      frameIndex,
      pts: descriptor.pts,
      ptsSeconds: descriptor.ptsSeconds,
      width: descriptor.width,
      height: descriptor.height,
      pixelFormat: "rgba",
      pixels: decoded.pixelBuffers[0],
      fingerprint: descriptor.fingerprint,
      cache: "miss",
      requestMs: performance.now() - startedAt,
    };
  }
}
