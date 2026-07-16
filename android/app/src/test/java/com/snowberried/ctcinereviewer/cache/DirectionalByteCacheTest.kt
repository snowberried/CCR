package com.snowberried.ctcinereviewer.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DirectionalByteCacheTest {
    @Test
    fun `holds a byte cap and evicts behind the current direction`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(12, { it }) { _, value -> evicted += value }
        cache.recordRequest(1)
        cache.put(1, "one", 4)
        cache.recordRequest(2)
        cache.put(2, "two", 4)
        cache.recordRequest(3)
        cache.put(3, "three", 4)
        cache.recordRequest(4)
        cache.put(4, "four", 4)

        assertEquals(12, cache.byteSize)
        assertNull(cache.get(1))
        assertEquals(listOf("one"), evicted)
        assertEquals(3, cache.peakSize)
        assertEquals(1L, cache.evictionCount)
        assertEquals(0L, cache.rejectionCount)
    }

    @Test
    fun `does not retain an entry larger than its byte budget`() {
        val cache = DirectionalByteCache<Int, String>(8, { it })
        cache.put(0, "large", 16)
        assertEquals(0, cache.byteSize)
        assertEquals(0, cache.size)
        assertEquals(1L, cache.rejectionCount)
    }

    @Test
    fun `trim releases entries toward a requested byte target`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(16, { it }) { _, value -> evicted += value }
        cache.put(1, "one", 4)
        cache.put(2, "two", 4)
        cache.put(3, "three", 4)

        cache.trimToBytes(4)

        assertEquals(4L, cache.byteSize)
        assertEquals(1, cache.size)
        assertEquals(2, evicted.size)
        cache.trimToBytes(0)
        assertEquals(0L, cache.byteSize)
    }

    @Test
    fun `protected published entry rejects prefetch instead of evicting the screen`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(8, { it }) { _, value -> evicted += value }
        assertEquals(true, cache.put(1, "published", 4))

        val retained = cache.put(2, "prefetch", 8, protectedKeys = setOf(1))

        assertEquals(false, retained)
        assertEquals("published", cache.get(1))
        assertEquals(4L, cache.byteSize)
        assertEquals(emptyList<String>(), evicted)
        assertEquals(1L, cache.rejectionCount)
    }

    @Test
    fun `cache never grows past its byte budget`() {
        val cache = DirectionalByteCache<Int, String>(32, { it })
        repeat(1_000) { index ->
            cache.recordRequest(index)
            cache.put(index, index.toString(), 4)
            assertEquals(true, cache.byteSize <= 32L)
        }
        assertEquals(8, cache.size)
    }

    @Test
    fun `prefetch admission can reserve part of the cache budget`() {
        val cache = DirectionalByteCache<Int, String>(16, { it })
        cache.put(1, "published", 4)
        cache.put(2, "old", 4)

        assertEquals(true, cache.put(3, "prefetch", 4, protectedKeys = setOf(1), maximumByteSize = 8))
        assertEquals(8L, cache.byteSize)
        assertEquals("published", cache.get(1))
        assertEquals("prefetch", cache.get(3))
    }

    @Test
    fun `explicit reverse intent evicts the far forward frame after coalescing`() {
        val cache = DirectionalByteCache<Int, String>(12, { it })
        cache.recordRequest(0)
        cache.put(27, "behind-two", 4)
        cache.put(28, "behind-one", 4)
        cache.put(30, "ahead", 4)

        // The reverse target is numerically above the last published request. Inference alone
        // would call this forward and evict frame 27 while admitting the reverse prefetch.
        cache.recordRequest(index = 29, explicitDirection = -1)
        cache.put(26, "reverse-prefetch", 4)

        assertEquals("reverse-prefetch", cache.get(26))
        assertEquals("behind-two", cache.get(27))
        assertEquals("behind-one", cache.get(28))
        assertNull(cache.get(30))
    }

    @Test
    fun `clear replacement and explicit removal count each resident release exactly once`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(12, { it }) { _, value -> evicted += value }
        cache.put(1, "one", 4)
        cache.put(1, "replacement", 4)
        cache.put(2, "two", 4)
        assertEquals(true, cache.remove(1))
        assertEquals(false, cache.remove(1))
        cache.clear()

        assertEquals(listOf("one", "replacement", "two"), evicted)
        assertEquals(3L, cache.evictionCount)
        assertEquals(2, cache.peakSize)
        assertEquals(0, cache.size)
        assertEquals(0L, cache.byteSize)
    }
}
