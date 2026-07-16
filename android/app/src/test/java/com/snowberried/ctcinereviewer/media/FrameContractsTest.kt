package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class FrameContractsTest {
    @Test
    fun `builds presentation order without deriving indexes from FPS`() {
        val video = buildFrameIndex(
            7,
            listOf(
                IndexedSample(0, 0, true),
                IndexedSample(1, 200_000, false),
                IndexedSample(2, 100_000, false),
                IndexedSample(3, 200_000, false),
            ),
        )

        assertEquals(listOf(0L, 100_000L, 200_000L, 200_000L), video.frames.map { it.key.ptsUs })
        assertEquals(listOf(0, 0, 0, 1), video.frames.map { it.key.duplicateOrdinal })
        assertEquals(listOf(0, 2, 1, 3), video.frames.map { it.sampleOrdinal })
        assertEquals(video.frames[2], video.frameForOutput(200_000L, 0))
        assertEquals(video.frames[3], video.frameForOutput(200_000L, 1))
        assertEquals(0, video.previousSyncSample(video.frames.last()).sampleOrdinal)
    }

    @Test
    fun `previous sync lookup selects the nearest indexed sample`() {
        val video = buildFrameIndex(
            8,
            listOf(
                IndexedSample(0, 0, true),
                IndexedSample(1, 3_000, false),
                IndexedSample(2, 1_000, true),
                IndexedSample(3, 2_000, false),
            ),
        )

        assertEquals(0, video.previousSyncSample(video.frames.first { it.sampleOrdinal == 1 }).sampleOrdinal)
        assertEquals(2, video.previousSyncSample(video.frames.first { it.sampleOrdinal == 3 }).sampleOrdinal)
    }

    @Test
    fun `previous sync lookup never selects a future sync sample`() {
        val video = buildFrameIndex(
            9,
            listOf(
                IndexedSample(0, 0, false),
                IndexedSample(1, 1_000, true),
            ),
        )

        assertEquals(0, video.previousSyncSample(video.frames.first()).sampleOrdinal)
    }

    @Test
    fun `rescales PTS with integer truncation toward zero`() {
        assertEquals(41_666L, rescalePtsToUs("1", 1, 24))
        assertEquals(-41_666L, rescalePtsToUs("-1", 1, 24))
        assertEquals(5_000_000L, rescalePtsToUs("450000", 1, 90_000))
    }

    @Test
    fun `publication gate distinguishes stale swap failure and invalid surface`() {
        val gate = PublicationGate()
        val fileA = gate.beginFile()
        val keyA = FrameKey(0, 0, 0)
        val requestA = gate.acceptRequest(fileA.fileGeneration, 0, keyA)!!.request
        val requestB = gate.acceptRequest(fileA.fileGeneration, 1, FrameKey(1, 1_000, 0))!!.request
        assertFalse(gate.isCurrent(requestA.token))
        var swapCalled = false
        val stale = gate.publish(requestA, 0, { true }) {
            swapCalled = true
            true
        }
        assertEquals(PublicationResult.STALE_BEFORE_SWAP, stale.result)
        assertFalse(swapCalled)

        val swapFailed = gate.publish(requestB, 1_000_000, { true }) { false }
        assertEquals(PublicationResult.SWAP_FAILED, swapFailed.result)
        assertTrue(swapFailed.swapAttempted)
        assertEquals(false, swapFailed.eglSwapBuffersResult)

        val surfaceInvalid = gate.publish(requestB, 1_000_000, { false }) { true }
        assertEquals(PublicationResult.SURFACE_INVALID, surfaceInvalid.result)
        assertFalse(surfaceInvalid.swapAttempted)
        assertNull(surfaceInvalid.eglSwapBuffersResult)

        val published = gate.publish(requestB, 1_000_000, { true }) { true }
        assertEquals(PublicationResult.PUBLISHED, published.result)
        assertEquals(0, publicationInvariantViolationCount(listOf(published)))
        gate.beginFile()
        assertEquals(
            PublicationResult.STALE_BEFORE_SWAP,
            gate.publish(requestB, 1_000_000, { true }) { true }.result,
        )
        assertNull(gate.acceptRequest(fileA.fileGeneration, 0, keyA))
    }

    @Test
    fun `request acceptance cannot pass a generation check while prior swap is in flight`() {
        val gate = PublicationGate()
        val file = gate.beginFile()
        val oldRequest = gate.acceptRequest(file.fileGeneration, 0, FrameKey(0, 0, 0))!!.request
        val swapEntered = CountDownLatch(1)
        val releaseSwap = CountDownLatch(1)
        val oldEvent = AtomicReference<PublicationEvent>()
        val acceptFinished = AtomicBoolean(false)

        val publisher = Thread {
            oldEvent.set(gate.publish(oldRequest, 0, { true }) {
                swapEntered.countDown()
                assertTrue(releaseSwap.await(2, TimeUnit.SECONDS))
                true
            })
        }.apply { start() }
        assertTrue(swapEntered.await(2, TimeUnit.SECONDS))

        val acceptance = AtomicReference<RequestAcceptance>()
        val accepter = Thread {
            acceptance.set(gate.acceptRequest(file.fileGeneration, 1, FrameKey(1, 1_000, 0)))
            acceptFinished.set(true)
        }.apply { start() }
        Thread.sleep(50)
        assertFalse("new request must wait for the publication linearization lock", acceptFinished.get())
        releaseSwap.countDown()
        publisher.join(2_000)
        accepter.join(2_000)

        assertEquals(PublicationResult.PUBLISHED, oldEvent.get().result)
        assertTrue(oldEvent.get().eventSequence < acceptance.get().eventSequence)
    }

    @Test
    fun `UI try mutations never wait for an in flight swap`() {
        val gate = PublicationGate()
        val file = gate.beginFile()
        val request = gate.acceptRequest(file.fileGeneration, 0, FrameKey(0, 0, 0))!!.request
        val swapEntered = CountDownLatch(1)
        val releaseSwap = CountDownLatch(1)
        val publisher = Thread {
            gate.publish(request, 0, { true }) {
                swapEntered.countDown()
                releaseSwap.await(2, TimeUnit.SECONDS)
            }
        }.apply { start() }
        assertTrue(swapEntered.await(2, TimeUnit.SECONDS))

        assertNull(gate.tryAcceptRequest(file.fileGeneration, 1, FrameKey(1, 1_000, 0)))
        assertNull(gate.tryInvalidateRequest())
        assertNull(gate.tryInvalidateIfCurrent(request.token))
        assertNull(gate.tryBeginFile())
        assertNull(gate.tryIsCurrent(request.token))
        assertNull(gate.trySnapshotStats())
        assertNull(gate.tryRecentEvents())

        releaseSwap.countDown()
        publisher.join(2_000)
        assertEquals(1, gate.tryAcceptRequest(file.fileGeneration, 1, FrameKey(1, 1_000, 0))!!.request.requestedFrameIndex)
    }

    @Test
    fun `timeout invalidation cannot cancel a newer request`() {
        val gate = PublicationGate()
        val file = gate.beginFile()
        val old = gate.acceptRequest(file.fileGeneration, 0, FrameKey(0, 0, 0))!!.request
        val newer = gate.acceptRequest(file.fileGeneration, 1, FrameKey(1, 1_000, 0))!!.request

        assertNull(gate.invalidateIfCurrent(old.token))
        assertTrue(gate.isCurrent(newer.token))
        assertEquals(newer.token.fileGeneration, gate.invalidateIfCurrent(newer.token)?.fileGeneration)
        assertFalse(gate.isCurrent(newer.token))
    }

    @Test
    fun `publication history is a bounded chronological ring`() {
        val gate = PublicationGate(eventHistoryCapacity = 2)
        val file = gate.beginFile()
        repeat(3) { index ->
            val request = gate.acceptRequest(file.fileGeneration, index, FrameKey(index, index * 1_000L, 0))!!.request
            assertEquals(PublicationResult.PUBLISHED, gate.publish(request, index * 1_000_000L, { true }) { true }.result)
        }

        assertEquals(listOf(1, 2), gate.recentEvents().map(PublicationEvent::requestedFrameIndex))
    }

    @Test
    fun `synthetic stale successful swap is counted as an invariant violation`() {
        val invalid = PublicationEvent(
            eventSequence = 1,
            elapsedRealtimeNanos = 1,
            fileGeneration = 1,
            requestGeneration = 1,
            requestedFrameIndex = 0,
            expectedKey = FrameKey(0, 0, 0),
            currentFileGeneration = 2,
            currentRequestGeneration = 2,
            textureTimestampNs = 0,
            swapAttempted = true,
            eglSwapBuffersResult = true,
            result = PublicationResult.PUBLISHED,
        )

        assertEquals(1L, publicationInvariantViolationCount(listOf(invalid)))
    }

    @Test
    fun `cancelled open cannot accept its initial frame request`() {
        val gate = PublicationGate()
        val openToken = gate.beginFile()
        gate.invalidateRequest()

        assertNull(
            gate.acceptInitialRequest(
                openToken,
                0,
                FrameKey(0, 0, 0),
            ),
        )
    }

    @Test
    fun `latest request slot coalesces pending work`() {
        val slot = LatestRequestSlot<Int>()
        assertEquals(false, slot.offer(1))
        assertEquals(true, slot.offer(5))
        assertEquals(true, slot.offer(10))
        assertEquals(10, slot.take())
        assertNull(slot.take())
        assertEquals(false, slot.offer(20))
    }
}
