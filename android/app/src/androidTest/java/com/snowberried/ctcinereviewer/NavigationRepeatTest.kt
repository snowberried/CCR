package com.snowberried.ctcinereviewer

import android.view.ViewConfiguration
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class NavigationRepeatTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun shortTapMovesExactlyOnce() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }

        compose.onNodeWithText("+1").performTouchInput { click(center) }

        assertEquals(1, moves.get())
    }

    @Test
    fun holdRepeatsAndReleaseDoesNotAddOrContinue() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 3)
        val beforeRelease = moves.get()
        button.performTouchInput { up() }
        compose.waitForIdle()

        assertTrue("hold did not repeat: $beforeRelease", beforeRelease >= 3)
        assertEquals("release added a move", beforeRelease, moves.get())
        compose.mainClock.advanceTimeBy(NAVIGATION_REPEAT_INTERVAL_MS * 3)
        assertEquals("repeat continued after release", beforeRelease, moves.get())
    }

    @Test
    fun cancelStopsRepeatAndDoesNotConsumeNextTap() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 2)
        val beforeCancel = moves.get()
        button.performTouchInput { cancel() }
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(NAVIGATION_REPEAT_INTERVAL_MS * 3)

        assertTrue("hold did not repeat before cancel: $beforeCancel", beforeCancel >= 2)
        assertEquals("repeat continued after cancel", beforeCancel, moves.get())
        button.performTouchInput { click(center) }
        assertEquals("cancel consumed the next tap", beforeCancel + 1, moves.get())
    }

    @Test
    fun becomingDisabledStopsRepeatAtBoundary() {
        val moves = AtomicInteger()
        val enabled = mutableStateOf(true)
        compose.setContent {
            MaterialTheme {
                Row(modifier = Modifier.fillMaxWidth()) {
                    NavigationButton("+1", enabled = enabled.value) {
                        if (moves.incrementAndGet() == 3) enabled.value = false
                    }
                }
            }
        }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 8)
        button.performTouchInput { up() }
        compose.waitForIdle()

        assertEquals("disabled button continued repeating", 3, moves.get())
    }

    private fun advancePastLongPress(repeatIntervals: Int) {
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() +
                NAVIGATION_REPEAT_INTERVAL_MS * repeatIntervals + 32,
        )
    }

    private fun setButton(onClick: () -> Unit) {
        compose.setContent {
            MaterialTheme {
                Row(modifier = Modifier.fillMaxWidth()) {
                    NavigationButton("+1", enabled = true, onClick = onClick)
                }
            }
        }
    }
}
