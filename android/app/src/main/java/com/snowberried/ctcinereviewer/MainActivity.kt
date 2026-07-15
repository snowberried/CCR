package com.snowberried.ctcinereviewer

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.boundedFrameIndex

internal object SpikeBuildContract {
    const val VERSION_NAME = "0.1.0"
    const val MIN_SDK = 34
    const val COMPILE_SDK = 37
}

private data class DiagnosticUiState(
    val status: String = "파일을 여세요",
    val detail: String? = null,
    val metadata: ContainerMetadata? = null,
    val frame: FrameKey? = null,
    val diagnostics: DecoderDiagnostics = DecoderDiagnostics(),
    val notice: String? = null,
)

class MainActivity : ComponentActivity(), ExactFrameSession.Listener {
    private lateinit var session: ExactFrameSession
    private var uiState by mutableStateOf(DiagnosticUiState())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        session = ExactFrameSession(this, this)
        setContent {
            MaterialTheme {
                CcrSpikeApp(
                    state = uiState,
                    onOpen = ::openVideo,
                    onRequest = session::requestFrame,
                    onCancel = session::cancel,
                    viewport = { context -> session.createViewport(context) },
                )
            }
        }
    }

    override fun onDestroy() {
        session.close()
        super.onDestroy()
    }

    override fun onStatus(status: String, detail: String?) {
        uiState = uiState.copy(status = status, detail = detail)
    }

    override fun onVideoOpened(metadata: ContainerMetadata) {
        uiState = uiState.copy(
            status = "decoding",
            detail = null,
            metadata = metadata,
            frame = null,
            diagnostics = DecoderDiagnostics(),
        )
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        uiState = when (result) {
            is FrameResult.Published -> uiState.copy(
                status = "ready",
                detail = if (result.cacheHit) "cache hit" else "decoded",
                frame = result.request.expectedKey,
                diagnostics = diagnostics,
            )
            is FrameResult.DiscardedStale -> uiState.copy(
                status = "discarded stale",
                detail = result.stage,
                diagnostics = diagnostics,
            )
            is FrameResult.Unsupported -> uiState.copy(
                status = "unsupported",
                detail = result.reason,
                diagnostics = diagnostics,
            )
            is FrameResult.Error -> uiState.copy(
                status = "error",
                detail = result.code,
                diagnostics = diagnostics,
            )
        }
    }

    private fun openVideo(uri: Uri) {
        val permissionDetail = try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            null
        } catch (_: SecurityException) {
            "읽기 권한은 이번 실행에만 유지됩니다. 앱 재실행 뒤에는 영상을 다시 여세요."
        }
        uiState = DiagnosticUiState(status = "indexing", notice = permissionDetail)
        session.open(uri)
    }
}

@Composable
private fun CcrSpikeApp(
    state: DiagnosticUiState,
    onOpen: (Uri) -> Unit,
    onRequest: (Int) -> Unit,
    onCancel: () -> Unit,
    viewport: (android.content.Context) -> android.view.View,
) {
    var directInput by remember { mutableStateOf("") }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(onOpen)
    }
    val metadata = state.metadata
    val currentIndex = state.frame?.displayFrameIndex ?: 0
    val lastIndex = (metadata?.frameCount ?: 1) - 1
    val canNavigate = metadata != null
    val directIndex = directInput.toIntOrNull()

    Surface(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text("CT Cine Reviewer · S24 exact-frame spike", style = MaterialTheme.typography.titleMedium)
            AndroidView(
                factory = viewport,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Button(onClick = { launcher.launch(arrayOf("video/mp4")) }, modifier = Modifier.weight(1f)) {
                    Text("열기")
                }
                Button(onClick = onCancel, enabled = canNavigate, modifier = Modifier.weight(1f)) {
                    Text("취소")
                }
                Button(onClick = { onRequest(0) }, enabled = canNavigate, modifier = Modifier.weight(1f)) {
                    Text("처음")
                }
                Button(onClick = { onRequest(lastIndex) }, enabled = canNavigate, modifier = Modifier.weight(1f)) {
                    Text("마지막")
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                NavigationButton("−5", canNavigate && currentIndex > 0) {
                    onRequest(boundedFrameIndex(currentIndex, -5, metadata!!.frameCount))
                }
                NavigationButton("−1", canNavigate && currentIndex > 0) {
                    onRequest(boundedFrameIndex(currentIndex, -1, metadata!!.frameCount))
                }
                NavigationButton("+1", canNavigate && currentIndex < lastIndex) {
                    onRequest(boundedFrameIndex(currentIndex, 1, metadata!!.frameCount))
                }
                NavigationButton("+5", canNavigate && currentIndex < lastIndex) {
                    onRequest(boundedFrameIndex(currentIndex, 5, metadata!!.frameCount))
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = directInput,
                    onValueChange = { directInput = it.filter(Char::isDigit) },
                    label = { Text("0-based frame") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = { directInput.toIntOrNull()?.let(onRequest) },
                    enabled = canNavigate && directIndex != null && directIndex in 0..lastIndex,
                    modifier = Modifier.heightIn(min = 56.dp),
                ) {
                    Text("이동")
                }
            }
            DiagnosticPanel(state, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.NavigationButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.weight(1f)) {
        Text(label)
    }
}

@Composable
private fun DiagnosticPanel(state: DiagnosticUiState, modifier: Modifier = Modifier) {
    val metadata = state.metadata
    val frame = state.frame
    val diagnostics = state.diagnostics
    Column(
        modifier = modifier
            .heightIn(max = 180.dp)
            .verticalScroll(rememberScrollState())
            .padding(top = 8.dp),
    ) {
        Text("상태: ${state.status}${state.detail?.let { " · $it" } ?: ""}")
        state.notice?.let { Text("안내: $it") }
        Text("프레임: ${frame?.displayFrameIndex ?: "-"} / ${(metadata?.frameCount?.minus(1)) ?: "-"} (0-based)")
        Text("PTS: ${frame?.ptsUs ?: "-"} µs · duplicate: ${frame?.duplicateOrdinal ?: "-"}")
        if (metadata != null) {
            Text("영상: ${metadata.mime} · ${metadata.codedWidth}×${metadata.codedHeight} · 회전 ${metadata.rotationDegrees}°")
            Text("디코더: ${metadata.codecComponent} · hardware=${metadata.hardwareAccelerated}")
        }
        Text("인덱스: ${diagnostics.indexBuildMs} ms · 디코드 출력: ${diagnostics.decodeOrdinal}")
        Text("캐시: ${diagnostics.cacheHitCount}/${diagnostics.cacheMissCount} · ${diagnostics.cacheBytes} bytes")
        Text("stale discard/before-swap: ${diagnostics.staleDiscardCount}/${diagnostics.staleBeforeSwapCount} · recreate: ${diagnostics.decoderRecreateCount}")
        Text("swap 성공/실패/invalid: ${diagnostics.publishedSwapCount}/${diagnostics.swapFailureCount}/${diagnostics.surfaceInvalidCount}")
        Text("publication invariant violation: ${diagnostics.publicationInvariantViolationCount}")
    }
}
