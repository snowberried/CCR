package com.snowberried.ctcinereviewer

/**
 * Accepts navigation steps only from the currently pressed gesture.
 *
 * The UI also checks its local pressed state, but this second gate keeps a callback that was
 * already scheduled before release from changing requestedFrameIndex after release is handled.
 */
internal class NavigationGestureGate {
    private var lastGeneration = 0L
    private var activeGeneration: Long? = null

    fun begin(): Long {
        check(lastGeneration < Long.MAX_VALUE) { "Navigation gesture generation exhausted" }
        return (++lastGeneration).also { activeGeneration = it }
    }

    fun accepts(generation: Long): Boolean = activeGeneration == generation

    fun end(generation: Long) {
        if (activeGeneration == generation) activeGeneration = null
    }

    fun invalidate() {
        activeGeneration = null
    }
}
