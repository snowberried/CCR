package com.snowberried.ctcinereviewer.cache

class DirectionalByteCache<K, V>(
    private val byteBudget: Long,
    private val frameIndex: (K) -> Int,
    private val onEvict: (V) -> Unit = {},
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

    fun put(key: K, value: V, bytes: Long) {
        require(bytes > 0)
        entries.remove(key)?.also {
            byteSize -= it.bytes
            onEvict(it.value)
        }
        entries[key] = Entry(value, bytes)
        byteSize += bytes
        evictToBudget(key)
    }

    fun clear() {
        entries.values.forEach { onEvict(it.value) }
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
            onEvict(removed.value)
        }
    }

    private fun evictToBudget(protectedKey: K) {
        while (byteSize > byteBudget && entries.isNotEmpty()) {
            val candidates = entries.keys.filter { it != protectedKey }.ifEmpty { entries.keys.toList() }
            val victim = when {
                direction > 0 -> candidates.minBy(frameIndex)
                direction < 0 -> candidates.maxBy(frameIndex)
                else -> candidates.first()
            }
            val removed = entries.remove(victim) ?: continue
            byteSize -= removed.bytes
            onEvict(removed.value)
        }
    }
}
