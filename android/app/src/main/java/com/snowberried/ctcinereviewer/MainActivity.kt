package com.snowberried.ctcinereviewer

import android.net.Uri
import android.os.Bundle
import android.view.ViewConfiguration
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.ViewModelProvider
import androidx.window.core.layout.WindowSizeClass
import com.snowberried.ctcinereviewer.media.timelineFractionForFrame
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal const val NAVIGATION_REPEAT_INTERVAL_MS = 50L

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
                    onMoveBy = viewer::moveBy,
                    onDirectInputChange = viewer::setDirectInput,
                    onTimelineRequest = viewer::requestTimelineFraction,
                    onCancel = viewer::cancel,
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
}

@Composable
private fun CcrSpikeApp(
    state: ViewerUiState,
    onOpen: (Uri) -> Unit,
    onRequest: (Int) -> Unit,
    onMoveBy: (Int) -> Unit,
    onDirectInputChange: (String) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
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
                    onMoveBy = onMoveBy,
                    onTimelineRequest = onTimelineRequest,
                    onCancel = onCancel,
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
                    onMoveBy = onMoveBy,
                    onTimelineRequest = onTimelineRequest,
                    onCancel = onCancel,
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
    onMoveBy: (Int) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
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
            NavigationButton("−5", canNavigate && requestedIndex > 0) { onMoveBy(-5) }
            NavigationButton("−1", canNavigate && requestedIndex > 0) { onMoveBy(-1) }
            NavigationButton("+1", canNavigate && requestedIndex < lastIndex) { onMoveBy(1) }
            NavigationButton("+5", canNavigate && requestedIndex < lastIndex) { onMoveBy(5) }
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
        if (state.diagnosticsVisible) DiagnosticPanel(state, modifier = Modifier.fillMaxWidth())
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
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val currentOnClick by rememberUpdatedState(onClick)
    var repeated by remember { mutableStateOf(false) }

    LaunchedEffect(interactionSource, enabled) {
        if (!enabled) {
            repeated = false
            return@LaunchedEffect
        }
        var activePress: PressInteraction.Press? = null
        var repeatJob: Job? = null
        try {
            interactionSource.interactions.collect { interaction ->
                when (interaction) {
                    is PressInteraction.Press -> {
                        repeatJob?.cancel()
                        activePress = interaction
                        repeated = false
                        repeatJob = launch {
                            delay(ViewConfiguration.getLongPressTimeout().toLong())
                            while (isActive) {
                                repeated = true
                                currentOnClick()
                                delay(NAVIGATION_REPEAT_INTERVAL_MS)
                            }
                        }
                    }

                    is PressInteraction.Release -> if (interaction.press === activePress) {
                        repeatJob?.cancel()
                        repeatJob = null
                        activePress = null
                    }

                    is PressInteraction.Cancel -> if (interaction.press === activePress) {
                        repeatJob?.cancel()
                        repeatJob = null
                        activePress = null
                        repeated = false
                    }
                }
            }
        } finally {
            repeatJob?.cancel()
        }
    }

    Button(
        onClick = {
            val wasRepeated = repeated
            repeated = false
            if (!wasRepeated) currentOnClick()
        },
        interactionSource = interactionSource,
        enabled = enabled,
        modifier = Modifier.weight(1f),
    ) {
        Text(label)
    }
}

@Composable
private fun DiagnosticPanel(state: ViewerUiState, modifier: Modifier = Modifier) {
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
        Text("복구: ${state.restoreState} · surface=${state.surfaceAvailable}")
        Text("세대: ${state.activeFileGeneration ?: "-"}/${state.activeRequestGeneration ?: "-"}")
    }
}
