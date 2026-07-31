package com.snowberried.ctcinereviewer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationGestureGateTest {
    @Test
    fun `ending gesture rejects a callback that was scheduled before release`() {
        val gate = NavigationGestureGate()
        val generation = gate.begin()

        assertTrue(gate.accepts(generation))
        gate.end(generation)

        assertFalse(gate.accepts(generation))
    }

    @Test
    fun `new press invalidates the previous monotonic generation`() {
        val gate = NavigationGestureGate()
        val first = gate.begin()
        val second = gate.begin()

        assertNotEquals(first, second)
        assertFalse(gate.accepts(first))
        assertTrue(gate.accepts(second))
    }

    @Test
    fun `lifecycle invalidation rejects the active generation`() {
        val gate = NavigationGestureGate()
        val generation = gate.begin()

        gate.invalidate()

        assertFalse(gate.accepts(generation))
    }
}
