package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ViewTransformTest {
    @Test
    fun `pinch keeps the image point under its anchor`() {
        val initial = createViewTransform(ViewSize(1_000f, 500f), ViewSize(400f, 400f))
        val anchor = ViewPoint(300f, 200f)
        val anchoredImagePoint = viewportToImage(initial, anchor)

        val zoomed = zoomViewTransform(initial, 2f, anchor)

        assertPointEquals(anchor, imageToViewport(zoomed, anchoredImagePoint))
        assertEquals(2f, zoomed.zoom, EPSILON)
        assertFalse(zoomed.isFit)
    }

    @Test
    fun `pan clamps every large axis and centers a smaller axis`() {
        val fit = createViewTransform(ViewSize(1_000f, 500f), ViewSize(400f, 400f))
        val zoomed = zoomViewTransform(fit, 3f, ViewPoint(200f, 200f))

        val topLeftLimit = panViewTransform(zoomed, ViewPoint(10_000f, 10_000f))
        val bottomRightLimit = panViewTransform(zoomed, ViewPoint(-20_000f, -20_000f))

        val firstPlacement = viewPlacement(topLeftLimit)
        val secondPlacement = viewPlacement(bottomRightLimit)
        assertEquals(0f, firstPlacement.left, EPSILON)
        assertEquals(0f, firstPlacement.top, EPSILON)
        assertEquals(400f, secondPlacement.left + secondPlacement.width, EPSILON)
        assertEquals(400f, secondPlacement.top + secondPlacement.height, EPSILON)

        val smallerAxis = createViewTransform(ViewSize(1_000f, 500f), ViewSize(400f, 400f))
        assertEquals(250f, smallerAxis.center.y, EPSILON)
    }

    @Test
    fun `fit reset restores contain fit zoom and center`() {
        val initial = createViewTransform(ViewSize(1_000f, 500f), ViewSize(400f, 400f))
        val changed = panViewTransform(
            zoomViewTransform(initial, 4f, ViewPoint(250f, 220f)),
            ViewPoint(-80f, 45f),
        )

        val reset = fitViewTransform(changed)

        assertTrue(reset.isFit)
        assertEquals(1f, reset.zoom, EPSILON)
        assertPointEquals(ViewPoint(500f, 250f), reset.center)
        assertEquals(ViewPlacement(0f, 100f, 400f, 200f), viewPlacement(reset))
    }

    @Test
    fun `viewport resize preserves manual scale then clamps safely`() {
        val initial = createViewTransform(ViewSize(1_000f, 500f), ViewSize(400f, 400f))
        val changed = panViewTransform(
            zoomViewTransform(initial, 2f, ViewPoint(200f, 200f)),
            ViewPoint(-80f, 0f),
        )
        val scaleBefore = effectiveScale(changed)

        val resized = resizeViewTransform(changed, ViewSize(300f, 500f))

        assertEquals(scaleBefore, effectiveScale(resized), EPSILON)
        assertEquals(changed.center.x, resized.center.x, EPSILON)
        assertEquals(250f, resized.center.y, EPSILON)
        val placement = viewPlacement(resized)
        assertTrue(placement.left <= EPSILON)
        assertTrue(placement.left + placement.width >= 300f - EPSILON)
        assertEquals(50f, placement.top, EPSILON)
        assertEquals(450f, placement.top + placement.height, EPSILON)
    }

    private fun assertPointEquals(expected: ViewPoint, actual: ViewPoint) {
        assertEquals(expected.x, actual.x, EPSILON)
        assertEquals(expected.y, actual.y, EPSILON)
    }

    private companion object {
        const val EPSILON = 0.001f
    }
}
