import assert from "node:assert/strict";
import test from "node:test";
import { targetFullscreen } from "../src/application/fullscreenPolicy";
import { beginPan, endsPan, fullscreenShortcut, movePan, viewWheelIntent, zoomShortcut } from "../src/domain/viewInteraction";

test("separates Ctrl+wheel zoom from ordinary frame wheel", () => {
  assert.deepEqual(viewWheelIntent({ ctrlKey: false, deltaY: 120, deltaMode: 0 }), { type: "frame" });
  const zoom = viewWheelIntent({ ctrlKey: true, deltaY: -10000, deltaMode: 0 });
  assert.equal(zoom.type, "zoom");
  if (zoom.type === "zoom") assert.ok(zoom.factor < 2);
});

test("suppresses view shortcuts while editing", () => {
  assert.equal(zoomShortcut({ key: "+", editing: true }), 0);
  assert.equal(zoomShortcut({ key: "+", editing: false }), 1);
  assert.equal(zoomShortcut({ key: "-", editing: false }), -1);
  assert.equal(zoomShortcut({ key: "0", editing: false }), "fit");
  assert.equal(fullscreenShortcut({ key: "f", editing: true }), null);
  assert.equal(fullscreenShortcut({ key: "F", editing: false }), "toggle");
});

test("tracks a single pointer pan lifecycle", () => {
  const started = beginPan(7, 100, 200);
  assert.deepEqual(movePan(started, 8, 120, 230).delta, null);
  const moved = movePan(started, 7, 120, 230);
  assert.deepEqual(moved.delta, { x: 20, y: 30 });
  assert.equal(endsPan(moved.gesture, 7), true);
  assert.equal(endsPan(moved.gesture, 8), false);
});

test("maps fullscreen transitions deterministically", () => {
  assert.equal(targetFullscreen(false, "toggle"), true);
  assert.equal(targetFullscreen(true, "toggle"), false);
  assert.equal(targetFullscreen(false, "enter"), true);
  assert.equal(targetFullscreen(true, "exit"), false);
});
