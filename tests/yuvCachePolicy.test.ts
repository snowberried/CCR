import assert from "node:assert/strict";
import test from "node:test";
import { createI420Layout, chooseI420BlockFrames } from "../src/domain/i420";
import { createYuvCachePolicy } from "../src/domain/yuvCachePolicy";
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
