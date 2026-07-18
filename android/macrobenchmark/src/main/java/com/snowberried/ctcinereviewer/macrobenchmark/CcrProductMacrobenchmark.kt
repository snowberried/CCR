package com.snowberried.ctcinereviewer.macrobenchmark

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.ExperimentalMetricApi
import androidx.benchmark.macro.ExperimentalMacrobenchmarkApi
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MemoryUsageMetric
import androidx.benchmark.macro.Metric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.TraceSectionMetric
import androidx.benchmark.macro.TraceMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.benchmark.traceprocessor.ExperimentalTraceProcessorApi
import androidx.benchmark.traceprocessor.TraceProcessor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.ceil

@LargeTest
@RunWith(AndroidJUnit4::class)
@OptIn(
    ExperimentalMetricApi::class,
    ExperimentalMacrobenchmarkApi::class,
    ExperimentalTraceProcessorApi::class,
)
class CcrProductMacrobenchmark {
    private data class RequestStageTimestamps(
        val acceptedNs: Long,
        val firstOutputNs: Long?,
        val targetOutputNs: Long?,
        val publishedNs: Long,
    )

    private class CcrRequestStageMetric : TraceMetric() {
        override fun getMeasurements(
            captureInfo: Metric.CaptureInfo,
            traceSession: TraceProcessor.Session,
        ): List<Metric.Measurement> {
            val rows = traceSession.query(
                """
                WITH measurement_window AS (
                    SELECT ts AS start_ns, ts + dur AS end_ns
                    FROM slice
                    WHERE name = '$TRACE_REPRESENTATIVE_SMOOTHNESS' AND dur >= 0
                ),
                accepted AS (
                    SELECT substr(name, length('$REQUEST_ACCEPT_STAGE') + 2) AS request_key,
                           MIN(ts) AS accepted_ns
                    FROM slice
                    WHERE name GLOB '$REQUEST_ACCEPT_STAGE f=* r=* i=* p=*'
                    GROUP BY request_key
                ),
                first_output AS (
                    SELECT substr(name, length('$OUTPUT_FIRST_STAGE') + 2) AS request_key,
                           MIN(ts) AS first_output_ns
                    FROM slice
                    WHERE name GLOB '$OUTPUT_FIRST_STAGE f=* r=* i=* p=*'
                    GROUP BY request_key
                ),
                target_output AS (
                    SELECT substr(name, length('$OUTPUT_TARGET_STAGE') + 2) AS request_key,
                           MIN(ts) AS target_output_ns
                    FROM slice
                    WHERE name GLOB '$OUTPUT_TARGET_STAGE f=* r=* i=* p=*'
                    GROUP BY request_key
                ),
                published AS (
                    SELECT substr(publication.name, length('$PUBLISH_STAGE') + 2) AS request_key,
                           MIN(publication.ts + publication.dur) AS published_ns
                    FROM slice AS publication
                    WHERE publication.name GLOB '$PUBLISH_STAGE f=* r=* i=* p=*'
                      AND publication.dur >= 0
                      AND EXISTS (
                          SELECT 1
                          FROM measurement_window
                          WHERE publication.ts + publication.dur
                              BETWEEN measurement_window.start_ns AND measurement_window.end_ns
                      )
                    GROUP BY request_key
                )
                SELECT accepted.accepted_ns AS accepted_ns,
                       first_output.first_output_ns AS first_output_ns,
                       target_output.target_output_ns AS target_output_ns,
                       published.published_ns AS published_ns
                FROM published
                JOIN accepted USING (request_key)
                LEFT JOIN first_output USING (request_key)
                LEFT JOIN target_output USING (request_key)
                ORDER BY published.published_ns
                """.trimIndent(),
            ).map { row ->
                RequestStageTimestamps(
                    acceptedNs = row.long("accepted_ns"),
                    firstOutputNs = row.nullableLong("first_output_ns"),
                    targetOutputNs = row.nullableLong("target_output_ns"),
                    publishedNs = row.long("published_ns"),
                )
            }.toList()

            val counters = traceSession.query(
                """
                WITH ranked AS (
                    SELECT counter_track.name AS name,
                           CAST(counter.value AS INT) AS value,
                           ROW_NUMBER() OVER (
                               PARTITION BY counter_track.name ORDER BY counter.ts DESC
                           ) AS rank
                    FROM counter
                    JOIN counter_track ON counter.track_id = counter_track.id
                    WHERE counter_track.name IN (
                        'ccr.publication_count',
                        'ccr.measurement_swap_failure'
                    )
                )
                SELECT name, value FROM ranked WHERE rank = 1
                """.trimIndent(),
            ).associate { row -> row.string("name") to row.long("value") }
            check(counters.keys == EXPECTED_COUNTERS) {
                "Missing CCR request-stage counters: ${(EXPECTED_COUNTERS - counters.keys).sorted()}"
            }
            val publishedCount = counters.getValue("ccr.publication_count")
            check(publishedCount > 0L) { "CCR request-stage trace has no successful publications" }
            check(counters.getValue("ccr.measurement_swap_failure") == 0L) {
                "CCR request-stage trace includes a swap failure"
            }
            check(rows.size.toLong() == publishedCount) {
                "CCR publication trace/count mismatch: trace=${rows.size}, counter=$publishedCount"
            }

            rows.forEach { row ->
                check(row.acceptedNs <= row.publishedNs) { "CCR publication precedes request acceptance" }
                check((row.firstOutputNs == null) == (row.targetOutputNs == null)) {
                    "CCR request has only one decoder-output stage"
                }
                row.firstOutputNs?.let { first ->
                    check(first in row.acceptedNs..row.publishedNs) {
                        "CCR first decoder output is outside the request/publication interval"
                    }
                }
                row.targetOutputNs?.let { target ->
                    check(target in row.acceptedNs..row.publishedNs) {
                        "CCR target decoder output is outside the request/publication interval"
                    }
                    check(target >= requireNotNull(row.firstOutputNs)) {
                        "CCR target decoder output precedes first decoder output"
                    }
                }
            }

            val decodedRows = rows.filter { it.firstOutputNs != null }
            check(decodedRows.isNotEmpty()) {
                "CCR request-stage trace contains no decoded request; latency remains unavailable"
            }
            val acceptedToFirstOutputUs = decodedRows.map {
                (requireNotNull(it.firstOutputNs) - it.acceptedNs) / 1_000L
            }.sorted()
            val acceptedToTargetOutputUs = decodedRows.map {
                (requireNotNull(it.targetOutputNs) - it.acceptedNs) / 1_000L
            }.sorted()
            val acceptedToPublicationUs = rows.map {
                (it.publishedNs - it.acceptedNs) / 1_000L
            }.sorted()

            return buildList {
                addSeries("ccrAcceptedToFirstOutput", acceptedToFirstOutputUs)
                addSeries("ccrAcceptedToTargetOutput", acceptedToTargetOutputUs)
                addSeries("ccrAcceptedToSuccessfulPublication", acceptedToPublicationUs)
                add(Metric.Measurement("ccrSuccessfulPublicationTraceCount", rows.size.toDouble()))
                add(Metric.Measurement("ccrDecoderOutputTraceCount", decodedRows.size.toDouble()))
                add(
                    Metric.Measurement(
                        "ccrMissingDecoderOutputTraceCount",
                        (rows.size - decodedRows.size).toDouble(),
                    ),
                )
            }
        }

