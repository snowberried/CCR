package com.snowberried.ctcinereviewer

import org.junit.Assert.assertEquals
import org.junit.Test

class NavigationCadencePolicyTest {
    private val policy = NavigationCadencePolicy()

    @Test
    fun `forward and reverse use the same cadence for the same stride`() {
        assertEquals(policy.intervalNanos(1), policy.intervalNanos(-1))
        assertEquals(policy.intervalNanos(5), policy.intervalNanos(-5))
        assertEquals(15, policy.publicationsPerSecond(1))
        assertEquals(10, policy.publicationsPerSecond(5))
    }

    @Test
    fun `next acceptance waits only for the unfinished cadence interval`() {
        val acceptedAt = 1_000_000_000L
        val fastPublication = acceptedAt + 10_000_000L
        assertEquals(
            acceptedAt + policy.intervalNanos(1),
            policy.nextAcceptanceNotBeforeNanos(1, acceptedAt, fastPublication),
        )

        val slowPublication = acceptedAt + policy.intervalNanos(1) + 1
        assertEquals(
            slowPublication,
            policy.nextAcceptanceNotBeforeNanos(-1, acceptedAt, slowPublication),
        )
    }

    @Test
    fun `navigation modes distinguish direction and direct seek`() {
        assertEquals(NavigationMode.HOLD_FORWARD, policy.mode(1))
        assertEquals(NavigationMode.HOLD_REVERSE, policy.mode(-5))
        assertEquals(true, NavigationMode.HOLD_FORWARD.isHold)
        assertEquals(false, NavigationMode.DIRECT_FRAME_SEEK.isHold)
    }
}
