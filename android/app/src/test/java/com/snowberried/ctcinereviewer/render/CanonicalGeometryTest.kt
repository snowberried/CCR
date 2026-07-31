package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertEquals
import org.junit.Test

class CanonicalGeometryTest {
    @Test
    fun `uses inclusive crop and square pixel dimensions`() {
        val geometry = CanonicalGeometry.fromInclusiveCrop(10, 20, 109, 69, 1, 1, 0)
        assertEquals(100, geometry.cropWidth)
        assertEquals(50, geometry.cropHeight)
        assertEquals(100, geometry.width)
        assertEquals(50, geometry.height)
    }

    @Test
    fun `corrects pixel aspect ratio before clockwise rotation`() {
        val unrotated = CanonicalGeometry(720, 480, 8, 9, 0)
        assertEquals(640, unrotated.width)
        assertEquals(480, unrotated.height)

        val rotated = CanonicalGeometry(720, 480, 8, 9, 90)
        assertEquals(480, rotated.width)
        assertEquals(640, rotated.height)
    }
}
