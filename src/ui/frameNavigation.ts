import { DEFAULT_FAST_FRAME_STEP, parseFastFrameStep } from "./fastFrameStep";
import type { ShortcutAction } from "./shortcuts";

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

export function navigationTargetForAction(
  action: ShortcutAction,
  currentFrameIndex: number,
  frameCount: number,
  fastFrameStep = DEFAULT_FAST_FRAME_STEP,
): number | null {
  const fastStep = parseFastFrameStep(fastFrameStep) ?? DEFAULT_FAST_FRAME_STEP;
  if (action === "previousFrame") return clampFrameIndex(currentFrameIndex - 1, frameCount);
  if (action === "nextFrame") return clampFrameIndex(currentFrameIndex + 1, frameCount);
  if (action === "fastPreviousFrame") return clampFrameIndex(currentFrameIndex - fastStep, frameCount);
  if (action === "fastNextFrame") return clampFrameIndex(currentFrameIndex + fastStep, frameCount);
  if (action === "firstFrame") return 0;
  if (action === "lastFrame") return Math.max(0, frameCount - 1);
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
