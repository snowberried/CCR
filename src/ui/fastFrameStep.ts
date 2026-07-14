export const DEFAULT_FAST_FRAME_STEP = 5;
export const MIN_FAST_FRAME_STEP = 2;
export const MAX_FAST_FRAME_STEP = 999;
export const FAST_FRAME_STEP_PRESETS = [2, 5, 10, 20, 30, 50] as const;
export const FAST_FRAME_STEP_STORAGE_KEY = "ccr.fastFrameStep.v1";

export type FastFrameStepStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
};

export function parseFastFrameStep(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < MIN_FAST_FRAME_STEP || parsed > MAX_FAST_FRAME_STEP) {
    return null;
  }
  return parsed;
}

export function isFastFrameStepPreset(value: number): boolean {
  return FAST_FRAME_STEP_PRESETS.some((preset) => preset === value);
}

export function loadFastFrameStep(storage: FastFrameStepStorage | null): number {
  if (!storage) return DEFAULT_FAST_FRAME_STEP;
  try {
    return parseFastFrameStep(storage.getItem(FAST_FRAME_STEP_STORAGE_KEY)) ?? DEFAULT_FAST_FRAME_STEP;
  } catch {
    return DEFAULT_FAST_FRAME_STEP;
  }
}

export function saveFastFrameStep(storage: FastFrameStepStorage | null, value: number): boolean {
  const parsed = parseFastFrameStep(value);
  if (!storage || parsed === null) return false;
  try {
    storage.setItem(FAST_FRAME_STEP_STORAGE_KEY, String(parsed));
    return true;
  } catch {
    return false;
  }
}
