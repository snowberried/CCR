import assert from "node:assert/strict";
import test from "node:test";
import {
  CACHE_MEMORY_GIB_BYTES,
  manualCacheMemoryOptions,
  parseCacheMemoryPreference,
  resolveCacheMemoryPreference,
} from "../src/domain/cacheMemory";
import {
  CACHE_MEMORY_PREFERENCE_STORAGE_KEY,
  DEFAULT_CACHE_MEMORY_PREFERENCE,
  loadCacheMemoryPreference,
  saveCacheMemoryPreference,
} from "../src/ui/cacheMemoryPreference";

const gib = (value: number) => value * CACHE_MEMORY_GIB_BYTES;

test("offers manual cache limits from the detected PC memory tier", () => {
  assert.deepEqual(manualCacheMemoryOptions(gib(7)), []);
  assert.deepEqual(manualCacheMemoryOptions(gib(8)), [2]);
  assert.deepEqual(manualCacheMemoryOptions(gib(16)), [2, 4]);
  assert.deepEqual(manualCacheMemoryOptions(gib(24)), [2, 4, 6]);
  assert.deepEqual(manualCacheMemoryOptions(gib(31.6)), [2, 4, 6, 8]);
  assert.deepEqual(manualCacheMemoryOptions(gib(32)), [2, 4, 6, 8]);
});

test("limits a manual cache by current available memory without preallocating it", () => {
  assert.deepEqual(resolveCacheMemoryPreference({
    preference: 8,
    totalMemoryBytes: gib(32),
    availableMemoryBytes: gib(20),
  }), {
    preference: 8,
    cacheBudgetBytes: gib(8),
  });

  assert.deepEqual(resolveCacheMemoryPreference({
    preference: "8",
    totalMemoryBytes: gib(32),
    availableMemoryBytes: gib(10),
  }), {
    preference: 8,
    cacheBudgetBytes: gib(5),
  });
});

test("falls back to automatic policy for unsupported or unsafe manual limits", () => {
  assert.deepEqual(resolveCacheMemoryPreference({
    preference: 8,
    totalMemoryBytes: gib(16),
    availableMemoryBytes: gib(12),
  }), {
    preference: "auto",
  });

  const lowAvailable = resolveCacheMemoryPreference({
    preference: 2,
    totalMemoryBytes: gib(8),
    availableMemoryBytes: 128 * 1024 ** 2,
  });
  assert.equal(lowAvailable.preference, 2);
  assert.equal(lowAvailable.cacheBudgetBytes, undefined);
});

test("validates and persists the cache memory preference", () => {
  assert.equal(parseCacheMemoryPreference("auto"), "auto");
  assert.equal(parseCacheMemoryPreference("4"), 4);
  assert.equal(parseCacheMemoryPreference(6), 6);
  assert.equal(parseCacheMemoryPreference(3), null);
  assert.equal(parseCacheMemoryPreference(""), null);

  const values = new Map<string, string>();
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value); },
  };
  assert.equal(loadCacheMemoryPreference(storage), DEFAULT_CACHE_MEMORY_PREFERENCE);
  assert.equal(saveCacheMemoryPreference(storage, 6), true);
  assert.equal(values.get(CACHE_MEMORY_PREFERENCE_STORAGE_KEY), "6");
  assert.equal(loadCacheMemoryPreference(storage), 6);
  values.set(CACHE_MEMORY_PREFERENCE_STORAGE_KEY, "invalid");
  assert.equal(loadCacheMemoryPreference(storage), DEFAULT_CACHE_MEMORY_PREFERENCE);
});