        private fun MutableList<Metric.Measurement>.addSeries(
            name: String,
            sortedValuesUs: List<Long>,
        ) {
            check(sortedValuesUs.isNotEmpty()) { "CCR request-stage latency series is empty: $name" }
            add(Metric.Measurement("${name}P50Us", sortedValuesUs.percentile(0.50).toDouble()))
            add(Metric.Measurement("${name}P95Us", sortedValuesUs.percentile(0.95).toDouble()))
            add(Metric.Measurement("${name}MaxUs", sortedValuesUs.last().toDouble()))
        }

        private fun List<Long>.percentile(fraction: Double): Long =
            this[(ceil(size * fraction).toInt() - 1).coerceIn(0, lastIndex)]

        private companion object {
            const val REQUEST_ACCEPT_STAGE = "CCR.request.accept"
            const val OUTPUT_FIRST_STAGE = "CCR.output.first"
            const val OUTPUT_TARGET_STAGE = "CCR.output.target"
            const val PUBLISH_STAGE = "CCR.publish"
            val EXPECTED_COUNTERS = setOf(
                "ccr.publication_count",
                "ccr.measurement_swap_failure",
            )
        }
    }

    private class CcrCounterMetric : TraceMetric() {
        override fun getMeasurements(
            captureInfo: Metric.CaptureInfo,
            traceSession: TraceProcessor.Session,
        ): List<Metric.Measurement> {
            val names = COUNTERS.joinToString(",") { "'$it'" }
            val values = traceSession.query(
                """
                WITH ranked AS (
                    SELECT counter_track.name AS name,
                           counter.value AS value,
                           ROW_NUMBER() OVER (
                               PARTITION BY counter_track.name ORDER BY counter.ts DESC
                           ) AS rank
                    FROM counter
                    JOIN counter_track ON counter.track_id = counter_track.id
                    WHERE counter_track.name IN ($names)
                )
                SELECT name, value FROM ranked WHERE rank = 1
                """.trimIndent(),
            ).associate { row -> row.string("name") to row.double("value") }
            val missing = COUNTERS - values.keys
            check(missing.isEmpty()) { "Missing CCR trace counters: ${missing.sorted()}" }
            check(values.getValue("ccr.counter_complete") == 1.0) {
                "CCR trace counters reported incomplete observation"
            }
            check(values.getValue("ccr.valid_trace_identity") == 1.0) {
                "CCR trace identity marker is missing"
            }
            check(values.getValue("ccr.run_iteration") > 0.0) { "CCR run iteration is invalid" }
            return COUNTERS.map { traceName ->
                Metric.Measurement(
                    METRIC_NAMES.getValue(traceName),
                    values.getValue(traceName),
                )
            }
        }

