package com.snowberried.ctcinereviewer

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.CcrTrace
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.DirectionalPrefetchDirection
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.PrefetchPermit
import com.snowberried.ctcinereviewer.media.boundedFrameIndex
import com.snowberried.ctcinereviewer.media.nearestFrameIndexForTimelineFraction
import com.snowberried.ctcinereviewer.render.VideoViewport

enum class ViewerRestoreState {
    NONE,
    WAITING_FOR_SURFACE,
    OPENING,
    DECODING,
    COMPLETE,
    PERMISSION_REQUIRED,
    CANCELLED,
}

data class ViewerUiState(
    val selectedUri: Uri? = null,
    val status: String = "파일을 여세요",
    val detail: String? = null,
    val metadata: ContainerMetadata? = null,
    val requestedFrameIndex: Int = 0,
    val displayedFrame: FrameKey? = null,
    val framePtsUs: List<Long> = emptyList(),
    val directInput: String = "",
    val diagnostics: DecoderDiagnostics = DecoderDiagnostics(),
    val diagnosticsVisible: Boolean = BuildConfig.DEBUG,
    val notice: String? = null,
    val activeFileGeneration: Long? = null,
    val activeRequestGeneration: Long? = null,
    val restoreState: ViewerRestoreState = ViewerRestoreState.NONE,
    val surfaceAvailable: Boolean = false,
    val currentDecodeTarget: Int? = null,
    val latestPendingRequest: Int? = null,
    val recentRequestToPublishLatencyMs: List<Double> = emptyList(),
    val lastPublicationResult: String? = null,
    val surfaceGeneration: Long = 0,
    val lastErrorCode: String? = null,
) {
    val displayedFrameIndex: Int? get() = displayedFrame?.displayFrameIndex
    val isIndexing: Boolean get() = status == "indexing"
    val isDecoding: Boolean get() = status == "decoding"
    val errorOrUnsupportedMessage: String?
        get() = detail?.takeIf { status == "error" || status == "unsupported" }
}

internal fun ViewerUiState.moveRequestedBy(delta: Int): ViewerUiState {
    val frameCount = metadata?.frameCount ?: return this
    return copy(requestedFrameIndex = boundedFrameIndex(requestedFrameIndex, delta, frameCount))
}

internal fun ViewerUiState.applyFrameResult(
    result: FrameResult,
    nextDiagnostics: DecoderDiagnostics,
): ViewerUiState {
    if (result.request.token.fileGeneration != activeFileGeneration) return this
    if (activeRequestGeneration != null && result.request.token.requestGeneration != activeRequestGeneration) return this
    return when (result) {
        is FrameResult.Published -> copy(
            status = "ready",
            detail = if (result.cacheHit) "cache hit" else "decoded",
            displayedFrame = result.request.expectedKey,
            diagnostics = nextDiagnostics,
            activeRequestGeneration = result.request.token.requestGeneration,
            restoreState = ViewerRestoreState.COMPLETE,
        )
        is FrameResult.DiscardedStale -> copy(diagnostics = nextDiagnostics)
        is FrameResult.Unsupported -> copy(
            status = "unsupported",
            detail = result.reason,
            diagnostics = nextDiagnostics,
        )
        is FrameResult.Error -> copy(
            status = "error",
            detail = result.code,
            diagnostics = nextDiagnostics,
        )
    }
}

