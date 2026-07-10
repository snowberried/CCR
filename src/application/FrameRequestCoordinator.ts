import type { FrameDecodeResult, FrameRequest } from "../domain/frameDecoding.js";
import type { VideoFrameProvider } from "./ports/VideoFrameProvider.js";

export type CoordinatedFrameResult<TPayload> = {
  accepted: boolean;
  result: FrameDecodeResult<TPayload> | null;
};

export class FrameRequestCoordinator<TPayload> {
  private requestId = 0;
  private sessionGeneration = 0;
  private activeController: AbortController | null = null;

  constructor(private readonly provider: VideoFrameProvider<TPayload>) {}

  beginSession(): void {
    this.sessionGeneration += 1;
    this.activeController?.abort();
    this.activeController = null;
  }

  async request(sessionId: string, frameIndex: number): Promise<CoordinatedFrameResult<TPayload>> {
    this.activeController?.abort();
    const controller = new AbortController();
    this.activeController = controller;
    const generation = this.sessionGeneration;
    const request: FrameRequest = {
      sessionId,
      requestId: ++this.requestId,
      frameIndex,
    };

    const result = await this.provider.requestFrame(request, controller.signal);
    const accepted = generation === this.sessionGeneration && request.requestId === this.requestId;
    return { accepted, result: accepted ? result : null };
  }

  cancel(): void {
    this.requestId += 1;
    this.activeController?.abort();
    this.activeController = null;
  }
}
