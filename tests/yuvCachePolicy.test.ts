import assert from "node:assert/strict";
import test from "node:test";
import { createI420Layout, chooseI420BlockFrames } from "../src/domain/i420";
import { createYuvCachePolicy, lruPrefetchBlockCandidates } from "../src/domain/yuvCachePolicy";
import { YuvBlockCache } from "../electron/adapters/YuvBlockCache";

test("calculates I420 planes for even and odd dimensions", () => {
  assert.deepEqual(createI420Layout(4, 2), {
    y: { offset: 0, stride: 4 },
    u: { offset: 8, stride: 2 },
    v: { offset: 10, stride: 2 },
    byteLength: 12,
  });
  assert.deepEqual(createI420Layout(3, 3), {
    y: { offset: 0, stride: 3 },
    u: { offset: 9, stride: 2 },
    v: { offset: 13, stride: 2 },
    byteLength: 17,
  });
  assert.equal(chooseI420BlockFrames(406 * 720 * 1.5), 64);
  assert.equal(chooseI420BlockFrames(1920 * 1080 * 1.5), 10);
});

test("selects full, LRU, and fallback cache modes", () => {
  const base = { totalMemoryBytes: 16 * 1024 ** 3, availableMemoryBytes: 12 * 1024 ** 3 };
  assert.equal(createYuvCachePolicy({ ...base, estimatedPayloadBytes: 1024 ** 3 }).mode, "full");
  assert.equal(createYuvCachePolicy({ ...base, estimatedPayloadBytes: 1.8 * 1024 ** 3 }).mode, "lru");
  assert.equal(createYuvCachePolicy({ totalMemoryBytes: 1024 ** 3, availableMemoryBytes: 256 * 1024 ** 2, estimatedPayloadBytes: 1 }).mode, "fallback");
  assert.throws(() => createYuvCachePolicy({ ...base, estimatedPayloadBytes: 1, metadataBytes: Number.NaN }), /INVALID/);
});

test("plans bounded directional LRU prefetch blocks", () => {
  assert.deepEqual(lruPrefetchBlockCandidates(3, 10, "forward"), [4, 5, 6, 7, 8, 9]);
  assert.deepEqual(lruPrefetchBlockCandidates(3, 10, "reverse"), [2, 1, 0]);
  assert.deepEqual(lruPrefetchBlockCandidates(3, 10, "forward", 4), [4, 5, 6, 7]);
  assert.deepEqual(lruPrefetchBlockCandidates(9, 10, "forward"), []);
  assert.throws(() => lruPrefetchBlockCandidates(10, 10, "forward"), /INVALID/);
});

test("stores block slabs, deduplicates loads, and evicts least recently used blocks", async () => {
  const cache = new YuvBlockCache(8);
  let loads = 0;
  const load = async (blockIndex: number) => {
    loads += 1;
    return { blockIndex, startFrameIndex: blockIndex * 2, frameCount: 2, frameByteLength: 2, payload: Buffer.alloc(4, blockIndex) };
  };
  await Promise.all([cache.getOrLoad(0, () => load(0)), cache.getOrLoad(0, () => load(0))]);
  await cache.getOrLoad(1, () => load(1));
  assert.equal(loads, 2);
  assert.deepEqual([...cache.getFrame(0, 2) ?? []], [0, 0]);
  await cache.getOrLoad(2, () => load(2));
  assert.equal(cache.hasBlock(0), true);
  assert.equal(cache.hasBlock(1), false);
  assert.equal(cache.status().evictions, 1);
});

test("touches protected blocks without changing hit and miss counters", async () => {
  const cache = new YuvBlockCache(8);
  const block = (blockIndex: number) => ({
    blockIndex,
    startFrameIndex: blockIndex * 2,
    frameCount: 2,
    frameByteLength: 2,
    payload: Buffer.alloc(4, blockIndex),
  });
  cache.insert(block(0));
  cache.insert(block(1));
  assert.equal(cache.touchBlock(0), true);
  assert.equal(cache.touchBlock(2), false);
  cache.insert(block(2));
  assert.equal(cache.hasBlock(0), true);
  assert.equal(cache.hasBlock(1), false);
  assert.deepEqual(cache.blockIndexes(), [0, 2]);
  assert.deepEqual({ hits: cache.status().hits, misses: cache.status().misses }, { hits: 0, misses: 0 });
});

test("keeps a background block inserted while the same seek load is pending", async () => {
  const cache = new YuvBlockCache(16);
  let finishLoad!: (block: {
    blockIndex: number;
    startFrameIndex: number;
    frameCount: number;
    frameByteLength: number;
    payload: Buffer;
  }) => void;
  const pending = cache.getOrLoad(0, () => new Promise((resolve) => { finishLoad = resolve; }));
  cache.insert({ blockIndex: 0, startFrameIndex: 0, frameCount: 2, frameByteLength: 2, payload: Buffer.alloc(4, 9) });
  finishLoad({ blockIndex: 0, startFrameIndex: 0, frameCount: 2, frameByteLength: 2, payload: Buffer.alloc(4, 1) });
  const block = await pending;
  assert.equal(block.payload[0], 9);
  assert.equal(cache.status().byteLength, 4);
});

test("reserves every block in one batch and resolves foreground reuse as each block arrives", async () => {
  const cache = new YuvBlockCache(8);
  const block = (blockIndex: number) => ({
    blockIndex,
    startFrameIndex: blockIndex * 2,
    frameCount: 2,
    frameByteLength: 2,
    payload: Buffer.alloc(4, blockIndex),
  });
  let releaseSecond!: () => void;
  let duplicateLoads = 0;
  const batch = cache.loadBatch([0, 1], async (accept) => {
    accept(block(0));
    await new Promise<void>((resolve) => { releaseSecond = resolve; });
    accept(block(1));
  });
  assert.equal(cache.hasBlockOrPending(0), true);
  assert.equal(cache.hasBlockOrPending(1), true);
  const foreground = cache.getOrLoad(1, async () => {
    duplicateLoads += 1;
    return block(1);
  });
  releaseSecond();
  assert.equal(await batch, true);
  assert.equal((await foreground).payload[0], 1);
  assert.equal(duplicateLoads, 0);
  assert.deepEqual(cache.blockIndexes(), [0, 1]);
});