class ViewerViewModel(
    application: Application,
    private val savedState: SavedStateHandle,
) : AndroidViewModel(application), ExactFrameSession.Listener {
    private data class PendingFrameRequest(
        val frameIndex: Int,
        val prefetchPermit: PrefetchPermit?,
        val mode: NavigationMode,
    )

    private data class InFlightFrameRequest(
        val mode: NavigationMode,
        val holdTarget: HoldTraversalTarget? = null,
    )

    private val session = ExactFrameSession(application, this)
    private var currentUri: Uri? = savedState.get<String>(KEY_URI)?.let(Uri::parse)
    private var currentUriPersisted = currentUri != null
    private var foregroundOwner: Any? = null
    private var autoRecoverEnabled = savedState[KEY_AUTO_RECOVER] ?: (currentUri != null)
    private val foreground: Boolean get() = foregroundOwner != null
    private var decodeInFlight = false
    private var inFlightRequestGeneration: Long? = null
    private var inFlightAcceptedAtNs: Long? = null
    private var inFlightFrameRequest: InFlightFrameRequest? = null
    private var pendingRequestedFrame: PendingFrameRequest? = null
    private val navigationGestureGate = NavigationGestureGate()
    private val holdController = CompletionDrivenHoldController()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var gateActionGeneration = 0L
    private var holdDriveGeneration = 0L
    private var holdDriveScheduled = false

    var uiState by mutableStateOf(
        ViewerUiState(
            selectedUri = currentUri,
            requestedFrameIndex = savedState[KEY_REQUESTED_FRAME] ?: 0,
            restoreState = when {
                currentUri == null -> ViewerRestoreState.NONE
                autoRecoverEnabled -> ViewerRestoreState.WAITING_FOR_SURFACE
                else -> ViewerRestoreState.CANCELLED
            },
        ),
    )
        private set

    init {
        savedState[KEY_STATE_SCHEMA_VERSION] = VIEWER_STATE_SCHEMA_VERSION
    }

    fun createViewport(context: Context): VideoViewport = session.createViewport(context)

    fun openVideo(uri: Uri) {
        navigationGestureGate.invalidate()
        holdController.invalidate()
        session.suspendPrefetch()
        val previousUri = currentUri
        val previousPersisted = currentUriPersisted
        val persisted = runCatching {
            getApplication<Application>().contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }.isSuccess
        if (previousPersisted && previousUri != null && previousUri != uri) {
            runCatching {
                getApplication<Application>().contentResolver.releasePersistableUriPermission(
                    previousUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
        }
        nextGateActionGeneration()
        currentUri = uri
        currentUriPersisted = persisted
        setAutoRecover(true)
        savedState[KEY_REQUESTED_FRAME] = 0
        if (persisted) savedState[KEY_URI] = uri.toString() else savedState.remove<String>(KEY_URI)
        resetRequestPump()
        uiState = uiState.copy(
            selectedUri = uri,
            status = if (uiState.surfaceAvailable && foreground) "indexing" else "surface waiting",
            detail = null,
            metadata = null,
            requestedFrameIndex = 0,
            displayedFrame = null,
            framePtsUs = emptyList(),
            directInput = "",
            diagnostics = DecoderDiagnostics(),
            notice = if (persisted) null else SESSION_ONLY_PERMISSION_NOTICE,
            activeFileGeneration = null,
            activeRequestGeneration = null,
            currentDecodeTarget = null,
            latestPendingRequest = null,
            recentRequestToPublishLatencyMs = emptyList(),
            lastPublicationResult = null,
            lastErrorCode = null,
            restoreState = if (uiState.surfaceAvailable && foreground) {
                ViewerRestoreState.OPENING
            } else {
                ViewerRestoreState.WAITING_FOR_SURFACE
            },
            surfaceAvailable = uiState.surfaceAvailable,
        )
        if (uiState.surfaceAvailable && foreground) openCurrentUri()
    }

    fun moveBy(delta: Int) {
        val next = uiState.moveRequestedBy(delta)
        val direction = when {
            delta > 0 -> DirectionalPrefetchDirection.FORWARD
            delta < 0 -> DirectionalPrefetchDirection.REVERSE
            else -> null
        }
        requestFrameInternal(
            frameIndex = next.requestedFrameIndex,
            prefetchPermit = direction?.let {
                session.newDirectionalPrefetchPermit(it, SystemClock.elapsedRealtime())
            },
            mode = NavigationMode.DISCRETE_TAP,
        )
    }

    fun beginNavigationGesture(): Long = navigationGestureGate.begin()

    fun moveByGesture(delta: Int, gestureGeneration: Long) {
        if (navigationGestureGate.accepts(gestureGeneration)) moveBy(delta)
    }

    fun startHoldTraversal(delta: Int, gestureGeneration: Long) {
        if (!navigationGestureGate.accepts(gestureGeneration) || delta !in HOLD_STRIDES) return
        val metadata = uiState.metadata ?: return
        val fileGeneration = uiState.activeFileGeneration ?: return
        if (!foreground || !uiState.surfaceAvailable) return
        session.suspendPrefetch()
        cancelScheduledHoldDrive()
        holdController.begin(gestureGeneration, fileGeneration, delta)
        pendingRequestedFrame = null
        val currentTarget = uiState.currentDecodeTarget ?: uiState.displayedFrameIndex ?: uiState.requestedFrameIndex
        savedState[KEY_REQUESTED_FRAME] = currentTarget
        uiState = uiState.copy(
            requestedFrameIndex = currentTarget.coerceIn(0, metadata.frameCount - 1),
            latestPendingRequest = null,
        )
        driveHoldTraversal()
    }

    fun endNavigationGesture(gestureGeneration: Long) {
        navigationGestureGate.end(gestureGeneration)
        holdController.end(gestureGeneration)
        session.endHoldTraversal(gestureGeneration)
        cancelScheduledHoldDrive()
    }

    fun setDirectInput(value: String) {
        uiState = uiState.copy(directInput = value.filter(Char::isDigit))
    }

    fun requestTimelineFraction(fraction: Float, final: Boolean) {
        if (uiState.framePtsUs.isEmpty()) return
        val target = nearestFrameIndexForTimelineFraction(uiState.framePtsUs, fraction)
        if (final || target != uiState.requestedFrameIndex) {
            requestFrameInternal(target, prefetchPermit = null, mode = NavigationMode.TIMELINE_SEEK)
        }
    }

    fun requestFrame(frameIndex: Int) {
        requestFrameInternal(
            frameIndex = frameIndex,
            prefetchPermit = null,
            mode = NavigationMode.DIRECT_FRAME_SEEK,
        )
    }

    private fun requestFrameInternal(
        frameIndex: Int,
        prefetchPermit: PrefetchPermit?,
        mode: NavigationMode,
        holdTarget: HoldTraversalTarget? = null,
    ) {
        if (!mode.isHold) {
            holdController.abortActive()
            cancelScheduledHoldDrive()
        }
        if (prefetchPermit == null) session.suspendPrefetch()
        val frameCount = uiState.metadata?.frameCount ?: return
        val target = frameIndex.coerceIn(0, frameCount - 1)
        val gateGeneration = nextGateActionGeneration()
        setAutoRecover(true)
        if (mode.isHold) {
            if (!foreground || !uiState.surfaceAvailable || decodeInFlight) return
            submitFrameRequest(target, prefetchPermit, mode, holdTarget, gateGeneration)
            return
        }
        savedState[KEY_REQUESTED_FRAME] = target
        uiState = uiState.copy(
            requestedFrameIndex = target,
            status = if (foreground && uiState.surfaceAvailable) "decoding" else "surface waiting",
            detail = null,
            restoreState = if (foreground && uiState.surfaceAvailable) {
                ViewerRestoreState.DECODING
            } else {
                ViewerRestoreState.WAITING_FOR_SURFACE
            },
        )
        if (!foreground || !uiState.surfaceAvailable) return
        if (decodeInFlight) {
            if (mode.isSupersedingSeek) {
                pendingRequestedFrame = null
                submitFrameRequest(target, prefetchPermit, mode, gateGeneration = gateGeneration)
            } else {
                if (pendingRequestedFrame != null) session.recordViewerRequestCoalesced()
                pendingRequestedFrame = PendingFrameRequest(target, prefetchPermit, mode)
                uiState = uiState.copy(latestPendingRequest = target)
            }
        } else {
            submitFrameRequest(target, prefetchPermit, mode, gateGeneration = gateGeneration)
        }
    }

    fun cancel() {
        navigationGestureGate.invalidate()
        holdController.invalidate()
        session.suspendPrefetch()
        val gateGeneration = nextGateActionGeneration()
        setAutoRecover(false)
        resetRequestPump()
        cancelSessionWhenAvailable(gateGeneration)
        uiState = uiState.copy(
            status = "cancelled",
            detail = null,
            activeRequestGeneration = null,
            restoreState = ViewerRestoreState.CANCELLED,
        )
    }

    fun onForeground(owner: Any = this) {
        foregroundOwner = owner
        nextGateActionGeneration()
        recoverIfReady()
    }

    fun onBackground(owner: Any = this) {
        if (foregroundOwner !== owner) return
        navigationGestureGate.invalidate()
        holdController.invalidate()
        session.suspendPrefetch()
        val gateGeneration = nextGateActionGeneration()
        foregroundOwner = null
        resetRequestPump()
        cancelSessionWhenAvailable(gateGeneration)
        if (currentUri != null && autoRecoverEnabled) {
            uiState = uiState.copy(
                status = "background",
                detail = null,
                displayedFrame = null,
                activeRequestGeneration = null,
                restoreState = ViewerRestoreState.WAITING_FOR_SURFACE,
            )
        }
    }

    fun onTrimMemory(level: Int) {
        session.trimMemory(level)
    }

    override fun onStatus(fileGeneration: Long?, status: String, detail: String?) {
        if (!autoRecoverEnabled || !foreground || !uiState.surfaceAvailable) return
        if (fileGeneration != null && fileGeneration != uiState.activeFileGeneration) return
        uiState = uiState.copy(
            status = status,
            detail = detail,
            lastErrorCode = if (status == "error" || status == "unsupported") {
                sanitizedErrorCode(detail)
            } else {
                uiState.lastErrorCode
            },
        )
    }

    override fun onVideoOpened(metadata: ContainerMetadata) {
        if (!autoRecoverEnabled || metadata.fileGeneration != uiState.activeFileGeneration) return
        val requested = uiState.requestedFrameIndex.coerceIn(0, metadata.frameCount - 1)
        savedState[KEY_REQUESTED_FRAME] = requested
        val readyForDecode = foreground && uiState.surfaceAvailable
        decodeInFlight = readyForDecode
        inFlightRequestGeneration = null
        inFlightAcceptedAtNs = null
        inFlightFrameRequest = null
        uiState = uiState.copy(
            status = if (readyForDecode) "decoding" else "surface waiting",
            detail = null,
            metadata = metadata,
            requestedFrameIndex = requested,
            diagnostics = DecoderDiagnostics(),
            activeRequestGeneration = null,
            currentDecodeTarget = requested.takeIf { readyForDecode },
            latestPendingRequest = null,
            restoreState = if (readyForDecode) ViewerRestoreState.DECODING else ViewerRestoreState.WAITING_FOR_SURFACE,
        )
    }

    override fun onVideoIndexed(video: IndexedVideo) {
        if (video.fileGeneration != uiState.activeFileGeneration) return
        uiState = uiState.copy(framePtsUs = video.frames.map { it.key.ptsUs })
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        if (!autoRecoverEnabled || !foreground || !uiState.surfaceAvailable) return
        if (result.request.token.fileGeneration != uiState.activeFileGeneration) return
        val expectedGeneration = inFlightRequestGeneration
        if (expectedGeneration != null && result.request.token.requestGeneration != expectedGeneration) return
        val completedFrameRequest = inFlightFrameRequest
        val completedAtNanos = SystemClock.elapsedRealtimeNanos()
        val latencyMs = if (result is FrameResult.Published) {
            inFlightAcceptedAtNs?.let { (completedAtNanos - it).coerceAtLeast(0) / 1_000_000.0 }
        } else {
            null
        }
        val lastResult = diagnostics.publicationEventHistory.lastOrNull { event ->
            event.fileGeneration == result.request.token.fileGeneration &&
                event.requestGeneration == result.request.token.requestGeneration
        }?.result?.name ?: when (result) {
            is FrameResult.Published -> "PUBLISHED"
            is FrameResult.DiscardedStale -> "DISCARDED_STALE"
            is FrameResult.Unsupported -> "UNSUPPORTED"
            is FrameResult.Error -> "ERROR"
        }
        val errorCode = when (result) {
            is FrameResult.Unsupported -> sanitizedErrorCode(result.reason)
            is FrameResult.Error -> sanitizedErrorCode(result.code)
            else -> uiState.lastErrorCode
        }
        uiState = uiState.applyFrameResult(result, diagnostics).copy(
            currentDecodeTarget = null,
            latestPendingRequest = pendingRequestedFrame?.frameIndex,
            recentRequestToPublishLatencyMs = latencyMs?.let {
                (uiState.recentRequestToPublishLatencyMs + it).takeLast(DIAGNOSTIC_LATENCY_HISTORY_LIMIT)
            } ?: uiState.recentRequestToPublishLatencyMs,
            lastPublicationResult = lastResult,
            lastErrorCode = errorCode,
        )
        decodeInFlight = false
        inFlightRequestGeneration = null
        inFlightAcceptedAtNs = null
        inFlightFrameRequest = null
        completedFrameRequest?.holdTarget?.let {
            holdController.complete(
                fileGeneration = result.request.token.fileGeneration,
                requestGeneration = result.request.token.requestGeneration,
                published = result is FrameResult.Published,
                publishedAtNanos = completedAtNanos,
            )
        }
        if (result !is FrameResult.Published) holdController.abortActive()
        if (result is FrameResult.Published || result is FrameResult.DiscardedStale) {
            if (pendingRequestedFrame != null) {
                submitPendingFrameRequest()
            } else if (result is FrameResult.Published) {
                driveHoldTraversal()
            }
        } else {
            pendingRequestedFrame = null
            uiState = uiState.copy(latestPendingRequest = null)
        }
    }

    override fun onSurfaceAvailabilityChanged(available: Boolean) {
        nextGateActionGeneration()
        val nextSurfaceGeneration = if (available && !uiState.surfaceAvailable) {
            uiState.surfaceGeneration + 1
        } else {
            uiState.surfaceGeneration
        }
        uiState = uiState.copy(surfaceAvailable = available, surfaceGeneration = nextSurfaceGeneration)
        if (!available) {
            navigationGestureGate.invalidate()
            holdController.invalidate()
            resetRequestPump()
            if (currentUri != null && autoRecoverEnabled) {
                uiState = uiState.copy(
                    status = "surface waiting",
                    detail = null,
                    displayedFrame = null,
                    activeRequestGeneration = null,
                    restoreState = ViewerRestoreState.WAITING_FOR_SURFACE,
                )
            }
            return
        }
        recoverIfReady()
    }

    override fun onCleared() {
        navigationGestureGate.invalidate()
        holdController.invalidate()
        nextGateActionGeneration()
        foregroundOwner = null
        session.close()
    }

    internal fun setBeforeDecodeHookForTest(hook: ((com.snowberried.ctcinereviewer.media.FrameRequest) -> Unit)?) {
        session.setBeforeDecodeHookForTest(hook)
    }

    internal fun setBeforePrefetchCacheHookForTest(
        hook: ((com.snowberried.ctcinereviewer.media.FrameRequest, FrameKey) -> Unit)?,
    ) {
        session.setBeforePrefetchCacheHookForTest(hook)
    }

    internal fun awaitActorIdleForTest(timeoutMs: Long = 5_000): Boolean =
        session.awaitActorIdleForTest(timeoutMs)

    internal fun diagnosticsSnapshotForTest(timeoutMs: Long = 5_000): DecoderDiagnostics? =
        session.diagnosticsSnapshotForTest(timeoutMs)

    private fun recoverIfReady() {
        if (!foreground || !uiState.surfaceAvailable || !autoRecoverEnabled) return
        if (uiState.metadata != null && uiState.activeFileGeneration != null) {
            requestFrameInternal(
                frameIndex = uiState.requestedFrameIndex,
                prefetchPermit = null,
                mode = NavigationMode.DISCRETE_TAP,
            )
        } else {
            openCurrentUri()
        }
    }

    private fun openCurrentUri(gateGeneration: Long = gateActionGeneration) {
        val uri = currentUri ?: return
        if (currentUriPersisted && !hasPersistedReadPermission(uri)) {
            savedState.remove<String>(KEY_URI)
            currentUri = null
            currentUriPersisted = false
            setAutoRecover(false)
            resetRequestPump()
            uiState = uiState.copy(
                selectedUri = null,
                status = "permission required",
                detail = "URI_PERMISSION_LOST",
                notice = "저장된 읽기 권한이 없어 영상을 다시 선택해야 합니다.",
                metadata = null,
                displayedFrame = null,
                activeFileGeneration = null,
                activeRequestGeneration = null,
                restoreState = ViewerRestoreState.PERMISSION_REQUIRED,
            )
            return
        }
        val token = session.tryOpen(uri, uiState.requestedFrameIndex)
        if (token == null) {
            retryGateAction(gateGeneration) {
                if (currentUri == uri && foreground && uiState.surfaceAvailable && autoRecoverEnabled) {
                    openCurrentUri(gateGeneration)
                }
            }
            return
        }
        resetRequestPump()
        uiState = uiState.copy(
            status = "indexing",
            detail = null,
            metadata = null,
            displayedFrame = null,
            framePtsUs = emptyList(),
            diagnostics = DecoderDiagnostics(),
            activeFileGeneration = token.fileGeneration,
            activeRequestGeneration = null,
            restoreState = ViewerRestoreState.OPENING,
        )
    }

    private fun submitFrameRequest(
        frameIndex: Int,
        prefetchPermit: PrefetchPermit?,
        mode: NavigationMode,
        holdTarget: HoldTraversalTarget? = null,
        gateGeneration: Long = gateActionGeneration,
    ) {
        val holdTraversalStride = holdTarget?.stride
        val acceptance = session.tryRequestFrame(
            frameIndex = frameIndex,
            prefetchPermit = prefetchPermit,
            holdTraversalStride = holdTraversalStride,
            holdGestureGeneration = holdTarget?.gestureGeneration,
            navigationMode = mode,
        )
        if (acceptance == null) {
            retryGateAction(gateGeneration) {
                val requestStillCurrent = if (mode.isHold) {
                    holdTarget != null && holdController.canSubmit(holdTarget)
                } else {
                    uiState.requestedFrameIndex == frameIndex
                }
                if (
                    (!decodeInFlight || mode.isSupersedingSeek) &&
                    foreground &&
                    uiState.surfaceAvailable &&
                    requestStillCurrent
                ) {
                    submitFrameRequest(frameIndex, prefetchPermit, mode, holdTarget, gateGeneration)
                }
            }
            return
        }
        CcrTrace.section(
            CcrTrace.navigationInputLabel(
                request = acceptance.request,
                navigationMode = mode.name,
                stride = holdTraversalStride,
                displayedFrameIndex = uiState.displayedFrameIndex,
            ),
        ) {}
        if (holdTarget != null) {
            check(
                holdController.markAccepted(
                    holdTarget,
                    acceptance.request.token.requestGeneration,
                    acceptance.elapsedRealtimeNanos,
                ),
            )
            savedState[KEY_REQUESTED_FRAME] = frameIndex
        }
        decodeInFlight = true
        inFlightRequestGeneration = acceptance.request.token.requestGeneration
        inFlightAcceptedAtNs = acceptance.elapsedRealtimeNanos
        inFlightFrameRequest = InFlightFrameRequest(mode, holdTarget)
        uiState = uiState.copy(
            requestedFrameIndex = if (holdTarget != null) frameIndex else uiState.requestedFrameIndex,
            status = if (holdTarget != null) "decoding" else uiState.status,
            restoreState = if (holdTarget != null) ViewerRestoreState.DECODING else uiState.restoreState,
            activeRequestGeneration = acceptance.request.token.requestGeneration,
            currentDecodeTarget = frameIndex,
            latestPendingRequest = null,
        )
    }

    private fun submitPendingFrameRequest() {
        val pending = pendingRequestedFrame
        pendingRequestedFrame = null
        uiState = uiState.copy(latestPendingRequest = null)
        if (pending == null || !foreground || !uiState.surfaceAvailable) return
        if (uiState.displayedFrameIndex == pending.frameIndex) {
            uiState = uiState.copy(
                status = "ready",
                detail = "already displayed",
                currentDecodeTarget = null,
            )
            return
        }
        submitFrameRequest(
            frameIndex = pending.frameIndex,
            prefetchPermit = pending.prefetchPermit,
            mode = pending.mode,
        )
    }

    private fun driveHoldTraversal() {
        if (!foreground || !uiState.surfaceAvailable) return
        val metadata = uiState.metadata ?: return
        val nowNanos = SystemClock.elapsedRealtimeNanos()
        val delayNanos = holdController.nanosUntilNextAcceptance(nowNanos) ?: return
        if (delayNanos > 0) {
            CcrTrace.section(
                "${CcrTrace.NAVIGATION_PACING} mode=${holdController.activeMode} " +
                    "s=${holdController.activeStride} delayNs=$delayNanos",
            ) {
                scheduleHoldDrive(delayNanos)
            }
            return
        }
        val target = holdController.reserveNext(
            displayedFrameIndex = uiState.displayedFrameIndex,
            frameCount = metadata.frameCount,
            foregroundRequestInFlight = decodeInFlight,
            nowNanos = nowNanos,
        ) ?: return
        session.suspendPrefetch()
        requestFrameInternal(
            frameIndex = target.frameIndex,
            prefetchPermit = null,
            mode = requireNotNull(holdController.activeMode),
            holdTarget = target,
        )
    }

    private fun scheduleHoldDrive(delayNanos: Long) {
        if (holdDriveScheduled) return
        holdDriveScheduled = true
        val generation = holdDriveGeneration
        val delayMillis = ((delayNanos + NANOS_PER_MILLISECOND - 1) / NANOS_PER_MILLISECOND)
            .coerceAtLeast(1)
        mainHandler.postDelayed(
            {
                if (generation != holdDriveGeneration) return@postDelayed
                holdDriveScheduled = false
                driveHoldTraversal()
            },
            delayMillis,
        )
    }

    private fun cancelScheduledHoldDrive() {
        holdDriveGeneration += 1
        holdDriveScheduled = false
    }

    private fun cancelSessionWhenAvailable(gateGeneration: Long) {
        if (session.tryCancel() != null) return
        retryGateAction(gateGeneration) { cancelSessionWhenAvailable(gateGeneration) }
    }

    private fun retryGateAction(gateGeneration: Long, action: () -> Unit) {
        mainHandler.postDelayed(
            { if (gateGeneration == gateActionGeneration) action() },
            GATE_RETRY_DELAY_MS,
        )
    }

    private fun nextGateActionGeneration(): Long {
        gateActionGeneration += 1
        return gateActionGeneration
    }

    private fun resetRequestPump() {
        cancelScheduledHoldDrive()
        holdController.invalidate()
        decodeInFlight = false
        inFlightRequestGeneration = null
        inFlightAcceptedAtNs = null
        inFlightFrameRequest = null
        pendingRequestedFrame = null
        uiState = uiState.copy(currentDecodeTarget = null, latestPendingRequest = null)
    }

    private fun setAutoRecover(enabled: Boolean) {
        autoRecoverEnabled = enabled
        savedState[KEY_AUTO_RECOVER] = enabled
    }

    private fun hasPersistedReadPermission(uri: Uri): Boolean =
        getApplication<Application>().contentResolver.persistedUriPermissions.any { permission ->
            permission.uri == uri && permission.isReadPermission
        }

    companion object {
        private const val KEY_URI = "viewer.uri"
        private const val KEY_REQUESTED_FRAME = "viewer.requested-frame"
        private const val KEY_AUTO_RECOVER = "viewer.auto-recover"
        private const val KEY_STATE_SCHEMA_VERSION = "viewer.state-schema-version"
        private const val VIEWER_STATE_SCHEMA_VERSION = 1
        private const val DIAGNOSTIC_LATENCY_HISTORY_LIMIT = 32
        private const val GATE_RETRY_DELAY_MS = 1L
        private const val NANOS_PER_MILLISECOND = 1_000_000L
        private val HOLD_STRIDES = setOf(-5, -1, 1, 5)
        private const val SESSION_ONLY_PERMISSION_NOTICE =
            "읽기 권한은 이번 실행에만 유지됩니다. 앱 재실행 뒤에는 영상을 다시 여세요."
    }
}
