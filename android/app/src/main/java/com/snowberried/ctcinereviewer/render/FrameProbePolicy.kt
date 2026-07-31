package com.snowberried.ctcinereviewer.render

import com.snowberried.ctcinereviewer.media.FrameImageProbe
import java.util.concurrent.atomic.AtomicLong

enum class FrameRenderMode {
    PILOT,
    EXACTNESS,
}

class FrameProbePolicy(
    val mode: FrameRenderMode,
) {
    private val readbacks = AtomicLong()

    fun capture(readback: () -> FrameImageProbe): FrameImageProbe? {
        if (mode != FrameRenderMode.EXACTNESS) return null
        readbacks.incrementAndGet()
        return readback()
    }

    fun readbackCount(): Long = readbacks.get()

    fun reset() {
        readbacks.set(0)
    }
}
