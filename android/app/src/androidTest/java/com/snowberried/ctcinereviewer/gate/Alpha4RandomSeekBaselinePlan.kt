package com.snowberried.ctcinereviewer.gate

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

internal enum class Alpha4SeekCategory(val wireName: String) {
    CACHE_OR_HISTORY_HIT("cache-or-history-hit"),
    AHEAD_OF_CURSOR("ahead-of-cursor"),
    SAME_GOP("same-gop"),
    ADJACENT_GOP("adjacent-gop"),
    FAR_RANDOM("far-random"),
}

internal enum class Alpha4SeekDirection(val wireName: String) {
    STATIONARY("stationary"),
    FORWARD("forward"),
    REVERSE("reverse"),
}

internal data class Alpha4SeekTarget(
    val ordinal: Int,
    val category: Alpha4SeekCategory,
    val setupFrameIndex: Int,
    val targetFrameIndex: Int,
    val direction: Alpha4SeekDirection,
)

/** Pure, deterministic plan. Setup requests are not part of the 50 measured targets. */
internal object Alpha4RandomSeekBaselinePlan {
    const val SCHEMA_VERSION = 1
    const val TARGETS_PER_CATEGORY = 10
    const val TARGET_COUNT = 50
    const val BURST_TARGET_COUNT = 10

    fun create(frameCount: Int, syncFrameIndices: List<Int>, seed: Long): List<Alpha4SeekTarget> {
        require(frameCount >= 300)
        val sync = syncFrameIndices.distinct().sorted().also {
            require(it.size >= 2)
            require(it.firstOrNull() == 0)
            require(it.all { index -> index in 0 until frameCount })
        }
        val random = Lcg(seed)
        val result = mutableListOf<Alpha4SeekTarget>()
        val used = mutableSetOf<Int>()
        val adjacentPairs = buildAdjacentPairs(frameCount, sync)
        val adjacentProtected = adjacentPairs.flatMapTo(mutableSetOf()) { listOf(it.first, it.second) }

        val cacheTargets = mutableListOf(0, frameCount / 2, frameCount - 1)
        while (cacheTargets.size < TARGETS_PER_CATEGORY) {
            val candidate = random.nextInt(frameCount)
            if (candidate !in used && candidate !in cacheTargets && candidate !in adjacentProtected) {
                cacheTargets += candidate
            }
        }
        cacheTargets.forEach { target ->
            check(used.add(target))
            result += target(Alpha4SeekCategory.CACHE_OR_HISTORY_HIT, target, target)
        }

        while (result.count { it.category == Alpha4SeekCategory.AHEAD_OF_CURSOR } < TARGETS_PER_CATEGORY) {
            val gop = random.nextInt(sync.size)
            val start = sync[gop]
            val endExclusive = sync.getOrNull(gop + 1) ?: frameCount
            if (endExclusive - start < MIN_AHEAD_DISTANCE + 1) continue
            val setup = start + random.nextInt(endExclusive - start - MIN_AHEAD_DISTANCE)
            val maximumDistance = minOf(MAX_AHEAD_DISTANCE, endExclusive - 1 - setup)
            val target = setup + MIN_AHEAD_DISTANCE + random.nextInt(maximumDistance - MIN_AHEAD_DISTANCE + 1)
            if (setup !in used && target !in used &&
                setup !in adjacentProtected && target !in adjacentProtected
            ) {
                used += setup
                used += target
                result += target(Alpha4SeekCategory.AHEAD_OF_CURSOR, setup, target)
            }
        }

        while (result.count { it.category == Alpha4SeekCategory.SAME_GOP } < TARGETS_PER_CATEGORY) {
            val gop = random.nextInt(sync.size)
            val start = sync[gop]
            val endExclusive = sync.getOrNull(gop + 1) ?: frameCount
            if (endExclusive - start < 2) continue
            val target = start + random.nextInt(endExclusive - start - 1)
            val maximumDistance = minOf(MAX_SAME_GOP_REVERSE_DISTANCE, endExclusive - 1 - target)
            val setup = target + 1 + random.nextInt(maximumDistance)
            if (setup !in used && target !in used &&
                setup !in adjacentProtected && target !in adjacentProtected
            ) {
                used += setup
                used += target
                result += target(Alpha4SeekCategory.SAME_GOP, setup, target)
            }
        }

        adjacentPairs.take(TARGETS_PER_CATEGORY).forEach { (setup, target) ->
            check(setup !in used && target !in used)
            used += setup
            used += target
            result += target(Alpha4SeekCategory.ADJACENT_GOP, setup, target)
        }

        while (result.count { it.category == Alpha4SeekCategory.FAR_RANDOM } < TARGETS_PER_CATEGORY) {
            val target = random.nextInt(frameCount)
            val setup = if (target < frameCount / 2) target + frameCount / 2 else target - frameCount / 2
            if (setup !in used && target !in used && setup != target) {
                used += setup
                used += target
                result += target(Alpha4SeekCategory.FAR_RANDOM, setup, target)
            }
        }

        check(result.size == TARGET_COUNT)
        check(result.map(Alpha4SeekTarget::targetFrameIndex).distinct().size == TARGET_COUNT)
        val globallyReservedSlots = result.flatMap { target ->
            setOf(target.setupFrameIndex, target.targetFrameIndex)
        }
        check(globallyReservedSlots.distinct().size == globallyReservedSlots.size)
        return result.mapIndexed { ordinal, value -> value.copy(ordinal = ordinal) }.also { targets ->
            targets.forEach { check(categoryMatchesExactlyOnce(it, frameCount, sync)) }
        }
    }

