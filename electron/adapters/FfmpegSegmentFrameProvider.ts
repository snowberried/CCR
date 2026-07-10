import type {
  FrameCacheStatus,
  FrameDecodeErrorCode,
  FrameDecodeResult,
  FrameRequest,
} from "../../src/domain/frameDecoding.js";
import { validateFrameRequest } from "../../src/domain/frameDecoding.js";
import type { VideoFrameProvider } from "../../src/application/ports/VideoFrameProvider.js";
import {
  CacheDirectionTracker,
  cacheWindowForDirection,
  createFrameCachePolicy,
  type FrameCachePolicy,
} from "../../src/domain/frameCachePolicy.js";
import {
  FfmpegRawFrameDecoder,
  RawFrameDecodeError,
  type DecodeRangeOptions,
  type RawFrameRangeResult,
} from "./FfmpegRawFrameDecoder.js";

type CachedFrame = {
  descriptor: Awaited<ReturnType<FfmpegRawFrameDecoder["decodeRange"]>>["descriptors"][number];
  pixels: Buffer;
};

export class FrameProviderError extends Error {
  constructor(public readonly code: FrameDecodeErrorCode) {
    super(code);
    this.name = "FrameProviderError";
  }
}

export type SegmentFrameProviderOptions = {
  sessionId: string;
  frameCount: number;
  decoder: FrameRangeDecoder;
  width?: number;
  height?: number;
  cachePolicy?: FrameCachePolicy;
  directional?: boolean;
  backwardFrames?: number;
  forwardFrames?: number;
};

export type FrameRangeDecoder = {
  decodeRange(
    startFrameIndex: number,
    requestedCount: number,
    options?: DecodeRangeOptions,
  ): Promise<RawFrameRangeResult>;
};

type FrameRange = { start: number; end: number };

function missingRanges(cache: ReadonlyMap<number, CachedFrame>, start: number, end: number): FrameRange[] {
  const ranges: FrameRange[] = [];
  let rangeStart: number | null = null;
  for (let index = start; index <= end; index += 1) {
    if (!cache.has(index) && rangeStart === null) {
      rangeStart = index;
    }
    if (cache.has(index) && rangeStart !== null) {
      ranges.push({ start: rangeStart, end: index - 1 });
      rangeStart = null;
    }
  }
  if (rangeStart !== null) {
    ranges.push({ start: rangeStart, end });
  }
  return ranges;
}

function mapDecodeError(error: RawFrameDecodeError): FrameDecodeErrorCode {
  switch (error.code) {
    case "FRAME_INDEX_OUT_OF_RANGE":
      return "FRAME_INDEX_OUT_OF_RANGE";
    case "DECODE_CANCELLED":
      return "DECODE_CANCELLED";
    case "DECODE_TIMEOUT":
      return "DECODE_TIMEOUT";
    case "DECODE_OUTPUT_INVALID":
    case "FRAME_PTS_MISSING":
      return "DECODE_OUTPUT_INVALID";
    default:
      return "DECODE_PROCESS_FAILED";
  }
}

export class FfmpegSegmentFrameProvider implements VideoFrameProvider<Buffer> {
  private readonly cache = new Map<number, CachedFrame>();
  private readonly policy: FrameCachePolicy;
  private readonly fixedWindow: { backwardFrames: number; forwardFrames: number } | null;
  private readonly directionTracker = new CacheDirectionTracker();
  private readonly directional: boolean;
  private hits = 0;
  private misses = 0;
  private reusedFrames = 0;
  private decodedFrames = 0;
  private closed = false;

  constructor(private readonly options: SegmentFrameProviderOptions) {
    const hasFixedWindow = options.backwardFrames !== undefined || options.forwardFrames !== undefined;
    this.fixedWindow = hasFixedWindow
      ? {
          backwardFrames: options.backwardFrames ?? 0,
          forwardFrames: options.forwardFrames ?? 0,
        }
      : null;
    this.policy = options.cachePolicy ?? createFrameCachePolicy(options.width ?? 406, options.height ?? 720);
    this.directional = options.directional ?? !hasFixedWindow;
  }

