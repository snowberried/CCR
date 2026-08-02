package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoCorrectionTest {
    @Test
    fun `defaults and limits match desktop correction contract`() {
        assertEquals(CorrectionLimit(0.50f, 0.00f, 1.00f, 0.01f), VideoCorrectionLimits.Level)
        assertEquals(CorrectionLimit(1.00f, 0.02f, 2.00f, 0.01f), VideoCorrectionLimits.Width)
        assertEquals(CorrectionLimit(1.00f, 0.25f, 4.00f, 0.05f), VideoCorrectionLimits.Gamma)
        assertEquals(CorrectionLimit(0.00f, 0.00f, 1.00f, 0.05f), VideoCorrectionLimits.SharpAmount)
        assertTrue(VideoCorrection.Default.isDefault)
    }

    @Test
    fun `values snap clamp and reset exactly`() {
        val changed = VideoCorrection.Default
            .withLevel(0.506f)
            .withWidth(-3f)
            .withGamma(8f)
            .withSharpAmount(0.127f)
            .toggledInvert()

        assertEquals(0.51f, changed.level, EPSILON)
        assertEquals(0.02f, changed.width, EPSILON)
        assertEquals(4f, changed.gamma, EPSILON)
        assertEquals(0.15f, changed.sharpAmount, EPSILON)
        assertTrue(changed.invert)

        val reset = CorrectionPanelState(changed, expanded = true).reset()
        assertEquals(VideoCorrection.Default, reset.correction)
        assertTrue(reset.expanded)
    }

    @Test
    fun `collapse and expand preserve values while a new state starts clean`() {
        val adjusted = CorrectionPanelState(
            correction = VideoCorrection.Default.withGamma(1.35f),
            expanded = true,
        )

        assertEquals(adjusted.correction, adjusted.toggled().correction)
        assertEquals(adjusted.correction, adjusted.toggled().toggled().correction)
        assertEquals(VideoCorrection.Default, CorrectionPanelState().correction)
        assertFalse(CorrectionPanelState().expanded)
    }

    @Test
    fun `luminance mapping follows desktop level width gamma and invert order`() {
        val correction = VideoCorrection(level = 0.6f, width = 0.5f, gamma = 2f, invert = false)
        val expected = kotlin.math.sqrt(((0.55 - 0.35) / 0.5).coerceIn(0.0, 1.0))

        assertEquals(expected, mapCorrectionLuminance(0.55, correction), 0.000001)
        assertEquals(1.0 - expected, mapCorrectionLuminance(0.55, correction.copy(invert = true)), 0.000001)
    }

    @Test
    fun `CPU reference preserves default pixels and applies invert with byte tolerance`() {
        val source = byteArrayOf(
            0, 0, 0, 7,
            128.toByte(), 128.toByte(), 128.toByte(), 8,
            255.toByte(), 255.toByte(), 255.toByte(), 9,
        )

        assertArrayEquals(source, applyVideoCorrectionReference(source, 3, 1, VideoCorrection.Default))
        val inverted = applyVideoCorrectionReference(
            source,
            3,
            1,
            VideoCorrection.Default.copy(invert = true),
        )
        assertPixel(inverted, 0, 255, 255, 255, 7)
        assertPixel(inverted, 1, 127, 127, 127, 8)
        assertPixel(inverted, 2, 0, 0, 0, 9)
    }

    @Test
    fun `flat field remains flat under the four-neighbor unsharp contract`() {
        val source = ByteArray(3 * 3 * 4)
        source.indices.step(4).forEach { offset ->
            source[offset] = 96
            source[offset + 1] = 96
            source[offset + 2] = 96
            source[offset + 3] = 255.toByte()
        }

        val output = applyVideoCorrectionReference(
            source,
            3,
            3,
            VideoCorrection.Default.copy(sharpAmount = 1f),
        )

        assertArrayEquals(source, output)
    }

    @Test
    fun `Android RGB shader contains the same post RGB correction formula`() {
        val shader = EglFrameRenderer.TEXTURE_FRAGMENT_SHADER
        assertTrue(shader.contains("dot(rgb, vec3(0.299, 0.587, 0.114))"))
        assertTrue(shader.contains("displayLevel - displayWidth * 0.5"))
        assertTrue(shader.contains("pow(mapped, 1.0 / displayGamma)"))
        assertTrue(shader.contains("mix(mapped, 1.0 - mapped, displayInvert)"))
        assertTrue(shader.contains("4.0 * adjustedLuma - neighbors"))
        assertTrue(shader.contains("rgb + vec3(adjustedLuma - originalLuma)"))
    }

    private fun assertPixel(
        pixels: ByteArray,
        index: Int,
        red: Int,
        green: Int,
        blue: Int,
        alpha: Int,
    ) {
        val offset = index * 4
        assertEquals(red, pixels[offset].toInt() and 0xff)
        assertEquals(green, pixels[offset + 1].toInt() and 0xff)
        assertEquals(blue, pixels[offset + 2].toInt() and 0xff)
        assertEquals(alpha, pixels[offset + 3].toInt() and 0xff)
    }

    private companion object {
        const val EPSILON = 0.0001f
    }
}
