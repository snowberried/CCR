import assert from "node:assert/strict";
import test from "node:test";
import { createAnnotation, createAnnotationSession } from "../src/domain/annotation.js";
import {
  defaultPngFileName,
  exportOutputSize,
  isStableExportFrame,
  projectAnnotation,
} from "../src/domain/frameExport.js";
import { createViewTransform, panByViewportDelta, zoomAtViewportPoint } from "../src/domain/viewTransform.js";

test("defines exact full-frame pixels and rounded DPR current-view backing pixels", () => {
  assert.deepEqual(exportOutputSize("full-frame", { width: 1920, height: 1080 }, { width: 701.2, height: 419.6 }, 1.5), { width: 1920, height: 1080 });
  assert.deepEqual(exportOutputSize("current-view", { width: 1920, height: 1080 }, { width: 701.2, height: 419.6 }, 1.5), { width: 1052, height: 629 });
  assert.deepEqual(exportOutputSize("current-view", { width: 1, height: 1 }, { width: 0.1, height: 0.1 }, 0), { width: 1, height: 1 });
});

test("creates Unicode-safe deterministic one-based frame filenames", () => {
  assert.equal(defaultPngFileName("검사 영상", 36, 240), "검사 영상_f0037.png");
  assert.equal(defaultPngFileName("bad:source?. ", 0, 12), "bad_source__f0001.png");
  assert.equal(defaultPngFileName("...", 9999, 10_000), "ct-cine_f10000.png");
});

test("accepts only the stable actually displayed frame", () => {
  const base = { accepted: true, hasPixels: true, identity: { frameIndex: 7, fingerprint: "abc", width: 8, height: 8 }, displayedFrameIndex: 7, viewerStatus: "ready", pumping: false };
  assert.equal(isStableExportFrame(base), true);
  assert.equal(isStableExportFrame({ ...base, displayedFrameIndex: 8 }), false);
  assert.equal(isStableExportFrame({ ...base, viewerStatus: "decoding" }), false);
  assert.equal(isStableExportFrame({ ...base, pumping: true }), false);
});

test("keeps full annotation image pixels and projects current-view geometry through ViewTransform", () => {
  const imageSize = { width: 200, height: 100 };
  let transform = createViewTransform(imageSize, { width: 400, height: 400 });
  transform = zoomAtViewportPoint(transform, 2, { x: 200, y: 200 });
  transform = panByViewportDelta(transform, { x: 20, y: -10 });
  const annotation = createAnnotation(createAnnotationSession(), 0, "rectangle", { x: 10, y: 20 }, { x: 30, y: 40 }, imageSize);
  assert.equal(projectAnnotation(annotation, "full-frame", transform), annotation);
  const projected = projectAnnotation(annotation, "current-view", transform);
  assert.equal(projected.kind, "rectangle");
  if (projected.kind === "rectangle") {
    assert.deepEqual(projected.geometry, { x: -140, y: 80, width: 80, height: 80 });
  }
});
