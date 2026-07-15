package com.snowberried.ctcinereviewer.macrobenchmark

import android.content.ComponentName
import android.content.Intent
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.ExperimentalMetricApi
import androidx.benchmark.macro.ExperimentalMacrobenchmarkApi
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MemoryUsageMetric
import androidx.benchmark.macro.Metric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.TraceSectionMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@LargeTest
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalMetricApi::class, ExperimentalMacrobenchmarkApi::class)
class CcrProductMacrobenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    @Test
    fun coldStartup() = startup(StartupMode.COLD)

    @Test
    fun warmStartup() = startup(StartupMode.WARM)

    @Test
    fun fixtureEntry() = fixture(SCENARIO_ENTRY, TRACE_FIXTURE_ENTRY)

    @Test
    fun fileOpenToIndexComplete() = fixture(SCENARIO_OPEN_INDEX, TRACE_OPEN_TO_INDEX)

    @Test
    fun fileOpenToFirstPublishedFrame() = fixture(SCENARIO_OPEN_FIRST_FRAME, TRACE_OPEN_TO_FIRST_FRAME)

    @Test
    fun plusOneCacheHit() = fixture(SCENARIO_CACHE_HIT, TRACE_REQUEST_TO_PUBLISH)

    @Test
    fun plusOneCacheMiss() = fixture(SCENARIO_CACHE_MISS, TRACE_REQUEST_TO_PUBLISH)

    @Test
    fun plusFive() = fixture(SCENARIO_STEP_FIVE, TRACE_REQUEST_TO_PUBLISH)

    @Test
    fun longPressNavigation() = fixture(SCENARIO_LONG_PRESS, TRACE_REQUEST_TO_PUBLISH)

    @Test
    fun timelineDistantSeek() = fixture(SCENARIO_TIMELINE_SEEK, TRACE_REQUEST_TO_PUBLISH)

    @Test
    fun h264ToH264() = fixture(SCENARIO_SWITCH_H264_H264, TRACE_SWITCH_TO_FIRST_FRAME)

    @Test
    fun h264ToHevc() = fixture(SCENARIO_SWITCH_H264_HEVC, TRACE_SWITCH_TO_FIRST_FRAME)

    @Test
    fun hevcToH264() = fixture(SCENARIO_SWITCH_HEVC_H264, TRACE_SWITCH_TO_FIRST_FRAME)

    @Test
    fun hevcToHevc() = fixture(SCENARIO_SWITCH_HEVC_HEVC, TRACE_SWITCH_TO_FIRST_FRAME)

    @Test
    fun backgroundForegroundFirstFrame() = benchmarkRule.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = interactionMetrics(TRACE_BACKGROUND_TO_FIRST_FRAME),
        iterations = ITERATIONS,
        compilationMode = CompilationMode.Ignore(),
        startupMode = null,
        setupBlock = {
            startActivityAndWait(benchmarkIntent(SCENARIO_PREPARE))
            awaitComplete(SCENARIO_PREPARE)
            killProcess()
            startActivityAndWait(benchmarkIntent(SCENARIO_BACKGROUND_FOREGROUND))
            awaitComplete(SCENARIO_BACKGROUND_FOREGROUND)
            device.pressHome()
        },
    ) {
        startActivityAndWait(
            benchmarkIntent(SCENARIO_BACKGROUND_FOREGROUND, clearTask = false),
        )
        awaitComplete(SCENARIO_BACKGROUND_FOREGROUND)
    }

    private fun startup(mode: StartupMode) = benchmarkRule.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(StartupTimingMetric()),
        iterations = ITERATIONS,
        compilationMode = CompilationMode.Ignore(),
        startupMode = mode,
    ) {
        startActivityAndWait()
    }

    private fun fixture(scenario: String, traceSection: String) = benchmarkRule.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = interactionMetrics(traceSection),
        iterations = ITERATIONS,
        compilationMode = CompilationMode.Ignore(),
        startupMode = null,
        setupBlock = {
            startActivityAndWait(benchmarkIntent(SCENARIO_PREPARE))
            awaitComplete(SCENARIO_PREPARE)
            killProcess()
        },
    ) {
        startActivityAndWait(benchmarkIntent(scenario))
        awaitComplete(scenario)
    }

    private fun interactionMetrics(traceSection: String): List<Metric> = listOf(
        TraceSectionMetric(
            sectionName = traceSection,
            mode = TraceSectionMetric.Mode.Sum,
        ),
        FrameTimingMetric(),
        MemoryUsageMetric(MemoryUsageMetric.Mode.Max),
    )

    private fun benchmarkIntent(scenario: String, clearTask: Boolean = true) = Intent(ACTION_BENCHMARK).apply {
        component = ComponentName(TARGET_PACKAGE, BENCHMARK_ACTIVITY)
        putExtra(EXTRA_SCENARIO, scenario)
        val taskFlags = if (clearTask) {
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        } else {
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        addFlags(taskFlags)
    }

    private fun awaitComplete(scenario: String) {
        check(
            device.wait(
                Until.hasObject(By.text("$STATUS_PREFIX-$scenario-$SUFFIX_COMPLETE")),
                SCENARIO_TIMEOUT_MS,
            ),
        ) { "Benchmark scenario did not complete: $scenario" }
    }

    companion object {
        private const val TARGET_PACKAGE = "com.snowberried.ctcinereviewer.internal"
        private const val BENCHMARK_ACTIVITY =
            "com.snowberried.ctcinereviewer.benchmark.BenchmarkActivity"
        private const val ACTION_BENCHMARK = "$TARGET_PACKAGE.BENCHMARK"
        private const val EXTRA_SCENARIO = "benchmark-scenario"
        private const val STATUS_PREFIX = "ccr-benchmark"
        private const val SUFFIX_COMPLETE = "complete"
        private const val ITERATIONS = 5
        private const val SCENARIO_TIMEOUT_MS = 30_000L

        private const val SCENARIO_PREPARE = "prepare"
        private const val SCENARIO_ENTRY = "entry"
        private const val SCENARIO_OPEN_INDEX = "open-index"
        private const val SCENARIO_OPEN_FIRST_FRAME = "open-first-frame"
        private const val SCENARIO_CACHE_HIT = "plus-one-cache-hit"
        private const val SCENARIO_CACHE_MISS = "plus-one-cache-miss"
        private const val SCENARIO_STEP_FIVE = "plus-five"
        private const val SCENARIO_LONG_PRESS = "long-press"
        private const val SCENARIO_TIMELINE_SEEK = "timeline-distant-seek"
        private const val SCENARIO_SWITCH_H264_H264 = "switch-h264-h264"
        private const val SCENARIO_SWITCH_H264_HEVC = "switch-h264-hevc"
        private const val SCENARIO_SWITCH_HEVC_H264 = "switch-hevc-h264"
        private const val SCENARIO_SWITCH_HEVC_HEVC = "switch-hevc-hevc"
        private const val SCENARIO_BACKGROUND_FOREGROUND = "background-foreground"

        private const val TRACE_OPEN_TO_INDEX = "ccr.open_to_index"
        private const val TRACE_OPEN_TO_FIRST_FRAME = "ccr.open_to_first_frame"
        private const val TRACE_REQUEST_TO_PUBLISH = "ccr.request_to_publish"
        private const val TRACE_SWITCH_TO_FIRST_FRAME = "ccr.switch_to_first_frame"
        private const val TRACE_FIXTURE_ENTRY = "ccr.fixture_entry"
        private const val TRACE_BACKGROUND_TO_FIRST_FRAME = "ccr.background_to_first_frame"
    }
}
