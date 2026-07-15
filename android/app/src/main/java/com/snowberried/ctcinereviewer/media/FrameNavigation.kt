package com.snowberried.ctcinereviewer.media

fun boundedFrameIndex(current: Int, delta: Int, frameCount: Int): Int {
    require(frameCount > 0)
    return (current.toLong() + delta.toLong()).coerceIn(0L, frameCount.toLong() - 1L).toInt()
}
