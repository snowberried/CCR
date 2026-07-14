export type VideoDisplayState = {
  level: number;
  width: number;
  gamma: number;
  invert: boolean;
  sharpAmount: number;
  presetId: "original" | "custom";
  revision: number;
};

export const VIDEO_DISPLAY_LIMITS = {
  level: { min: 0, max: 1 },
  width: { min: 0.02, max: 2 },
  gamma: { min: 0.25, max: 4 },
  sharpAmount: { min: 0, max: 1 },
} as const;

const comparableKeys = ["level", "width", "gamma", "invert", "sharpAmount"] as const;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, Number.isFinite(value) ? value : min));
}

export function originalVideoDisplay(revision = 0): VideoDisplayState {
  return { presetId: "original", level: 0.5, width: 1, gamma: 1, invert: false, sharpAmount: 0, revision };
}

export function clampVideoDisplay(state: VideoDisplayState): VideoDisplayState {
  return {
    ...state,
    level: clamp(state.level, VIDEO_DISPLAY_LIMITS.level.min, VIDEO_DISPLAY_LIMITS.level.max),
    width: clamp(state.width, VIDEO_DISPLAY_LIMITS.width.min, VIDEO_DISPLAY_LIMITS.width.max),
    gamma: clamp(state.gamma, VIDEO_DISPLAY_LIMITS.gamma.min, VIDEO_DISPLAY_LIMITS.gamma.max),
    sharpAmount: clamp(state.sharpAmount, VIDEO_DISPLAY_LIMITS.sharpAmount.min, VIDEO_DISPLAY_LIMITS.sharpAmount.max),
  };
}

export function videoDisplayEqual(left: VideoDisplayState, right: VideoDisplayState): boolean {
  return comparableKeys.every((key) => left[key] === right[key]);
}

export function resetVideoDisplay(state: VideoDisplayState): VideoDisplayState {
  return originalVideoDisplay(state.revision + 1);
}

export function updateVideoDisplay(
  state: VideoDisplayState,
  patch: Partial<Pick<VideoDisplayState, "level" | "width" | "gamma" | "sharpAmount">>,
): VideoDisplayState {
  const next = clampVideoDisplay({ ...state, ...patch, presetId: "custom", revision: state.revision + 1 });
  return { ...next, presetId: "custom" };
}

export function toggleVideoDisplayInvert(state: VideoDisplayState): VideoDisplayState {
  const next = { ...state, invert: !state.invert, revision: state.revision + 1 };
  return { ...next, presetId: videoDisplayEqual(next, originalVideoDisplay()) ? "original" : "custom" };
}

export function applyLevelWidthDrag(
  start: VideoDisplayState,
  delta: { x: number; y: number },
  sensitivity = { width: 0.003, level: 0.002 },
): VideoDisplayState {
  return updateVideoDisplay(start, {
    width: start.width + delta.x * sensitivity.width,
    level: start.level - delta.y * sensitivity.level,
  });
}

export function temporaryOriginalDisplay(state: VideoDisplayState, comparing: boolean): VideoDisplayState {
  return comparing ? originalVideoDisplay(state.revision) : state;
}

export function mapDisplayLuminance(luminance: number, state: VideoDisplayState): number {
  const lower = state.level - state.width / 2;
  const windowed = clamp((luminance - lower) / state.width, 0, 1);
  const gammaMapped = Math.pow(windowed, 1 / state.gamma);
  return state.invert ? 1 - gammaMapped : gammaMapped;
}

export type DisplayDragGesture = {
  pointerId: number;
  startX: number;
  startY: number;
  startState: VideoDisplayState;
};

export function beginDisplayDrag(pointerId: number, x: number, y: number, state: VideoDisplayState): DisplayDragGesture {
  return { pointerId, startX: x, startY: y, startState: state };
}

export function moveDisplayDrag(gesture: DisplayDragGesture, pointerId: number, x: number, y: number): VideoDisplayState | null {
  return gesture.pointerId === pointerId
    ? applyLevelWidthDrag(gesture.startState, { x: x - gesture.startX, y: y - gesture.startY })
    : null;
}

export function videoDisplayShortcut(input: { key: string; editing: boolean }): "reset" | "invert" | "compare" | null {
  if (input.editing) return null;
  const key = input.key.toLowerCase();
  if (key === "r") return "reset";
  if (key === "i") return "invert";
  if (key === "o") return "compare";
  return null;
}
