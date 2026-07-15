package com.snowberried.ctcinereviewer.render

import android.content.Context
import android.graphics.PixelFormat
import android.view.SurfaceHolder
import android.view.SurfaceView

class VideoViewport(
    context: Context,
    private val renderer: EglFrameRenderer,
) : SurfaceView(context), SurfaceHolder.Callback {
    init {
        holder.setFormat(PixelFormat.OPAQUE)
        holder.addCallback(this)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        renderer.attachWindow(holder.surface, width, height)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        renderer.resize(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        renderer.detachWindow()
    }
}
