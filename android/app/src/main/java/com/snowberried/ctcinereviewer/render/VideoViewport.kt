package com.snowberried.ctcinereviewer.render

import android.content.Context
import android.graphics.PixelFormat
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.util.concurrent.atomic.AtomicLong

class VideoViewport(
    context: Context,
    private val renderer: EglFrameRenderer,
) : SurfaceView(context), SurfaceHolder.Callback {
    private val surfaceLeaseId = nextSurfaceLeaseId.incrementAndGet()

    init {
        holder.setFormat(PixelFormat.OPAQUE)
        holder.addCallback(this)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        renderer.attachWindow(surfaceLeaseId, holder.surface, width, height)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        renderer.resize(surfaceLeaseId, width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        renderer.detachWindow(surfaceLeaseId)
    }

    companion object {
        private val nextSurfaceLeaseId = AtomicLong()
    }
}
