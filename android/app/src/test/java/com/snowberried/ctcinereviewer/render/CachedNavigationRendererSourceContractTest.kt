package com.snowberried.ctcinereviewer.render

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CachedNavigationRendererSourceContractTest {
    private val source = File("src/main/java/com/snowberried/ctcinereviewer/render/EglFrameRenderer.kt").readText()
    private val sessionSource =
        File("src/main/java/com/snowberried/ctcinereviewer/media/ExactFrameSession.kt").readText()

    @Test
    fun `cached navigation enqueue is non blocking and owns no EGL work on caller`() {
        val enqueue = source
            .substringAfter("internal fun enqueueCachedNavigation(")
            .substringBefore("private fun executeCachedNavigation(")

        assertTrue(enqueue.contains("handler.post"))
        assertFalse(enqueue.contains("callOnRenderer"))
        assertFalse(enqueue.contains("CountDownLatch"))
        assertFalse(enqueue.contains(".await("))
        assertFalse(enqueue.contains("drawTextureToWindow"))
        assertFalse(enqueue.contains("eglSwapBuffers"))
    }

    @Test
    fun `renderer execution uses full key and rechecks generations at publication`() {
        val execute = source
            .substringAfter("private fun executeCachedNavigation(")
            .substringBefore("private fun contextIsCurrent(")

        assertTrue(execute.contains("val key = request.expectedKey"))
        assertTrue(execute.contains("cache.get(key)"))
        assertTrue(execute.contains("key.ptsUs"))
        assertTrue(execute.contains("source !in input.allowedSources"))
        assertTrue(execute.contains("publicationGate.isCurrent(request.token)"))
        assertTrue(execute.contains("publish(request, cached.timestampNs)"))
        assertTrue(execute.contains("contextIsCurrent(input, contextCurrent)"))
    }

    @Test
    fun `file surface cancellation and close drain queued callbacks`() {
        val beginFile = source.substringAfter("fun beginFile(").substringBefore("fun configureFrame(")
        val cancel = source.substringAfter("fun cancelImmediately()").substringBefore("internal fun prefetchSnapshot")
        val close = source.substringAfter("override fun close()").substringBefore("private fun initializeGl")
        val releaseGl = source.substringAfter("private fun releaseGl()").substringBefore("private fun <T> callOnRenderer")

        assertTrue(beginFile.contains("completeCachedNavigationCommands(\"FILE_CHANGED\")"))
        assertTrue(cancel.contains("completeCachedNavigationCommands(\"RENDERER_CANCELLED\")"))
        assertTrue(close.contains("completeCachedNavigationCommands(\"RENDERER_CLOSED\")"))
        assertTrue(releaseGl.contains("completeCachedNavigationCommands(\"SURFACE_RELEASED\")"))
    }

    @Test
    fun `rolling texture becomes a reverse source only after engine commit`() {
        val retained = source.substringAfter("val committedReverseWindowKeys = if (")
            .substringBefore("private fun publish(")
        val commit = retained.indexOf("runCatching(handle.commitReverseWindowKeys)")
        val expose = retained.indexOf("reverseWindowKeys += exposed")
        val acknowledge = retained.indexOf("handle.complete(RenderAck(AckStatus.CACHED")

        assertTrue(commit >= 0)
        assertTrue(expose > commit)
        assertTrue(acknowledge > expose)
        assertTrue(source.substringAfter("private fun protectedCacheKeys()").contains("addAll(stagedReverseWindowKeys)"))

        val refill = sessionSource.substringAfter("private fun runReverseRefillSliceInternal()")
            .substringBefore("private fun completeReverseRefillGeneration")
        assertTrue(refill.contains("commitReverseWindowKeys ="))
        assertTrue(refill.contains("reverseWindowEngine.stageRefillTarget("))
        assertFalse(
            refill.substringAfter("if (ack.status != EglFrameRenderer.AckStatus.CACHED)")
                .contains("reverseWindowEngine.stageRefillTarget("),
        )
    }

    @Test
    fun `refill exception boundary preserves actor and forces codec recreation`() {
        val boundary = sessionSource.substringAfter("private fun runReverseRefillSlice()")
            .substringBefore("private fun runReverseRefillSliceInternal()")

        assertTrue(boundary.contains("try"))
        assertTrue(boundary.contains("catch (_: Throwable)"))
        assertTrue(boundary.contains("surfaceChanged.set(true)"))
        assertTrue(boundary.contains("forwardSequentialState.invalidate()"))
        assertTrue(boundary.contains("invalidateReverseWindow(ReverseWindowFallbackReason.CODEC_ERROR)"))
    }
}
