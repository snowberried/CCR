package com.snowberried.ctcinereviewer

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectContractTest {
    @Test
    fun `pins the approved internal SDK identity and version contract`() {
        assertEquals("1.0.0", BuildConfig.VERSION_NAME)
        assertEquals(8, BuildConfig.VERSION_CODE)
        assertEquals("com.snowberried.ctcinereviewer.internal", BuildConfig.APPLICATION_ID)
        assertEquals(34, AndroidSdkContract.MIN_SDK)
        assertEquals(37, AndroidSdkContract.COMPILE_SDK)
    }

    @Test
    fun `pins the final launcher name and adaptive icon contract`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val mainStrings = File("src/main/res/values/strings.xml").readText()
        val redesignStrings = File("src/redesign/res/values/strings.xml").readText()
        val adaptiveIcon = File("src/main/res/mipmap-anydpi-v26/ic_launcher.xml").readText()

        assertTrue(manifest.contains("@string/app_name"))
        assertTrue(manifest.contains("@mipmap/ic_launcher"))
        assertTrue(manifest.contains("@mipmap/ic_launcher_round"))
        assertTrue(mainStrings.contains(">CT Cine Reviewer</string>"))
        assertTrue(redesignStrings.contains(">CCR Redesign Dev</string>"))
        assertTrue(adaptiveIcon.contains("@color/ccr_launcher_background"))
        assertTrue(adaptiveIcon.contains("@drawable/ic_launcher_foreground"))
        assertTrue(adaptiveIcon.contains("@drawable/ic_launcher_monochrome"))
        assertTrue(File("src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml").isFile)
        assertTrue(File("src/main/res/drawable/ic_launcher_foreground.xml").isFile)
        assertTrue(File("src/main/res/drawable/ic_launcher_monochrome.xml").isFile)
    }
}
