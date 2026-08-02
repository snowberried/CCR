package com.snowberried.ctcinereviewer.gate

import android.net.Uri
import android.os.SystemClock
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import org.json.JSONArray
import org.json.JSONObject

internal enum class Alpha6SurfaceFailureClassification {
    SURFACE_NOT_STABLE_BEFORE_OPEN,
    SURFACE_LOST_DURING_OPEN,
    STALE_ACTIVITY_INSTANCE,
    PROVIDER_OR_EXTRACTOR_OPEN_FAILURE,
    DECODER_SURFACE_UNAVAILABLE,
    UNCLASSIFIED_AFTER_STABLE_SURFACE,
}

internal data class Alpha6GateSurfaceSnapshot(
    val capturedAtElapsedRealtimeNs: Long,
    val scenarioState: String,
    val activityInstanceId: Int?,
    val activityFinishing: Boolean?,
    val activityDestroyed: Boolean?,
    val decorAttached: Boolean?,
    val surfaceViewPresent: Boolean?,
    val surfaceValid: Boolean?,
    val surfaceGeneration: Long?,
    val decoderSurfaceAvailable: Boolean,
)

internal data class Alpha6GateDriftCounters(
    val activityInstanceDriftCount: Int,
    val surfaceGenerationDriftCount: Int,
    val surfaceLossCount: Int,
)

internal data class Alpha6StableGateLease(
    val activity: GateActivity,
    val snapshot: Alpha6GateSurfaceSnapshot,
)

internal data class Alpha6OpenedGateActivity(
    val activity: GateActivity,
    val beforeOpen: Alpha6GateSurfaceSnapshot,
    val afterOpen: Alpha6GateSurfaceSnapshot,
)

internal data class Alpha6GateEvent(
    val capturedAtElapsedRealtimeNs: Long,
    val status: String,
    val detail: String,
)

internal data class Alpha6OpenAttemptEvidence(
    val activity: GateActivity?,
    val beforeOpen: Alpha6GateSurfaceSnapshot,
    val afterOpen: Alpha6GateSurfaceSnapshot,
    val providerReadOpenCountBefore: Int,
    val dispatched: Boolean,
    val events: List<Alpha6GateEvent>,
)

internal class Alpha6StableGateException(
    val classification: Alpha6SurfaceFailureClassification,
    val stageCode: String,
    val sanitizedDetail: String,
) : AssertionError("$classification:$stageCode:$sanitizedDetail")

/**
 * AndroidTest-only Surface contract. It deliberately does not change GateActivity or product
 * rendering code: every open reacquires ActivityScenario's current RESUMED activity, proves the
 * decoder Surface is currently available, and continuously observes the actual SurfaceView for
 * one stable interval before dispatching the open on that same activity and generation.
 */
