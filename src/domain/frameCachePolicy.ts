export const DEFAULT_FRAME_CACHE_BUDGET_BYTES = 72 * 1024 * 1024;
export const DEFAULT_MINIMUM_TARGET_FRAMES = 5;
export const DEFAULT_MAXIMUM_FRAMES = 61;
export const DEFAULT_DIRECTION_SWITCH_THRESHOLD = 3;

export type CacheDirection = "forward" | "reverse" | "balanced";

export type FrameCachePolicy = {
  bytesPerFrame: number;
  budgetBytes: number;
  minimumTargetFrames: number;
  maximumFrames: number;
  frameCapacity: number;
  belowMinimumTarget: boolean;
};

export type CacheWindow = {
  backwardFrames: number;
  forwardFrames: number;
};

export type FrameCachePolicyOptions = {
  budgetBytes?: number;
  minimumTargetFrames?: number;
  maximumFrames?: number;
};

export function createFrameCachePolicy(
  width: number,
  height: number,
  options: FrameCachePolicyOptions = {},
): FrameCachePolicy {
  const budgetBytes = options.budgetBytes ?? DEFAULT_FRAME_CACHE_BUDGET_BYTES;
  const minimumTargetFrames = options.minimumTargetFrames ?? DEFAULT_MINIMUM_TARGET_FRAMES;
  const maximumFrames = options.maximumFrames ?? DEFAULT_MAXIMUM_FRAMES;
  if (
    !Number.isInteger(width) || width <= 0 ||
    !Number.isInteger(height) || height <= 0 ||
    !Number.isInteger(budgetBytes) || budgetBytes <= 0 ||
    !Number.isInteger(minimumTargetFrames) || minimumTargetFrames <= 0 ||
    !Number.isInteger(maximumFrames) || maximumFrames < minimumTargetFrames
  ) {
    throw new RangeError("INVALID_FRAME_CACHE_POLICY");
  }

  const bytesPerFrame = width * height * 4;
  const budgetCapacity = Math.max(1, Math.floor(budgetBytes / bytesPerFrame));
  const frameCapacity = Math.min(maximumFrames, budgetCapacity);
  return {
    bytesPerFrame,
    budgetBytes,
    minimumTargetFrames,
    maximumFrames,
    frameCapacity,
    belowMinimumTarget: frameCapacity < minimumTargetFrames,
  };
}

export function cacheWindowForDirection(
  frameCapacity: number,
  direction: CacheDirection,
): CacheWindow {
  if (!Number.isInteger(frameCapacity) || frameCapacity <= 0) {
    throw new RangeError("INVALID_FRAME_CACHE_CAPACITY");
  }
  const surroundingFrames = frameCapacity - 1;
  if (direction === "balanced") {
    const backwardFrames = Math.floor(surroundingFrames / 2);
    return { backwardFrames, forwardFrames: surroundingFrames - backwardFrames };
  }

  const shortSide = Math.floor(surroundingFrames / 3);
  const longSide = surroundingFrames - shortSide;
  return direction === "forward"
    ? { backwardFrames: shortSide, forwardFrames: longSide }
    : { backwardFrames: longSide, forwardFrames: shortSide };
}

export class CacheDirectionTracker {
  private previousFrameIndex: number | null = null;
  private previousMovement: "forward" | "reverse" | null = null;
  private sameDirectionCount = 0;
  private direction: CacheDirection = "forward";

  constructor(private readonly switchThreshold = DEFAULT_DIRECTION_SWITCH_THRESHOLD) {
    if (!Number.isInteger(switchThreshold) || switchThreshold <= 0) {
      throw new RangeError("INVALID_DIRECTION_SWITCH_THRESHOLD");
    }
  }

  observe(frameIndex: number): CacheDirection {
    if (this.previousFrameIndex === null) {
      this.previousFrameIndex = frameIndex;
      return this.direction;
    }
    const delta = frameIndex - this.previousFrameIndex;
    this.previousFrameIndex = frameIndex;
    if (delta === 0) {
      return this.direction;
    }

    const movement = delta > 0 ? "forward" : "reverse";
    if (movement === this.previousMovement) {
      this.sameDirectionCount += 1;
    } else {
      this.previousMovement = movement;
      this.sameDirectionCount = 1;
      this.direction = "balanced";
    }
    if (this.sameDirectionCount >= this.switchThreshold) {
      this.direction = movement;
    }
    return this.direction;
  }

  current(): CacheDirection {
    return this.direction;
  }
}
