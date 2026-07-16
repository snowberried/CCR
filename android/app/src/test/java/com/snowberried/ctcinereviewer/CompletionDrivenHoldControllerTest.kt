package com.snowberried.ctcinereviewer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionDrivenHoldControllerTest {
    @Test
    fun `plus and minus one and five complete one hundred published targets`() {
        assertEquals(100, publishedTargets(stride = 1, start = 100, frameCount = 1_000).size)
        assertEquals(100, publishedTargets(stride = 5, start = 100, frameCount = 1_000).size)
        assertEquals(100, publishedTargets(stride = -1, start = 500, frameCount = 1_000).size)
        assertEquals(100, publishedTargets(stride = -5, start = 600, frameCount = 1_000).size)
    }

    @Test
    fun `slow or delayed publisher cannot create a second outstanding target`() {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 1, fileGeneration = 7, stride = 1)
        val first = requireNotNull(controller.reserveNext(10, 100, foregroundRequestInFlight = false))
        assertTrue(controller.markAccepted(first, requestGeneration = 11))

        repeat(100) {
            assertNull(controller.reserveNext(10, 100, foregroundRequestInFlight = false))
            assertEquals(1, controller.outstandingTargetCount)
        }

        controller.complete(7, 11, published = true)
        assertEquals(0, controller.outstandingTargetCount)
        assertEquals(12, controller.reserveNext(11, 100, foregroundRequestInFlight = false)?.frameIndex)
    }

    @Test
    fun `stale and error result stop traversal`() {
        for (requestGeneration in listOf(21L, 22L)) {
            val controller = CompletionDrivenHoldController()
            controller.begin(gestureGeneration = 2, fileGeneration = 8, stride = 1)
            val target = requireNotNull(controller.reserveNext(5, 100, foregroundRequestInFlight = false))
            assertTrue(controller.markAccepted(target, requestGeneration))

            controller.complete(8, requestGeneration, published = false)

            assertEquals(0, controller.outstandingTargetCount)
            assertNull(controller.reserveNext(5, 100, foregroundRequestInFlight = false))
        }
    }

    @Test
    fun `release just before publish allows current result but creates no next target`() {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 3, fileGeneration = 9, stride = 1)
        val target = requireNotNull(controller.reserveNext(20, 100, foregroundRequestInFlight = false))
        assertTrue(controller.markAccepted(target, requestGeneration = 31))

        controller.end(3)
        controller.complete(9, 31, published = true)

        assertEquals(0, controller.outstandingTargetCount)
        assertNull(controller.reserveNext(21, 100, foregroundRequestInFlight = false))
    }

    @Test
    fun `benchmark hold stops exactly at accepted frame thirty`() {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 30, fileGeneration = 9, stride = 1)
        var displayed = 0

        for (requestGeneration in 1L..30L) {
            val target = requireNotNull(controller.reserveNext(displayed, 100, foregroundRequestInFlight = false))
            assertTrue(controller.markAccepted(target, requestGeneration))
            if (target.frameIndex == 30) controller.end(30)
            controller.complete(9, requestGeneration, published = true)
            displayed = target.frameIndex
        }

        assertEquals(30, displayed)
        assertNull(controller.reserveNext(displayed, 100, foregroundRequestInFlight = false))
    }

    @Test
    fun `release just after publish permits only the target already accepted by callback order`() {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 4, fileGeneration = 10, stride = 1)
        val first = requireNotNull(controller.reserveNext(30, 100, foregroundRequestInFlight = false))
        assertTrue(controller.markAccepted(first, requestGeneration = 41))
        controller.complete(10, 41, published = true)
        val second = requireNotNull(controller.reserveNext(31, 100, foregroundRequestInFlight = false))
        assertTrue(controller.markAccepted(second, requestGeneration = 42))

        controller.end(4)
        controller.complete(10, 42, published = true)

        assertNull(controller.reserveNext(32, 100, foregroundRequestInFlight = false))
    }

    @Test
    fun `release before acceptance rejects delayed submission`() {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 5, fileGeneration = 11, stride = 5)
        val target = requireNotNull(controller.reserveNext(10, 100, foregroundRequestInFlight = false))

        controller.end(5)

        assertFalse(controller.canSubmit(target))
        assertEquals(0, controller.outstandingTargetCount)
    }

    @Test
    fun `lifecycle stop and file switch invalidate active and outstanding work`() {
        for (generation in listOf(6L, 7L)) {
            val controller = CompletionDrivenHoldController()
            controller.begin(generation, fileGeneration = 12, stride = 1)
            val target = requireNotNull(controller.reserveNext(40, 100, foregroundRequestInFlight = false))
            assertTrue(controller.markAccepted(target, requestGeneration = generation + 100))

            controller.invalidate()

            assertEquals(0, controller.outstandingTargetCount)
            assertNull(controller.reserveNext(41, 100, foregroundRequestInFlight = false))
        }
    }

    @Test
    fun `deterministic simulation keeps target depth p95 and max at one`() {
        val depths = mutableListOf<Int>()
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 8, fileGeneration = 13, stride = 5)
        var displayed = 0
        repeat(100) { offset ->
            val target = requireNotNull(controller.reserveNext(displayed, 1_000, foregroundRequestInFlight = false))
            assertTrue(controller.markAccepted(target, requestGeneration = 200L + offset))
            depths += controller.outstandingTargetCount
            assertEquals(5, target.frameIndex - displayed)
            controller.complete(13, 200L + offset, published = true)
            displayed = target.frameIndex
            depths += controller.outstandingTargetCount
        }

        val sorted = depths.sorted()
        val p95 = sorted[((sorted.size - 1) * 0.95).toInt()]
        assertEquals(1, p95)
        assertEquals(1, depths.maxOrNull())
    }

    private fun publishedTargets(stride: Int, start: Int, frameCount: Int): List<Int> {
        val controller = CompletionDrivenHoldController()
        controller.begin(gestureGeneration = 99, fileGeneration = 100, stride = stride)
        val result = mutableListOf<Int>()
        var displayed = start
        repeat(100) { offset ->
            val target = requireNotNull(
                controller.reserveNext(displayed, frameCount, foregroundRequestInFlight = false),
            )
            assertTrue(controller.markAccepted(target, requestGeneration = offset + 1L))
            assertNull(controller.reserveNext(displayed, frameCount, foregroundRequestInFlight = false))
            controller.complete(100, offset + 1L, published = true)
            displayed = target.frameIndex
            result += displayed
        }
        return result
    }
}
