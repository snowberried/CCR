package com.snowberried.ctcinereviewer

import kotlin.math.ceil
import kotlin.math.roundToLong
import kotlin.math.sqrt

/** Pure, deterministic publication-interval tail statistics used by the S24 harness. */
internal data class PublicationTailMetrics(
    val sampleCount: Int,
    val coefficientOfVariationPpm: Long,
    val p50Ns: Long,
    val p95Ns: Long,
    val p99Ns: Long,
    val p995Ns: Long,
    val maxNs: Long,
    val overOnePointFiveCadenceCount: Int,
    val overTwoCadenceCount: Int,
    val longestConsecutiveOverOnePointFiveCadenceCount: Int,
)

internal object PublicationTailCalculator {
    fun calculate(intervalsNs: List<Long>, cadenceNs: Long): PublicationTailMetrics {
        require(cadenceNs > 0L) { "cadenceNs must be positive" }
        require(intervalsNs.isNotEmpty()) { "publication intervals must not be empty" }
        require(intervalsNs.all { it > 0L }) { "publication intervals must be positive" }
        require(cadenceNs <= Long.MAX_VALUE / 3L) { "cadenceNs is too large" }
        require(intervalsNs.all { it <= Long.MAX_VALUE / 2L }) {
            "publication interval is too large"
        }

        val sorted = intervalsNs.sorted()
        val mean = intervalsNs.sumOf(Long::toDouble) / intervalsNs.size
        val variance = intervalsNs.sumOf { interval ->
            val delta = interval - mean
            delta * delta
        } / intervalsNs.size
        val cvPpm = (sqrt(variance) / mean * 1_000_000.0).roundToLong()

        var overOnePointFiveCount = 0
        var overTwoCount = 0
        var currentOverOnePointFiveRun = 0
        var longestOverOnePointFiveRun = 0
        intervalsNs.forEach { interval ->
            if (interval * 2L > cadenceNs * 3L) {
                overOnePointFiveCount += 1
                currentOverOnePointFiveRun += 1
                longestOverOnePointFiveRun = maxOf(
                    longestOverOnePointFiveRun,
                    currentOverOnePointFiveRun,
                )
            } else {
                currentOverOnePointFiveRun = 0
            }
            if (interval * 2L > cadenceNs * 4L) overTwoCount += 1
        }

        return PublicationTailMetrics(
            sampleCount = sorted.size,
            coefficientOfVariationPpm = cvPpm,
            p50Ns = sorted.nearestRank(0.50),
            p95Ns = sorted.nearestRank(0.95),
            p99Ns = sorted.nearestRank(0.99),
            p995Ns = sorted.nearestRank(0.995),
            maxNs = sorted.last(),
            overOnePointFiveCadenceCount = overOnePointFiveCount,
            overTwoCadenceCount = overTwoCount,
            longestConsecutiveOverOnePointFiveCadenceCount = longestOverOnePointFiveRun,
        )
    }

    private fun List<Long>.nearestRank(fraction: Double): Long {
        require(fraction > 0.0 && fraction <= 1.0) { "fraction must be in (0, 1]" }
        val index = (ceil(size * fraction).toInt() - 1).coerceIn(0, lastIndex)
        return this[index]
    }
}
