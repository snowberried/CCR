import os from "node:os";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { createHash } from "node:crypto";
import { createI420Layout, chooseI420BlockFrames } from "../../src/domain/i420.js";
import { createFrameCachePolicy } from "../../src/domain/frameCachePolicy.js";
import { createYuvCachePolicy } from "../../src/domain/yuvCachePolicy.js";
import { selectYuvDisplayPolicy, type YuvDisplayPolicy } from "../../src/domain/yuvDisplayPolicy.js";
import type { FramePoint } from "../../src/domain/frameSequence.js";
import { FfmpegFrameIndexProvider } from "../adapters/FfmpegFrameIndexProvider.js";
import { FfmpegQuickProbeProvider, type QuickVideoProbe } from "../adapters/FfmpegQuickProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../adapters/FfmpegRawFrameDecoder.js";
import { FfmpegYuvDecoder } from "../adapters/FfmpegYuvDecoder.js";
import { FfmpegSegmentFrameProvider } from "../adapters/FfmpegSegmentFrameProvider.js";
import { YuvBlockCache, type YuvCacheBlock } from "../adapters/YuvBlockCache.js";

export type YuvCacheSessionOptions = {
  totalMemoryBytes?: number;
  availableMemoryBytes?: number;
  cacheBudgetBytes?: number;
};

export type CacheColorSpace = {
  fullRange: boolean;
  matrix: "bt709" | "smpte170m";
  primaries: "bt709" | "smpte170m";
  transfer: "bt709" | "smpte170m";
  source: "metadata-bt601-limited" | "candidate-bt601-limited" | "rgba-fallback";
  webglAllowed: boolean;
};

export type CachedFrame = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  width: number;
  height: number;
  pixelFormat: "i420" | "rgba";
  pixels: Buffer;
  layout?: ReturnType<typeof createI420Layout>;
  colorSpace?: CacheColorSpace;
  fingerprint: string;
  cache: "hit" | "miss";
  requestMs: number;
};

function rationalValue(value: string | null): number | null {
  const match = value?.match(/^(-?\d+)\/(-?\d+)$/);
  if (!match || Number(match[2]) === 0) return null;
  return Number(match[1]) / Number(match[2]);
}

function colorSpaceFor(probe: QuickVideoProbe, policy: YuvDisplayPolicy): CacheColorSpace {
  const fullRange = probe.colorRange === "pc" || probe.colorRange === "jpeg";
  const is709 = probe.colorSpace === "bt709" || probe.colorPrimaries === "bt709";
  return {
    fullRange,
    matrix: is709 ? "bt709" : "smpte170m",
    primaries: is709 ? "bt709" : "smpte170m",
    transfer: is709 ? "bt709" : "smpte170m",
    source: policy.mode === "bt601-limited" ? "metadata-bt601-limited" : policy.mode,
    webglAllowed: policy.mode !== "rgba-fallback",
  };
}

export class YuvCacheSession {
  readonly sessionId = randomUUID();
  readonly layout: ReturnType<typeof createI420Layout>;
  readonly blockFrames: number;
  readonly displayPolicy: YuvDisplayPolicy;
  readonly colorSpace: CacheColorSpace;
  readonly cache: YuvBlockCache;
  private readonly controller = new AbortController();
  private readonly decoder: FfmpegYuvDecoder;
  private readonly frameIndexProbe: FfmpegFrameIndexProvider;
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
  private backgroundError: string | null = null;
  private closed = false;
  private cacheMode: "full" | "lru" | "fallback";
  private readonly initialBudgetBytes: number;
  private rgbaProvider: FfmpegSegmentFrameProvider | null = null;
  private rgbaRequestId = 0;