  async requestFrame(
    request: FrameRequest,
    signal?: AbortSignal,
  ): Promise<FrameDecodeResult<Buffer>> {
    if (this.closed || request.sessionId !== this.options.sessionId) {
      throw new FrameProviderError("SESSION_CHANGED");
    }
    const requestError = validateFrameRequest(request, this.options.frameCount);
    if (requestError) {
      throw new FrameProviderError(requestError);
    }

    const direction = this.directional
      ? this.directionTracker.observe(request.frameIndex)
      : "forward";
    const cached = this.cache.get(request.frameIndex);
    if (cached) {
      this.hits += 1;
      return {
        request,
        descriptor: cached.descriptor,
        payload: cached.pixels,
        cache: "hit",
      };
    }

    this.misses += 1;
    const window = this.fixedWindow ?? cacheWindowForDirection(this.policy.frameCapacity, direction);
    const startFrameIndex = Math.max(0, request.frameIndex - window.backwardFrames);
    const endFrameIndex = Math.min(
      this.options.frameCount - 1,
      request.frameIndex + window.forwardFrames,
    );

    for (const frameIndex of this.cache.keys()) {
      if (frameIndex < startFrameIndex || frameIndex > endFrameIndex) {
        this.cache.delete(frameIndex);
      }
    }

    const additions = new Map<number, CachedFrame>();
    try {
      for (const range of missingRanges(this.cache, startFrameIndex, endFrameIndex)) {
        const decoded = await this.options.decoder.decodeRange(
          range.start,
          range.end - range.start + 1,
          { signal, retainPixels: true },
        );
        decoded.descriptors.forEach((descriptor, index) => {
          additions.set(descriptor.frameIndex, {
            descriptor,
            pixels: decoded.pixelBuffers[index],
          });
        });
      }
    } catch (error) {
      if (error instanceof RawFrameDecodeError) {
        throw new FrameProviderError(mapDecodeError(error));
      }
      throw error;
    }

    if (signal?.aborted || this.closed || request.sessionId !== this.options.sessionId) {
      throw new FrameProviderError(signal?.aborted ? "DECODE_CANCELLED" : "SESSION_CHANGED");
    }

    const nextCache = new Map<number, CachedFrame>();
    let reused = 0;
    for (let index = startFrameIndex; index <= endFrameIndex; index += 1) {
      const existing = this.cache.get(index);
      const added = additions.get(index);
      if (existing) {
        nextCache.set(index, existing);
        reused += 1;
      } else if (added) {
        nextCache.set(index, added);
      }
    }
    this.cache.clear();
    nextCache.forEach((frame, index) => this.cache.set(index, frame));
    this.reusedFrames += reused;
    this.decodedFrames += additions.size;

    const result = this.cache.get(request.frameIndex);
    if (!result) {
      throw new FrameProviderError("DECODE_OUTPUT_INVALID");
    }
    return {
      request,
      descriptor: result.descriptor,
      payload: result.pixels,
      cache: "miss",
    };
  }

  getCacheStatus(): FrameCacheStatus {
    const indexes = [...this.cache.keys()].sort((left, right) => left - right);
    const byteLength = [...this.cache.values()].reduce(
      (total, frame) => total + frame.pixels.byteLength,
      0,
    );
    return {
      startFrameIndex: indexes[0] ?? null,
      endFrameIndex: indexes.at(-1) ?? null,
      frameCount: indexes.length,
      byteLength,
      hits: this.hits,
      misses: this.misses,
      direction: this.directional ? this.directionTracker.current() : "forward",
      budgetBytes: this.policy.budgetBytes,
      bytesPerFrame: this.policy.bytesPerFrame,
      frameCapacity: this.fixedWindow
        ? this.fixedWindow.backwardFrames + 1 + this.fixedWindow.forwardFrames
        : this.policy.frameCapacity,
      reusedFrames: this.reusedFrames,
      decodedFrames: this.decodedFrames,
    };
  }

  async closeSession(sessionId: string): Promise<void> {
    if (sessionId !== this.options.sessionId) {
      return;
    }
    this.closed = true;
    this.cache.clear();
  }
}