        private companion object {
            val METRIC_NAMES = linkedMapOf(
                "ccr.publication_interval_p50_us" to "ccrPublicationIntervalP50Us",
                "ccr.publication_interval_p95_us" to "ccrPublicationIntervalP95Us",
                "ccr.publication_interval_max_us" to "ccrPublicationIntervalMaxUs",
                "ccr.published_fps_milli" to "ccrPublishedFpsMilli",
                "ccr.publication_count" to "ccrPublicationCount",
                "ccr.active_duration_ms" to "ccrActiveDurationMs",
                "ccr.requested_displayed_lag_p50" to "ccrRawLagP50",
                "ccr.requested_displayed_lag_p95" to "ccrRawLagP95",
                "ccr.raw_lag_max" to "ccrRawLagMax",
                "ccr.outstanding_foreground_target_depth_max" to "ccrOutstandingForegroundTargetDepthMax",
                "ccr.accepted_target_count" to "ccrAcceptedTargetCount",
                "ccr.release_after_accepted_target_count" to "ccrReleaseAfterAcceptedTargetCount",
                "ccr.hold_prefetch_started" to "ccrHoldPrefetchStarted",
                "ccr.hold_prefetch_completed" to "ccrHoldPrefetchCompleted",
                "ccr.counter_complete" to "ccrCounterComplete",
                "ccr.valid_trace_identity" to "ccrValidTraceIdentity",
                "ccr.run_iteration" to "ccrRunIteration",
                "ccr.run_id_hash53" to "ccrRunIdHash53",
                "ccr.trace_identity_hash53" to "ccrTraceIdentityHash53",
                "ccr.runtime_source_hash53" to "ccrRuntimeSourceHash53",
                "ccr.harness_source_hash53" to "ccrHarnessSourceHash53",
                "ccr.runtime_inputs_tree_hash53" to "ccrRuntimeInputsTreeHash53",
            )
            val COUNTERS = METRIC_NAMES.keys
        }
    }

    private data class HarnessIdentity(
        val runId: String,
        val runtimeSourceSha: String,
        val harnessSourceSha: String,
        val runtimeInputsTreeSha256: String,
        val artifactSetRevision: Int,
    )