  private constructor(
    private readonly paths: { ffmpegPath: string; ffprobePath: string },
    private readonly sourcePath: string,
    readonly quickProbe: QuickVideoProbe,
    firstFrame: Buffer,
    readonly firstFrameMs: number,
    private readonly options: YuvCacheSessionOptions,
  ) {
    this.layout = createI420Layout(quickProbe.width, quickProbe.height);
    if (firstFrame.byteLength !== this.layout.byteLength) throw new Error("YUV_FIRST_FRAME_SIZE_INVALID");
    this.frameCount = quickProbe.reportedFrameCount ?? 1;
    this.blockFrames = chooseI420BlockFrames(this.layout.byteLength);
    this.displayPolicy = selectYuvDisplayPolicy(quickProbe);
    this.colorSpace = colorSpaceFor(quickProbe, this.displayPolicy);
    const policy = this.createPolicy(this.frameCount);
    this.cacheMode = policy.mode;
    this.initialBudgetBytes = Math.max(
      this.layout.byteLength * this.blockFrames,
      policy.budgetBytes || 72 * 1024 * 1024,
    );
    this.cache = new YuvBlockCache(this.initialBudgetBytes);
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
    this.frameIndexProbe = new FfmpegFrameIndexProvider(paths.ffprobePath);
  }

