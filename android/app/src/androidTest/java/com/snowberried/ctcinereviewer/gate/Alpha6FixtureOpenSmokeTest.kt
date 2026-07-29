package com.snowberried.ctcinereviewer.gate

import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import org.json.JSONArray
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class Alpha6FixtureOpenSmokeTest {
    @Test
    fun allRequiredFixturesOpenWithoutFrameDecodeOrPerformance() {
        assumeTrue(
            "Alpha 6 fixture-open smoke requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", ignoreCase = true) &&
                Build.MODEL.startsWith("SM-S928"),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        val startedAtNs = SystemClock.elapsedRealtimeNanos()
        val fixtures = JSONArray()
        val progresses = mutableListOf<Alpha6FixtureOpenProgress>()
        ReadOnlyFixtureProvider.readOpenCount.set(0)
        ReadOnlyFixtureProvider.writeOpenCount.set(0)

        val outcome = runCatching {
            val requiredFixtures = S24FrameAccuracyTest.REQUIRED_FIXTURES
            if (
                requiredFixtures.size != 17 ||
                requiredFixtures != Alpha6FixtureOpenProbe.requiredFixtures
            ) {
                throw Alpha6FixtureProbeException(
                    Alpha6ProbeFailure(
                        stageCode = "FIXTURE_LIST_CONTRACT",
                        classification = "FIXTURE_OPEN_SMOKE_FAILURE",
                        exceptionClass = "ContractViolation",
                        sanitizedDetail = "REQUIRED_FIXTURE_LIST_MISMATCH",
                    ),
                )
            }
            requiredFixtures.forEach { fixtureId ->
                val progress = Alpha6FixtureOpenProgress(fixtureId)
                progresses += progress
                val result = try {
                    Alpha6FixtureOpenProbe.probe(
                        context = context,
                        fixtureId = fixtureId,
                        configureCodec = false,
                        compareExplicitRange = false,
                        progress = progress,
                    )
                } catch (throwable: Throwable) {
                    val failure = Alpha6FixtureOpenProbe.normalizedFailure(throwable)
                    fixtures.put(progress.fixtureJson(failure))
                    throw throwable
                }
                fixtures.put(progress.fixtureJson())
                Alpha6FixtureOpenProbe.requirePassed(result)
            }
            Alpha6FixtureOpenProbe.requireNoWriteOpens()
        }
        val failure = outcome.exceptionOrNull()?.let(Alpha6FixtureOpenProbe::normalizedFailure)
        if (failure != null && fixtures.length() == 0) {
            fixtures.put(
                Alpha6FixtureOpenProbe.fixtureFailureJson(
                    fixture = "fixture-list",
                    failure = failure,
                ),
            )
        }
        val reportOutcome = runCatching {
            val report = Alpha6FixtureOpenProbe.newReport(
                context = context,
                kind = "alpha6-fixture-open-smoke",
                status = if (outcome.isSuccess) "PASS" else "FAIL",
                fixtureReports = fixtures,
                progresses = progresses,
                failure = failure,
            )
            ValidationHarnessV2.putReportIdentity(
                report = report,
                identity = identity,
                startedAtElapsedRealtimeNs = startedAtNs,
                finishedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
                testCount = 1,
                instrumentationExpectedTestCount = 1,
            )
            File(context.filesDir, REPORT_FILE).writeText(report.toString(2))
        }
        outcome.exceptionOrNull()?.let { primary ->
            reportOutcome.exceptionOrNull()?.let(primary::addSuppressed)
            throw primary
        }
        reportOutcome.getOrThrow()
    }

    private companion object {
        const val REPORT_FILE = "s24-alpha6-fixture-open-smoke-v1.json"
    }
}
