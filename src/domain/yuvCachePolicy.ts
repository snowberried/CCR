const MIB = 1024 * 1024;
const GIB = 1024 * MIB;

export const YUV_CACHE_HARD_CAP_BYTES = 2 * GIB;
export const YUV_CACHE_MINIMUM_BYTES = 256 * MIB;

export type YuvCachePolicy = {
  budgetBytes: number;
  enabled: boolean;
  mode: "full" | "lru" | "fallback";
};

export type YuvPrefetchDirection = "forward" | "reverse";

export const YUV_LRU_PREFETCH_LOOKAHEAD_BLOCKS = 8;
export const YUV_LRU_PREFETCH_LOW_WATER_BLOCKS = 4;
export const YUV_LRU_PREFETCH_REFILL_BLOCKS = 4;

export function lruPrefetchBlockCandidates(
  currentBlockIndex: number,
  blockCount: number,
  direction: YuvPrefetchDirection,
  lookaheadBlocks = YUV_LRU_PREFETCH_LOOKAHEAD_BLOCKS,
): number[] {
  if (
    !Number.isInteger(currentBlockIndex) || currentBlockIndex < 0 ||
    !Number.isInteger(blockCount) || blockCount <= 0 || currentBlockIndex >= blockCount ||
    !Number.isInteger(lookaheadBlocks) || lookaheadBlocks <= 0
  ) {
    throw new RangeError("INVALID_YUV_PREFETCH_POLICY");
  }
  const step = direction === "forward" ? 1 : -1;
  const candidates: number[] = [];
  for (let distance = 1; distance <= lookaheadBlocks; distance += 1) {
    const blockIndex = currentBlockIndex + step * distance;
    if (blockIndex < 0 || blockIndex >= blockCount) break;
    candidates.push(blockIndex);
  }
  return candidates;
}

export function createYuvCachePolicy(input: {
  totalMemoryBytes: number;
  availableMemoryBytes: number;
  estimatedPayloadBytes: number;
  metadataBytes?: number;
}): YuvCachePolicy {
  const values = [input.totalMemoryBytes, input.availableMemoryBytes, input.estimatedPayloadBytes, input.metadataBytes ?? 0];
  if (values.some((value) => !Number.isFinite(value) || value < 0)) {
    throw new RangeError("INVALID_YUV_CACHE_POLICY");
  }
  const budgetBytes = Math.floor(Math.min(
    YUV_CACHE_HARD_CAP_BYTES,
    input.totalMemoryBytes * 0.125,
    input.availableMemoryBytes * 0.25,
  ));
  if (budgetBytes < YUV_CACHE_MINIMUM_BYTES) {
    return { budgetBytes, enabled: false, mode: "fallback" };
  }
  const requiredBytes = input.estimatedPayloadBytes + (input.metadataBytes ?? 0);
  return {
    budgetBytes,
    enabled: true,
    mode: requiredBytes <= budgetBytes * 0.8 ? "full" : "lru",
  };
}
