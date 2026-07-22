package com.snowberried.ctcinereviewer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PublicationTailMetricsTest {
    @Test
    fun `uses population CV and nearest-rank tail percentiles`() {
        val values = (1L..200L).map { it * 1_000L }

        val metrics = PublicationTailCalculator.calculate(values, cadenceNs = 100_000L)

        assertEquals(200, metrics.sampleCount)
        assertEquals(574_471L, metrics.coefficientOfVariationPpm)
        assertEquals(100_000L, metrics.p50Ns)
        assertEquals(190_000L, metrics.p95Ns)
        assertEquals(198_000L, metrics.p99Ns)
        assertEquals(199_000L, metrics.p995Ns)
        assertEquals(200_000L, metrics.maxNs)
    }

    @Test
    fun `constant cadence has zero variation and no tail breaches`() {
        val metrics = PublicationTailCalculator.calculate(
            intervalsNs = List(10) { 66_666_666L },
            cadenceNs = 66_666_666L,
        )

        assertEquals(0L, metrics.coefficientOfVariationPpm)
        assertEquals(0, metrics.overOnePointFiveCadenceCount)
        assertEquals(0, metrics.overTwoCadenceCount)
        assertEquals(0, metrics.longestConsecutiveOverOnePointFiveCadenceCount)
    }

    @Test
    fun `strict cadence multiples exclude equality and preserve the longest run`() {
        val cadence = 100L
        val metrics = PublicationTailCalculator.calculate(
            intervalsNs = listOf(150L, 151L, 201L, 160L, 100L, 151L),
            cadenceNs = cadence,
        )

        assertEquals(4, metrics.overOnePointFiveCadenceCount)
        assertEquals(1, metrics.overTwoCadenceCount)
        assertEquals(3, metrics.longestConsecutiveOverOnePointFiveCadenceCount)
    }

    @Test
    fun `rejects incomplete or invalid interval evidence`() {
        assertThrows(IllegalArgumentException::class.java) {
            PublicationTailCalculator.calculate(emptyList(), 1L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PublicationTailCalculator.calculate(listOf(0L), 1L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PublicationTailCalculator.calculate(listOf(1L), 0L)
        }
    }
}
