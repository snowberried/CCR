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

    var peakSize: Int = 0
        private set

    var peakByteSize: Long = 0
        private set

    var evictionCount: Long = 0
        private set

    var rejectionCount: Long = 0
        private set

    init {
        require(byteBudget > 0)
    }

    fun recordRequest(index: Int, explicitDirection: Int? = null) {
        require(explicitDirection == null || explicitDirection in -1..1)
        val previous = previousRequestIndex
        direction = explicitDirection ?: when {
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

    fun remove(key: K): Boolean {
        val removed = entries.remove(key) ?: return false
        removeEntry(key, removed)
        return true
    }

    fun put(
        key: K,
        value: V,
        bytes: Long,
        protectedKeys: Set<K> = emptySet(),
        maximumByteSize: Long = byteBudget,
    ): Boolean {
        require(bytes > 0)
        require(maximumByteSize in 0..byteBudget)
        val existing = entries[key]
        if (
            bytes > maximumByteSize ||
            !makeRoomFor(
                bytes = bytes,
                protectedKeys = protectedKeys + key,
                maximumByteSize = maximumByteSize,
                replacedBytes = existing?.bytes ?: 0,
            )
        ) {
            rejectionCount += 1
            return false
        }
        entries.remove(key)?.also { removeEntry(key, it) }
        entries[key] = Entry(value, bytes)
        byteSize += bytes
        peakSize = maxOf(peakSize, entries.size)
        peakByteSize = maxOf(peakByteSize, byteSize)
        return true
    }

    fun clear() {
        entries.forEach { (key, entry) ->
            evictionCount += 1
            onEvict(key, entry.value)
        }
        entries.clear()
        byteSize = 0
        previousRequestIndex = null
        direction = 0
    }

    fun trimToBytes(targetBytes: Long, protectedKeys: Set<K> = emptySet()): Boolean {
        require(targetBytes in 0..byteBudget)
        while (byteSize > targetBytes && entries.isNotEmpty()) {
            val candidates = entries.keys.filterNot(protectedKeys::contains)
            if (candidates.isEmpty()) return false
            val victim = when {
                direction > 0 -> candidates.minBy(frameIndex)
                direction < 0 -> candidates.maxBy(frameIndex)
                else -> candidates.first()
            }
            val removed = entries.remove(victim) ?: continue
            removeEntry(victim, removed)
        }
        return byteSize <= targetBytes
    }

    private fun makeRoomFor(
        bytes: Long,
        protectedKeys: Set<K>,
        maximumByteSize: Long,
        replacedBytes: Long,
    ): Boolean {
        val targetBytes = maximumByteSize - bytes + replacedBytes
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
            removeEntry(victim, removed)
        }
        return byteSize <= targetBytes
    }

    private fun removeEntry(key: K, entry: Entry<V>) {
        byteSize -= entry.bytes
        evictionCount += 1
        onEvict(key, entry.value)
    }
}
