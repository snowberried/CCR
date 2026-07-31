package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.floor

class FrameProbeTest {
    @Test
    fun `recovers finder and CRC frame ID from bottom-up RGBA`() {
        val geometry = CanonicalGeometry(256, 144, 1, 1, 0)
        val probe = FrameProbe.fromRgbaBottomUp(makeCanonicalRgba(geometry, 321), geometry.width, geometry.height, geometry)
        assertEquals(321, probe.embeddedFrameId)
        assertEquals(16 * 16 * 3, probe.imageSignature.size)
    }

    @Test
    fun `recovers ID after PAR correction and clockwise rotation`() {
        val geometry = CanonicalGeometry(256, 144, 8, 9, 90)
        val probe = FrameProbe.fromRgbaBottomUp(makeCanonicalRgba(geometry, 987), geometry.width, geometry.height, geometry)
        assertEquals(987, probe.embeddedFrameId)
    }

    private fun makeCanonicalRgba(geometry: CanonicalGeometry, id: Int): ByteArray {
        val rgba = ByteArray(geometry.width * geometry.height * 4)
        val bits = markerBits(id)
        for (canonicalY in 0 until geometry.height) {
            for (canonicalX in 0 until geometry.width) {
                val (preX, preY) = when (geometry.rotationDegrees) {
                    90 -> canonicalY to geometry.preRotationHeight - 1 - canonicalX
                    180 -> geometry.preRotationWidth - 1 - canonicalX to geometry.preRotationHeight - 1 - canonicalY
                    270 -> geometry.preRotationWidth - 1 - canonicalY to canonicalX
                    else -> canonicalX to canonicalY
                }
                val sourceX = floor((preX + 0.5) * geometry.cropWidth / geometry.preRotationWidth).toInt()
                val sourceY = preY
                val column = (sourceX - 8) / 12
                val row = (sourceY - 8) / 12
                val inside = sourceX >= 8 && sourceY >= 8 && column in 0..7 && row in 0..7
                val value = if (inside && bits[row * 8 + column] == 1) 240 else if (inside) 16 else 96
                val offset = ((geometry.height - 1 - canonicalY) * geometry.width + canonicalX) * 4
                rgba[offset] = value.toByte()
                rgba[offset + 1] = value.toByte()
                rgba[offset + 2] = value.toByte()
                rgba[offset + 3] = 255.toByte()
            }
        }
        return rgba
    }

    private fun markerBits(id: Int): IntArray {
        val bits = IntArray(64)
        intArrayOf(1, 0, 1, 1, 0, 0, 1, 0).copyInto(bits, 0)
        intArrayOf(1, 1, 0, 0, 1, 0, 1, 1).copyInto(bits, 56)
        intArrayOf(1, 0, 1, 0, 1, 1).forEachIndexed { row, value -> bits[(row + 1) * 8] = value }
        intArrayOf(0, 1, 1, 0, 0, 1).forEachIndexed { row, value -> bits[(row + 1) * 8 + 7] = value }
        val payload = ArrayList<Int>()
        for (bit in 15 downTo 0) payload += (id ushr bit) and 1
        val crc = crc8(id)
        for (bit in 7 downTo 0) payload += (crc ushr bit) and 1
        repeat(12) { payload += it % 2 }
        var cursor = 0
        for (row in 1..6) for (column in 1..6) bits[row * 8 + column] = payload[cursor++]
        return bits
    }

    private fun crc8(value: Int): Int {
        var crc = 0
        for (byte in intArrayOf((value ushr 8) and 0xff, value and 0xff)) {
            crc = crc xor byte
            repeat(8) { crc = if (crc and 0x80 != 0) ((crc shl 1) xor 0x07) and 0xff else (crc shl 1) and 0xff }
        }
        return crc
    }
}
