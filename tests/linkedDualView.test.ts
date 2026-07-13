import assert from "node:assert/strict";
import test from "node:test";
import {
  clonePaneState,
  linkedPaneFramesMatch,
  mapLinkedCrosshair,
  otherPane,
  updatePaneState,
  type PaneState,
  type PaneStates,
} from "../src/domain/linkedDualView";
import { originalVideoDisplay, updateVideoDisplay } from "../src/domain/videoDisplay";
import {
  createViewTransform,
  imageToViewport,
  panByViewportDelta,
  viewportToImage,
  zoomAtViewportPoint,
} from "../src/domain/viewTransform";

const imageSize = { width: 406, height: 720 };

function pane(viewportSize = { width: 600, height: 700 }): PaneState {
  return {
    viewTransform: createViewTransform(imageSize, viewportSize),
    display: originalVideoDisplay(),
    tool: "pan",
    comparingOriginal: false,
  };
}

test("updates only the selected pane state", () => {
  const states: PaneStates = { a: pane(), b: pane() };
  const originalB = structuredClone(states.b);
  const nextA = {
    ...states.a,
    viewTransform: zoomAtViewportPoint(states.a.viewTransform!, 2.5, { x: 300, y: 350 }),
    display: updateVideoDisplay(states.a.display, { level: 0.7, gamma: 1.4 }),
    tool: "rectangle" as const,
  };
  const next = updatePaneState(states, "a", nextA);
  assert.deepEqual(next.a, nextA);
  assert.deepEqual(next.b, originalB);
  assert.equal(otherPane("a"), "b");
  assert.equal(otherPane("b"), "a");
});

test("clones single-view state without sharing temporary Original hold", () => {
  const source = { ...pane(), comparingOriginal: true };
  const copy = clonePaneState(source);
  assert.deepEqual(copy.viewTransform, source.viewTransform);
  assert.deepEqual(copy.display, source.display);
  assert.equal(copy.tool, source.tool);
  assert.equal(copy.comparingOriginal, false);
  assert.notEqual(copy, source);
});

test("accepts only matching frame index fingerprint and shared pixel identity", () => {
  for (const frameIndex of [0, 171, 341]) {
    const pixels = new Uint8Array([frameIndex & 255]);
    const a = { frameIndex, fingerprint: `frame-${frameIndex}`, pixels };
    assert.equal(linkedPaneFramesMatch(a, { ...a }), true);
    assert.equal(linkedPaneFramesMatch(a, { ...a, frameIndex: frameIndex + 1 }), false);
    assert.equal(linkedPaneFramesMatch(a, { ...a, fingerprint: "stale" }), false);
    assert.equal(linkedPaneFramesMatch(a, { ...a, pixels: Uint8Array.from(pixels) }), false);
  }
  assert.equal(linkedPaneFramesMatch(null, null), false);
});

test("maps linked crosshair through image space across independent transforms", () => {
  const sourceVariants = [
    createViewTransform(imageSize, { width: 600, height: 700 }),
    zoomAtViewportPoint(createViewTransform(imageSize, { width: 600, height: 700 }), 2.5, { x: 320, y: 330 }),
    panByViewportDelta(
      zoomAtViewportPoint(createViewTransform(imageSize, { width: 900, height: 700 }), 3, { x: 450, y: 350 }),
      { x: -75, y: 40 },
    ),
  ];
  const targetVariants = [
    createViewTransform(imageSize, { width: 600, height: 700 }),
    zoomAtViewportPoint(createViewTransform(imageSize, { width: 500, height: 620 }), 3, { x: 240, y: 300 }),
    panByViewportDelta(
      zoomAtViewportPoint(createViewTransform(imageSize, { width: 800, height: 900 }), 2.2, { x: 400, y: 450 }),
      { x: 60, y: -90 },
    ),
  ];
  const imagePoint = { x: 210.25, y: 361.75 };
  for (const sourceTransform of sourceVariants) {
    for (const targetTransform of targetVariants) {
      const sourceViewportPoint = imageToViewport(sourceTransform, imagePoint);
      const mapped = mapLinkedCrosshair({
        sourceTransform,
        targetTransform,
        sourceViewportPoint,
        framesMatch: true,
        rendererReady: true,
      });
      if (!mapped) continue;
      const roundTrip = viewportToImage(targetTransform, mapped.targetViewportPoint);
      assert.ok(Math.abs(roundTrip.x - imagePoint.x) <= 0.25);
      assert.ok(Math.abs(roundTrip.y - imagePoint.y) <= 0.25);
    }
  }
});

test("keeps the same image-space correspondence at DPR 1, 1.5, and 2", () => {
  const imagePoint = { x: 203.125, y: 360.125 };
  for (const dpr of [1, 1.5, 2]) {
    const sourceTransform = createViewTransform(imageSize, { width: 640, height: 760 });
    const targetTransform = panByViewportDelta(
      zoomAtViewportPoint(createViewTransform(imageSize, { width: 520, height: 760 }), 2.7, { x: 260, y: 380 }),
      { x: -30 * dpr, y: 20 * dpr },
    );
    const mapped = mapLinkedCrosshair({
      sourceTransform,
      targetTransform,
      sourceViewportPoint: imageToViewport(sourceTransform, imagePoint),
      framesMatch: true,
      rendererReady: true,
    });
    assert.ok(mapped);
    const roundTrip = viewportToImage(targetTransform, mapped.targetViewportPoint);
    assert.ok(Math.abs(roundTrip.x - imagePoint.x) <= 0.25);
    assert.ok(Math.abs(roundTrip.y - imagePoint.y) <= 0.25);
  }
});

test("hides crosshair for letterbox, target outside, stale frame, and invalid renderer", () => {
  const sourceTransform = createViewTransform(imageSize, { width: 1000, height: 600 });
  const targetTransform = zoomAtViewportPoint(
    createViewTransform(imageSize, { width: 500, height: 600 }),
    3,
    { x: 250, y: 300 },
  );
  const valid = imageToViewport(sourceTransform, { x: 203, y: 360 });
  assert.equal(mapLinkedCrosshair({ sourceTransform, targetTransform, sourceViewportPoint: { x: 10, y: 10 }, framesMatch: true, rendererReady: true }), null);
  assert.equal(mapLinkedCrosshair({ sourceTransform, targetTransform, sourceViewportPoint: valid, framesMatch: false, rendererReady: true }), null);
  assert.equal(mapLinkedCrosshair({ sourceTransform, targetTransform, sourceViewportPoint: valid, framesMatch: true, rendererReady: false }), null);
  const edge = imageToViewport(sourceTransform, { x: 0, y: 0 });
  assert.equal(mapLinkedCrosshair({ sourceTransform, targetTransform, sourceViewportPoint: edge, framesMatch: true, rendererReady: true }), null);
});
