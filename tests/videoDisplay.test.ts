import assert from "node:assert/strict";
import test from "node:test";
import {
  VIDEO_DISPLAY_LIMITS,
  applyLevelWidthDrag,
  beginDisplayDrag,
  clampVideoDisplay,
  mapDisplayLuminance,
  moveDisplayDrag,
  originalVideoDisplay,
  resetVideoDisplay,
  temporaryOriginalDisplay,
  toggleVideoDisplayInvert,
  updateVideoDisplay,
  videoDisplayEqual,
} from "../src/domain/videoDisplay";
import { applyVideoDisplayToRgba } from "../src/domain/videoDisplayReference";

test("creates the documented Original display state", () => {
  assert.deepEqual(originalVideoDisplay(), {
    presetId: "original", level: 0.5, width: 1, gamma: 1, invert: false, sharpAmount: 0, revision: 0,
  });
});

test("clamps every display parameter", () => {
  const clamped = clampVideoDisplay({ ...originalVideoDisplay(), level: -1, width: 0, gamma: 8, sharpAmount: 2 });
  assert.equal(clamped.level, VIDEO_DISPLAY_LIMITS.level.min);
  assert.equal(clamped.width, VIDEO_DISPLAY_LIMITS.width.min);
  assert.equal(clamped.gamma, VIDEO_DISPLAY_LIMITS.gamma.max);
  assert.equal(clamped.sharpAmount, VIDEO_DISPLAY_LIMITS.sharpAmount.max);
});

test("maps Level/Width, brightening gamma, and inverse consistently", () => {
  assert.equal(mapDisplayLuminance(0, originalVideoDisplay()), 0);
  assert.equal(mapDisplayLuminance(0.5, originalVideoDisplay()), 0.5);
  assert.equal(mapDisplayLuminance(1, originalVideoDisplay()), 1);
  const bright = updateVideoDisplay(originalVideoDisplay(), { gamma: 2 });
  assert.ok(mapDisplayLuminance(0.25, bright) > 0.25);
  assert.equal(mapDisplayLuminance(0.25, toggleVideoDisplayInvert(originalVideoDisplay())), 0.75);
});

test("marks manual adjustments Custom and resets to Original", () => {
  const adjusted = updateVideoDisplay(originalVideoDisplay(), { width: 0.8 });
  assert.equal(adjusted.presetId, "custom");
  assert.deepEqual(resetVideoDisplay(adjusted), {
    presetId: "original", level: 0.5, width: 1, gamma: 1, invert: false, sharpAmount: 0, revision: 2,
  });
});

test("temporary Original comparison preserves the stored state", () => {
  const adjusted = updateVideoDisplay(originalVideoDisplay(), { level: 0.62, width: 0.65, sharpAmount: 0.25 });
  assert.equal(temporaryOriginalDisplay(adjusted, true).presetId, "original");
  assert.equal(temporaryOriginalDisplay(adjusted, false), adjusted);
  assert.equal(adjusted.presetId, "custom");
  assert.equal(videoDisplayEqual(adjusted, temporaryOriginalDisplay(adjusted, true)), false);
});

test("right drag maps horizontal Width and vertical Level from its start state", () => {
  const start = originalVideoDisplay();
  const direct = applyLevelWidthDrag(start, { x: 100, y: -50 });
  assert.equal(direct.width, 1.3);
  assert.equal(direct.level, 0.6);
  const gesture = beginDisplayDrag(7, 10, 20, start);
  assert.deepEqual(moveDisplayDrag(gesture, 8, 110, -30), null);
  assert.deepEqual(moveDisplayDrag(gesture, 7, 110, -30), direct);
});

test("RGBA reference keeps Original bytes exact and preserves alpha", () => {
  const source = new Uint8Array([20, 40, 80, 17, 180, 120, 60, 99]);
  assert.deepEqual(applyVideoDisplayToRgba(source, 2, 1, originalVideoDisplay()), new Uint8ClampedArray(source));
  const adjusted = applyVideoDisplayToRgba(source, 2, 1, updateVideoDisplay(originalVideoDisplay(), { width: 0.32, sharpAmount: 0.2 }));
  assert.equal(adjusted[3], 17);
  assert.equal(adjusted[7], 99);
});

test("sharp amount is bounded and does not alter a flat field", () => {
  const flat = new Uint8Array(3 * 3 * 4).fill(128);
  for (let index = 3; index < flat.length; index += 4) flat[index] = 255;
  const state = updateVideoDisplay(originalVideoDisplay(), { sharpAmount: 5 });
  assert.equal(state.sharpAmount, 1);
  const output = applyVideoDisplayToRgba(flat, 3, 3, state);
  assert.equal(output[4 * 4], 128);
});

test("synthetic grayscale, colored overlay, and edge patterns stay bounded", () => {
  const ramp = new Uint8Array([0, 0, 0, 255, 128, 128, 128, 255, 255, 255, 255, 255]);
  const inverse = applyVideoDisplayToRgba(ramp, 3, 1, toggleVideoDisplayInvert(originalVideoDisplay()));
  assert.deepEqual([...inverse.filter((_, index) => index % 4 === 0)], [255, 127, 0]);

  const color = new Uint8Array([220, 40, 40, 255]);
  const adjustedColor = applyVideoDisplayToRgba(color, 1, 1, updateVideoDisplay(originalVideoDisplay(), { level: 0.35, width: 1.07, sharpAmount: 1 }));
  assert.ok(Math.max(adjustedColor[0], adjustedColor[1], adjustedColor[2]) - Math.min(adjustedColor[0], adjustedColor[1], adjustedColor[2]) > 100);

  const edge = new Uint8Array([20, 20, 20, 255, 20, 20, 20, 255, 220, 220, 220, 255, 220, 220, 220, 255]);
  const sharp = applyVideoDisplayToRgba(edge, 4, 1, updateVideoDisplay(originalVideoDisplay(), { sharpAmount: 1 }));
  assert.ok([...sharp].every((value) => value >= 0 && value <= 255));
  assert.ok(sharp[4] <= edge[4]);
  assert.ok(sharp[8] >= edge[8]);
});
