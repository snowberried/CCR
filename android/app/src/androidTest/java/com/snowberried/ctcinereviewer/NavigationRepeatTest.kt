package com.snowberried.ctcinereviewer

import android.view.ViewConfiguration
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
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
    fun holdStartsOnceAndReleaseDoesNotAddOrContinue() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 3)
        val beforeRelease = moves.get()
        button.performTouchInput { up() }
        compose.waitForIdle()

        assertEquals("hold start was not exactly once", 1, beforeRelease)
        assertEquals("release added a move", beforeRelease, moves.get())
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)
        assertEquals("hold callback continued after release", beforeRelease, moves.get())
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
        val afterCancel = moves.get()
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertEquals("hold start was not exactly once", 1, beforeCancel)
        assertEquals("hold callback continued after cancel was handled", afterCancel, moves.get())
        button.performTouchInput { click(center) }
        assertEquals("cancel consumed the next tap", afterCancel + 1, moves.get())
    }

    @Test
    fun releaseImmediatelyBeforeTickRejectsTheScheduledCallback() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() + 32,
        )
        val beforeRelease = moves.get()
        button.performTouchInput { up() }
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertTrue("long press did not produce a tick", beforeRelease >= 1)
        assertEquals("scheduled callback crossed release", beforeRelease, moves.get())
    }

    @Test
    fun leavingButtonBoundsStopsWithoutOvershoot() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 2)
        button.performTouchInput { moveTo(Offset(-1f, center.y)) }
        compose.waitForIdle()
        val afterExit = moves.get()
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertEquals("repeat continued after bounds exit was handled", afterExit, moves.get())
        button.performTouchInput { cancel() }
    }

    @Test
    fun secondPointerStopsWithoutOvershoot() {
        val moves = AtomicInteger()
        setButton { moves.incrementAndGet() }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(0, center) }
        advancePastLongPress(repeatIntervals = 2)
        button.performTouchInput { down(1, center + Offset(4f, 4f)) }
        compose.waitForIdle()
        val afterSecondPointer = moves.get()
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertEquals("repeat continued after second pointer was handled", afterSecondPointer, moves.get())
        button.performTouchInput { cancel() }
    }

    @Test
    fun lifecycleStopAndComposableDisposeBothRejectScheduledCallbacks() {
        val moves = AtomicInteger()
        val show = mutableStateOf(true)
        val owner = TestLifecycleOwner()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            owner.registry.currentState = Lifecycle.State.RESUMED
        }
        compose.setContent {
            CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                MaterialTheme {
                    Row(modifier = Modifier.fillMaxWidth()) {
                        if (show.value) navigationButton(moves)
                    }
                }
            }
        }
        val button = compose.onNodeWithText("+1")
        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 2)
        val beforeStop = moves.get()

        compose.runOnIdle { owner.registry.currentState = Lifecycle.State.CREATED }
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)
        assertEquals("lifecycle stop added or continued a move", beforeStop, moves.get())

        compose.runOnIdle {
            owner.registry.currentState = Lifecycle.State.RESUMED
            show.value = false
        }
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)
        assertEquals("disposal added or continued a move", beforeStop, moves.get())
    }

    @Test
    fun becomingDisabledStopsRepeatAtBoundary() {
        val moves = AtomicInteger()
        val enabled = mutableStateOf(true)
        compose.setContent {
            MaterialTheme {
                Row(modifier = Modifier.fillMaxWidth()) {
                    navigationButton(moves, enabled.value) {
                        if (moves.incrementAndGet() == 1) enabled.value = false
                    }
                }
            }
        }
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(repeatIntervals = 8)
        button.performTouchInput { up() }
        compose.waitForIdle()

        assertEquals("disabled button repeated hold start", 1, moves.get())
    }

    private fun advancePastLongPress(repeatIntervals: Int) {
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() + repeatIntervals.coerceAtLeast(1) * 32L,
        )
    }

    private fun setButton(onClick: () -> Unit) {
        compose.setContent {
            MaterialTheme {
                Row(modifier = Modifier.fillMaxWidth()) {
                    navigationButton(onClick = onClick)
                }
            }
        }
    }

    @Composable
    private fun androidx.compose.foundation.layout.RowScope.navigationButton(
        moves: AtomicInteger = AtomicInteger(),
        enabled: Boolean = true,
        onClick: () -> Unit = { moves.incrementAndGet() },
    ) {
        val gate = androidx.compose.runtime.remember { NavigationGestureGate() }
        NavigationButton(
            label = "+1",
            delta = 1,
            enabled = enabled,
            onGestureStart = gate::begin,
            onTap = { _, generation -> if (gate.accepts(generation)) onClick() },
            onHoldStart = { _, generation -> if (gate.accepts(generation)) onClick() },
            onGestureEnd = gate::end,
        )
    }

    private class TestLifecycleOwner : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private companion object {
        const val HOLD_SETTLE_MS = 150L
    }
}
