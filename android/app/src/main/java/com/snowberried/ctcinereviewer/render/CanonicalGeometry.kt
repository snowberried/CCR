package com.snowberried.ctcinereviewer.render

data class CanonicalGeometry(
    val cropWidth: Int,
    val cropHeight: Int,
    val pixelAspectRatioWidth: Int,
    val pixelAspectRatioHeight: Int,
    val rotationDegrees: Int,
) {
    init {
        require(cropWidth > 0 && cropHeight > 0)
        require(pixelAspectRatioWidth > 0 && pixelAspectRatioHeight > 0)
        require(rotationDegrees in setOf(0, 90, 180, 270))
    }

    private val squarePixelWidth = roundedRatio(cropWidth, pixelAspectRatioWidth, pixelAspectRatioHeight)

    val width: Int = if (rotationDegrees == 90 || rotationDegrees == 270) cropHeight else squarePixelWidth
    val height: Int = if (rotationDegrees == 90 || rotationDegrees == 270) squarePixelWidth else cropHeight

    companion object {
        fun fromInclusiveCrop(
            cropLeft: Int,
            cropTop: Int,
            cropRight: Int,
            cropBottom: Int,
            pixelAspectRatioWidth: Int,
            pixelAspectRatioHeight: Int,
            rotationDegrees: Int,
        ): CanonicalGeometry = CanonicalGeometry(
            cropWidth = cropRight - cropLeft + 1,
            cropHeight = cropBottom - cropTop + 1,
            pixelAspectRatioWidth = pixelAspectRatioWidth,
            pixelAspectRatioHeight = pixelAspectRatioHeight,
            rotationDegrees = rotationDegrees,
        )

        private fun roundedRatio(value: Int, numerator: Int, denominator: Int): Int {
            val scaled = value.toLong() * numerator.toLong()
            return ((scaled + denominator / 2L) / denominator).coerceAtLeast(1L).toInt()
        }
    }
}