internal class Alpha6StableGateActivity(
    private val scenario: ActivityScenario<GateActivity>,
) {
    private var activityInstanceDriftCount = 0
    private var surfaceGenerationDriftCount = 0
    private var surfaceLossCount = 0
    private var decoderReadyInstanceId: Int? = null
    private var decoderReadyGeneration: Long? = null
    private val attemptEvents = mutableListOf<Alpha6GateEvent>()
    private var attemptActivity: GateActivity? = null
    private var attemptBeforeOpen: Alpha6GateSurfaceSnapshot? = null
    private var attemptAfterOpen: Alpha6GateSurfaceSnapshot? = null
    private var attemptProviderReadOpenCountBefore = 0
    private var attemptDispatched = false
    private var lastAttemptEvidence: Alpha6OpenAttemptEvidence? = null

    fun awaitStableCurrent(timeoutMs: Long = DEFAULT_TIMEOUT_MS): Alpha6StableGateLease {
        val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
        val stability = Alpha6SurfaceStabilityMachine()
        var lastSnapshot = unavailableSnapshot()
        var lastReason = Alpha6SurfaceStabilityMachine.Reason.STABILITY_TIMEOUT

        while (SystemClock.elapsedRealtime() < deadlineMs) {
            var observed = observeCurrent()
            val activity = observed.activity
            val generation = observed.snapshot.surfaceGeneration
            if (activity != null &&
                generation != null &&
                observed.snapshot.isCurrentSurfaceCandidate() &&
                !decoderReadyMatches(activity)
            ) {
                val decoderWaitMs = minOf(
                    DECODER_WAIT_SLICE_MS,
                    (deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(1L),
                )
                if (activity.awaitSurfaceAvailabilityAfter(generation - 1L, true, decoderWaitMs)) {
                    decoderReadyInstanceId = System.identityHashCode(activity)
                    decoderReadyGeneration = activity.surfaceAvailabilityGeneration()
                }
                observed = observeCurrent()
            }
            lastSnapshot = observed.snapshot
            val decision = stability.observe(lastSnapshot.toMachineObservation(), deadlineMs)
            lastReason = decision.reason
            if (decision.outcome == Alpha6SurfaceStabilityMachine.Outcome.READY &&
                observed.activity != null &&
                decision.candidateActivityInstanceId != null &&
                decision.candidateSurfaceGeneration != null
            ) {
                val current = observeCurrent()
                lastSnapshot = current.snapshot
                val leaseDecision = stability.validateLease(
                    current.snapshot.toMachineObservation(),
                    decision.candidateActivityInstanceId,
                    decision.candidateSurfaceGeneration,
                )
                lastReason = leaseDecision.reason
                if (leaseDecision.outcome == Alpha6SurfaceStabilityMachine.Outcome.READY &&
                    current.activity === observed.activity
                ) {
                    return Alpha6StableGateLease(requireNotNull(current.activity), current.snapshot)
                }
            }
            pollUntil(deadlineMs)
        }

        val failureContract = lastReason.failureContract()
        throw Alpha6StableGateException(
            classification = failureContract.first,
            stageCode = failureContract.second,
            sanitizedDetail = lastSnapshot.sanitizedState(),
        )
    }

    fun openFixture(
        uri: Uri,
        timeoutMs: Long = DEFAULT_OPEN_TIMEOUT_MS,
    ): Alpha6OpenedGateActivity = openFixtureInternal(uri, timeoutMs, {})

    fun openFixtureAfterStableAction(
        uri: Uri,
        timeoutMs: Long = DEFAULT_OPEN_TIMEOUT_MS,
        beforeOpen: (GateActivity) -> Unit,
    ): Alpha6OpenedGateActivity =
        openFixtureInternal(uri, timeoutMs, beforeOpen)

    private fun openFixtureInternal(
        uri: Uri,
        timeoutMs: Long,
        beforeDispatch: (GateActivity) -> Unit,
    ): Alpha6OpenedGateActivity {
        beginOpenAttempt()
        val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
        var lastFailure = Alpha6StableGateException(
            Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN,
            "GATE_SURFACE_STABILITY_TIMEOUT",
            "OPEN_NOT_ATTEMPTED",
        )

        while (SystemClock.elapsedRealtime() < deadlineMs) {
            val lease = try {
                awaitStableCurrent((deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(1L))
            } catch (failure: Alpha6StableGateException) {
                val failedSnapshot = observeCurrent().snapshot
                attemptBeforeOpen = failedSnapshot
                attemptAfterOpen = failedSnapshot
                recordAttemptEvent("GATE_STABILITY_FAILED", failure.stageCode)
                publishAttemptEvidence()
                throw failure
            }
            var beforeSnapshot = lease.snapshot
            var afterOpen = lease.snapshot
            var opened = false
            var dispatched = false
            var driftStageCode: String? = null
            var dispatchFailure: Throwable? = null
            attemptActivity = lease.activity
            attemptBeforeOpen = lease.snapshot
            attemptAfterOpen = lease.snapshot
            recordAttemptEvent("GATE_STABILITY_READY", lease.snapshot.sanitizedState())
            publishAttemptEvidence()

            try {
                val scenarioState = scenario.state
                scenario.onActivity { current ->
                    beforeSnapshot = snapshotOnMain(
                        activity = current,
                        scenarioState = scenarioState,
                        decoderSurfaceAvailable = decoderReadyMatches(current),
                    )
                    attemptActivity = current
                    attemptBeforeOpen = beforeSnapshot
                    attemptAfterOpen = beforeSnapshot
                    recordAttemptEvent("GATE_PRE_DISPATCH", beforeSnapshot.sanitizedState())
                    publishAttemptEvidence()
                    when {
                        current !== lease.activity -> {
                            driftStageCode = "GATE_ACTIVITY_INSTANCE_STALE"
                        }
                        beforeSnapshot.surfaceGeneration != lease.snapshot.surfaceGeneration -> {
                            driftStageCode = "GATE_SURFACE_GENERATION_CHANGED"
                        }
                        !beforeSnapshot.isReadyForOpen() -> {
                            driftStageCode = "GATE_SURFACE_NOT_CURRENT"
                        }
                        else -> {
                            beforeDispatch(current)
                            current.openFixture(uri)
                            dispatched = true
                            attemptDispatched = true
                            recordAttemptEvent("OPEN_DISPATCHED", "OPEN_FIXTURE_DISPATCHED")
                            afterOpen = snapshotOnMain(
                                activity = current,
                                scenarioState = scenarioState,
                                decoderSurfaceAvailable = decoderReadyMatches(current),
                            )
                            attemptAfterOpen = afterOpen
                            publishAttemptEvidence()
                            opened = afterOpen.surfaceGeneration == beforeSnapshot.surfaceGeneration &&
                                afterOpen.isReadyForOpen()
                            if (!opened) {
                                surfaceLossCount += 1
                                if (afterOpen.surfaceGeneration != beforeSnapshot.surfaceGeneration) {
                                    surfaceGenerationDriftCount += 1
                                    driftStageCode = "GATE_SURFACE_GENERATION_CHANGED"
                                } else {
                                    driftStageCode = "GATE_SURFACE_NOT_CURRENT"
                                }
                            }
                        }
                    }
                }
            } catch (failure: Throwable) {
                if (failure is IllegalStateException) {
                    activityInstanceDriftCount += 1
                    driftStageCode = "GATE_ACTIVITY_INSTANCE_STALE"
                } else {
                    dispatchFailure = failure
                }
            }
            attemptBeforeOpen = beforeSnapshot
            attemptAfterOpen = afterOpen
            publishAttemptEvidence()
            dispatchFailure?.let { failure ->
                recordAttemptEvent(
                    "OPEN_DISPATCH_FAILED",
                    failure.javaClass.simpleName.take(80),
                )
                publishAttemptEvidence()
                throw failure
            }

            if (opened) {
                val current = observeCurrent()
                afterOpen = current.snapshot
                attemptActivity = current.activity ?: lease.activity
                attemptAfterOpen = afterOpen
                when {
                    current.activity !== lease.activity -> {
                        activityInstanceDriftCount += 1
                        driftStageCode = "GATE_ACTIVITY_INSTANCE_STALE"
                    }
                    afterOpen.surfaceGeneration != beforeSnapshot.surfaceGeneration -> {
                        surfaceGenerationDriftCount += 1
                        surfaceLossCount += 1
                        driftStageCode = "GATE_SURFACE_GENERATION_CHANGED"
                    }
                    !afterOpen.isReadyForOpen() -> {
                        if (afterOpen.surfaceValid == false) surfaceLossCount += 1
                        driftStageCode = "GATE_SURFACE_NOT_CURRENT"
                    }
                    else -> {
                        recordAttemptEvent("OPEN_SURFACE_STABLE", afterOpen.sanitizedState())
                        publishAttemptEvidence()
                        return Alpha6OpenedGateActivity(lease.activity, beforeSnapshot, afterOpen)
                    }
                }
            }

            lastFailure = Alpha6StableGateException(
                classification = when {
                    driftStageCode == "GATE_ACTIVITY_INSTANCE_STALE" ->
                        Alpha6SurfaceFailureClassification.STALE_ACTIVITY_INSTANCE
                    dispatched -> Alpha6SurfaceFailureClassification.SURFACE_LOST_DURING_OPEN
                    else -> Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN
                },
                stageCode = driftStageCode ?: "GATE_SURFACE_NOT_CURRENT",
                sanitizedDetail = afterOpen.sanitizedState(),
            )
            recordAttemptEvent("OPEN_SURFACE_DRIFT", lastFailure.stageCode)
            publishAttemptEvidence()
            if (dispatched) throw lastFailure
        }
        recordAttemptEvent("OPEN_STABILITY_TIMEOUT", lastFailure.stageCode)
        publishAttemptEvidence()
        throw lastFailure
    }

    fun currentSnapshot(): Alpha6GateSurfaceSnapshot = observeCurrent().snapshot

    fun lastOpenAttemptEvidence(): Alpha6OpenAttemptEvidence? = lastAttemptEvidence

    fun driftCounters(): Alpha6GateDriftCounters = Alpha6GateDriftCounters(
        activityInstanceDriftCount = activityInstanceDriftCount,
        surfaceGenerationDriftCount = surfaceGenerationDriftCount,
        surfaceLossCount = surfaceLossCount,
    )

    private fun beginOpenAttempt() {
        attemptEvents.clear()
        attemptProviderReadOpenCountBefore = ReadOnlyFixtureProvider.readOpenCount.get()
        attemptDispatched = false
        val current = observeCurrent()
        attemptActivity = current.activity
        attemptBeforeOpen = current.snapshot
        attemptAfterOpen = current.snapshot
        recordAttemptEvent("GATE_STABILITY_BEGIN", current.snapshot.sanitizedState())
        publishAttemptEvidence()
    }

    private fun recordAttemptEvent(status: String, detail: String) {
        attemptEvents += Alpha6GateEvent(
            capturedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            status = status,
            detail = detail,
        )
    }

    private fun publishAttemptEvidence() {
        val before = attemptBeforeOpen ?: unavailableSnapshot()
        val after = attemptAfterOpen ?: before
        lastAttemptEvidence = Alpha6OpenAttemptEvidence(
            activity = attemptActivity,
            beforeOpen = before,
            afterOpen = after,
            providerReadOpenCountBefore = attemptProviderReadOpenCountBefore,
            dispatched = attemptDispatched,
            events = attemptEvents.toList(),
        )
    }

    private fun observeCurrent(): ObservedActivity {
        val scenarioState = try {
            scenario.state
        } catch (_: IllegalStateException) {
            return ObservedActivity(null, unavailableSnapshot("DESTROYED"))
        }
        var observed: ObservedActivity? = null
        try {
            scenario.onActivity { activity ->
                observed = ObservedActivity(
                    activity = activity,
                    snapshot = snapshotOnMain(
                        activity = activity,
                        scenarioState = scenarioState,
                        decoderSurfaceAvailable = decoderReadyMatches(activity),
                    ),
                )
            }
        } catch (_: IllegalStateException) {
            return ObservedActivity(null, unavailableSnapshot(scenarioState.name))
        }
        return observed ?: ObservedActivity(null, unavailableSnapshot(scenarioState.name))
    }

    private fun snapshotOnMain(
        activity: GateActivity,
        scenarioState: Lifecycle.State,
        decoderSurfaceAvailable: Boolean,
    ): Alpha6GateSurfaceSnapshot {
        val decor = activity.window.decorView
        val surfaceView = findSurfaceView(decor)
        return Alpha6GateSurfaceSnapshot(
            capturedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            scenarioState = scenarioState.name,
            activityInstanceId = System.identityHashCode(activity),
            activityFinishing = activity.isFinishing,
            activityDestroyed = activity.isDestroyed,
            decorAttached = decor.isAttachedToWindow,
            surfaceViewPresent = surfaceView != null,
            surfaceValid = surfaceView?.holder?.surface?.isValid,
            surfaceGeneration = activity.surfaceAvailabilityGeneration(),
            decoderSurfaceAvailable = decoderSurfaceAvailable,
        )
    }

    private fun decoderReadyMatches(activity: GateActivity): Boolean =
        decoderReadyInstanceId == System.identityHashCode(activity) &&
            decoderReadyGeneration == activity.surfaceAvailabilityGeneration()

    private fun findSurfaceView(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) {
            findSurfaceView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun pollUntil(deadlineMs: Long) {
        val remainingMs = deadlineMs - SystemClock.elapsedRealtime()
        if (remainingMs > 0L) SystemClock.sleep(minOf(POLL_INTERVAL_MS, remainingMs))
    }

    private fun unavailableSnapshot(state: String = runCatching { scenario.state.name }.getOrDefault("UNKNOWN")) =
        Alpha6GateSurfaceSnapshot(
            capturedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            scenarioState = state,
            activityInstanceId = null,
            activityFinishing = null,
            activityDestroyed = null,
            decorAttached = null,
            surfaceViewPresent = null,
            surfaceValid = null,
            surfaceGeneration = null,
            decoderSurfaceAvailable = false,
        )

    private data class ObservedActivity(
        val activity: GateActivity?,
        val snapshot: Alpha6GateSurfaceSnapshot,
    )

    private companion object {
        const val POLL_INTERVAL_MS = 25L
        const val DECODER_WAIT_SLICE_MS = 250L
        const val DEFAULT_TIMEOUT_MS = 10_000L
        const val DEFAULT_OPEN_TIMEOUT_MS = 15_000L
    }
}

private fun Alpha6GateSurfaceSnapshot.isCurrentResumedActivity(): Boolean =
    scenarioState == Lifecycle.State.RESUMED.name &&
        activityInstanceId != null &&
        activityFinishing == false &&
        activityDestroyed == false &&
        decorAttached == true

private fun Alpha6GateSurfaceSnapshot.isCurrentSurfaceCandidate(): Boolean =
    isCurrentResumedActivity() &&
        surfaceViewPresent == true &&
        surfaceValid == true &&
        surfaceGeneration != null

private fun Alpha6GateSurfaceSnapshot.isReadyForOpen(): Boolean =
    isCurrentSurfaceCandidate() &&
        decoderSurfaceAvailable

private fun Alpha6GateSurfaceSnapshot.toMachineObservation() =
    Alpha6SurfaceStabilityMachine.Observation(
        capturedAtElapsedRealtimeNs / 1_000_000L,
        activityInstanceId,
        scenarioState == Lifecycle.State.RESUMED.name,
        activityFinishing == true,
        activityDestroyed == true,
        decorAttached == true,
        surfaceViewPresent == true,
        surfaceValid == true,
        decoderSurfaceAvailable,
        surfaceGeneration,
    )

private fun Alpha6SurfaceStabilityMachine.Reason.failureContract():
    Pair<Alpha6SurfaceFailureClassification, String> = when (this) {
    Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_INSTANCE_STALE,
    Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_INSTANCE_CHANGED
    -> Alpha6SurfaceFailureClassification.STALE_ACTIVITY_INSTANCE to
        "GATE_ACTIVITY_INSTANCE_STALE"
    Alpha6SurfaceStabilityMachine.Reason.DECODER_SURFACE_UNAVAILABLE ->
        Alpha6SurfaceFailureClassification.DECODER_SURFACE_UNAVAILABLE to
            "GATE_DECODER_SURFACE_UNAVAILABLE"
    Alpha6SurfaceStabilityMachine.Reason.SURFACE_GENERATION_CHANGED ->
        Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN to
            "GATE_SURFACE_GENERATION_CHANGED"
    Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_NOT_CURRENT,
    Alpha6SurfaceStabilityMachine.Reason.SURFACE_NOT_CURRENT
    -> Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN to
        "GATE_SURFACE_NOT_CURRENT"
    Alpha6SurfaceStabilityMachine.Reason.NONE,
    Alpha6SurfaceStabilityMachine.Reason.STABILITY_TIMEOUT
    -> Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN to
        "GATE_SURFACE_STABILITY_TIMEOUT"
}

private fun Alpha6GateSurfaceSnapshot.sanitizedState(): String = buildString {
    append("state=").append(scenarioState)
    append(",activity=").append(activityInstanceId ?: "none")
    append(",finishing=").append(activityFinishing ?: "unknown")
    append(",destroyed=").append(activityDestroyed ?: "unknown")
    append(",attached=").append(decorAttached ?: "unknown")
    append(",surface=").append(surfaceValid ?: "unknown")
    append(",generation=").append(surfaceGeneration ?: "unknown")
    append(",decoder=").append(decoderSurfaceAvailable)
}

internal fun Alpha6StableGateActivity.failureEvidenceJson(
    failure: Throwable,
): JSONObject {
    val attempt = lastOpenAttemptEvidence()
    val providerReadOpenCountAfter = ReadOnlyFixtureProvider.readOpenCount.get()
    val providerOrExtractorEntered = attempt != null &&
        providerReadOpenCountAfter > attempt.providerReadOpenCountBefore
    val current = currentSnapshot()
    val before = attempt?.beforeOpen ?: current
    val after = current
    val classification = when {
        failure is Alpha6StableGateException -> failure.classification
        before.activityInstanceId != null &&
            after.activityInstanceId != null &&
            before.activityInstanceId != after.activityInstanceId ->
            Alpha6SurfaceFailureClassification.STALE_ACTIVITY_INSTANCE
        before.surfaceGeneration != null &&
            after.surfaceGeneration != null &&
            before.surfaceGeneration != after.surfaceGeneration ->
            Alpha6SurfaceFailureClassification.SURFACE_LOST_DURING_OPEN
        before.isReadyForOpen() && !after.isReadyForOpen() ->
            Alpha6SurfaceFailureClassification.SURFACE_LOST_DURING_OPEN
        !before.isCurrentSurfaceCandidate() ->
            Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN
        !before.decoderSurfaceAvailable ->
            Alpha6SurfaceFailureClassification.DECODER_SURFACE_UNAVAILABLE
        providerOrExtractorEntered ->
            Alpha6SurfaceFailureClassification.PROVIDER_OR_EXTRACTOR_OPEN_FAILURE
        else -> Alpha6SurfaceFailureClassification.UNCLASSIFIED_AFTER_STABLE_SURFACE
    }
    val stageCode = if (failure is Alpha6StableGateException) {
        failure.stageCode
    } else {
        "CORRECTNESS_${failure.javaClass.simpleName.uppercase()}"
    }
    val statuses = mutableListOf<Alpha6GateEvent>()
    statuses += attempt?.events.orEmpty()
    val capturedAtNs = SystemClock.elapsedRealtimeNanos()
    attempt?.activity?.drainStatuses()?.forEach { (status, detail) ->
        statuses += Alpha6GateEvent(
            capturedAtElapsedRealtimeNs = capturedAtNs,
            status = alpha6SafeToken(status),
            detail = alpha6SafeToken(detail ?: "NO_DETAIL"),
        )
    }
    if (failure.message?.contains("VIDEO_OPEN_FAILED") == true) {
        statuses += Alpha6GateEvent(
            capturedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            status = "VIDEO_OPEN_FAILED",
            detail = "FAILURE_MESSAGE_RECORDED",
        )
    }
    if (statuses.isEmpty()) {
        statuses += Alpha6GateEvent(
            capturedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            status = "CORRECTNESS_FAILURE",
            detail = alpha6SafeToken(failure.javaClass.simpleName),
        )
    }
    val orderedStatuses = statuses.withIndex()
        .sortedWith(
            compareBy<IndexedValue<Alpha6GateEvent>>(
                { it.value.capturedAtElapsedRealtimeNs },
                { it.index },
            ),
        )
        .mapIndexed { index, entry ->
            JSONObject()
                .put("ordinal", index)
                .put("sequence", index)
                .put(
                    "capturedAtElapsedRealtimeNs",
                    entry.value.capturedAtElapsedRealtimeNs,
                )
                .put("status", alpha6SafeToken(entry.value.status))
                .put("detail", alpha6SafeToken(entry.value.detail))
        }
    return JSONObject()
        .put("classification", classification.name)
        .put("stageCode", alpha6SafeToken(stageCode))
        .put("exceptionClass", alpha6SafeToken(failure.javaClass.simpleName))
        .put(
            "sanitizedDetail",
            alpha6SafeToken(failure.message ?: failure.javaClass.simpleName),
        )
        .put("providerOrExtractorEntered", providerOrExtractorEntered)
        .put(
            "providerReadOpenCountBefore",
            attempt?.providerReadOpenCountBefore ?: JSONObject.NULL,
        )
        .put("providerReadOpenCountAfter", providerReadOpenCountAfter)
        .put(
            "activitySurfaceEvidence",
            JSONObject()
                .put("beforeOpen", before.surfaceSnapshotJson())
                .put("afterOpen", after.surfaceSnapshotJson())
                .put("statusSequence", JSONArray(orderedStatuses)),
        )
}

private fun Alpha6GateSurfaceSnapshot.surfaceSnapshotJson(): JSONObject = JSONObject()
    .put("capturedAtElapsedRealtimeNs", capturedAtElapsedRealtimeNs)
    .put("scenarioState", scenarioState)
    .put("activityInstanceId", activityInstanceId ?: JSONObject.NULL)
    .put("activityFinishing", activityFinishing ?: JSONObject.NULL)
    .put("activityDestroyed", activityDestroyed ?: JSONObject.NULL)
    .put("decorAttached", decorAttached ?: JSONObject.NULL)
    .put("surfaceViewPresent", surfaceViewPresent ?: JSONObject.NULL)
    .put("surfaceValid", surfaceValid ?: JSONObject.NULL)
    .put("surfaceGeneration", surfaceGeneration ?: JSONObject.NULL)
    .put("decoderSurfaceAvailable", decoderSurfaceAvailable)

private fun alpha6SafeToken(value: String): String =
    value.take(160).takeIf { ALPHA6_SAFE_TOKEN.matches(it) } ?: "REDACTED"

private val ALPHA6_SAFE_TOKEN = Regex("[A-Za-z0-9_.:\\[\\]=,/ -]{1,160}")
