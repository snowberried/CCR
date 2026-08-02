package com.snowberried.ctcinereviewer.render

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal const val VIEW_ZOOM_MIN = 1f
internal const val VIEW_ZOOM_MAX = 10f

internal data class ViewPoint(val x: Float, val y: Float)

internal data class ViewSize(val width: Float, val height: Float) {
    val isValid: Boolean get() = width.isFinite() && height.isFinite() && width > 0f && height > 0f
}

internal enum class ViewScaleMode { FIT, MANUAL }

internal data class ViewTransform(
    val imageSize: ViewSize,
    val viewportSize: ViewSize,
    val center: ViewPoint,
    val zoom: Float,
    val scaleMode: ViewScaleMode,
    val revision: Long = 0,
) {
    val isFit: Boolean
        get() = scaleMode == ViewScaleMode.FIT &&
            abs(zoom - 1f) < VIEW_EPSILON &&
            abs(center.x - imageSize.width / 2f) < VIEW_EPSILON &&
            abs(center.y - imageSize.height / 2f) < VIEW_EPSILON
}

internal data class ViewPlacement(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
)

internal fun fitScale(imageSize: ViewSize, viewportSize: ViewSize): Float {
    if (!imageSize.isValid || !viewportSize.isValid) return 0f
    return min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
}

internal fun effectiveScale(transform: ViewTransform): Float =
    fitScale(transform.imageSize, transform.viewportSize) * transform.zoom

internal fun createViewTransform(imageSize: ViewSize, viewportSize: ViewSize): ViewTransform {
    require(imageSize.isValid) { "INVALID_VIEW_TRANSFORM" }
    return ViewTransform(
        imageSize = imageSize,
        viewportSize = viewportSize,
        center = ViewPoint(imageSize.width / 2f, imageSize.height / 2f),
        zoom = 1f,
        scaleMode = ViewScaleMode.FIT,
    )
}

internal fun imageToViewport(transform: ViewTransform, point: ViewPoint): ViewPoint {
    val scale = effectiveScale(transform)
    return ViewPoint(
        x = (point.x - transform.center.x) * scale + transform.viewportSize.width / 2f,
        y = (point.y - transform.center.y) * scale + transform.viewportSize.height / 2f,
    )
}

internal fun viewportToImage(transform: ViewTransform, point: ViewPoint): ViewPoint {
    val scale = effectiveScale(transform)
    if (scale <= 0f) return transform.center
    return ViewPoint(
        x = transform.center.x + (point.x - transform.viewportSize.width / 2f) / scale,
        y = transform.center.y + (point.y - transform.viewportSize.height / 2f) / scale,
    )
}

internal fun zoomViewTransform(
    transform: ViewTransform,
    scaleFactor: Float,
    anchor: ViewPoint,
): ViewTransform {
    if (!scaleFactor.isFinite() || scaleFactor <= 0f) return transform
    val zoom = (transform.zoom * scaleFactor).coerceIn(VIEW_ZOOM_MIN, VIEW_ZOOM_MAX)
    if (abs(zoom - transform.zoom) < VIEW_EPSILON) return transform
    val anchoredImagePoint = viewportToImage(transform, anchor)
    val next = transform.copy(
        zoom = zoom,
        scaleMode = ViewScaleMode.MANUAL,
        revision = transform.revision + 1,
    )
    val scale = effectiveScale(next)
    val center = ViewPoint(
        x = anchoredImagePoint.x - (anchor.x - next.viewportSize.width / 2f) / scale,
        y = anchoredImagePoint.y - (anchor.y - next.viewportSize.height / 2f) / scale,
    )
    return next.copy(center = clampCenter(next, center))
}

internal fun panViewTransform(transform: ViewTransform, delta: ViewPoint): ViewTransform {
    if (transform.zoom <= VIEW_ZOOM_MIN || (delta.x == 0f && delta.y == 0f)) return transform
    val scale = effectiveScale(transform)
    if (scale <= 0f) return transform
    val next = transform.copy(
        scaleMode = ViewScaleMode.MANUAL,
        revision = transform.revision + 1,
    )
    return next.copy(
        center = clampCenter(
            next,
            ViewPoint(
                x = transform.center.x - delta.x / scale,
                y = transform.center.y - delta.y / scale,
            ),
        ),
    )
}

internal fun resizeViewTransform(transform: ViewTransform, viewportSize: ViewSize): ViewTransform {
    if (viewportSize == transform.viewportSize || !viewportSize.isValid) return transform
    val currentScale = effectiveScale(transform)
    val nextFitScale = fitScale(transform.imageSize, viewportSize)
    val zoom = if (transform.scaleMode == ViewScaleMode.FIT || nextFitScale <= 0f) {
        1f
    } else {
        (currentScale / nextFitScale).coerceIn(VIEW_ZOOM_MIN, VIEW_ZOOM_MAX)
    }
    val center = if (transform.scaleMode == ViewScaleMode.FIT) {
        ViewPoint(transform.imageSize.width / 2f, transform.imageSize.height / 2f)
    } else {
        transform.center
    }
    val next = transform.copy(
        viewportSize = viewportSize,
        center = center,
        zoom = zoom,
        revision = transform.revision + 1,
    )
    return next.copy(center = clampCenter(next, center))
}

internal fun fitViewTransform(transform: ViewTransform): ViewTransform {
    if (transform.isFit) return transform
    return transform.copy(
        center = ViewPoint(transform.imageSize.width / 2f, transform.imageSize.height / 2f),
        zoom = 1f,
        scaleMode = ViewScaleMode.FIT,
        revision = transform.revision + 1,
    )
}

internal fun viewPlacement(transform: ViewTransform): ViewPlacement {
    val scale = effectiveScale(transform)
    val topLeft = imageToViewport(transform, ViewPoint(0f, 0f))
    return ViewPlacement(
        left = topLeft.x,
        top = topLeft.y,
        width = transform.imageSize.width * scale,
        height = transform.imageSize.height * scale,
    )
}

private fun clampCenter(transform: ViewTransform, center: ViewPoint): ViewPoint {
    val scale = effectiveScale(transform)
    if (scale <= 0f) return ViewPoint(transform.imageSize.width / 2f, transform.imageSize.height / 2f)
    val halfVisibleWidth = transform.viewportSize.width / (2f * scale)
    val halfVisibleHeight = transform.viewportSize.height / (2f * scale)
    fun clampAxis(value: Float, imageLength: Float, halfVisible: Float): Float =
        if (halfVisible * 2f >= imageLength) imageLength / 2f
        else max(halfVisible, min(imageLength - halfVisible, value))
    return ViewPoint(
        x = clampAxis(center.x, transform.imageSize.width, halfVisibleWidth),
        y = clampAxis(center.y, transform.imageSize.height, halfVisibleHeight),
    )
}

private const val VIEW_EPSILON = 0.0001f
