import assert from "node:assert/strict";
import test from "node:test";
import { FrameRequestCoordinator } from "../src/application/FrameRequestCoordinator";
import type { VideoFrameProvider } from "../src/application/ports/VideoFrameProvider";
import {
  validateFrameRequest,
  type FrameCacheStatus,
  type FrameDecodeResult,
  type FrameRequest,
} from "../src/domain/frameDecoding";

test("validates first, last, and invalid frame request boundaries", () => {
  assert.equal(
    validateFrameRequest({ sessionId: "s", requestId: 1, frameIndex: 0 }, 10),
    null,
  );
  assert.equal(
    validateFrameRequest({ sessionId: "s", requestId: 2, frameIndex: 9 }, 10),
    null,
  );
  assert.equal(
    validateFrameRequest({ sessionId: "s", requestId: 3, frameIndex: 10 }, 10),
    "FRAME_INDEX_OUT_OF_RANGE",
  );
  assert.equal(
    validateFrameRequest({ sessionId: "s", requestId: 4, frameIndex: -1 }, 10),
    "FRAME_INDEX_OUT_OF_RANGE",
  );
});

test("coalesces requests and rejects stale results", async () => {
  const emptyStatus: FrameCacheStatus = {
    startFrameIndex: null,
    endFrameIndex: null,
    frameCount: 0,
    byteLength: 0,
    hits: 0,
    misses: 0,
    direction: "forward",
    budgetBytes: 1024,
    bytesPerFrame: 4,
    frameCapacity: 10,
    reusedFrames: 0,
    decodedFrames: 0,
  };
  const provider: VideoFrameProvider<number> = {
    async requestFrame(request: FrameRequest): Promise<FrameDecodeResult<number>> {
      await new Promise((resolve) => setTimeout(resolve, request.frameIndex === 1 ? 30 : 5));
      return {
        request,
        descriptor: {
          frameIndex: request.frameIndex,
          pts: String(request.frameIndex),
          ptsSeconds: request.frameIndex / 10,
          width: 1,
          height: 1,
          pixelFormat: "rgba",
          byteLength: 4,
          fingerprint: String(request.frameIndex),
        },
        payload: request.frameIndex,
        cache: "miss",
      };
    },
    getCacheStatus: () => emptyStatus,
    closeSession: async () => {},
  };
  const coordinator = new FrameRequestCoordinator(provider);

  const first = coordinator.request("session", 1);
  const second = coordinator.request("session", 2);

  const secondResult = await second;
  assert.equal(secondResult.accepted, true);
  assert.equal(secondResult.result?.payload, 2);
  const firstResult = await first;
  assert.equal(firstResult.accepted, false);
  assert.equal(firstResult.result, null);
});

test("accepts a new request after cancellation", async () => {
  const status: FrameCacheStatus = {
    startFrameIndex: null,
    endFrameIndex: null,
    frameCount: 0,
    byteLength: 0,
    hits: 0,
    misses: 0,
    direction: "forward",
    budgetBytes: 4,
    bytesPerFrame: 4,
    frameCapacity: 1,
    reusedFrames: 0,
    decodedFrames: 0,
  };
  const provider: VideoFrameProvider<number> = {
    async requestFrame(request) {
      return {
        request,
        descriptor: {
          frameIndex: request.frameIndex,
          pts: String(request.frameIndex),
          ptsSeconds: request.frameIndex,
          width: 1,
          height: 1,
          pixelFormat: "rgba",
          byteLength: 4,
          fingerprint: String(request.frameIndex),
        },
        payload: request.frameIndex,
        cache: "miss",
      };
    },
    getCacheStatus: () => status,
    closeSession: async () => {},
  };
  const coordinator = new FrameRequestCoordinator(provider);
  coordinator.cancel();
  const result = await coordinator.request("session", 4);
  assert.equal(result.accepted, true);
  assert.equal(result.result?.payload, 4);
});
