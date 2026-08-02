package com.snowberried.ctcinereviewer.render

import kotlin.math.pow
import kotlin.math.round
import kotlin.math.roundToInt

internal data class CorrectionLimit(
    val default: Float,
    val min: Float,
    val max: Float,
    val step: Float,
)

internal object VideoCorrectionLimits {
    val Level = CorrectionLimit(default = 0.50f, min = 0.00f, max = 1.00f, step = 0.01f)
    val Width = CorrectionLimit(default = 1.00f, min = 0.02f, max = 2.00f, step = 0.01f)
    val Gamma = CorrectionLimit(default = 1.00f, min = 0.25f, max = 4.00f, step = 0.05f)
    val SharpAmount = CorrectionLimit(default = 0.00f, min = 0.00f, max = 1.00f, step = 0.05f)
}

internal data class VideoCorrection(
    val level: Float = VideoCorrectionLimits.Level.default,
    val width: Float = VideoCorrectionLimits.Width.default,
    val gamma: Float = VideoCorrectionLimits.Gamma.default,
    val sharpAmount: Float = VideoCorrectionLimits.SharpAmount.default,
    val invert: Boolean = false,
) {
    val isDefault: Boolean get() = this == Default

    fun withLevel(value: Float): VideoCorrection = copy(level = snap(value, VideoCorrectionLimits.Level))
    fun withWidth(value: Float): VideoCorrection = copy(width = snap(value, VideoCorrectionLimits.Width))
    fun withGamma(value: Float): VideoCorrection = copy(gamma = snap(value, VideoCorrectionLimits.Gamma))
    fun withSharpAmount(value: Float): VideoCorrection = copy(
        sharpAmount = snap(value, VideoCorrectionLimits.SharpAmount),
    )

    fun toggledInvert(): VideoCorrection = copy(invert = !invert)

    companion object {
        val Default = VideoCorrection()
    }
}

internal data class CorrectionPanelState(
    val correction: VideoCorrection = VideoCorrection.Default,
    val expanded: Boolean = false,
) {
    fun toggled(): CorrectionPanelState = copy(expanded = !expanded)
    fun withCorrection(value: VideoCorrection): CorrectionPanelState = copy(correction = value)
    fun reset(): CorrectionPanelState = copy(correction = VideoCorrection.Default)
}

internal fun mapCorrectionLuminance(luminance: Double, correction: VideoCorrection): Double {
    val lower = correction.level - correction.width / 2.0
    val windowed = ((luminance - lower) / correction.width).coerceIn(0.0, 1.0)
    val gammaMapped = windowed.pow(1.0 / correction.gamma)
    return if (correction.invert) 1.0 - gammaMapped else gammaMapped
}

internal fun applyVideoCorrectionReference(
    source: ByteArray,
    width: Int,
    height: Int,
    correction: VideoCorrection,
): ByteArray {
    require(width > 0 && height > 0 && source.size == width * height * 4)
    if (correction.isDefault) return source.copyOf()
    val mapped = DoubleArray(width * height)
    for (pixel in mapped.indices) {
        val offset = pixel * 4
        mapped[pixel] = mapCorrectionLuminance(sourceLuminance(source, offset), correction)
    }
    val output = source.copyOf()
    for (y in 0 until height) {
        for (x in 0 until width) {
            val pixel = y * width + x
            val offset = pixel * 4
            val originalLuminance = sourceLuminance(source, offset)
            var adjustedLuminance = mapped[pixel]
            if (correction.sharpAmount > 0f) {
                val left = mapped[y * width + (x - 1).coerceAtLeast(0)]
                val right = mapped[y * width + (x + 1).coerceAtMost(width - 1)]
                val up = mapped[(y - 1).coerceAtLeast(0) * width + x]
                val down = mapped[(y + 1).coerceAtMost(height - 1) * width + x]
                adjustedLuminance = (
                    adjustedLuminance + correction.sharpAmount * 0.25 *
                        (4.0 * adjustedLuminance - left - right - up - down)
                    ).coerceIn(0.0, 1.0)
            }
            val delta = adjustedLuminance - originalLuminance
            output[offset] = correctedByte(source[offset], delta)
            output[offset + 1] = correctedByte(source[offset + 1], delta)
            output[offset + 2] = correctedByte(source[offset + 2], delta)
        }
    }
    return output
}

private fun snap(value: Float, limit: CorrectionLimit): Float {
    val finite = if (value.isFinite()) value else limit.min
    val clamped = finite.coerceIn(limit.min, limit.max)
    val steps = round((clamped - limit.min) / limit.step)
    return (limit.min + steps * limit.step)
        .coerceIn(limit.min, limit.max)
        .let { (it * 10_000f).roundToInt() / 10_000f }
}

private fun sourceLuminance(source: ByteArray, offset: Int): Double {
    val red = (source[offset].toInt() and 0xff) / 255.0
    val green = (source[offset + 1].toInt() and 0xff) / 255.0
    val blue = (source[offset + 2].toInt() and 0xff) / 255.0
    return 0.299 * red + 0.587 * green + 0.114 * blue
}

private fun correctedByte(source: Byte, delta: Double): Byte {
    val original = (source.toInt() and 0xff) / 255.0
    return ((original + delta).coerceIn(0.0, 1.0) * 255.0).roundToInt().toByte()
}
