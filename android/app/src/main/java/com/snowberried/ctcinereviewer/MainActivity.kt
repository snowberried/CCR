package com.snowberried.ctcinereviewer

import android.content.ClipData
import android.content.ClipboardManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.ViewConfiguration
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.window.core.layout.WindowSizeClass
import com.snowberried.ctcinereviewer.media.timelineFractionForFrame
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job

internal object AndroidSdkContract {
    const val MIN_SDK = 34
    const val COMPILE_SDK = 37
}

class MainActivity : ComponentActivity() {
    private lateinit var viewer: ViewerViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        viewer = ViewModelProvider(this)[ViewerViewModel::class.java]
        setContent {
            MaterialTheme {
                CcrSpikeApp(
                    state = viewer.uiState,
                    onOpen = viewer::openVideo,
                    onRequest = viewer::requestFrame,
                    onNavigationGestureStart = viewer::beginNavigationGesture,
                    onNavigationStep = viewer::moveByGesture,
                    onNavigationHoldStart = viewer::startHoldTraversal,
                    onNavigationGestureEnd = viewer::endNavigationGesture,
                    onDirectInputChange = viewer::setDirectInput,
                    onTimelineRequest = viewer::requestTimelineFraction,
                    onCancel = viewer::cancel,
                    onCopyDiagnostics = ::copyDiagnostics,
                    viewport = viewer::createViewport,
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewer.onForeground(this)
    }

    override fun onStop() {
        viewer.onBackground(this)
        super.onStop()
    }

    override fun onTrimMemory(level: Int) {
        viewer.onTrimMemory(level)
        super.onTrimMemory(level)
    }

    private fun copyDiagnostics() {
        if (!BuildConfig.DEBUG) return
        val report = buildSanitizedDiagnostics(
            viewer.uiState,
            DiagnosticBuildInfo(
                versionName = BuildConfig.VERSION_NAME,
                versionCode = BuildConfig.VERSION_CODE,
                commitSha = BuildConfig.COMMIT_SHA,
                deviceModel = Build.MODEL,
                sdk = Build.VERSION.SDK_INT,
            ),
        )
        getSystemService(ClipboardManager::class.java).setPrimaryClip(
            ClipData.newPlainText("CCR sanitized diagnostics", report),
        )
    }
}

@Composable
internal fun CcrSpikeApp(
    state: ViewerUiState,
    onOpen: (Uri) -> Unit,
    onRequest: (Int) -> Unit,
    onNavigationGestureStart: () -> Long,
    onNavigationStep: (Int, Long) -> Unit,
    onNavigationHoldStart: (Int, Long) -> Unit,
    onNavigationGestureEnd: (Long) -> Unit,
    onDirectInputChange: (String) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
    viewport: (android.content.Context) -> android.view.View,
) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(onOpen)
    }
    val windowSizeClass = currentWindowAdaptiveInfo().windowSizeClass
    val twoPane = windowSizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND)
    Surface(modifier = Modifier.fillMaxSize()) {
        if (twoPane) {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(12.dp)
                    .testTag("viewer-two-pane"),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "CT Cine Reviewer · Android ${BuildConfig.VERSION_NAME} internal",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    AndroidView(factory = viewport, modifier = Modifier.fillMaxSize())
                }
                ViewerControls(
                    state = state,
                    directInput = state.directInput,
                    onDirectInputChange = onDirectInputChange,
                    onOpen = { launcher.launch(arrayOf("video/mp4")) },
                    onRequest = onRequest,
                    onNavigationGestureStart = onNavigationGestureStart,
                    onNavigationStep = onNavigationStep,
                    onNavigationHoldStart = onNavigationHoldStart,
                    onNavigationGestureEnd = onNavigationGestureEnd,
                    onTimelineRequest = onTimelineRequest,
                    onCancel = onCancel,
                    onCopyDiagnostics = onCopyDiagnostics,
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState()),
                )
            }
        } else {
            Column(
                modifier = Modifier
                    .padding(12.dp)
                    .testTag("viewer-single-pane"),
            ) {
                Text(
                    "CT Cine Reviewer · Android ${BuildConfig.VERSION_NAME} internal",
                    style = MaterialTheme.typography.titleMedium,
                )
                AndroidView(
                    factory = viewport,
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                )
                ViewerControls(
                    state = state,
                    directInput = state.directInput,
                    onDirectInputChange = onDirectInputChange,
                    onOpen = { launcher.launch(arrayOf("video/mp4")) },
                    onRequest = onRequest,
                    onNavigationGestureStart = onNavigationGestureStart,
                    onNavigationStep = onNavigationStep,
                    onNavigationHoldStart = onNavigationHoldStart,
                    onNavigationGestureEnd = onNavigationGestureEnd,
                    onTimelineRequest = onTimelineRequest,
                    onCancel = onCancel,
                    onCopyDiagnostics = onCopyDiagnostics,
                )
            }
        }
    }
}

