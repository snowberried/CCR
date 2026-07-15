package com.snowberried.ctcinereviewer

import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectContractTest {
    @Test
    fun `pins the approved internal SDK identity and version contract`() {
        assertEquals("0.1.1", BuildConfig.VERSION_NAME)
        assertEquals(2, BuildConfig.VERSION_CODE)
        assertEquals("com.snowberried.ctcinereviewer.internal", BuildConfig.APPLICATION_ID)
        assertEquals(34, AndroidSdkContract.MIN_SDK)
        assertEquals(37, AndroidSdkContract.COMPILE_SDK)
    }
}
