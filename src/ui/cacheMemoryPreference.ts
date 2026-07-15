import {
  parseCacheMemoryPreference,
  type CacheMemoryPreference,
} from "../domain/cacheMemory";

export const DEFAULT_CACHE_MEMORY_PREFERENCE: CacheMemoryPreference = "auto";
export const CACHE_MEMORY_PREFERENCE_STORAGE_KEY = "ccr.cacheMemoryGiB.v1";

export type CacheMemoryPreferenceStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
};

export function loadCacheMemoryPreference(storage: CacheMemoryPreferenceStorage | null): CacheMemoryPreference {
  if (!storage) return DEFAULT_CACHE_MEMORY_PREFERENCE;
  try {
    return parseCacheMemoryPreference(storage.getItem(CACHE_MEMORY_PREFERENCE_STORAGE_KEY))
      ?? DEFAULT_CACHE_MEMORY_PREFERENCE;
  } catch {
    return DEFAULT_CACHE_MEMORY_PREFERENCE;
  }
}

export function saveCacheMemoryPreference(
  storage: CacheMemoryPreferenceStorage | null,
  preference: CacheMemoryPreference,
): boolean {
  if (!storage || parseCacheMemoryPreference(preference) === null) return false;
  try {
    storage.setItem(CACHE_MEMORY_PREFERENCE_STORAGE_KEY, String(preference));
    return true;
  } catch {
    return false;
  }
}