@Composable
private fun ViewerControls(
    state: ViewerUiState,
    directInput: String,
    onDirectInputChange: (String) -> Unit,
    onOpen: () -> Unit,
    onRequest: (Int) -> Unit,
    onNavigationGestureStart: () -> Long,
    onNavigationStep: (Int, Long) -> Unit,
    onNavigationHoldStart: (Int, Long) -> Unit,
    onNavigationGestureEnd: (Long) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val metadata = state.metadata
    val requestedIndex = state.requestedFrameIndex
    val lastIndex = (metadata?.frameCount ?: 1) - 1
    val canNavigate = metadata != null && state.surfaceAvailable
    val canCancel = state.activeFileGeneration != null && state.restoreState != ViewerRestoreState.CANCELLED
    val directIndex = directInput.toIntOrNull()

    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Button(onClick = onOpen, modifier = Modifier.weight(1f)) { Text("열기") }
            Button(onClick = onCancel, enabled = canCancel, modifier = Modifier.weight(1f)) { Text("취소") }
            Button(onClick = { onRequest(0) }, enabled = canNavigate, modifier = Modifier.weight(1f)) { Text("처음") }
            Button(onClick = { onRequest(lastIndex) }, enabled = canNavigate, modifier = Modifier.weight(1f)) {
                Text("마지막")
            }
        }
        FrameTimeline(state, onTimelineRequest)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            NavigationButton("−5", -5, canNavigate && requestedIndex > 0, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
            NavigationButton("−1", -1, canNavigate && requestedIndex > 0, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
            NavigationButton("+1", 1, canNavigate && requestedIndex < lastIndex, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
            NavigationButton("+5", 5, canNavigate && requestedIndex < lastIndex, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = directInput,
                onValueChange = onDirectInputChange,
                label = { Text("0-based frame") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
            )
            Button(
                onClick = { directIndex?.let(onRequest) },
                enabled = canNavigate && directIndex != null && directIndex in 0..lastIndex,
                modifier = Modifier.heightIn(min = 56.dp),
            ) {
                Text("이동")
            }
        }
        state.errorOrUnsupportedMessage?.let { message ->
            Text(
                text = "열 수 없음: $message",
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        if (state.diagnosticsVisible) {
            DiagnosticPanel(state, onCopyDiagnostics, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun FrameTimeline(
    state: ViewerUiState,
    onTimelineRequest: (Float, Boolean) -> Unit,
) {
    val ptsUs = state.framePtsUs
    if (ptsUs.isEmpty()) return
    val requestedFraction = timelineFractionForFrame(ptsUs, state.requestedFrameIndex)
    var dragFraction by remember(state.activeFileGeneration) { mutableFloatStateOf(requestedFraction) }
    var dragging by remember(state.activeFileGeneration) { mutableStateOf(false) }
    LaunchedEffect(requestedFraction, dragging) {
        if (!dragging) dragFraction = requestedFraction
    }

    Text(
        text = "표시 ${state.displayedFrameIndex ?: "-"} / ${ptsUs.lastIndex} (전체 ${ptsUs.size}, 0-based) · " +
            "PTS ${state.displayedFrame?.ptsUs ?: "-"} µs",
        modifier = Modifier.padding(top = 8.dp),
    )
    Slider(
        value = dragFraction,
        onValueChange = { value ->
            dragging = true
            dragFraction = value
            onTimelineRequest(value, false)
        },
        onValueChangeFinished = {
            dragging = false
            onTimelineRequest(dragFraction, true)
        },
        enabled = state.metadata != null && state.surfaceAvailable,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("pts-timeline"),
    )
}

@Composable
internal fun androidx.compose.foundation.layout.RowScope.NavigationButton(
    label: String,
    delta: Int,
    enabled: Boolean,
    onGestureStart: () -> Long,
    onTap: (Int, Long) -> Unit,
    onHoldStart: (Int, Long) -> Unit,
    onGestureEnd: (Long) -> Unit,
) {
    val currentOnGestureStart by rememberUpdatedState(onGestureStart)
    val currentOnTap by rememberUpdatedState(onTap)
    val currentOnHoldStart by rememberUpdatedState(onHoldStart)
    val currentOnGestureEnd by rememberUpdatedState(onGestureEnd)
    val lifecycleOwner = LocalLifecycleOwner.current
    val activeGesture = remember { ActiveNavigationGesture() }

    DisposableEffect(lifecycleOwner, activeGesture) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) activeGesture.cancelActive()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            activeGesture.cancelActive()
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    Button(
        onClick = {},
        enabled = enabled,
        modifier = Modifier
            .weight(1f)
            .pointerInput(enabled, activeGesture) {
                if (!enabled) return@pointerInput
                coroutineScope {
                    awaitEachGesture {
                        val down = awaitFirstDown(
                            requireUnconsumed = false,
                            pass = PointerEventPass.Initial,
                        )
                        val generation = currentOnGestureStart()
                        var holdStarted = false
                        activeGesture.begin(generation, currentOnGestureEnd)
                        val longPressJob = launch {
                            delay(ViewConfiguration.getLongPressTimeout().toLong())
                            if (activeGesture.isActive(generation)) {
                                holdStarted = true
                                currentOnHoldStart(delta, generation)
                            }
                        }
                        activeGesture.attach(generation, longPressJob)
                        try {
                            while (activeGesture.isActive(generation)) {
                                val event = awaitPointerEvent(PointerEventPass.Initial)
                                val primary = event.changes.firstOrNull { it.id == down.id }
                                val secondPointer = event.changes.any { it.id != down.id && it.pressed }
                                val outside = primary == null || primary.position.isOutside(size.width, size.height)
                                if (secondPointer || outside) break
                                event.changes.forEach { it.consume() }
                                if (!primary.pressed) {
                                    if (!holdStarted && activeGesture.isActive(generation)) {
                                        currentOnTap(delta, generation)
                                    }
                                    break
                                }
                            }
                        } finally {
                            activeGesture.end(generation)
                        }
                    }
                }
            },
    ) {
        Text(label)
    }
}

private fun Offset.isOutside(width: Int, height: Int): Boolean =
    x < 0f || y < 0f || x >= width || y >= height

private class ActiveNavigationGesture {
    private data class Active(
        val generation: Long,
        val onEnd: (Long) -> Unit,
        var longPressJob: Job? = null,
    )

    private var active: Active? = null

    fun begin(generation: Long, onEnd: (Long) -> Unit) {
        cancelActive()
        active = Active(generation, onEnd)
    }

    fun attach(generation: Long, longPressJob: Job) {
        val current = active
        if (current?.generation == generation) current.longPressJob = longPressJob else longPressJob.cancel()
    }

    fun isActive(generation: Long): Boolean = active?.generation == generation

    fun end(generation: Long) {
        if (active?.generation == generation) cancelActive()
    }

    fun cancelActive() {
        val ending = active ?: return
        active = null
        ending.onEnd(ending.generation)
        ending.longPressJob?.cancel()
    }
}

@Composable
private fun DiagnosticPanel(
    state: ViewerUiState,
    onCopyDiagnostics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val metadata = state.metadata
    val frame = state.displayedFrame
    val diagnostics = state.diagnostics
    Column(
        modifier = modifier
            .heightIn(max = 180.dp)
            .verticalScroll(rememberScrollState())
            .padding(top = 8.dp),
    ) {
        Text("상태: ${state.status}${state.detail?.let { " · $it" } ?: ""}")
        state.notice?.let { Text("안내: $it") }
        Text("요청 프레임: ${state.requestedFrameIndex} / ${(metadata?.frameCount?.minus(1)) ?: "-"} (0-based)")
        Text("표시 프레임: ${frame?.displayFrameIndex ?: "-"}")
        Text("PTS: ${frame?.ptsUs ?: "-"} µs · duplicate: ${frame?.duplicateOrdinal ?: "-"}")
        if (metadata != null) {
            Text("영상: ${metadata.mime} · ${metadata.codedWidth}×${metadata.codedHeight} · 회전 ${metadata.rotationDegrees}°")
            Text("디코더: ${metadata.codecComponent} · hardware=${metadata.hardwareAccelerated}")
        }
        Text("인덱스: ${diagnostics.indexBuildMs} ms · 디코드 출력: ${diagnostics.decodeOrdinal}")
        Text(
            "캐시 hit/miss: ${diagnostics.cacheHitCount}/${diagnostics.cacheMissCount} · " +
                "미리읽기: ${diagnostics.prefetchedFrameCount} · ${diagnostics.cacheBytes} bytes",
        )
        Text("stale discard/before-swap: ${diagnostics.staleDiscardCount}/${diagnostics.staleBeforeSwapCount} · recreate: ${diagnostics.decoderRecreateCount}")
        Text("swap 성공/실패/invalid: ${diagnostics.publishedSwapCount}/${diagnostics.swapFailureCount}/${diagnostics.surfaceInvalidCount}")
        Text("publication invariant violation: ${diagnostics.publicationInvariantViolationCount}")
        Text("full-frame readback: ${diagnostics.fullFrameReadbackCount}")
        Text(
            "보호/history: ${diagnostics.protectedTextureCount} · " +
                "${diagnostics.backwardHistoryDepth}/${diagnostics.backwardHistoryCapacity} · " +
                "hit ${diagnostics.backwardHistoryHitCount}",
        )
        Text("복구: ${state.restoreState} · surface=${state.surfaceAvailable}")
        Text("세대: ${state.activeFileGeneration ?: "-"}/${state.activeRequestGeneration ?: "-"}")
        if (BuildConfig.DEBUG) {
            Button(
                onClick = onCopyDiagnostics,
                modifier = Modifier.testTag("copy-sanitized-diagnostics"),
            ) {
                Text("진단 복사")
            }
        }
    }
}
