package com.snowberried.ctcinereviewer

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.boundedFrameIndex
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
    val status: String = "파일을 여세요",
    val detail: String? = null,
    val metadata: ContainerMetadata? = null,
    val requestedFrameIndex: Int = 0,
    val displayedFrame: FrameKey? = null,
    val diagnostics: DecoderDiagnostics = DecoderDiagnostics(),
    val notice: String? = null,
    val activeFileGeneration: Long? = null,
    val activeRequestGeneration: Long? = null,
    val restoreState: ViewerRestoreState = ViewerRestoreState.NONE,
    val surfaceAvailable: Boolean = false,
)

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
    private val session = ExactFrameSession(application, this)
    private var currentUri: Uri? = savedState.get<String>(KEY_URI)?.let(Uri::parse)
    private var currentUriPersisted = currentUri != null
    private var foregroundOwner: Any? = null
    private var autoRecoverEnabled = savedState[KEY_AUTO_RECOVER] ?: (currentUri != null)
    private val foreground: Boolean get() = foregroundOwner != null

    var uiState by mutableStateOf(
        ViewerUiState(
            requestedFrameIndex = savedState[KEY_REQUESTED_FRAME] ?: 0,
            restoreState = when {
                currentUri == null -> ViewerRestoreState.NONE
                autoRecoverEnabled -> ViewerRestoreState.WAITING_FOR_SURFACE
                else -> ViewerRestoreState.CANCELLED
            },
        ),
    )
        private set

    fun createViewport(context: Context): VideoViewport = session.createViewport(context)

    fun openVideo(uri: Uri) {
        val persisted = runCatching {
            getApplication<Application>().contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }.isSuccess
        currentUri = uri
        currentUriPersisted = persisted
        setAutoRecover(true)
        savedState[KEY_REQUESTED_FRAME] = 0
        if (persisted) savedState[KEY_URI] = uri.toString() else savedState.remove<String>(KEY_URI)
        uiState = ViewerUiState(
            status = if (uiState.surfaceAvailable && foreground) "indexing" else "surface waiting",
            requestedFrameIndex = 0,
            notice = if (persisted) null else SESSION_ONLY_PERMISSION_NOTICE,
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
        requestFrame(next.requestedFrameIndex)
    }

    fun requestFrame(frameIndex: Int) {
        val frameCount = uiState.metadata?.frameCount ?: return
        val target = frameIndex.coerceIn(0, frameCount - 1)
        setAutoRecover(true)
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
        if (foreground && uiState.surfaceAvailable) {
            session.requestFrame(target)?.let { acceptance ->
                uiState = uiState.copy(
                    activeRequestGeneration = acceptance.request.token.requestGeneration,
                )
            }
        }
    }

    fun cancel() {
        setAutoRecover(false)
        session.cancel()
        uiState = uiState.copy(
            status = "cancelled",
            detail = null,
            activeRequestGeneration = null,
            restoreState = ViewerRestoreState.CANCELLED,
        )
    }

    fun onForeground(owner: Any = this) {
        foregroundOwner = owner
        recoverIfReady()
    }

    fun onBackground(owner: Any = this) {
        if (foregroundOwner !== owner) return
        foregroundOwner = null
        session.cancel()
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
        uiState = uiState.copy(status = status, detail = detail)
    }

    override fun onVideoOpened(metadata: ContainerMetadata) {
        if (!autoRecoverEnabled || metadata.fileGeneration != uiState.activeFileGeneration) return
        val requested = uiState.requestedFrameIndex.coerceIn(0, metadata.frameCount - 1)
        savedState[KEY_REQUESTED_FRAME] = requested
        val readyForDecode = foreground && uiState.surfaceAvailable
        uiState = uiState.copy(
            status = if (readyForDecode) "decoding" else "surface waiting",
            detail = null,
            metadata = metadata,
            requestedFrameIndex = requested,
            diagnostics = DecoderDiagnostics(),
            activeRequestGeneration = null,
            restoreState = if (readyForDecode) ViewerRestoreState.DECODING else ViewerRestoreState.WAITING_FOR_SURFACE,
        )
    }

    override fun onVideoIndexed(video: IndexedVideo) {
        if (video.fileGeneration != uiState.activeFileGeneration) return
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        if (!autoRecoverEnabled || !foreground || !uiState.surfaceAvailable) return
        uiState = uiState.applyFrameResult(result, diagnostics)
    }

    override fun onSurfaceAvailabilityChanged(available: Boolean) {
        uiState = uiState.copy(surfaceAvailable = available)
        if (!available) {
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
        foregroundOwner = null
        session.close()
    }

    internal fun setBeforeDecodeHookForTest(hook: ((com.snowberried.ctcinereviewer.media.FrameRequest) -> Unit)?) {
        session.setBeforeDecodeHookForTest(hook)
    }

    internal fun awaitActorIdleForTest(timeoutMs: Long = 5_000): Boolean =
        session.awaitActorIdleForTest(timeoutMs)

    private fun recoverIfReady() {
        if (!foreground || !uiState.surfaceAvailable || !autoRecoverEnabled) return
        if (uiState.metadata != null && uiState.activeFileGeneration != null) {
            requestFrame(uiState.requestedFrameIndex)
        } else {
            openCurrentUri()
        }
    }

    private fun openCurrentUri() {
        val uri = currentUri ?: return
        if (currentUriPersisted && !hasPersistedReadPermission(uri)) {
            savedState.remove<String>(KEY_URI)
            currentUri = null
            currentUriPersisted = false
            setAutoRecover(false)
            uiState = uiState.copy(
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
        val token = session.open(uri, uiState.requestedFrameIndex) ?: return
        uiState = uiState.copy(
            status = "indexing",
            detail = null,
            metadata = null,
            displayedFrame = null,
            diagnostics = DecoderDiagnostics(),
            activeFileGeneration = token.fileGeneration,
            activeRequestGeneration = null,
            restoreState = ViewerRestoreState.OPENING,
        )
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
        private const val SESSION_ONLY_PERMISSION_NOTICE =
            "읽기 권한은 이번 실행에만 유지됩니다. 앱 재실행 뒤에는 영상을 다시 여세요."
    }
}
