export type YuvCacheBlock = {
  blockIndex: number;
  startFrameIndex: number;
  frameCount: number;
  frameByteLength: number;
  payload: Buffer;
};

export type YuvBlockCacheStatus = {
  blockCount: number;
  readyFrameCount: number;
  byteLength: number;
  budgetBytes: number;
  evictions: number;
  hits: number;
  misses: number;
};

export class YuvBlockCache {
  private readonly blocks = new Map<number, YuvCacheBlock>();
  private readonly inFlight = new Map<number, Promise<YuvCacheBlock>>();
  private byteLength = 0;
  private evictions = 0;
  private hits = 0;
  private misses = 0;

  constructor(private budgetBytes: number) {
    if (!Number.isInteger(budgetBytes) || budgetBytes <= 0) {
      throw new RangeError("INVALID_YUV_CACHE_BUDGET");
    }
  }

  getFrame(frameIndex: number, blockFrames: number): Buffer | null {
    const blockIndex = Math.floor(frameIndex / blockFrames);
    const block = this.blocks.get(blockIndex);
    if (!block) {
      this.misses += 1;
      return null;
    }
    this.blocks.delete(blockIndex);
    this.blocks.set(blockIndex, block);
    const offset = (frameIndex - block.startFrameIndex) * block.frameByteLength;
    if (offset < 0 || offset + block.frameByteLength > block.payload.byteLength) {
      this.misses += 1;
      return null;
    }
    this.hits += 1;
    return block.payload.subarray(offset, offset + block.frameByteLength);
  }

  setBudget(nextBudgetBytes: number): void {
    if (!Number.isInteger(nextBudgetBytes) || nextBudgetBytes <= 0) {
      throw new RangeError("INVALID_YUV_CACHE_BUDGET");
    }
    this.budgetBytes = nextBudgetBytes;
    this.evictToBudget();
  }

  async getOrLoad(blockIndex: number, load: () => Promise<YuvCacheBlock>): Promise<YuvCacheBlock> {
    const existing = this.blocks.get(blockIndex);
    if (existing) {
      this.blocks.delete(blockIndex);
      this.blocks.set(blockIndex, existing);
      return existing;
    }
    const pending = this.inFlight.get(blockIndex);
    if (pending) {
      return pending;
    }
    const promise = load().then((block) => {
      const insertedWhileLoading = this.blocks.get(blockIndex);
      if (insertedWhileLoading) return insertedWhileLoading;
      this.insert(block);
      return block;
    }).finally(() => this.inFlight.delete(blockIndex));
    this.inFlight.set(blockIndex, promise);
    return promise;
  }

  insert(block: YuvCacheBlock): void {
    const previous = this.blocks.get(block.blockIndex);
    if (previous) {
      this.blocks.delete(block.blockIndex);
      if (previous.frameCount >= block.frameCount) {
        this.blocks.set(block.blockIndex, previous);
        return;
      }
      this.byteLength -= previous.payload.byteLength;
    }
    this.blocks.set(block.blockIndex, block);
    this.byteLength += block.payload.byteLength;
    this.evictToBudget();
  }

  hasBlock(blockIndex: number): boolean {
    return this.blocks.has(blockIndex);
  }

  clear(): void {
    this.blocks.clear();
    this.inFlight.clear();
    this.byteLength = 0;
  }

  status(): YuvBlockCacheStatus {
    let readyFrameCount = 0;
    for (const block of this.blocks.values()) {
      readyFrameCount += block.frameCount;
    }
    return {
      blockCount: this.blocks.size,
      readyFrameCount,
      byteLength: this.byteLength,
      budgetBytes: this.budgetBytes,
      evictions: this.evictions,
      hits: this.hits,
      misses: this.misses,
    };
  }

  private evictToBudget(): void {
    while (this.byteLength > this.budgetBytes && this.blocks.size > 1) {
      const oldest = this.blocks.entries().next().value as [number, YuvCacheBlock] | undefined;
      if (!oldest) break;
      this.blocks.delete(oldest[0]);
      this.byteLength -= oldest[1].payload.byteLength;
      this.evictions += 1;
    }
  }
}
