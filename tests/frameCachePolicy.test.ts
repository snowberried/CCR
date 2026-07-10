import assert from "node:assert/strict";
import test from "node:test";
import {
  CacheDirectionTracker,
  cacheWindowForDirection,
  createFrameCachePolicy,
} from "../src/domain/frameCachePolicy";

test("calculates a hard memory-budget frame capacity", () => {
  const representative = createFrameCachePolicy(406, 720);
  assert.equal(representative.frameCapacity, 61);
  assert.equal(representative.bytesPerFrame, 406 * 720 * 4);
  assert.ok(representative.frameCapacity * representative.bytesPerFrame <= representative.budgetBytes);

  const fullHd = createFrameCachePolicy(1920, 1080);
  assert.equal(fullHd.frameCapacity, 9);
  assert.ok(fullHd.frameCapacity * fullHd.bytesPerFrame <= fullHd.budgetBytes);
});

test("allocates forward, reverse, and balanced cache windows", () => {
  assert.deepEqual(cacheWindowForDirection(61, "forward"), { backwardFrames: 20, forwardFrames: 40 });
  assert.deepEqual(cacheWindowForDirection(61, "reverse"), { backwardFrames: 40, forwardFrames: 20 });
  assert.deepEqual(cacheWindowForDirection(61, "balanced"), { backwardFrames: 30, forwardFrames: 30 });
});

test("switches direction after three same-direction inputs and balances alternation", () => {
  const tracker = new CacheDirectionTracker(3);
  assert.equal(tracker.observe(10), "forward");
  assert.equal(tracker.observe(11), "balanced");
  assert.equal(tracker.observe(12), "balanced");
  assert.equal(tracker.observe(13), "forward");
  assert.equal(tracker.observe(12), "balanced");
  assert.equal(tracker.observe(13), "balanced");
  assert.equal(tracker.observe(12), "balanced");
  assert.equal(tracker.observe(11), "balanced");
  assert.equal(tracker.observe(10), "reverse");
});
