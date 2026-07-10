import assert from "node:assert/strict";
import test from "node:test";
import {
  WheelFrameAccumulator,
  displayToInternalFrame,
  internalToDisplayFrame,
  isOpenVideoShortcut,
  isTextEntryElement,
  navigationTargetForKey,
} from "../src/ui/frameNavigation";
import { calculateContainedSize, releaseCanvas } from "../src/ui/viewerGeometry";

test("converts internal zero-based frames to one-based UI frames", () => {
  assert.equal(internalToDisplayFrame(0), 1);
  assert.equal(internalToDisplayFrame(99), 100);
  assert.equal(displayToInternalFrame(1, 100), 0);
  assert.equal(displayToInternalFrame(100, 100), 99);
  assert.equal(displayToInternalFrame(999, 100), 99);
});

test("maps arrows, Shift, Home, and End while suppressing text entry", () => {
  assert.equal(isOpenVideoShortcut({ key: "o", shiftKey: false, ctrlKey: true }), true);
  assert.equal(navigationTargetForKey({ key: "ArrowRight", shiftKey: false }, 10, 100, false), 11);
  assert.equal(navigationTargetForKey({ key: "ArrowLeft", shiftKey: true }, 10, 100, false), 5);
  assert.equal(navigationTargetForKey({ key: "Home", shiftKey: false }, 10, 100, false), 0);
  assert.equal(navigationTargetForKey({ key: "End", shiftKey: false }, 10, 100, false), 99);
  assert.equal(navigationTargetForKey({ key: "ArrowRight", shiftKey: false }, 10, 100, true), null);
  assert.equal(isTextEntryElement({ tagName: "input" } as unknown as EventTarget), true);
  assert.equal(isTextEntryElement({ tagName: "div" } as unknown as EventTarget), false);
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
