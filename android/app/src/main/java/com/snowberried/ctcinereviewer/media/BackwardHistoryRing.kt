package com.snowberried.ctcinereviewer.media

internal data class BackwardHistorySnapshot(
    val capacity: Int,
    val depth: Int,
    val frameBytes: Long,
    val keys: List<FrameKey>,
)

/** A key-only view over textures owned by the renderer cache. */
internal class BackwardHistoryRing(private val cacheBudgetBytes: Long) {
    private val keys = ArrayDeque<FrameKey>()
    private var frameBytes = 0L
    private var capacity = 0

    init {
        require(cacheBudgetBytes > 0)
    }

    fun configure(
        canonicalFrameBytes: Long,
        availableBudgetBytes: Long = cacheBudgetBytes,
        protectedTextureCount: Int = 2,
    ) {
        require(canonicalFrameBytes >= 0)
        require(availableBudgetBytes in 0..cacheBudgetBytes)
        require(protectedTextureCount >= 0)
        frameBytes = canonicalFrameBytes
        val totalTextureCapacity = if (canonicalFrameBytes == 0L) {
            0
        } else {
            (availableBudgetBytes / canonicalFrameBytes).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }
        capacity = (totalTextureCapacity - protectedTextureCount).coerceAtLeast(0)
        trim()
    }

    fun recordPublished(previous: FrameKey?, current: FrameKey) {
        keys.remove(current)
        if (previous != null && previous != current) {
            keys.remove(previous)
            keys.addLast(previous)
        }
        trim()
    }

    fun remove(key: FrameKey): Boolean = keys.remove(key)

    fun contains(key: FrameKey): Boolean = key in keys

    fun clear() = keys.clear()

    fun reset() {
        keys.clear()
        frameBytes = 0
        capacity = 0
    }

    fun snapshot(): BackwardHistorySnapshot = BackwardHistorySnapshot(
        capacity = capacity,
        depth = keys.size,
        frameBytes = frameBytes,
        keys = keys.toList(),
    )

    private fun trim() {
        while (keys.size > capacity) keys.removeFirst()
    }
}
