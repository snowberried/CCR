import assert from "node:assert/strict";
import test from "node:test";
import {
  actualSizeViewTransform,
  createViewTransform,
  effectiveScale,
  fitScale,
  fitViewTransform,
  imageToViewport,
  panByViewportDelta,
  resizeViewTransform,
  stepViewZoom,
  viewportToImage,
  zoomAtViewportPoint,
} from "../src/domain/viewTransform";

const close = (actual: number, expected: number, tolerance = 1e-9) =>
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);

test("calculates contain fit scale without aspect ratio distortion", () => {
  close(fitScale({ width: 406, height: 720 }, { width: 1000, height: 600 }), 600 / 720);
  close(fitScale({ width: 1920, height: 1080 }, { width: 600, height: 1000 }), 600 / 1920);
});

test("round trips image and viewport coordinates", () => {
  const transform = createViewTransform({ width: 406, height: 720 }, { width: 1000, height: 600 });
  const imagePoint = { x: 123.25, y: 456.75 };
  const roundTrip = viewportToImage(transform, imageToViewport(transform, imagePoint));
  close(roundTrip.x, imagePoint.x);
  close(roundTrip.y, imagePoint.y);
});

test("keeps the cursor image point anchored while zooming", () => {
  const transform = createViewTransform({ width: 1000, height: 1000 }, { width: 800, height: 600 });
  const anchor = { x: 600, y: 200 };
  const before = viewportToImage(transform, anchor);
  const zoomed = zoomAtViewportPoint(transform, 3, anchor);
  const after = viewportToImage(zoomed, anchor);
  close(after.x, before.x);
  close(after.y, before.y);
});

test("clamps zoom and pan while centering undersized axes", () => {
  const transform = createViewTransform({ width: 406, height: 720 }, { width: 1000, height: 600 });
  const zoomed = zoomAtViewportPoint(transform, 100, { x: 500, y: 300 });
  assert.equal(zoomed.zoom, 10);
  const panned = panByViewportDelta(zoomed, { x: 100000, y: -100000 });
  const scale = effectiveScale(panned);
  assert.ok(panned.center.x >= panned.viewportSize.width / (2 * scale));
  assert.ok(panned.center.y <= panned.imageSize.height - panned.viewportSize.height / (2 * scale));
  const fit = fitViewTransform(panned);
  assert.deepEqual(fit.center, { x: 203, y: 360 });
  assert.equal(fit.zoom, 1);
});

test("preserves the viewed image center across resize and frame reuse", () => {
  const transform = panByViewportDelta(
    zoomAtViewportPoint(createViewTransform({ width: 1000, height: 800 }, { width: 800, height: 600 }), 2, { x: 400, y: 300 }),
    { x: -80, y: 40 },
  );
  const resized = resizeViewTransform(transform, { width: 1200, height: 700 });
  close(resized.center.x, transform.center.x);
  close(resized.center.y, transform.center.y);
  assert.equal(resized.zoom, transform.zoom);
  assert.equal(resized, resizeViewTransform(resized, resized.viewportSize));
});

test("repeated inverse zooms do not drift at the viewport center", () => {
  let transform = createViewTransform({ width: 1000, height: 800 }, { width: 800, height: 600 });
  const anchor = { x: 400, y: 300 };
  for (let index = 0; index < 100; index += 1) {
    transform = zoomAtViewportPoint(transform, 2, anchor);
    transform = zoomAtViewportPoint(transform, 1, anchor);
  }
  close(transform.center.x, 500);
  close(transform.center.y, 400);
  assert.equal(transform.zoom, 1);
});

test("steps zoom by fixed ten percentage points instead of multiplying", () => {
  const anchor = { x: 400, y: 300 };
  let transform = createViewTransform({ width: 1000, height: 800 }, { width: 800, height: 600 });
  transform = stepViewZoom(transform, 1, anchor);
  assert.equal(transform.zoom, 1.1);
  transform = stepViewZoom(transform, 1, anchor);
  assert.equal(transform.zoom, 1.2);
  transform = stepViewZoom(transform, -1, anchor);
  assert.equal(transform.zoom, 1.1);
  transform = stepViewZoom(fitViewTransform(transform), -1, anchor);
  assert.equal(transform.zoom, 1);
  const maximum = zoomAtViewportPoint(transform, 10, anchor);
  assert.equal(stepViewZoom(maximum, 1, anchor), maximum);
});

test("keeps fixed-step cursor anchor stable without round-trip drift", () => {
  const anchor = { x: 400, y: 300 };
  let transform = createViewTransform({ width: 1000, height: 800 }, { width: 800, height: 600 });
  const before = viewportToImage(transform, anchor);
  for (let index = 0; index < 100; index += 1) {
    transform = stepViewZoom(transform, 1, anchor);
    transform = stepViewZoom(transform, -1, anchor);
  }
  const after = viewportToImage(transform, anchor);
  close(after.x, before.x);
  close(after.y, before.y);
  assert.equal(transform.zoom, 1);
});

test("sets original pixel size while preserving the viewed center", () => {
  const transform = panByViewportDelta(
    zoomAtViewportPoint(createViewTransform({ width: 1000, height: 800 }, { width: 800, height: 600 }), 2, { x: 400, y: 300 }),
    { x: -50, y: 25 },
  );
  const actual = actualSizeViewTransform(transform);
  close(effectiveScale(actual), 1);
  close(actual.center.x, transform.center.x);
  close(actual.center.y, transform.center.y);
});
