import assert from "node:assert/strict";
import test from "node:test";
import {
  boxFromPoints,
  clampImagePoint,
  commitAnnotationChange,
  createAnnotation,
  createAnnotationSession,
  moveAnnotation,
  pointInImage,
  previewAnnotation,
  redoAnnotation,
  resizeAnnotation,
  undoAnnotation,
  updateAnnotationStyle,
} from "../src/domain/annotation";

const imageSize = { width: 100, height: 80 };

test("stores every annotation geometry in image pixels and clamps drawing bounds", () => {
  const session = createAnnotationSession();
  assert.equal(pointInImage({ x: 0, y: 80 }, imageSize), true);
  assert.equal(pointInImage({ x: -0.1, y: 40 }, imageSize), false);
  assert.deepEqual(clampImagePoint({ x: 110, y: -4 }, imageSize), { x: 100, y: 0 });
  const rectangle = createAnnotation(session, 3, "rectangle", { x: 90, y: 70 }, { x: 130, y: 90 }, imageSize);
  assert.deepEqual(rectangle.geometry, { x: 90, y: 70, width: 10, height: 10 });
  assert.deepEqual(boxFromPoints({ x: 50, y: 40 }, { x: 90, y: 50 }, imageSize, true), { x: 50, y: 40, width: 40, height: 40 });
});

test("creates stable ordered frame annotations and clears redo after a new action", () => {
  let session = createAnnotationSession();
  const arrow = createAnnotation(session, 0, "arrow", { x: 10, y: 10 }, { x: 20, y: 20 }, imageSize);
  session = commitAnnotationChange(session, null, arrow, arrow.id);
  assert.equal(session.nextOrder, 2);
  const undone = undoAnnotation(session)!;
  assert.equal(undone.session.annotations.length, 0);
  assert.equal(undone.frameIndex, 0);
  const redone = redoAnnotation(undone.session)!;
  assert.deepEqual(redone.session.annotations, [arrow]);
  const moved = moveAnnotation(arrow, { x: 5, y: -5 }, imageSize);
  const branched = commitAnnotationChange(undone.session, null, moved, moved.id);
  assert.equal(branched.redoStack.length, 0);
});

test("moves and resizes shapes and arrow endpoints inside image bounds", () => {
  const session = createAnnotationSession();
  const rectangle = createAnnotation(session, 2, "rectangle", { x: 10, y: 10 }, { x: 30, y: 30 }, imageSize);
  const moved = moveAnnotation(rectangle, { x: 100, y: 100 }, imageSize);
  assert.deepEqual(moved.geometry, { x: 80, y: 60, width: 20, height: 20 });
  const resized = resizeAnnotation(moved, "nw", { x: 70, y: 50 }, imageSize);
  assert.deepEqual(resized.geometry, { x: 70, y: 50, width: 30, height: 30 });
  const arrow = createAnnotation(session, 2, "arrow", { x: 10, y: 10 }, { x: 20, y: 20 }, imageSize);
  const endpoint = resizeAnnotation(arrow, "end", { x: 200, y: -10 }, imageSize);
  assert.equal(endpoint.kind, "arrow");
  if (endpoint.kind === "arrow") assert.deepEqual(endpoint.geometry.end, { x: 100, y: 0 });
});

test("records creation move style and deletion as global single transactions", () => {
  let session = createAnnotationSession();
  const text = createAnnotation(session, 7, "text", { x: 10, y: 20 }, undefined, undefined, false, "검사");
  session = commitAnnotationChange(session, null, text, text.id);
  const moved = moveAnnotation(text, { x: 3, y: 4 }, imageSize);
  session = previewAnnotation(session, moved);
  session = commitAnnotationChange(session, text, moved, moved.id);
  const styled = updateAnnotationStyle(moved, { color: "#00ff00", fontSize: 24 });
  session = commitAnnotationChange(session, moved, styled, styled.id);
  session = commitAnnotationChange(session, styled, null, null);
  assert.equal(session.undoStack.length, 4);
  assert.equal(session.annotations.length, 0);
  const restoreDelete = undoAnnotation(session)!;
  assert.equal(restoreDelete.frameIndex, 7);
  assert.deepEqual(restoreDelete.session.annotations, [styled]);
  assert.equal(restoreDelete.session.selectedId, styled.id);
});
