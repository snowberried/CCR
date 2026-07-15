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

  hasBlockOrPending(blockIndex: number): boolean {
    return this.blocks.has(blockIndex) || this.inFlight.has(blockIndex);
  }

  async loadBatch(
    blockIndexes: readonly number[],
    load: (accept: (block: YuvCacheBlock) => void) => Promise<void>,
  ): Promise<boolean> {
    const uniqueIndexes = [...new Set(blockIndexes)];
    if (
      uniqueIndexes.length === 0 || uniqueIndexes.length !== blockIndexes.length ||
      uniqueIndexes.some((blockIndex) => !Number.isInteger(blockIndex) || blockIndex < 0)
    ) {
      throw new RangeError("INVALID_YUV_BATCH_BLOCKS");
    }
    if (uniqueIndexes.some((blockIndex) => this.hasBlockOrPending(blockIndex))) return false;

    type Deferred = {
      promise: Promise<YuvCacheBlock>;
      resolve: (block: YuvCacheBlock) => void;
      reject: (error: unknown) => void;
      settled: boolean;
    };
    const deferreds = new Map<number, Deferred>();
    for (const blockIndex of uniqueIndexes) {
      let resolve!: (block: YuvCacheBlock) => void;
      let reject!: (error: unknown) => void;
      const promise = new Promise<YuvCacheBlock>((accept, fail) => {
        resolve = accept;
        reject = fail;
      });
      deferreds.set(blockIndex, { promise, resolve, reject, settled: false });
      this.inFlight.set(blockIndex, promise);
    }

    try {
      await load((block) => {
        const deferred = deferreds.get(block.blockIndex);
        if (!deferred || deferred.settled) throw new Error("YUV_BATCH_BLOCK_UNEXPECTED");
        this.insert(block);
        deferred.settled = true;
        deferred.resolve(block);
      });
      if ([...deferreds.values()].some((deferred) => !deferred.settled)) {
        throw new Error("YUV_BATCH_BLOCK_MISSING");
      }
      return true;
    } catch (error) {
      for (const deferred of deferreds.values()) {
        if (deferred.settled) continue;
        deferred.settled = true;
        deferred.reject(error);
      }
      await Promise.allSettled([...deferreds.values()].map((deferred) => deferred.promise));
      throw error;
    } finally {
      for (const [blockIndex, deferred] of deferreds) {
        if (this.inFlight.get(blockIndex) === deferred.promise) this.inFlight.delete(blockIndex);
      }
    }
  }

  touchBlock(blockIndex: number): boolean {
    const block = this.blocks.get(blockIndex);
    if (!block) return false;
    this.blocks.delete(blockIndex);
    this.blocks.set(blockIndex, block);
    return true;
  }

  blockIndexes(): number[] {
    return [...this.blocks.keys()];
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
