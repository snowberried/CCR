package com.snowberried.ctcinereviewer.render

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.util.concurrent.atomic.AtomicLong

// Programmatic-only render surface; its pinch/pan gestures intentionally expose no click action.
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class VideoViewport(
    context: Context,
    private val renderer: EglFrameRenderer,
) : SurfaceView(context), SurfaceHolder.Callback2 {
    private val surfaceLeaseId = nextSurfaceLeaseId.incrementAndGet()
    private var activePointerId = MotionEvent.INVALID_POINTER_ID
    private var lastPanX = 0f
    private var lastPanY = 0f
    private var zoomedBeyondFit = false

    internal var onTransformChanged: ((ViewTransform) -> Unit)? = null

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                renderer.zoomBy(
                    scaleFactor = detector.scaleFactor,
                    anchorX = detector.focusX,
                    anchorY = detector.focusY,
                )
                return true
            }
        },
    )

    init {
        holder.setFormat(PixelFormat.OPAQUE)
        holder.addCallback(this)
        isFocusable = true
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        renderer.attachWindow(surfaceLeaseId, holder.surface, width, height, ::dispatchTransform)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        renderer.resize(surfaceLeaseId, width, height)
    }

    override fun surfaceRedrawNeeded(holder: SurfaceHolder) {
        renderer.resize(surfaceLeaseId, width, height)
    }

    override fun surfaceRedrawNeededAsync(holder: SurfaceHolder, drawingFinished: Runnable) {
        renderer.resize(surfaceLeaseId, width, height, drawingFinished::run)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        renderer.detachWindow(surfaceLeaseId)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activePointerId = event.getPointerId(0)
                lastPanX = event.x
                lastPanY = event.y
            }
            MotionEvent.ACTION_MOVE -> {
                if (!scaleDetector.isInProgress && event.pointerCount == 1 && zoomedBeyondFit) {
                    val pointerIndex = event.findPointerIndex(activePointerId)
                    if (pointerIndex >= 0) {
                        val x = event.getX(pointerIndex)
                        val y = event.getY(pointerIndex)
                        renderer.panBy(x - lastPanX, y - lastPanY)
                        lastPanX = x
                        lastPanY = y
                    }
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                val liftedId = event.getPointerId(event.actionIndex)
                if (liftedId == activePointerId) {
                    val replacement = if (event.actionIndex == 0) 1 else 0
                    if (replacement < event.pointerCount) {
                        activePointerId = event.getPointerId(replacement)
                        lastPanX = event.getX(replacement)
                        lastPanY = event.getY(replacement)
                    }
                } else {
                    val activeIndex = event.findPointerIndex(activePointerId)
                    if (activeIndex >= 0) {
                        lastPanX = event.getX(activeIndex)
                        lastPanY = event.getY(activeIndex)
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                activePointerId = MotionEvent.INVALID_POINTER_ID
            }
        }
        return true
    }

    internal fun updateCorrection(correction: VideoCorrection, comparingOriginal: Boolean) {
        renderer.updateCorrection(correction, comparingOriginal)
    }

    internal fun resetView() {
        renderer.resetView()
    }

    private fun dispatchTransform(transform: ViewTransform) {
        post {
            zoomedBeyondFit = transform.zoom > VIEW_ZOOM_MIN
            onTransformChanged?.invoke(transform)
        }
    }

    companion object {
        private val nextSurfaceLeaseId = AtomicLong()
    }
}