    fun burstTargets(frameCount: Int, seed: Long): List<Int> {
        require(frameCount >= BURST_TARGET_COUNT + 1)
        val random = Lcg(seed xor 0x5EED5EEDL)
        return buildList {
            while (size < BURST_TARGET_COUNT) {
                val candidate = random.nextInt(frameCount)
                if (candidate !in this) add(candidate)
            }
        }
    }

    fun identity(
        frameCount: Int,
        syncFrameIndices: List<Int>,
        seed: Long,
        targets: List<Alpha4SeekTarget>,
    ): String {
        val canonical = buildString {
            append("alpha4-random-seek-baseline-v1\n")
            append(frameCount).append('\n')
            append(syncFrameIndices.distinct().sorted().joinToString(",")).append('\n')
            append(seed).append('\n')
            targets.forEach { target ->
                append(target.ordinal).append('|')
                append(target.category.wireName).append('|')
                append(target.setupFrameIndex).append('|')
                append(target.targetFrameIndex).append('|')
                append(target.direction.wireName).append('\n')
            }
        }
        return MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(StandardCharsets.US_ASCII))
            .joinToString("") { "%02x".format(it) }
    }

    private fun target(category: Alpha4SeekCategory, setup: Int, target: Int) = Alpha4SeekTarget(
        ordinal = -1,
        category = category,
        setupFrameIndex = setup,
        targetFrameIndex = target,
        direction = when {
            target > setup -> Alpha4SeekDirection.FORWARD
            target < setup -> Alpha4SeekDirection.REVERSE
            else -> Alpha4SeekDirection.STATIONARY
        },
    )

    private fun categoryMatchesExactlyOnce(
        target: Alpha4SeekTarget,
        frameCount: Int,
        sync: List<Int>,
    ): Boolean {
        val distance = kotlin.math.abs(target.targetFrameIndex - target.setupFrameIndex)
        val setupSyncOrdinal = sync.indexOfLast { it <= target.setupFrameIndex }.coerceAtLeast(0)
        val targetSyncOrdinal = sync.indexOfLast { it <= target.targetFrameIndex }.coerceAtLeast(0)
        val matches = listOf(
            Alpha4SeekCategory.CACHE_OR_HISTORY_HIT to
                (target.direction == Alpha4SeekDirection.STATIONARY && distance == 0),
            Alpha4SeekCategory.AHEAD_OF_CURSOR to
                (target.direction == Alpha4SeekDirection.FORWARD &&
                distance in MIN_AHEAD_DISTANCE..MAX_AHEAD_DISTANCE &&
                setupSyncOrdinal == targetSyncOrdinal),
            Alpha4SeekCategory.SAME_GOP to
                (target.direction == Alpha4SeekDirection.REVERSE &&
                distance in 1..MAX_SAME_GOP_REVERSE_DISTANCE &&
                setupSyncOrdinal == targetSyncOrdinal),
            Alpha4SeekCategory.ADJACENT_GOP to
                (target.direction == Alpha4SeekDirection.FORWARD &&
                targetSyncOrdinal - setupSyncOrdinal == 1 && distance < frameCount / 2),
            Alpha4SeekCategory.FAR_RANDOM to
                (target.direction != Alpha4SeekDirection.STATIONARY && distance == frameCount / 2),
        ).filter { it.second }
        return matches.size == 1 && matches.single().first == target.category
    }

    private fun buildAdjacentPairs(frameCount: Int, sync: List<Int>): List<Pair<Int, Int>> = buildList {
        var offset = 0
        while (size < TARGETS_PER_CATEGORY) {
            var addedAtOffset = false
            sync.drop(1).forEachIndexed { relativeIndex, boundary ->
                if (size >= TARGETS_PER_CATEGORY) return@forEachIndexed
                val previousBoundary = sync[relativeIndex]
                val nextBoundary = sync.getOrNull(relativeIndex + 2) ?: frameCount
                val setup = boundary - 1 - offset
                val target = boundary + offset
                if (setup >= previousBoundary && target < nextBoundary) {
                    add(setup to target)
                    addedAtOffset = true
                }
            }
            check(addedAtOffset) { "not enough adjacent-GOP targets" }
            offset += 1
        }
    }

    private class Lcg(seed: Long) {
        private var state = seed and 0x7fff_ffffL

        fun nextInt(bound: Int): Int {
            require(bound > 0)
            state = (state * 1_103_515_245L + 12_345L) and 0x7fff_ffffL
            return (state % bound).toInt()
        }
    }

    private const val MIN_AHEAD_DISTANCE = 16
    private const val MAX_AHEAD_DISTANCE = 32
    private const val MAX_SAME_GOP_REVERSE_DISTANCE = 15
}
