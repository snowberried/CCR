import assert from "node:assert/strict";
import test from "node:test";
import { validateFrameSequence, type FramePoint } from "../src/domain/frameSequence";

test("accepts contiguous frame indexes with monotonic PTS", () => {
  const frames: FramePoint[] = [
    { frameIndex: 0, pts: "0", ptsSeconds: 0, durationSeconds: 0.04, keyframe: true },
    { frameIndex: 1, pts: "1", ptsSeconds: 0.04, durationSeconds: 0.04, keyframe: false },
    { frameIndex: 2, pts: "2", ptsSeconds: 0.08, durationSeconds: 0.04, keyframe: false },
  ];

  assert.deepEqual(validateFrameSequence(frames), {
    frameCount: 3,
    contiguousFrameIndex: true,
    completePts: true,
    validPts: true,
    monotonicPts: true,
    duplicatePts: false,
    issues: [],
  });
});

test("reports skipped frame indexes without inferring by FPS", () => {
  const frames: FramePoint[] = [
    { frameIndex: 0, pts: "0", ptsSeconds: 0, durationSeconds: null, keyframe: true },
    { frameIndex: 2, pts: "2", ptsSeconds: 0.08, durationSeconds: null, keyframe: false },
  ];

  const validation = validateFrameSequence(frames);

  assert.equal(validation.contiguousFrameIndex, false);
  assert.deepEqual(validation.issues[0], {
    code: "FRAME_INDEX_GAP",
    frameIndex: 2,
    expectedFrameIndex: 1,
  });
});

test("compares duplicate and backward PTS using raw timestamp values", () => {
  const frames: FramePoint[] = [
    { frameIndex: 0, pts: "2", ptsSeconds: 0.08, durationSeconds: null, keyframe: true },
    { frameIndex: 1, pts: "02", ptsSeconds: 0.0800001, durationSeconds: null, keyframe: false },
    { frameIndex: 2, pts: "1", ptsSeconds: 0.04, durationSeconds: null, keyframe: false },
  ];

  const validation = validateFrameSequence(frames);

  assert.equal(validation.contiguousFrameIndex, true);
  assert.equal(validation.duplicatePts, true);
  assert.equal(validation.monotonicPts, false);
});

test("reports missing and invalid PTS without inventing values from FPS", () => {
  const frames: FramePoint[] = [
    { frameIndex: 0, pts: null, ptsSeconds: null, durationSeconds: null, keyframe: true },
    { frameIndex: 1, pts: "invalid", ptsSeconds: 0.04, durationSeconds: null, keyframe: false },
  ];

  const validation = validateFrameSequence(frames);

  assert.equal(validation.completePts, false);
  assert.equal(validation.validPts, false);
  assert.deepEqual(
    validation.issues.map((issue) => issue.code),
    ["PTS_MISSING", "PTS_INVALID"],
  );
});
