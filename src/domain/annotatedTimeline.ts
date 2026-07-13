import type { Annotation } from "./annotation.js";

export type AnnotatedFrame = {
  frameIndex: number;
  annotationCount: number;
  firstAnnotationId: string;
};

export type TimelineMarkerBucket = {
  column: number;
  annotationCount: number;
  frames: AnnotatedFrame[];
};

export function frameIndexFromTimelinePosition(position: number, width: number, frameCount: number): number {
  if (frameCount <= 1 || width <= 1) return 0;
  const ratio = Math.max(0, Math.min(1, position / (width - 1)));
  return Math.round(ratio * (frameCount - 1));
}

export function timelinePositionForFrame(frameIndex: number, width: number, frameCount: number): number {
  if (frameCount <= 1 || width <= 1) return 0;
  const bounded = Math.max(0, Math.min(frameCount - 1, frameIndex));
  return (bounded / (frameCount - 1)) * (width - 1);
}

export function aggregateTimelineMarkers(
  annotations: readonly Annotation[],
  width: number,
  frameCount: number,
): TimelineMarkerBucket[] {
  const frames = new Map<number, AnnotatedFrame>();
  const orders = new Map(annotations.map((annotation) => [annotation.id, annotation.order]));
  for (const annotation of annotations) {
    const current = frames.get(annotation.frameIndex);
    if (current) {
      current.annotationCount += 1;
      if (annotation.order < (orders.get(current.firstAnnotationId) ?? Number.POSITIVE_INFINITY)) {
        current.firstAnnotationId = annotation.id;
      }
    } else {
      frames.set(annotation.frameIndex, {
        frameIndex: annotation.frameIndex,
        annotationCount: 1,
        firstAnnotationId: annotation.id,
      });
    }
  }
  const buckets = new Map<number, TimelineMarkerBucket>();
  for (const frame of frames.values()) {
    const column = Math.round(timelinePositionForFrame(frame.frameIndex, width, frameCount));
    const bucket = buckets.get(column) ?? { column, annotationCount: 0, frames: [] };
    bucket.annotationCount += frame.annotationCount;
    bucket.frames.push(frame);
    buckets.set(column, bucket);
  }
  return [...buckets.values()]
    .map((bucket) => ({ ...bucket, frames: bucket.frames.sort((a, b) => a.frameIndex - b.frameIndex) }))
    .sort((a, b) => a.column - b.column);
}

export function nearestAnnotatedFrame(bucket: TimelineMarkerBucket, targetFrame: number): AnnotatedFrame {
  return bucket.frames.reduce((nearest, candidate) =>
    Math.abs(candidate.frameIndex - targetFrame) < Math.abs(nearest.frameIndex - targetFrame)
      ? candidate
      : nearest);
}
