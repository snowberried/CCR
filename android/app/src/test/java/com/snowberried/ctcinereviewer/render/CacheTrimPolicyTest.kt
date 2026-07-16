package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertEquals
import org.junit.Test

class CacheTrimPolicyTest {
    @Test
    fun cacheIsReturnedInModerateLowAndCriticalSteps() {
        val budget = 1_000L

        assertEquals(1_000L, cacheTargetBytes(0, budget))
        assertEquals(750L, cacheTargetBytes(5, budget))
        assertEquals(500L, cacheTargetBytes(10, budget))
        assertEquals(0L, cacheTargetBytes(15, budget))
        assertEquals(0L, cacheTargetBytes(20, budget))
    }
}
