import type {
  FrameCacheStatus,
  FrameDecodeResult,
  FrameRequest,
} from "../../domain/frameDecoding.js";

export interface VideoFrameProvider<TPayload> {
  requestFrame(request: FrameRequest, signal?: AbortSignal): Promise<FrameDecodeResult<TPayload>>;
  getCacheStatus(): FrameCacheStatus;
  closeSession(sessionId: string): Promise<void>;
}
