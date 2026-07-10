export type PixelFormat = "rgba";

export type FrameRequest = {
  sessionId: string;
  requestId: number;
  frameIndex: number;
};

export type DecodedFrameDescriptor = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  width: number;
  height: number;
  pixelFormat: PixelFormat;
  byteLength: number;
  fingerprint: string;
};

export type FrameDecodeResult<TPayload> = {
  request: FrameRequest;
  descriptor: DecodedFrameDescriptor;
  payload: TPayload;
  cache: "hit" | "miss";
};

export type FrameDecodeErrorCode =
  | "FRAME_INDEX_OUT_OF_RANGE"
  | "SESSION_CHANGED"
  | "DECODE_CANCELLED"
  | "DECODE_TIMEOUT"
  | "DECODE_PROCESS_FAILED"
  | "DECODE_OUTPUT_INVALID";

export type FrameCacheStatus = {
  startFrameIndex: number | null;
  endFrameIndex: number | null;
  frameCount: number;
  byteLength: number;
  hits: number;
  misses: number;
  direction: "forward" | "reverse" | "balanced";
  budgetBytes: number;
  bytesPerFrame: number;
  frameCapacity: number;
  reusedFrames: number;
  decodedFrames: number;
};

export function validateFrameRequest(request: FrameRequest, frameCount: number): FrameDecodeErrorCode | null {
  if (!Number.isInteger(request.frameIndex) || request.frameIndex < 0 || request.frameIndex >= frameCount) {
    return "FRAME_INDEX_OUT_OF_RANGE";
  }
  return null;
}
