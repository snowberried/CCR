export type NavigationKeyInput = {
  key: string;
  shiftKey: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
};

export function isOpenVideoShortcut(input: NavigationKeyInput): boolean {
  return Boolean(input.ctrlKey || input.metaKey) && input.key.toLowerCase() === "o";
}

export function clampFrameIndex(frameIndex: number, frameCount: number): number {
  if (!Number.isFinite(frameIndex) || !Number.isInteger(frameCount) || frameCount <= 0) {
    return 0;
  }
  return Math.max(0, Math.min(frameCount - 1, Math.trunc(frameIndex)));
}

export function internalToDisplayFrame(frameIndex: number): number {
  return frameIndex + 1;
}

export function displayToInternalFrame(displayFrame: number, frameCount: number): number {
  return clampFrameIndex(Math.trunc(displayFrame) - 1, frameCount);
}

export function navigationTargetForKey(
  input: NavigationKeyInput,
  currentFrameIndex: number,
  frameCount: number,
  editing: boolean,
): number | null {
  if (editing) {
    return null;
  }
  if (input.key === "ArrowLeft" || input.key === "ArrowRight") {
    const direction = input.key === "ArrowLeft" ? -1 : 1;
    return clampFrameIndex(currentFrameIndex + direction * (input.shiftKey ? 5 : 1), frameCount);
  }
  if (input.key === "Home") {
    return 0;
  }
  if (input.key === "End") {
    return Math.max(0, frameCount - 1);
  }
  return null;
}

export class WheelFrameAccumulator {
  private accumulatedDelta = 0;

  constructor(private readonly threshold = 50) {}

  consume(deltaY: number, deltaMode: number): -1 | 0 | 1 {
    const normalizedDelta = deltaMode === 1 ? deltaY * 16 : deltaY;
    if (Math.abs(normalizedDelta) >= this.threshold) {
      this.accumulatedDelta = 0;
      return Math.sign(normalizedDelta) as -1 | 1;
    }
    this.accumulatedDelta += normalizedDelta;
    if (Math.abs(this.accumulatedDelta) < this.threshold) {
      return 0;
    }
    const direction = Math.sign(this.accumulatedDelta) as -1 | 1;
    this.accumulatedDelta -= direction * this.threshold;
    return direction;
  }

  reset(): void {
    this.accumulatedDelta = 0;
  }
}

export function isTextEntryElement(target: EventTarget | null): boolean {
  if (typeof target !== "object" || target === null) {
    return false;
  }
  const element = target as EventTarget & { tagName?: unknown; isContentEditable?: unknown };
  const tagName = typeof element.tagName === "string" ? element.tagName.toUpperCase() : "";
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" ||
    element.isContentEditable === true;
}
