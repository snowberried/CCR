export type ViewWheelIntent =
  | { type: "zoom" }
  | { type: "frame" };

export type PanGesture = {
  pointerId: number;
  lastX: number;
  lastY: number;
};

export type ZoomDragGesture = {
  pointerId: number;
  startY: number;
  startZoom: number;
  anchor: { x: number; y: number };
};

export function viewWheelIntent(input: { ctrlKey: boolean; deltaY: number; deltaMode: number }): ViewWheelIntent {
  if (!input.ctrlKey) return { type: "frame" };
  return { type: "zoom" };
}

export class WheelZoomAccumulator {
  private accumulatedDelta = 0;

  constructor(private readonly threshold = 50) {}

  consume(deltaY: number, deltaMode: number): -1 | 0 | 1 {
    const normalizedDelta = deltaMode === 1 ? deltaY * 16 : deltaY;
    if (Math.abs(normalizedDelta) >= this.threshold) {
      this.accumulatedDelta = 0;
      return Math.sign(normalizedDelta) as -1 | 1;
    }
    this.accumulatedDelta += normalizedDelta;
    if (Math.abs(this.accumulatedDelta) < this.threshold) return 0;
    const direction = Math.sign(this.accumulatedDelta) as -1 | 1;
    this.accumulatedDelta -= direction * this.threshold;
    return direction;
  }

  reset(): void {
    this.accumulatedDelta = 0;
  }
}

export function zoomShortcut(input: { key: string; editing: boolean }): -1 | 0 | 1 | "fit" {
  if (input.editing) return 0;
  if (["+", "=", "Add"].includes(input.key)) return 1;
  if (["-", "_", "Subtract"].includes(input.key)) return -1;
  if (input.key === "0") return "fit";
  return 0;
}

export function beginPan(pointerId: number, x: number, y: number): PanGesture {
  return { pointerId, lastX: x, lastY: y };
}

export function movePan(gesture: PanGesture, pointerId: number, x: number, y: number) {
  if (gesture.pointerId !== pointerId) return { gesture, delta: null };
  return {
    gesture: { pointerId, lastX: x, lastY: y },
    delta: { x: x - gesture.lastX, y: y - gesture.lastY },
  };
}

export function endsPan(gesture: PanGesture | null, pointerId: number): boolean {
  return gesture?.pointerId === pointerId;
}

export function beginZoomDrag(
  pointerId: number,
  y: number,
  startZoom: number,
  anchor: { x: number; y: number },
): ZoomDragGesture {
  return { pointerId, startY: y, startZoom, anchor };
}

export function zoomForVerticalDrag(gesture: ZoomDragGesture, pointerId: number, y: number): number | null {
  return gesture.pointerId === pointerId
    ? gesture.startZoom * Math.exp(-(y - gesture.startY) * 0.003)
    : null;
}

export function fullscreenShortcut(input: { key: string; editing: boolean }): "toggle" | null {
  return !input.editing && input.key.toLowerCase() === "f" ? "toggle" : null;
}
