package com.snowberried.ctcinereviewer

import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectContractTest {
    @Test
    fun `pins the approved spike SDK and version contract`() {
        assertEquals("0.1.0", SpikeBuildContract.VERSION_NAME)
        assertEquals(34, SpikeBuildContract.MIN_SDK)
        assertEquals(37, SpikeBuildContract.COMPILE_SDK)
    }
}
