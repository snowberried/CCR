package com.snowberried.ctcinereviewer.media

fun boundedFrameIndex(current: Int, delta: Int, frameCount: Int): Int {
    require(frameCount > 0)
    return (current.toLong() + delta.toLong()).coerceIn(0L, frameCount.toLong() - 1L).toInt()
}

fun timelineFractionForFrame(framePtsUs: List<Long>, frameIndex: Int): Float {
    if (framePtsUs.size <= 1) return 0f
    val firstPtsUs = framePtsUs.first()
    val spanUs = framePtsUs.last() - firstPtsUs
    if (spanUs <= 0L) return 0f
    val index = frameIndex.coerceIn(framePtsUs.indices)
    return ((framePtsUs[index] - firstPtsUs).toDouble() / spanUs.toDouble())
        .coerceIn(0.0, 1.0)
        .toFloat()
}

fun nearestFrameIndexForTimelineFraction(framePtsUs: List<Long>, fraction: Float): Int {
    if (framePtsUs.size <= 1) return 0
    val firstPtsUs = framePtsUs.first()
    val spanUs = framePtsUs.last() - firstPtsUs
    if (spanUs <= 0L) return 0
    val targetPtsUs = firstPtsUs + (spanUs.toDouble() * fraction.coerceIn(0f, 1f)).toLong()
    val result = framePtsUs.binarySearch(targetPtsUs)
    if (result >= 0) {
        var firstDuplicate = result
        while (firstDuplicate > 0 && framePtsUs[firstDuplicate - 1] == targetPtsUs) firstDuplicate -= 1
        return firstDuplicate
    }
    val upper = (-result - 1).coerceAtMost(framePtsUs.lastIndex)
    val lower = (upper - 1).coerceAtLeast(0)
    return if (targetPtsUs - framePtsUs[lower] <= framePtsUs[upper] - targetPtsUs) lower else upper
}
