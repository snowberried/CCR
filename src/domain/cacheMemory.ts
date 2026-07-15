import { YUV_CACHE_MINIMUM_BYTES } from "./yuvCachePolicy.js";

export const CACHE_MEMORY_GIB_BYTES = 1024 ** 3;
export const CACHE_MEMORY_MANUAL_OPTIONS = [2, 4, 6, 8] as const;

export type CacheMemoryGiB = typeof CACHE_MEMORY_MANUAL_OPTIONS[number];
export type CacheMemoryPreference = "auto" | CacheMemoryGiB;

export type CacheMemoryResolution = {
  preference: CacheMemoryPreference;
  cacheBudgetBytes?: number;
};

export function parseCacheMemoryPreference(value: unknown): CacheMemoryPreference | null {
  if (value === "auto") return value;
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return CACHE_MEMORY_MANUAL_OPTIONS.find((option) => option === parsed) ?? null;
}

export function manualCacheMemoryOptions(totalMemoryBytes: number): CacheMemoryGiB[] {
  if (!Number.isFinite(totalMemoryBytes) || totalMemoryBytes < 0) {
    throw new RangeError("INVALID_TOTAL_MEMORY");
  }
  const roundedTotalGiB = Math.round(totalMemoryBytes / CACHE_MEMORY_GIB_BYTES);
  return CACHE_MEMORY_MANUAL_OPTIONS.filter((option) => roundedTotalGiB >= option * 4);
}

export function resolveCacheMemoryPreference(input: {
  preference: unknown;
  totalMemoryBytes: number;
  availableMemoryBytes: number;
}): CacheMemoryResolution {
  if (
    !Number.isFinite(input.totalMemoryBytes) || input.totalMemoryBytes < 0 ||
    !Number.isFinite(input.availableMemoryBytes) || input.availableMemoryBytes < 0
  ) {
    throw new RangeError("INVALID_CACHE_MEMORY");
  }
  const parsed = parseCacheMemoryPreference(input.preference) ?? "auto";
  const allowed = manualCacheMemoryOptions(input.totalMemoryBytes);
  if (parsed === "auto" || !allowed.includes(parsed)) {
    return { preference: "auto" };
  }

  const requestedBudgetBytes = parsed * CACHE_MEMORY_GIB_BYTES;
  const safeBudgetBytes = Math.floor(Math.min(
    requestedBudgetBytes,
    input.totalMemoryBytes * 0.25,
    input.availableMemoryBytes * 0.5,
  ));
  return {
    preference: parsed,
    cacheBudgetBytes: safeBudgetBytes >= YUV_CACHE_MINIMUM_BYTES ? safeBudgetBytes : undefined,
  };
}
