import assert from "node:assert/strict";
import test from "node:test";
import { createAnnotation, createAnnotationSession } from "../src/domain/annotation";
import {
  aggregateTimelineMarkers,
  frameIndexFromTimelinePosition,
  nearestAnnotatedFrame,
  timelinePositionForFrame,
} from "../src/domain/annotatedTimeline";

test("maps exact first middle and last timeline positions", () => {
  assert.equal(frameIndexFromTimelinePosition(0, 101, 11), 0);
  assert.equal(frameIndexFromTimelinePosition(50, 101, 11), 5);
  assert.equal(frameIndexFromTimelinePosition(100, 101, 11), 10);
  assert.equal(timelinePositionForFrame(5, 101, 11), 50);
  assert.equal(frameIndexFromTimelinePosition(50, 1, 11), 0);
});

test("aggregates annotated frames by pixel column without unbounded marker DOM", () => {
  const session = createAnnotationSession();
  const annotations = [
    createAnnotation(session, 100, "text", { x: 1, y: 1 }, undefined, undefined, false, "A"),
    { ...createAnnotation(session, 100, "text", { x: 2, y: 2 }, undefined, undefined, false, "B"), id: "annotation-2", order: 2 },
    { ...createAnnotation(session, 101, "arrow", { x: 1, y: 1 }, { x: 3, y: 3 }), id: "annotation-3", order: 3 },
    { ...createAnnotation(session, 999, "ellipse", { x: 1, y: 1 }, { x: 3, y: 3 }, { width: 10, height: 10 }), id: "annotation-4", order: 4 },
  ];
  const buckets = aggregateTimelineMarkers(annotations, 10, 1000);
  assert.ok(buckets.length <= 10);
  const first = buckets.find((bucket) => bucket.frames.some((frame) => frame.frameIndex === 100))!;
  assert.equal(first.annotationCount, 3);
  assert.equal(first.frames[0].annotationCount, 2);
  assert.equal(nearestAnnotatedFrame(first, 101).frameIndex, 101);
});
