package com.snowberried.ctcinereviewer.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DirectionalByteCacheTest {
    @Test
    fun `holds a byte cap and evicts behind the current direction`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(12, { it }, evicted::add)
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
    }

    @Test
    fun `does not retain an entry larger than its byte budget`() {
        val cache = DirectionalByteCache<Int, String>(8, { it })
        cache.put(0, "large", 16)
        assertEquals(0, cache.byteSize)
        assertEquals(0, cache.size)
    }

    @Test
    fun `trim releases entries toward a requested byte target`() {
        val evicted = mutableListOf<String>()
        val cache = DirectionalByteCache<Int, String>(16, { it }, evicted::add)
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
}
