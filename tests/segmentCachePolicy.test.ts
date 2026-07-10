import assert from "node:assert/strict";
import test from "node:test";
import { FfmpegSegmentFrameProvider, type FrameRangeDecoder } from "../electron/adapters/FfmpegSegmentFrameProvider";
import { createFrameCachePolicy } from "../src/domain/frameCachePolicy";

function fakeDecoder(): { decoder: FrameRangeDecoder; calls: Array<[number, number]> } {
  const calls: Array<[number, number]> = [];
  const decoder: FrameRangeDecoder = {
    async decodeRange(startFrameIndex, requestedCount) {
      calls.push([startFrameIndex, requestedCount]);
      const descriptors = Array.from({ length: requestedCount }, (_, offset) => {
        const frameIndex = startFrameIndex + offset;
        return {
          frameIndex,
          pts: String(frameIndex),
          ptsSeconds: frameIndex / 10,
          width: 1,
          height: 1,
          pixelFormat: "rgba" as const,
          byteLength: 4,
          fingerprint: `frame-${frameIndex}`,
        };
      });
      return {
        descriptors,
        pixelBuffers: descriptors.map((frame) => Buffer.from([frame.frameIndex, 0, 0, 255])),
        firstFrameMs: 0,
        elapsedMs: 0,
        peakRssBytes: 0,
        processCount: 1 as const,
      };
    },
  };
  return { decoder, calls };
}

test("reuses overlapping frames, switches direction, and holds the memory cap", async () => {
  const { decoder, calls } = fakeDecoder();
  const policy = createFrameCachePolicy(1, 1, {
    budgetBytes: 28,
    minimumTargetFrames: 3,
    maximumFrames: 7,
  });
  const provider = new FfmpegSegmentFrameProvider({
    sessionId: "directional",
    frameCount: 100,
    decoder,
    cachePolicy: policy,
    directional: true,
  });
  let requestId = 0;
  const request = (frameIndex: number) => provider.requestFrame({
    sessionId: "directional",
    requestId: ++requestId,
    frameIndex,
  });

  await request(0);
  await request(1);
  await request(2);
  await request(3);
  await request(5);
  let status = provider.getCacheStatus();
  assert.equal(status.direction, "forward");
  assert.equal(status.frameCount, 7);
  assert.equal(status.reusedFrames, 2);
  assert.deepEqual(calls, [[0, 5], [5, 5]]);

  await request(4);
  await request(3);
  await request(2);
  status = provider.getCacheStatus();
  assert.equal(status.direction, "reverse");
  assert.ok(status.byteLength <= status.budgetBytes);
  assert.ok(status.frameCount <= status.frameCapacity);

  for (let iteration = 0; iteration < 1000; iteration += 1) {
    const result = await request(iteration % 2 === 0 ? 3 : 4);
    assert.equal(result.descriptor.fingerprint, `frame-${iteration % 2 === 0 ? 3 : 4}`);
  }
  assert.equal(provider.getCacheStatus().direction, "balanced");
});
