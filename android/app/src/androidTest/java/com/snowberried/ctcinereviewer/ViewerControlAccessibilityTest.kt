package com.snowberried.ctcinereviewer

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

class ViewerControlAccessibilityTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun originalComparePointerIsTrueOnlyWhilePressed() {
        val comparingOriginal = AtomicBoolean(false)
        setOriginalCompareButton(comparingOriginal.get(), comparingOriginal::set)
        val button = compose.onNodeWithTag("original-compare")
        compose.mainClock.autoAdvance = false

        button.performTouchInput { down(center) }
        compose.runOnIdle { assertTrue(comparingOriginal.get()) }

        button.performTouchInput { up() }
        compose.runOnIdle { assertFalse(comparingOriginal.get()) }
        compose.mainClock.advanceTimeBy(1_001L)
        compose.runOnIdle { assertFalse(comparingOriginal.get()) }
    }

    @Test
    fun originalCompareSemanticsClickShowsOriginalThenReturnsToCorrection() {
        val events = CopyOnWriteArrayList<Boolean>()
        setOriginalCompareButton(onChange = events::add)
        val button = compose.onNodeWithTag("original-compare")

        button.performClick()
        compose.waitUntil(timeoutMillis = 2_000L) { events.size >= 2 }

        assertEquals(listOf(true, false), events.take(2))
    }

    @Test
    fun ccrSliderKeepsProgressSemanticsWithThinTrackAndRoundThumb() {
        compose.setContent {
            MaterialTheme {
                CcrSlider(
                    value = 0.5f,
                    onValueChange = {},
                    steps = 99,
                    modifier = Modifier.testTag("slider-under-test"),
                )
            }
        }

        val slider = compose.onNodeWithTag("slider-under-test")
        assertTrue(slider.fetchSemanticsNode().config.contains(SemanticsActions.SetProgress))
        compose.onNodeWithTag("ccr-slider-track", useUnmergedTree = true)
            .assertHeightIsEqualTo(2.dp)
        compose.onNodeWithTag("ccr-slider-thumb", useUnmergedTree = true)
            .assertWidthIsEqualTo(12.dp)
            .assertHeightIsEqualTo(12.dp)
    }

    private fun setOriginalCompareButton(
        comparingOriginal: Boolean = false,
        onChange: (Boolean) -> Unit,
    ) {
        compose.setContent {
            MaterialTheme {
                Row(modifier = Modifier.fillMaxWidth()) {
                    OriginalCompareButton(
                        comparingOriginal = comparingOriginal,
                        onComparingOriginalChange = onChange,
                    )
                }
            }
        }
    }
}
