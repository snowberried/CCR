package com.snowberried.ctcinereviewer.cache

class DirectionalByteCache<K, V>(
    private val byteBudget: Long,
    private val frameIndex: (K) -> Int,
    private val onEvict: (K, V) -> Unit = { _, _ -> },
) {
    private data class Entry<V>(val value: V, val bytes: Long)

    private val entries = LinkedHashMap<K, Entry<V>>(16, 0.75f, true)
    private var previousRequestIndex: Int? = null
    private var direction = 0

    var byteSize: Long = 0
        private set

    var hitCount: Long = 0
        private set

    var missCount: Long = 0
        private set

    val size: Int get() = entries.size

    init {
        require(byteBudget > 0)
    }

    fun recordRequest(index: Int) {
        val previous = previousRequestIndex
        direction = when {
            previous == null || index == previous -> direction
            index > previous -> 1
            else -> -1
        }
        previousRequestIndex = index
    }

    fun get(key: K): V? {
        val entry = entries[key]
        if (entry == null) missCount += 1 else hitCount += 1
        return entry?.value
    }

    fun containsKey(key: K): Boolean = entries.containsKey(key)

    fun put(
        key: K,
        value: V,
        bytes: Long,
        protectedKeys: Set<K> = emptySet(),
        maximumByteSize: Long = byteBudget,
    ): Boolean {
        require(bytes > 0)
        require(maximumByteSize in 0..byteBudget)
        entries.remove(key)?.also {
            byteSize -= it.bytes
            onEvict(key, it.value)
        }
        if (bytes > maximumByteSize || !makeRoomFor(bytes, protectedKeys, maximumByteSize)) {
            return false
        }
        entries[key] = Entry(value, bytes)
        byteSize += bytes
        return true
    }

    fun clear() {
        entries.forEach { (key, entry) -> onEvict(key, entry.value) }
        entries.clear()
        byteSize = 0
        previousRequestIndex = null
        direction = 0
    }

    fun trimToBytes(targetBytes: Long) {
        require(targetBytes >= 0)
        while (byteSize > targetBytes && entries.isNotEmpty()) {
            val victim = when {
                direction > 0 -> entries.keys.minBy(frameIndex)
                direction < 0 -> entries.keys.maxBy(frameIndex)
                else -> entries.keys.first()
            }
            val removed = entries.remove(victim) ?: continue
            byteSize -= removed.bytes
            onEvict(victim, removed.value)
        }
    }

    private fun makeRoomFor(bytes: Long, protectedKeys: Set<K>, maximumByteSize: Long): Boolean {
        val targetBytes = maximumByteSize - bytes
        val reclaimableBytes = entries
            .filterKeys { it !in protectedKeys }
            .values
            .sumOf { it.bytes }
        if (byteSize - reclaimableBytes > targetBytes) return false
        while (byteSize > targetBytes && entries.isNotEmpty()) {
            val candidates = entries.keys.filterNot(protectedKeys::contains)
            if (candidates.isEmpty()) return false
            val victim = when {
                direction > 0 -> candidates.minBy(frameIndex)
                direction < 0 -> candidates.maxBy(frameIndex)
                else -> candidates.first()
            }
            val removed = entries.remove(victim) ?: continue
            byteSize -= removed.bytes
            onEvict(victim, removed.value)
        }
        return byteSize <= targetBytes
    }
}