    private data class IterationEvidence(
        val runIteration: Int,
        val traceIdentity: String,
        val status: String,
    )

    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    private val harnessIdentity by lazy(::readHarnessIdentity)

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
    fun backgroundForegroundFirstFrame() {
        var iteration = 0
        lateinit var traceIdentity: String
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = interactionMetrics(TRACE_BACKGROUND_TO_FIRST_FRAME),
            iterations = ITERATIONS,
            compilationMode = CompilationMode.Ignore(),
            startupMode = null,
            setupBlock = {
                iteration += 1
                traceIdentity = traceIdentity(SCENARIO_BACKGROUND_FOREGROUND, iteration)
                val prepareIdentity = "$traceIdentity.prepare"
                startActivityAndWait(benchmarkIntent(SCENARIO_PREPARE, prepareIdentity, iteration))
                awaitComplete(SCENARIO_PREPARE, prepareIdentity, iteration)
                killProcess()
                startActivityAndWait(
                    benchmarkIntent(SCENARIO_BACKGROUND_FOREGROUND, traceIdentity, iteration),
                )
                awaitComplete(SCENARIO_BACKGROUND_FOREGROUND, traceIdentity, iteration)
                device.pressHome()
            },
        ) {
            startActivityAndWait(
                benchmarkIntent(
                    SCENARIO_BACKGROUND_FOREGROUND,
                    traceIdentity,
                    iteration,
                    clearTask = false,
                ),
            )
            awaitComplete(SCENARIO_BACKGROUND_FOREGROUND, traceIdentity, iteration)
        }
    }

    @Test
    fun hold720PlusOne() = representativeFixture(SCENARIO_HOLD_720_PLUS_ONE)

    @Test
    fun hold720PlusFive() = representativeFixture(SCENARIO_HOLD_720_PLUS_FIVE)

    @Test
    fun hold1080PlusOne() = representativeFixture(SCENARIO_HOLD_1080_PLUS_ONE)

    @Test
    fun hold1080PlusFive() = representativeFixture(SCENARIO_HOLD_1080_PLUS_FIVE)

    @Test
    fun hold1080MinusOneAlpha4Baseline() = representativeFixture(SCENARIO_HOLD_1080_MINUS_ONE)

    @Test
    fun hold1080MinusFiveAlpha4Baseline() = representativeFixture(SCENARIO_HOLD_1080_MINUS_FIVE)

    @Test
    fun reverse1080() = representativeFixture(SCENARIO_REVERSE_1080)

    @Test
    fun distantSeek1080() = representativeFixture(SCENARIO_SEEK_1080)

    @Test
    fun switch1080H264ToHevc() = representativeFixture(SCENARIO_SWITCH_1080_H264_HEVC)

    @Test
    fun switch1080HevcToH264() = representativeFixture(SCENARIO_SWITCH_1080_HEVC_H264)

    private fun startup(mode: StartupMode) = benchmarkRule.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(StartupTimingMetric()),
        iterations = ITERATIONS,
        compilationMode = CompilationMode.Ignore(),
        startupMode = mode,
    ) {
        startActivityAndWait()
    }

    private fun fixture(scenario: String, traceSection: String) {
        var iteration = 0
        lateinit var traceIdentity: String
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = interactionMetrics(traceSection),
            iterations = ITERATIONS,
            compilationMode = CompilationMode.Ignore(),
            startupMode = null,
            setupBlock = {
                iteration += 1
                traceIdentity = traceIdentity(scenario, iteration)
                val prepareIdentity = "$traceIdentity.prepare"
                startActivityAndWait(benchmarkIntent(SCENARIO_PREPARE, prepareIdentity, iteration))
                awaitComplete(SCENARIO_PREPARE, prepareIdentity, iteration)
                killProcess()
            },
        ) {
            startActivityAndWait(benchmarkIntent(scenario, traceIdentity, iteration))
            awaitComplete(scenario, traceIdentity, iteration)
        }
    }

    private fun representativeFixture(scenario: String) {
        var iteration = 0
        lateinit var traceIdentity: String
        val traceIdentities = mutableSetOf<String>()
        val iterationEvidence = mutableListOf<IterationEvidence>()
        val requestStageMetrics = if (scenario in ALPHA4_REVERSE_BASELINE_SCENARIOS) {
            listOf(CcrRequestStageMetric())
        } else {
            emptyList()
        }
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = interactionMetrics(TRACE_REPRESENTATIVE_SMOOTHNESS) +
                CcrCounterMetric() + requestStageMetrics,
            iterations = REPRESENTATIVE_ITERATIONS,
            compilationMode = CompilationMode.Ignore(),
            startupMode = null,
            setupBlock = {
                iteration += 1
                traceIdentity = traceIdentity(scenario, iteration)
                check(traceIdentities.add(traceIdentity)) { "Duplicate trace identity: $traceIdentity" }
                val prepareIdentity = "$traceIdentity.prepare"
                startActivityAndWait(benchmarkIntent(SCENARIO_PREPARE, prepareIdentity, iteration))
                awaitComplete(SCENARIO_PREPARE, prepareIdentity, iteration)
                killProcess()
            },
        ) {
            startActivityAndWait(benchmarkIntent(scenario, traceIdentity, iteration))
            val status = awaitComplete(
                scenario = scenario,
                expectedTraceIdentity = traceIdentity,
                expectedIteration = iteration,
                timeoutMs = REPRESENTATIVE_SCENARIO_TIMEOUT_MS,
                requireCompleteCounters = true,
            )
            iterationEvidence += IterationEvidence(iteration, traceIdentity, status)
        }
        check(iteration == REPRESENTATIVE_ITERATIONS) {
            "Expected $REPRESENTATIVE_ITERATIONS trace identities, observed $iteration for $scenario"
        }
        check(traceIdentities.size == REPRESENTATIVE_ITERATIONS) {
            "Expected $REPRESENTATIVE_ITERATIONS unique trace identities for $scenario"
        }
        check(iterationEvidence.size == REPRESENTATIVE_ITERATIONS) {
            "Expected $REPRESENTATIVE_ITERATIONS iteration reports for $scenario"
        }
        reportHarnessEvidence(scenario, iterationEvidence)
        println(
            "CCR_BENCHMARK_V2_SUMMARY|runId=${harnessIdentity.runId}|scenario=$scenario" +
                "|expectedTraceCount=$REPRESENTATIVE_ITERATIONS" +
                "|traceIdentityCount=${traceIdentities.size}" +
                "|reportStatusKey=$HARNESS_REPORT_STATUS_KEY",
        )
    }

    private fun interactionMetrics(traceSection: String): List<Metric> = listOf(
        TraceSectionMetric(
            sectionName = traceSection,
            mode = TraceSectionMetric.Mode.Sum,
        ),
        FrameTimingMetric(),
        MemoryUsageMetric(MemoryUsageMetric.Mode.Max),
    )

    private fun benchmarkIntent(
        scenario: String,
        traceIdentity: String,
        runIteration: Int,
        clearTask: Boolean = true,
    ) = Intent(ACTION_BENCHMARK).apply {
        component = ComponentName(TARGET_PACKAGE, BENCHMARK_ACTIVITY)
        putExtra(EXTRA_SCENARIO, scenario)
        putExtra(EXTRA_RUN_ID, harnessIdentity.runId)
        putExtra(EXTRA_RUNTIME_SOURCE_SHA, harnessIdentity.runtimeSourceSha)
        putExtra(EXTRA_HARNESS_SOURCE_SHA, harnessIdentity.harnessSourceSha)
        putExtra(EXTRA_RUNTIME_INPUTS_TREE_SHA256, harnessIdentity.runtimeInputsTreeSha256)
        putExtra(EXTRA_TRACE_IDENTITY, traceIdentity)
        putExtra(EXTRA_RUN_ITERATION, runIteration)
        putExtra(EXTRA_ARTIFACT_SET_REVISION, harnessIdentity.artifactSetRevision)
        val taskFlags = if (clearTask) {
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        } else {
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        addFlags(taskFlags)
    }

    private fun awaitComplete(
        scenario: String,
        expectedTraceIdentity: String,
        expectedIteration: Int,
        timeoutMs: Long = SCENARIO_TIMEOUT_MS,
        requireCompleteCounters: Boolean = false,
    ): String {
        val status = device.wait(
            Until.findObject(By.textStartsWith("$STATUS_PREFIX-$scenario-$SUFFIX_COMPLETE")),
            timeoutMs,
        )?.text ?: error("Benchmark scenario did not complete: $scenario")
        val requiredIdentity = listOf(
            "|artifactSetRevision=${harnessIdentity.artifactSetRevision}",
            "|runtimeSourceSha=${harnessIdentity.runtimeSourceSha}",
            "|harnessSourceSha=${harnessIdentity.harnessSourceSha}",
            "|runtimeInputsTreeSha256=${harnessIdentity.runtimeInputsTreeSha256}",
            "|runId=${harnessIdentity.runId}",
            "|traceIdentity=$expectedTraceIdentity",
            "|runIteration=$expectedIteration",
        )
        check(requiredIdentity.all(status::contains)) {
            "Benchmark identity mismatch: $scenario / $expectedTraceIdentity"
        }
        if (requireCompleteCounters) {
            val requiredCounters = listOf(
                "|published=",
                "|fps=",
                "|intervalP50Us=",
                "|lagMax=",
                "|outstandingForegroundTargetDepthMax=",
                "|acceptedTargetCount=",
                "|releaseAfterAcceptedTargetCount=",
                "|holdPrefetchStarted=",
                "|holdPrefetchCompleted=",
                "|codecComponent=",
                "|cacheBudgetBytes=",
                "|cacheBytes=",
                "|textureDoubleReleaseCount=",
                "|staleBeforeSwapCount=",
                "|surfaceInvalidCount=",
                "|publicationInvariantViolationCount=",
                "|javaUsedBytes=",
                "|nativeAllocatedBytes=",
                "|totalPssBytes=",
                "|counterComplete=true",
            )
            check(requiredCounters.all(status::contains)) {
                "Benchmark counters incomplete: $scenario / $expectedTraceIdentity"
            }
        }
        println(
            "CCR_BENCHMARK_V2|runId=${harnessIdentity.runId}" +
                "|traceIdentity=$expectedTraceIdentity|runIteration=$expectedIteration" +
                "|scenario=$scenario|counterRequired=$requireCompleteCounters",
        )
        return status
    }

    private fun reportHarnessEvidence(
        scenario: String,
        evidence: List<IterationEvidence>,
    ) {
        val iterations = JSONArray()
        evidence.forEach { item ->
            val values = item.status.split('|').drop(1).associate { token ->
                val separator = token.indexOf('=')
                check(separator > 0) { "Malformed benchmark status token: $token" }
                token.substring(0, separator) to token.substring(separator + 1)
            }
            fun required(name: String): String = values[name]
                ?: error("Missing benchmark status field: $name")
            check(required("runId") == harnessIdentity.runId) { "Report runId mismatch" }
            check(required("runtimeSourceSha") == harnessIdentity.runtimeSourceSha) {
                "Report runtime source mismatch"
            }
            check(required("harnessSourceSha") == harnessIdentity.harnessSourceSha) {
                "Report harness source mismatch"
            }
            check(required("runtimeInputsTreeSha256") == harnessIdentity.runtimeInputsTreeSha256) {
                "Report runtime inputs tree mismatch"
            }
            check(required("traceIdentity") == item.traceIdentity) { "Report trace identity mismatch" }
            check(required("runIteration").toInt() == item.runIteration) { "Report iteration mismatch" }
            check(required("counterComplete").toBooleanStrict()) { "Report counters incomplete" }
            check(required("codecComponent") != "UNKNOWN") { "Decoder component unavailable" }
            check(required("hardwareAccelerated").toBooleanStrict()) { "Software decoder forbidden" }
            val canonicalFrameBytes = required("canonicalFrameBytes").toLong()
            val cacheBudgetBytes = required("cacheBudgetBytes").toLong()
            val cacheBytes = required("cacheBytes").toLong()
            check(canonicalFrameBytes > 0L && cacheBudgetBytes > 0L) {
                "Cache byte contract unavailable"
            }
            check(cacheBytes in 0L..cacheBudgetBytes) {
                "Cache budget exceeded"
            }
            check(required("staleDiscardCount").toLong() == 0L) { "Stale decode result observed" }
            check(required("outstandingForegroundTargetDepthMax").toInt() <= 1) {
                "More than one foreground target was outstanding"
            }
            check(required("releaseAfterAcceptedTargetCount").toLong() == 0L) {
                "A target was accepted after hold release"
            }
            listOf(
                "swapFailure" to "Swap failure",
                "textureDoubleReleaseCount" to "Texture double release",
                "staleBeforeSwapCount" to "Stale swap",
                "surfaceInvalidCount" to "Invalid Surface publication",
                "publicationInvariantViolationCount" to "Publication invariant violation",
            ).forEach { (field, description) ->
                check(required(field).toLong() == 0L) { "$description observed" }
            }
            check(required("gpuMetricAvailability") == "UNKNOWN") {
                "Unexpected GPU metric availability value"
            }
            iterations.put(
                JSONObject()
                    .put("runIteration", item.runIteration)
                    .put("traceIdentity", item.traceIdentity)
                    .put("counterComplete", true)
                    .put("activeMs", required("activeMs").toLong())
                    .put("published", required("published").toLong())
                    .put("publishedFps", required("fps").toDouble())
                    .put("publicationIntervalP50Us", required("intervalP50Us").toLong())
                    .put("publicationIntervalP95Us", required("intervalP95Us").toLong())
                    .put("publicationIntervalMaxUs", required("intervalMaxUs").toLong())
                    .put("publicationGapMaxUs", required("gapMaxUs").toLong())
                    .put("rawLagP50", required("lagP50").toLong())
                    .put("rawLagP95", required("lagP95").toLong())
                    .put("rawLagMax", required("lagMax").toLong())
                    .put(
                        "outstandingForegroundTargetDepthMax",
                        required("outstandingForegroundTargetDepthMax").toLong(),
                    )
                    .put("acceptedTargetCount", required("acceptedTargetCount").toLong())
                    .put(
                        "releaseAfterAcceptedTargetCount",
                        required("releaseAfterAcceptedTargetCount").toLong(),
                    )
                    .put("holdPrefetchStarted", required("holdPrefetchStarted").toLong())
                    .put("holdPrefetchCompleted", required("holdPrefetchCompleted").toLong())
                    .put("foregroundDecoded", required("foregroundDecoded").toLong())
                    .put("issuedRequestCount", required("issued").toLong())
                    .put("coalescedRequestCount", required("coalesced").toLong())
                    .put("prefetchHitCount", required("prefetchHit").toLong())
                    .put("cacheEvictionCount", required("cacheEviction").toLong())
                    .put("seekCount", required("seek").toLong())
                    .put("flushCount", required("flush").toLong())
                    .put("sequentialEntryCount", required("sequentialEntry").toLong())
                    .put("sequentialFallbackCount", required("sequentialFallback").toLong())
                    .put("sequentialOutputCount", required("sequentialOutput").toLong())
                    .put("swapFailureCount", required("swapFailure").toLong())
                    .put("codecComponent", required("codecComponent"))
                    .put("hardwareAccelerated", required("hardwareAccelerated").toBooleanStrict())
                    .put("canonicalFrameBytes", required("canonicalFrameBytes").toLong())
                    .put("cacheBudgetBytes", required("cacheBudgetBytes").toLong())
                    .put("cacheBytes", required("cacheBytes").toLong())
                    .put("cacheEntryCount", required("cacheEntryCount").toLong())
                    .put("peakCacheEntryCount", required("peakCacheEntryCount").toLong())
                    .put("cacheRejectionCount", required("cacheRejectionCount").toLong())
                    .put("cacheThrashCount", required("cacheThrashCount").toLong())
                    .put("liveTextureCount", required("liveTextureCount").toLong())
                    .put("peakLiveTextureCount", required("peakLiveTextureCount").toLong())
                    .put("textureDoubleReleaseCount", required("textureDoubleReleaseCount").toLong())
                    .put("staleDiscardCount", required("staleDiscardCount").toLong())
                    .put("staleBeforeSwapCount", required("staleBeforeSwapCount").toLong())
                    .put("surfaceInvalidCount", required("surfaceInvalidCount").toLong())
                    .put(
                        "publicationInvariantViolationCount",
                        required("publicationInvariantViolationCount").toLong(),
                    )
                    .put("decoderRecreateCount", required("decoderRecreateCount").toLong())
                    .put("javaUsedBytes", required("javaUsedBytes").toLong())
                    .put("nativeAllocatedBytes", required("nativeAllocatedBytes").toLong())
                    .put("totalPssBytes", required("totalPssBytes").toLong())
                    .put("gpuMetricAvailability", required("gpuMetricAvailability")),
            )
        }
        val report = JSONObject()
            .put("schemaVersion", 1)
            .put("reportKind", "ccr-benchmark-harness-v2")
            .put("artifactSetRevision", harnessIdentity.artifactSetRevision)
            .put("runId", harnessIdentity.runId)
            .put("runtimeSourceSha", harnessIdentity.runtimeSourceSha)
            .put("harnessSourceSha", harnessIdentity.harnessSourceSha)
            .put("runtimeInputsTreeSha256", harnessIdentity.runtimeInputsTreeSha256)
            .put("scenario", scenario)
            .put("measurementDescription", "source-equivalent pinned benchmark measurement build")
            .put("expectedTraceCount", REPRESENTATIVE_ITERATIONS)
            .put("traceIdentityCount", evidence.map(IterationEvidence::traceIdentity).distinct().size)
            .put("traceArtifactValidation", "PENDING_HOST")
            .put("iterations", iterations)
        InstrumentationRegistry.getInstrumentation().sendStatus(
            HARNESS_REPORT_STATUS_CODE,
            Bundle().apply { putString(HARNESS_REPORT_STATUS_KEY, report.toString()) },
        )
    }

    private fun traceIdentity(scenario: String, iteration: Int): String =
        "${harnessIdentity.runId}.$scenario.$iteration"

    private fun readHarnessIdentity(): HarnessIdentity {
        val arguments = InstrumentationRegistry.getArguments()
        fun required(name: String): String = arguments.getString(name)?.takeIf(String::isNotBlank)
            ?: error("Missing instrumentation argument: $name")

        val identity = HarnessIdentity(
            runId = required(ARG_RUN_ID),
            runtimeSourceSha = required(ARG_RUNTIME_SOURCE_SHA),
            harnessSourceSha = required(ARG_HARNESS_SOURCE_SHA),
            runtimeInputsTreeSha256 = required(ARG_RUNTIME_INPUTS_TREE_SHA256),
            artifactSetRevision = required(ARG_ARTIFACT_SET_REVISION).toIntOrNull()
                ?: error("Invalid instrumentation argument: $ARG_ARTIFACT_SET_REVISION"),
        )
        check(identity.runId.matches(RUN_ID_PATTERN)) { "Invalid runId" }
        check(identity.runtimeSourceSha == EXPECTED_RUNTIME_SOURCE_SHA) { "Runtime source mismatch" }
        check(identity.harnessSourceSha.matches(GIT_SHA_PATTERN)) { "Invalid harness source SHA" }
        check(identity.runtimeInputsTreeSha256.matches(SHA256_PATTERN)) { "Invalid runtime inputs tree SHA" }
        check(identity.artifactSetRevision == ARTIFACT_SET_REVISION) { "Artifact set revision mismatch" }
        return identity
    }

    companion object {
        private const val TARGET_PACKAGE = "com.snowberried.ctcinereviewer.internal"
        private const val BENCHMARK_ACTIVITY =
            "com.snowberried.ctcinereviewer.benchmark.BenchmarkActivity"
        private const val ACTION_BENCHMARK = "$TARGET_PACKAGE.BENCHMARK"
        private const val EXTRA_SCENARIO = "benchmark-scenario"
        private const val EXTRA_RUN_ID = "benchmark-run-id"
        private const val EXTRA_RUNTIME_SOURCE_SHA = "benchmark-runtime-source-sha"
        private const val EXTRA_HARNESS_SOURCE_SHA = "benchmark-harness-source-sha"
        private const val EXTRA_RUNTIME_INPUTS_TREE_SHA256 = "benchmark-runtime-inputs-tree-sha256"
        private const val EXTRA_TRACE_IDENTITY = "benchmark-trace-identity"
        private const val EXTRA_RUN_ITERATION = "benchmark-run-iteration"
        private const val EXTRA_ARTIFACT_SET_REVISION = "benchmark-artifact-set-revision"
        private const val ARG_RUN_ID = "runId"
        private const val ARG_RUNTIME_SOURCE_SHA = "runtimeSourceSha"
        private const val ARG_HARNESS_SOURCE_SHA = "harnessSourceSha"
        private const val ARG_RUNTIME_INPUTS_TREE_SHA256 = "runtimeInputsTreeSha256"
        private const val ARG_ARTIFACT_SET_REVISION = "artifactSetRevision"
        private const val HARNESS_REPORT_STATUS_KEY = "ccrBenchmarkHarnessV2"
        private const val HARNESS_REPORT_STATUS_CODE = 2
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
        private const val SCENARIO_HOLD_720_PLUS_ONE = "720p-hold-plus-one"
        private const val SCENARIO_HOLD_720_PLUS_FIVE = "720p-hold-plus-five"
        private const val SCENARIO_HOLD_1080_PLUS_ONE = "1080p-hold-plus-one"
        private const val SCENARIO_HOLD_1080_PLUS_FIVE = "1080p-hold-plus-five"
        private const val SCENARIO_HOLD_1080_MINUS_ONE = "1080p-hold-minus-one"
        private const val SCENARIO_HOLD_1080_MINUS_FIVE = "1080p-hold-minus-five"
        private const val SCENARIO_REVERSE_1080 = "1080p-direction-reverse"
        private const val SCENARIO_SEEK_1080 = "1080p-distant-seek"
        private const val SCENARIO_SWITCH_1080_H264_HEVC = "1080p-switch-h264-hevc"
        private const val SCENARIO_SWITCH_1080_HEVC_H264 = "1080p-switch-hevc-h264"

        private const val TRACE_OPEN_TO_INDEX = "ccr.open_to_index"
        private const val TRACE_OPEN_TO_FIRST_FRAME = "ccr.open_to_first_frame"
        private const val TRACE_REQUEST_TO_PUBLISH = "ccr.request_to_publish"
        private const val TRACE_SWITCH_TO_FIRST_FRAME = "ccr.switch_to_first_frame"
        private const val TRACE_FIXTURE_ENTRY = "ccr.fixture_entry"
        private const val TRACE_BACKGROUND_TO_FIRST_FRAME = "ccr.background_to_first_frame"
        private const val TRACE_REPRESENTATIVE_SMOOTHNESS = "ccr.representative_smoothness"
        private const val REPRESENTATIVE_ITERATIONS = 3
        private const val REPRESENTATIVE_SCENARIO_TIMEOUT_MS = 180_000L
        private const val ARTIFACT_SET_REVISION = 2
        private const val EXPECTED_RUNTIME_SOURCE_SHA = "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e"
        private val RUN_ID_PATTERN = Regex("[A-Za-z0-9._:-]{1,48}")
        private val GIT_SHA_PATTERN = Regex("[0-9a-f]{40}")
        private val SHA256_PATTERN = Regex("[0-9a-f]{64}")
        private val ALPHA4_REVERSE_BASELINE_SCENARIOS = setOf(
            SCENARIO_HOLD_1080_MINUS_ONE,
            SCENARIO_HOLD_1080_MINUS_FIVE,
        )
    }
}
