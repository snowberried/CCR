import type { Point, Size } from "./viewTransform.js";

export type AnnotationKind = "arrow" | "text" | "ellipse" | "rectangle";
export type DrawingAnnotationKind = Exclude<AnnotationKind, "text">;
export type BoxHandle = "nw" | "n" | "ne" | "e" | "se" | "s" | "sw" | "w";
export type AnnotationHandle = BoxHandle | "start" | "end";

export type AnnotationStyle = {
  color: string;
  lineWidth: number;
  fontSize: number;
};

type AnnotationBase = {
  id: string;
  frameIndex: number;
  style: AnnotationStyle;
  order: number;
};

export type ArrowAnnotation = AnnotationBase & {
  kind: "arrow";
  geometry: { start: Point; end: Point };
};

export type TextAnnotation = AnnotationBase & {
  kind: "text";
  geometry: { anchor: Point; text: string };
};

export type BoxAnnotation = AnnotationBase & {
  kind: "ellipse" | "rectangle";
  geometry: { x: number; y: number; width: number; height: number };
};

export type Annotation = ArrowAnnotation | TextAnnotation | BoxAnnotation;

export type AnnotationTransaction = {
  frameIndex: number;
  before: Annotation | null;
  after: Annotation | null;
  selectionBefore: string | null;
  selectionAfter: string | null;
};

export type AnnotationSession = {
  annotations: Annotation[];
  selectedId: string | null;
  defaults: AnnotationStyle;
  nextOrder: number;
  undoStack: AnnotationTransaction[];
  redoStack: AnnotationTransaction[];
};

export const DEFAULT_ANNOTATION_STYLE: AnnotationStyle = {
  color: "#ffd54f",
  lineWidth: 2,
  fontSize: 18,
};

export function createAnnotationSession(): AnnotationSession {
  return {
    annotations: [],
    selectedId: null,
    defaults: { ...DEFAULT_ANNOTATION_STYLE },
    nextOrder: 1,
    undoStack: [],
    redoStack: [],
  };
}

export function pointInImage(point: Point, imageSize: Size): boolean {
  return point.x >= 0 && point.x <= imageSize.width && point.y >= 0 && point.y <= imageSize.height;
}

export function clampImagePoint(point: Point, imageSize: Size): Point {
  return {
    x: Math.max(0, Math.min(imageSize.width, point.x)),
    y: Math.max(0, Math.min(imageSize.height, point.y)),
  };
}

function constrainedEnd(start: Point, end: Point, imageSize: Size): Point {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const xDirection = dx < 0 ? -1 : 1;
  const yDirection = dy < 0 ? -1 : 1;
  const xRoom = xDirection < 0 ? start.x : imageSize.width - start.x;
  const yRoom = yDirection < 0 ? start.y : imageSize.height - start.y;
  const side = Math.min(Math.max(Math.abs(dx), Math.abs(dy)), xRoom, yRoom);
  return { x: start.x + xDirection * side, y: start.y + yDirection * side };
}

export function boxFromPoints(start: Point, end: Point, imageSize: Size, square = false): BoxAnnotation["geometry"] {
  const boundedEnd = square ? constrainedEnd(start, end, imageSize) : clampImagePoint(end, imageSize);
  return {
    x: Math.min(start.x, boundedEnd.x),
    y: Math.min(start.y, boundedEnd.y),
    width: Math.abs(boundedEnd.x - start.x),
    height: Math.abs(boundedEnd.y - start.y),
  };
}

export function createAnnotation(
  session: AnnotationSession,
  frameIndex: number,
  kind: AnnotationKind,
  start: Point,
  end = start,
  imageSize?: Size,
  square = false,
  text = "",
): Annotation {
  const base = {
    id: `annotation-${session.nextOrder}`,
    frameIndex,
    order: session.nextOrder,
    style: { ...session.defaults },
  };
  if (kind === "text") return { ...base, kind, geometry: { anchor: start, text } };
  if (kind === "arrow") return { ...base, kind, geometry: { start, end: imageSize ? clampImagePoint(end, imageSize) : end } };
  if (!imageSize) throw new RangeError("ANNOTATION_IMAGE_SIZE_REQUIRED");
  return { ...base, kind, geometry: boxFromPoints(start, end, imageSize, square) };
}

function replaceAnnotation(annotations: Annotation[], annotation: Annotation | null, id: string): Annotation[] {
  const index = annotations.findIndex((candidate) => candidate.id === id);
  if (annotation === null) return index < 0 ? annotations : annotations.filter((candidate) => candidate.id !== id);
  if (index < 0) return [...annotations, annotation].sort((a, b) => a.order - b.order);
  const next = [...annotations];
  next[index] = annotation;
  return next;
}

export function previewAnnotation(session: AnnotationSession, annotation: Annotation): AnnotationSession {
  return { ...session, annotations: replaceAnnotation(session.annotations, annotation, annotation.id) };
}

export function discardAnnotationPreview(
  session: AnnotationSession,
  annotationId: string,
  selectedId: string | null,
): AnnotationSession {
  return { ...session, annotations: replaceAnnotation(session.annotations, null, annotationId), selectedId };
}

export function selectAnnotation(session: AnnotationSession, selectedId: string | null): AnnotationSession {
  return session.selectedId === selectedId ? session : { ...session, selectedId };
}

export function updateAnnotationDefaults(session: AnnotationSession, style: Partial<AnnotationStyle>): AnnotationSession {
  return { ...session, defaults: { ...session.defaults, ...style } };
}

