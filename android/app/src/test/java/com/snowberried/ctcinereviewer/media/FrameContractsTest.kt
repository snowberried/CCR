package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

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
        assertEquals(0, video.previousSyncSample(video.frames.last()).sampleOrdinal)
    }

    @Test
    fun `rescales PTS with integer truncation toward zero`() {
        assertEquals(41_666L, rescalePtsToUs("1", 1, 24))
        assertEquals(-41_666L, rescalePtsToUs("-1", 1, 24))
        assertEquals(5_000_000L, rescalePtsToUs("450000", 1, 90_000))
    }

    @Test
    fun `publication gate rejects stale request and file generations`() {
        val gate = PublicationGate()
        val fileA = gate.beginFile()
        val requestA = gate.beginRequest(fileA.fileGeneration)!!
        val requestB = gate.beginRequest(fileA.fileGeneration)!!
        assertFalse(gate.isCurrent(requestA))
        assertTrue(gate.publishIfCurrent(requestB) { true })
        gate.beginFile()
        assertFalse(gate.publishIfCurrent(requestB) { true })
        assertNull(gate.beginRequest(fileA.fileGeneration))
    }

    @Test
    fun `latest request slot coalesces pending work`() {
        val slot = LatestRequestSlot<Int>()
        slot.offer(1)
        slot.offer(5)
        slot.offer(10)
        assertEquals(10, slot.take())
        assertNull(slot.take())
    }
}
