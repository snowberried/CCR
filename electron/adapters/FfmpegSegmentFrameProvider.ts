import type {
  FrameCacheStatus,
  FrameDecodeErrorCode,
  FrameDecodeResult,
  FrameRequest,
} from "../../src/domain/frameDecoding.js";
import { validateFrameRequest } from "../../src/domain/frameDecoding.js";
import type { VideoFrameProvider } from "../../src/application/ports/VideoFrameProvider.js";
import { FfmpegRawFrameDecoder, RawFrameDecodeError } from "./FfmpegRawFrameDecoder.js";

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
  decoder: FfmpegRawFrameDecoder;
  backwardFrames?: number;
  forwardFrames?: number;
};

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
  private readonly backwardFrames: number;
  private readonly forwardFrames: number;
  private hits = 0;
  private misses = 0;
  private closed = false;

  constructor(private readonly options: SegmentFrameProviderOptions) {
    this.backwardFrames = options.backwardFrames ?? 60;
    this.forwardFrames = options.forwardFrames ?? 120;
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
    const startFrameIndex = Math.max(0, request.frameIndex - this.backwardFrames);
    const endFrameIndex = Math.min(
      this.options.frameCount - 1,
      request.frameIndex + this.forwardFrames,
    );

    let decoded;
    try {
      decoded = await this.options.decoder.decodeRange(
        startFrameIndex,
        endFrameIndex - startFrameIndex + 1,
        { signal, retainPixels: true },
      );
    } catch (error) {
      if (error instanceof RawFrameDecodeError) {
        throw new FrameProviderError(mapDecodeError(error));
      }
      throw error;
    }

    if (signal?.aborted || this.closed || request.sessionId !== this.options.sessionId) {
      throw new FrameProviderError(signal?.aborted ? "DECODE_CANCELLED" : "SESSION_CHANGED");
    }

    this.cache.clear();
    decoded.descriptors.forEach((descriptor, index) => {
      this.cache.set(descriptor.frameIndex, {
        descriptor,
        pixels: decoded.pixelBuffers[index],
      });
    });

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
