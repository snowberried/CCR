import assert from "node:assert/strict";
import test from "node:test";
import {
  WheelFrameAccumulator,
  displayToInternalFrame,
  internalToDisplayFrame,
  isTextEntryElement,
  navigationTargetForAction,
} from "../src/ui/frameNavigation";
import {
  DEFAULT_FAST_FRAME_STEP,
  FAST_FRAME_STEP_STORAGE_KEY,
  loadFastFrameStep,
  parseFastFrameStep,
  saveFastFrameStep,
} from "../src/ui/fastFrameStep";
import { calculateContainedSize, releaseCanvas } from "../src/ui/viewerGeometry";

test("converts internal zero-based frames to one-based UI frames", () => {
  assert.equal(internalToDisplayFrame(0), 1);
  assert.equal(internalToDisplayFrame(99), 100);
  assert.equal(displayToInternalFrame(1, 100), 0);
  assert.equal(displayToInternalFrame(100, 100), 99);
  assert.equal(displayToInternalFrame(999, 100), 99);
});

test("maps configured navigation actions with fast-step boundary clamping", () => {
  assert.equal(navigationTargetForAction("nextFrame", 10, 100, 20), 11);
  assert.equal(navigationTargetForAction("previousFrame", 30, 100, 20), 29);
  assert.equal(navigationTargetForAction("fastNextFrame", 10, 100, 2), 12);
  assert.equal(navigationTargetForAction("fastNextFrame", 10, 100, 20), 30);
  assert.equal(navigationTargetForAction("fastPreviousFrame", 30, 100, 20), 10);
  assert.equal(navigationTargetForAction("fastNextFrame", 10, 100, 37), 47);
  assert.equal(navigationTargetForAction("fastNextFrame", 98, 100, 50), 99);
  assert.equal(navigationTargetForAction("fastPreviousFrame", 1, 100, 50), 0);
  assert.equal(navigationTargetForAction("firstFrame", 10, 100), 0);
  assert.equal(navigationTargetForAction("lastFrame", 10, 100), 99);
  assert.equal(navigationTargetForAction("openVideo", 10, 100, 20), null);
  assert.equal(isTextEntryElement({ tagName: "input" } as unknown as EventTarget), true);
  assert.equal(isTextEntryElement({ tagName: "select" } as unknown as EventTarget), true);
  assert.equal(isTextEntryElement({ tagName: "div" } as unknown as EventTarget), false);
});

test("validates and persists fast frame step preferences", () => {
  assert.equal(parseFastFrameStep(2), 2);
  assert.equal(parseFastFrameStep("999"), 999);
  assert.equal(parseFastFrameStep(""), null);
  assert.equal(parseFastFrameStep(1), null);
  assert.equal(parseFastFrameStep(1000), null);
  assert.equal(parseFastFrameStep(2.5), null);

  const values = new Map<string, string>();
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value); },
  };
  assert.equal(loadFastFrameStep(storage), DEFAULT_FAST_FRAME_STEP);
  assert.equal(saveFastFrameStep(storage, 37), true);
  assert.equal(values.get(FAST_FRAME_STEP_STORAGE_KEY), "37");
  assert.equal(loadFastFrameStep(storage), 37);
  values.set(FAST_FRAME_STEP_STORAGE_KEY, "invalid");
  assert.equal(loadFastFrameStep(storage), DEFAULT_FAST_FRAME_STEP);
  assert.equal(saveFastFrameStep(storage, 1000), false);
});

test("stabilizes wheel notches and trackpad deltas", () => {
  const wheel = new WheelFrameAccumulator(50);
  assert.equal(wheel.consume(100, 0), 1);
  assert.equal(wheel.consume(-100, 0), -1);
  assert.equal(wheel.consume(15, 0), 0);
  assert.equal(wheel.consume(20, 0), 0);
  assert.equal(wheel.consume(15, 0), 1);
  assert.equal(wheel.consume(-4, 1), -1);
});

test("contains portrait and landscape content without distortion", () => {
  const portrait = calculateContainedSize({ width: 406, height: 720 }, { width: 1000, height: 600 });
  assert.ok(Math.abs(portrait.width - 338.3333333333333) < 0.000001);
  assert.equal(portrait.height, 600);
  assert.deepEqual(calculateContainedSize({ width: 1920, height: 1080 }, { width: 600, height: 1000 }), {
    width: 600,
    height: 337.5,
  });
});

test("releases canvas backing memory", () => {
  let cleared = false;
  const canvas = {
    width: 406,
    height: 720,
    getContext: () => ({ clearRect: () => { cleared = true; } }),
  };
  releaseCanvas(canvas);
  assert.equal(cleared, true);
  assert.equal(canvas.width, 0);
  assert.equal(canvas.height, 0);
});
