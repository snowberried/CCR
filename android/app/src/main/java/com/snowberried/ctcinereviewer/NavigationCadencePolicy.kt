package com.snowberried.ctcinereviewer

import kotlin.math.abs

internal enum class NavigationMode {
    DISCRETE_TAP,
    HOLD_FORWARD,
    HOLD_REVERSE,
    TIMELINE_SEEK,
    DIRECT_FRAME_SEEK,
}

internal val NavigationMode.isHold: Boolean
    get() = this == NavigationMode.HOLD_FORWARD || this == NavigationMode.HOLD_REVERSE

internal val NavigationMode.isSupersedingSeek: Boolean
    get() = this == NavigationMode.TIMELINE_SEEK || this == NavigationMode.DIRECT_FRAME_SEEK

/** Caps held-navigation request cadence without creating a target backlog. */
internal class NavigationCadencePolicy(
    private val strideOnePublicationsPerSecond: Int = STRIDE_ONE_PUBLICATIONS_PER_SECOND,
    private val strideFivePublicationsPerSecond: Int = STRIDE_FIVE_PUBLICATIONS_PER_SECOND,
) {
    init {
        require(strideOnePublicationsPerSecond > 0)
        require(strideFivePublicationsPerSecond > 0)
    }

    fun mode(stride: Int): NavigationMode = when (stride) {
        1, 5 -> NavigationMode.HOLD_FORWARD
        -1, -5 -> NavigationMode.HOLD_REVERSE
        else -> error("Unsupported hold stride: $stride")
    }

    fun publicationsPerSecond(stride: Int): Int = when (abs(stride)) {
        1 -> strideOnePublicationsPerSecond
        5 -> strideFivePublicationsPerSecond
        else -> error("Unsupported hold stride: $stride")
    }

    fun intervalNanos(stride: Int): Long = NANOS_PER_SECOND / publicationsPerSecond(stride)

    fun nextAcceptanceNotBeforeNanos(
        stride: Int,
        acceptedAtNanos: Long,
        publishedAtNanos: Long,
    ): Long {
        val interval = intervalNanos(stride)
        val cadenceBoundary = if (acceptedAtNanos > Long.MAX_VALUE - interval) {
            Long.MAX_VALUE
        } else {
            acceptedAtNanos + interval
        }
        return maxOf(publishedAtNanos, cadenceBoundary)
    }

    companion object {
        const val STRIDE_ONE_PUBLICATIONS_PER_SECOND = 15
        const val STRIDE_FIVE_PUBLICATIONS_PER_SECOND = 10
        private const val NANOS_PER_SECOND = 1_000_000_000L
    }
}
