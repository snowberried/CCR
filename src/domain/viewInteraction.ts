export type ViewWheelIntent =
  | { type: "zoom"; factor: number }
  | { type: "frame" };

export type PanGesture = {
  pointerId: number;
  lastX: number;
  lastY: number;
};

export function viewWheelIntent(input: { ctrlKey: boolean; deltaY: number; deltaMode: number }): ViewWheelIntent {
  if (!input.ctrlKey) return { type: "frame" };
  const pixelDelta = input.deltaMode === 1 ? input.deltaY * 16 : input.deltaY;
  const boundedDelta = Math.max(-240, Math.min(240, pixelDelta));
  return { type: "zoom", factor: Math.exp(-boundedDelta * 0.0025) };
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

export function fullscreenShortcut(input: { key: string; editing: boolean }): "toggle" | null {
  return !input.editing && input.key.toLowerCase() === "f" ? "toggle" : null;
}