export function commitAnnotationChange(
  session: AnnotationSession,
  before: Annotation | null,
  after: Annotation | null,
  selectionAfter: string | null,
): AnnotationSession {
  const id = after?.id ?? before?.id;
  if (!id) return session;
  const transaction: AnnotationTransaction = {
    frameIndex: after?.frameIndex ?? before!.frameIndex,
    before,
    after,
    selectionBefore: session.selectedId,
    selectionAfter,
  };
  return {
    ...session,
    annotations: replaceAnnotation(session.annotations, after, id),
    selectedId: selectionAfter,
    nextOrder: Math.max(session.nextOrder, (after?.order ?? 0) + 1),
    undoStack: [...session.undoStack, transaction],
    redoStack: [],
  };
}

export type HistoryResult = { session: AnnotationSession; frameIndex: number } | null;

export function undoAnnotation(session: AnnotationSession): HistoryResult {
  const transaction = session.undoStack.at(-1);
  if (!transaction) return null;
  const id = transaction.after?.id ?? transaction.before!.id;
  return {
    frameIndex: transaction.frameIndex,
    session: {
      ...session,
      annotations: replaceAnnotation(session.annotations, transaction.before, id),
      selectedId: transaction.before ? transaction.before.id : transaction.selectionBefore,
      undoStack: session.undoStack.slice(0, -1),
      redoStack: [...session.redoStack, transaction],
    },
  };
}

export function redoAnnotation(session: AnnotationSession): HistoryResult {
  const transaction = session.redoStack.at(-1);
  if (!transaction) return null;
  const id = transaction.after?.id ?? transaction.before!.id;
  return {
    frameIndex: transaction.frameIndex,
    session: {
      ...session,
      annotations: replaceAnnotation(session.annotations, transaction.after, id),
      selectedId: transaction.after ? transaction.after.id : transaction.selectionAfter,
      undoStack: [...session.undoStack, transaction],
      redoStack: session.redoStack.slice(0, -1),
    },
  };
}

function boundsForAnnotation(annotation: Annotation): { x: number; y: number; width: number; height: number } {
  if (annotation.kind === "text") return { x: annotation.geometry.anchor.x, y: annotation.geometry.anchor.y, width: 0, height: 0 };
  if (annotation.kind === "arrow") {
    return {
      x: Math.min(annotation.geometry.start.x, annotation.geometry.end.x),
      y: Math.min(annotation.geometry.start.y, annotation.geometry.end.y),
      width: Math.abs(annotation.geometry.end.x - annotation.geometry.start.x),
      height: Math.abs(annotation.geometry.end.y - annotation.geometry.start.y),
    };
  }
  return annotation.geometry;
}

export function moveAnnotation(annotation: Annotation, delta: Point, imageSize: Size): Annotation {
  const bounds = boundsForAnnotation(annotation);
  const dx = Math.max(-bounds.x, Math.min(imageSize.width - bounds.x - bounds.width, delta.x));
  const dy = Math.max(-bounds.y, Math.min(imageSize.height - bounds.y - bounds.height, delta.y));
  if (annotation.kind === "text") {
    return { ...annotation, geometry: { ...annotation.geometry, anchor: { x: annotation.geometry.anchor.x + dx, y: annotation.geometry.anchor.y + dy } } };
  }
  if (annotation.kind === "arrow") {
    return {
      ...annotation,
      geometry: {
        start: { x: annotation.geometry.start.x + dx, y: annotation.geometry.start.y + dy },
        end: { x: annotation.geometry.end.x + dx, y: annotation.geometry.end.y + dy },
      },
    };
  }
  return { ...annotation, geometry: { ...annotation.geometry, x: annotation.geometry.x + dx, y: annotation.geometry.y + dy } };
}

const oppositeCorner = (geometry: BoxAnnotation["geometry"], handle: BoxHandle): Point => ({
  x: handle.includes("w") ? geometry.x + geometry.width : handle.includes("e") ? geometry.x : geometry.x + geometry.width / 2,
  y: handle.includes("n") ? geometry.y + geometry.height : handle.includes("s") ? geometry.y : geometry.y + geometry.height / 2,
});

export function resizeAnnotation(
  annotation: Annotation,
  handle: AnnotationHandle,
  point: Point,
  imageSize: Size,
  square = false,
): Annotation {
  const bounded = clampImagePoint(point, imageSize);
  if (annotation.kind === "arrow") {
    if (handle !== "start" && handle !== "end") return annotation;
    return { ...annotation, geometry: { ...annotation.geometry, [handle]: bounded } };
  }
  if (annotation.kind === "text" || handle === "start" || handle === "end") return annotation;
  const geometry = annotation.geometry;
  if (handle === "n" || handle === "s") {
    const fixedY = handle === "n" ? geometry.y + geometry.height : geometry.y;
    return { ...annotation, geometry: { ...geometry, y: Math.min(fixedY, bounded.y), height: Math.abs(bounded.y - fixedY) } };
  }
  if (handle === "e" || handle === "w") {
    const fixedX = handle === "w" ? geometry.x + geometry.width : geometry.x;
    return { ...annotation, geometry: { ...geometry, x: Math.min(fixedX, bounded.x), width: Math.abs(bounded.x - fixedX) } };
  }
  return { ...annotation, geometry: boxFromPoints(oppositeCorner(geometry, handle), bounded, imageSize, square) };
}

export function updateAnnotationStyle(annotation: Annotation, style: Partial<AnnotationStyle>): Annotation {
  return { ...annotation, style: { ...annotation.style, ...style } };
}

export function annotationsForFrame(session: AnnotationSession, frameIndex: number): Annotation[] {
  return session.annotations.filter((annotation) => annotation.frameIndex === frameIndex);
}