  static async open(
    paths: { ffmpegPath: string; ffprobePath: string },
    sourcePath: string,
    signal?: AbortSignal,
    options: YuvCacheSessionOptions = {},
  ) {
    const startedAt = performance.now();
    const quickProvider = new FfmpegQuickProbeProvider(paths.ffprobePath);
    const [quickProbe, firstFrame] = await Promise.all([
      quickProvider.probe(sourcePath, signal),
      FfmpegYuvDecoder.decodeFirstRaw(paths.ffmpegPath, sourcePath, signal),
    ]);
    return new YuvCacheSession(paths, sourcePath, quickProbe, firstFrame, performance.now() - startedAt, options);
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
      productCache: true,
      blockFrames: this.blockFrames,
      colorSource: this.colorSpace.source,
      colorReason: this.displayPolicy.reason,
      cacheMode: this.cacheMode,
    };
  }

  firstFrame(): CachedFrame {
    const pixels = this.cache.getFrame(0, this.blockFrames);
    if (!pixels) throw new Error("YUV_FIRST_FRAME_MISSING");
    return this.serializeI420(0, pixels, "hit", this.firstFrameMs);
  }

  startBackground(onMetadata: (metadata: ReturnType<YuvCacheSession["metadata"]>) => void): void {
    if (this.backgroundStarted || this.closed) return;
    this.backgroundStarted = true;
    const runProbe = () => {
      const probeStartedAt = performance.now();
      return this.frameIndexProbe.probe(this.sourcePath, this.controller.signal).then((probe) => {
      if (probe.issueCount > 0) throw new Error("FRAME_INDEX_VALIDATION_FAILED");
      this.frames = probe.frames;
      this.frameCount = probe.frames.length;
      this.analysisReady = true;
      this.fullProbeMs = performance.now() - probeStartedAt;
      return probe;
      });
    };
    if (this.cacheMode === "fallback") {
      this.cachePromise = Promise.resolve();
      this.backgroundPromise = runProbe().then((probe) => {
        this.ensureRgbaProvider(probe.frames.length);
        this.backgroundComplete = true;
        onMetadata(this.metadata());
      });
      void this.backgroundPromise.catch((error) => this.recordBackgroundError(error, onMetadata));
      return;
    }
    let startProbe: (() => void) | null = null;
    const probeStart = new Promise<void>((resolve) => { startProbe = resolve; });
    const probePromise = probeStart.then(runProbe);
    this.backgroundDecodeCount += 1;
    const cacheStartedAt = performance.now();
    const decodePromise = this.decoder.decodeSequential({
      signal: this.controller.signal,
      onBlock: (block) => {
        this.cache.insert(block);
        this.backgroundDecodedFrames += block.frameCount;
        startProbe?.();
        startProbe = null;
      },
    }).then((stats) => {
      this.backgroundDecodedFrames = stats.frameCount;
      this.backgroundComplete = true;
      this.backgroundCacheMs = performance.now() - cacheStartedAt;
    }).finally(() => {
      startProbe?.();
      startProbe = null;
    });
    this.cachePromise = decodePromise;
    this.backgroundPromise = Promise.all([decodePromise, probePromise]).then(([, probe]) => {
      if (this.backgroundDecodedFrames !== probe.frames.length) {
        this.backgroundComplete = false;
      }
      onMetadata(this.metadata());
    });
    void this.backgroundPromise.catch((error) => this.recordBackgroundError(error, onMetadata));
  }

  async waitForBackground(): Promise<void> {
    if (!this.backgroundPromise) throw new Error("YUV_BACKGROUND_NOT_STARTED");
    await this.backgroundPromise;
  }

  async waitForCache(): Promise<void> {
    if (!this.cachePromise) throw new Error("YUV_BACKGROUND_NOT_STARTED");
    await this.cachePromise;
  }

  async requestFrame(frameIndex: number, format: "i420" | "rgba" = "i420"): Promise<CachedFrame> {
    if (this.closed || !Number.isInteger(frameIndex) || frameIndex < 0 || frameIndex >= this.frameCount) {
      throw new Error("FRAME_INDEX_OUT_OF_RANGE");
    }
    const startedAt = performance.now();
    if (format === "rgba" || (this.cacheMode === "fallback" && this.analysisReady)) {
      return this.requestRgba(frameIndex, startedAt);
    }
    let pixels = this.cache.getFrame(frameIndex, this.blockFrames);
    let cache: "hit" | "miss" = "hit";
    if (!pixels) {
      if (!this.analysisReady) throw new Error("FRAME_NOT_READY");
      cache = "miss";
      const blockIndex = Math.floor(frameIndex / this.blockFrames);
      const nextBackgroundBlock = Math.floor(this.backgroundDecodedFrames / this.blockFrames);
      if (
        this.backgroundStarted && !this.backgroundComplete &&
        blockIndex >= nextBackgroundBlock && blockIndex <= nextBackgroundBlock + 1
      ) {
        await this.waitForNearbyBackgroundBlock(blockIndex);
        pixels = this.cache.getFrame(frameIndex, this.blockFrames);
      }
      if (pixels) return this.serializeI420(frameIndex, pixels, cache, performance.now() - startedAt);
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
    const rgbaCache = this.rgbaProvider?.getCacheStatus();
    return {
      startFrameIndex: rgbaCache?.startFrameIndex ?? null,
      endFrameIndex: rgbaCache?.endFrameIndex ?? null,
      frameCount: rgbaCache?.frameCount ?? cache.readyFrameCount,
      byteLength: rgbaCache?.byteLength ?? cache.byteLength,
      hits: rgbaCache?.hits ?? cache.hits,
      misses: rgbaCache?.misses ?? cache.misses,
      direction: rgbaCache?.direction ?? "balanced" as const,
      budgetBytes: rgbaCache?.budgetBytes ?? cache.budgetBytes,
      bytesPerFrame: rgbaCache?.bytesPerFrame ?? this.layout.byteLength,
      frameCapacity: rgbaCache?.frameCapacity ?? Math.floor(cache.budgetBytes / this.layout.byteLength),
      reusedFrames: rgbaCache?.reusedFrames ?? cache.hits,
      decodedFrames: rgbaCache?.decodedFrames ?? this.backgroundDecodedFrames,
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
      backgroundError: this.backgroundError,
      cacheMode: this.cacheMode,
    };
  }

  applyMemoryPressure(availableMemoryBytes: number): void {
    if (!Number.isFinite(availableMemoryBytes) || availableMemoryBytes < 0) {
      throw new RangeError("INVALID_AVAILABLE_MEMORY");
    }
    const minimumBlockBytes = this.layout.byteLength * this.blockFrames;
    const nextBudget = Math.max(
      minimumBlockBytes,
      Math.min(this.initialBudgetBytes, Math.floor(availableMemoryBytes * 0.25)),
    );
    if (nextBudget < this.cache.status().budgetBytes) {
      this.cacheMode = "lru";
      this.cache.setBudget(nextBudget);
    }
  }

  close(): void {
    this.closed = true;
    this.controller.abort();
    if (this.rgbaProvider) void this.rgbaProvider.closeSession(this.sessionId);
    this.rgbaProvider = null;
    this.cache.clear();
  }

  private createPolicy(frameCount: number) {
    if (this.displayPolicy.mode === "rgba-fallback") {
      return { budgetBytes: 0, enabled: false, mode: "fallback" as const };
    }
    if (this.options.cacheBudgetBytes !== undefined) {
      if (!Number.isInteger(this.options.cacheBudgetBytes) || this.options.cacheBudgetBytes <= 0) {
        throw new RangeError("INVALID_YUV_CACHE_BUDGET");
      }
      const estimatedPayloadBytes = this.layout.byteLength * frameCount;
      return {
        budgetBytes: this.options.cacheBudgetBytes,
        enabled: true,
        mode: estimatedPayloadBytes <= this.options.cacheBudgetBytes * 0.8 ? "full" as const : "lru" as const,
      };
    }
    return createYuvCachePolicy({
      totalMemoryBytes: this.options.totalMemoryBytes ?? os.totalmem(),
      availableMemoryBytes: this.options.availableMemoryBytes ?? os.freemem(),
      estimatedPayloadBytes: this.layout.byteLength * frameCount,
      metadataBytes: frameCount * 48,
    });
  }

  private serializeI420(frameIndex: number, pixels: Buffer, cache: "hit" | "miss", requestMs: number): CachedFrame {
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

  private async requestRgba(frameIndex: number, startedAt: number): Promise<CachedFrame> {
    if (!this.analysisReady) throw new Error("FRAME_NOT_READY");
    this.ensureRgbaProvider(this.frames.length);
    const decoded = await this.rgbaProvider!.requestFrame({
      sessionId: this.sessionId,
      requestId: ++this.rgbaRequestId,
      frameIndex,
    });
    return {
      frameIndex,
      pts: decoded.descriptor.pts,
      ptsSeconds: decoded.descriptor.ptsSeconds,
      width: decoded.descriptor.width,
      height: decoded.descriptor.height,
      pixelFormat: "rgba",
      pixels: decoded.payload,
      fingerprint: decoded.descriptor.fingerprint,
      cache: decoded.cache,
      requestMs: performance.now() - startedAt,
    };
  }

  private async waitForNearbyBackgroundBlock(blockIndex: number): Promise<void> {
    while (!this.closed && !this.backgroundComplete && !this.backgroundError && !this.cache.hasBlock(blockIndex)) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  }

  private recordBackgroundError(
    error: unknown,
    onMetadata: (metadata: ReturnType<YuvCacheSession["metadata"]>) => void,
  ): void {
    if (this.closed) return;
    this.backgroundError = error instanceof Error ? error.message : "YUV_BACKGROUND_FAILED";
    onMetadata(this.metadata());
  }

  private ensureRgbaProvider(frameCount: number): void {
    if (this.rgbaProvider) return;
    const decoder = new FfmpegRawFrameDecoder({
      ffmpegPath: this.paths.ffmpegPath,
      sourcePath: this.sourcePath,
      frames: this.frames,
      width: this.quickProbe.width,
      height: this.quickProbe.height,
      timeoutMs: 30_000,
    });
    this.rgbaProvider = new FfmpegSegmentFrameProvider({
      sessionId: this.sessionId,
      frameCount,
      decoder,
      cachePolicy: createFrameCachePolicy(this.quickProbe.width, this.quickProbe.height),
      directional: true,
    });
  }
}
