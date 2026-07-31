package com.snowberried.ctcinereviewer.render

import com.snowberried.ctcinereviewer.media.FrameImageProbe
import kotlin.math.roundToInt

object FrameProbe {
    private const val MARKER_X = 8
    private const val MARKER_Y = 8
    private const val MARKER_CELLS = 8
    private const val CELL_SIZE = 12

    fun fromRgbaBottomUp(
        rgba: ByteArray,
        width: Int,
        height: Int,
        geometry: CanonicalGeometry,
    ): FrameImageProbe {
        require(rgba.size == width * height * 4)
        require(width == geometry.width && height == geometry.height)
        return FrameImageProbe(
            embeddedFrameId = decodeEmbeddedId(rgba, width, height, geometry),
            imageSignature = signature(rgba, width, height),
        )
    }

    private fun signature(rgba: ByteArray, width: Int, height: Int): List<Int> {
        val result = ArrayList<Int>(16 * 16 * 3)
        repeat(16) { blockY ->
            val y0 = blockY * height / 16
            val y1 = (blockY + 1) * height / 16
            repeat(16) { blockX ->
                val x0 = blockX * width / 16
                val x1 = (blockX + 1) * width / 16
                val sums = LongArray(3)
                var count = 0
                for (y in y0 until y1) {
                    for (x in x0 until x1) {
                        val offset = bottomUpOffset(x, y, width, height)
                        repeat(3) { channel -> sums[channel] += rgba[offset + channel].toUByte().toLong() }
                        count += 1
                    }
                }
                repeat(3) { channel -> result += ((sums[channel] + count / 2L) / count).toInt() }
            }
        }
        return result
    }

    private fun decodeEmbeddedId(
        rgba: ByteArray,
        width: Int,
        height: Int,
        geometry: CanonicalGeometry,
    ): Int? {
        if (geometry.cropWidth < MARKER_X + MARKER_CELLS * CELL_SIZE ||
            geometry.cropHeight < MARKER_Y + MARKER_CELLS * CELL_SIZE
        ) return null
        val bits = IntArray(MARKER_CELLS * MARKER_CELLS)
        repeat(MARKER_CELLS) { row ->
            repeat(MARKER_CELLS) { column ->
                var luminance = 0L
                var count = 0
                for (fractionY in SAMPLE_FRACTIONS) {
                    for (fractionX in SAMPLE_FRACTIONS) {
                        val sourceX = MARKER_X + (column + fractionX) * CELL_SIZE
                        val sourceY = MARKER_Y + (row + fractionY) * CELL_SIZE
                        val (canonicalX, canonicalY) = canonicalPoint(sourceX, sourceY, geometry)
                        val x = canonicalX.roundToInt().coerceIn(0, width - 1)
                        val y = canonicalY.roundToInt().coerceIn(0, height - 1)
                        val offset = bottomUpOffset(x, y, width, height)
                        repeat(3) { channel -> luminance += rgba[offset + channel].toUByte().toLong() }
                        count += 3
                    }
                }
                bits[row * MARKER_CELLS + column] = if (luminance / count >= 128L) 1 else 0
            }
        }
        val finder = markerBits(0)
        repeat(MARKER_CELLS) { row ->
            repeat(MARKER_CELLS) { column ->
                if (row != 0 && row != 7 && column != 0 && column != 7) return@repeat
                val index = row * MARKER_CELLS + column
                if (bits[index] != finder[index]) return null
            }
        }
        val payload = ArrayList<Int>(36)
        for (row in 1..6) for (column in 1..6) payload += bits[row * MARKER_CELLS + column]
        val id = payload.take(16).fold(0) { value, bit -> value * 2 + bit }
        val embeddedCrc = payload.drop(16).take(8).fold(0) { value, bit -> value * 2 + bit }
        return id.takeIf { crc8(it) == embeddedCrc }
    }

    private fun canonicalPoint(
        sourceX: Double,
        sourceY: Double,
        geometry: CanonicalGeometry,
    ): Pair<Double, Double> {
        val x = (sourceX + 0.5) * geometry.preRotationWidth / geometry.cropWidth - 0.5
        val y = sourceY
        return when (geometry.rotationDegrees) {
            90 -> geometry.preRotationHeight - 1.0 - y to x
            180 -> geometry.preRotationWidth - 1.0 - x to geometry.preRotationHeight - 1.0 - y
            270 -> y to geometry.preRotationWidth - 1.0 - x
            else -> x to y
        }
    }

    private fun bottomUpOffset(x: Int, yFromTop: Int, width: Int, height: Int): Int =
        ((height - 1 - yFromTop) * width + x) * 4

    private fun markerBits(id: Int): IntArray {
        val bits = IntArray(64)
        intArrayOf(1, 0, 1, 1, 0, 0, 1, 0).copyInto(bits, 0)
        intArrayOf(1, 1, 0, 0, 1, 0, 1, 1).copyInto(bits, 56)
        intArrayOf(1, 0, 1, 0, 1, 1).forEachIndexed { row, value -> bits[(row + 1) * 8] = value }
        intArrayOf(0, 1, 1, 0, 0, 1).forEachIndexed { row, value -> bits[(row + 1) * 8 + 7] = value }
        val payload = ArrayList<Int>(36)
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

    private val SAMPLE_FRACTIONS = doubleArrayOf(0.3, 0.5, 0.7)
}
