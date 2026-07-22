package com.snowberried.ctcinereviewer

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainThreadContractTest {
    @Test
    fun `view model main entry points do not perform media EGL readback or blocking waits`() {
        val source = source("main/java/com/snowberried/ctcinereviewer/ViewerViewModel.kt")
        for (forbidden in listOf(
            "CountDownLatch",
            ".await(",
            ".join(",
            "openFileDescriptor",
            "MediaCodec",
            "glReadPixels",
            "session.open(",
            "session.requestFrame(",
            "session.cancel()",
        )) assertFalse(forbidden, source.contains(forbidden))
        assertTrue(source.contains("session.tryOpen("))
        assertTrue(source.contains("session.tryRequestFrame("))
        assertTrue(source.contains("session.tryCancel()"))
    }

    @Test
    fun `session and renderer close paths are asynchronous to their callers`() {
        val sessionClose = source("main/java/com/snowberried/ctcinereviewer/media/ExactFrameSession.kt")
            .substringAfter("override fun close()")
            .substringBefore("private fun openInternal")
        val rendererClose = source("main/java/com/snowberried/ctcinereviewer/render/EglFrameRenderer.kt")
            .substringAfter("override fun close()")
            .substringBefore("private fun initializeGl")
        for (closePath in listOf(sessionClose, rendererClose)) {
            assertFalse(closePath.contains(".await("))
            assertFalse(closePath.contains(".join("))
        }
        assertTrue(sessionClose.contains("renderer.cancelImmediately()"))
        assertTrue(rendererClose.contains("removeCallbacksAndMessages(null)"))
        assertTrue(rendererClose.contains("postAtFrontOfQueue"))
    }

    @Test
    fun `debug strict mode logs codes only`() {
        val source = source("debug/java/com/snowberried/ctcinereviewer/DebugApplication.kt")
        assertTrue(source.contains("detectDiskReads()"))
        assertTrue(source.contains("detectDiskWrites()"))
        assertTrue(source.contains("Log.w(\"CcrStrictMode\", code)"))
        assertFalse(source.contains("Log.w(\"CcrStrictMode\", violation"))
        assertFalse(source.contains("printStackTrace"))
    }

    @Test
    fun `batched codec supersede stages are classified as expected stale results`() {
        val source = source("androidTest/java/com/snowberried/ctcinereviewer/gate/S24FrameAccuracyTest.kt")
        val stages = source.substringAfter("EXPECTED_SUPERSEDED_STAGES = setOf(")
            .substringBefore(")")
        assertTrue(stages.contains("\"input-batch\""))
        assertTrue(stages.contains("\"output-batch\""))
    }

    private fun source(relative: String): String = File("src/$relative").readText()
}
