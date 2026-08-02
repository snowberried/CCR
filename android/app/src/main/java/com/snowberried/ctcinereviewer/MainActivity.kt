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
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.snowberried.ctcinereviewer.media.timelineFractionForFrame
import com.snowberried.ctcinereviewer.render.CorrectionLimit
import com.snowberried.ctcinereviewer.render.CorrectionPanelState
import com.snowberried.ctcinereviewer.render.VideoCorrection
import com.snowberried.ctcinereviewer.render.VideoCorrectionLimits
import com.snowberried.ctcinereviewer.render.VideoViewport
import com.snowberried.ctcinereviewer.render.ViewTransform
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

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
            CcrTheme {
                CcrSpikeApp(
                    state = viewer.uiState,
                    onOpen = viewer::openVideo,
                    onNavigationGestureStart = viewer::beginNavigationGesture,
                    onNavigationStep = viewer::moveByGesture,
                    onNavigationHoldStart = viewer::startHoldTraversal,
                    onNavigationGestureEnd = viewer::endNavigationGesture,
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
    onNavigationGestureStart: () -> Long,
    onNavigationStep: (Int, Long) -> Unit,
    onNavigationHoldStart: (Int, Long) -> Unit,
    onNavigationGestureEnd: (Long) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
    viewport: (android.content.Context) -> VideoViewport,
) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(onOpen)
    }
    CcrViewerScreen(
        state = state,
        onOpen = { launcher.launch(arrayOf("video/mp4")) },
        onNavigationGestureStart = onNavigationGestureStart,
        onNavigationStep = onNavigationStep,
        onNavigationHoldStart = onNavigationHoldStart,
        onNavigationGestureEnd = onNavigationGestureEnd,
        onTimelineRequest = onTimelineRequest,
        onCancel = onCancel,
        onCopyDiagnostics = onCopyDiagnostics,
        viewport = viewport,
    )
}

@Composable
internal fun CcrViewerScreen(
    state: ViewerUiState,
    onOpen: () -> Unit,
    onNavigationGestureStart: () -> Long,
    onNavigationStep: (Int, Long) -> Unit,
    onNavigationHoldStart: (Int, Long) -> Unit,
    onNavigationGestureEnd: (Long) -> Unit,
    onTimelineRequest: (Float, Boolean) -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
    viewport: (android.content.Context) -> VideoViewport,
) {
    val fileSelected = state.selectedUri != null
    var panelState by remember(state.activeFileGeneration) { mutableStateOf(CorrectionPanelState()) }
    var comparingOriginal by remember(state.activeFileGeneration) { mutableStateOf(false) }
    var viewportView by remember { mutableStateOf<VideoViewport?>(null) }
    var viewTransform by remember(state.activeFileGeneration) { mutableStateOf<ViewTransform?>(null) }

    DisposableEffect(viewportView) {
        val currentViewport = viewportView
        onDispose {
            currentViewport?.updateCorrection(panelState.correction, false)
            currentViewport?.onTransformChanged = null
        }
    }

    Surface(
        modifier = Modifier
            .fillMaxSize()
            .testTag("window-root"),
        color = CcrColors.Canvas,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(CcrColors.Canvas)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .testTag("safe-drawing-root"),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(CcrColors.Shell)
                    .testTag("safe-drawing-content"),
            ) {
                CcrHeader(
                    fileSelected = fileSelected,
                    canCancel = state.activeFileGeneration != null &&
                        state.restoreState != ViewerRestoreState.CANCELLED,
                    onOpen = onOpen,
                    onCancel = onCancel,
                    onCopyDiagnostics = onCopyDiagnostics,
                )
                if (!fileSelected) {
                    EmptyViewer(onOpen, Modifier.weight(1f))
                } else {
                    Text(
                        text = displayFileName(state.selectedUri) ?: "선택한 동영상",
                        color = CcrColors.SecondaryText,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                            .testTag("selected-file-name"),
                    )
                    VideoArea(
                        state = state,
                        correction = panelState.correction,
                        comparingOriginal = comparingOriginal,
                        viewTransform = viewTransform,
                        onViewportCreated = { viewportView = it },
                        onTransformChanged = { viewTransform = it },
                        onFitReset = { viewportView?.resetView() },
                        viewport = viewport,
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .heightIn(min = 120.dp)
                            .padding(horizontal = 8.dp),
                    )
                    if (state.metadata != null) {
                        FrameControls(
                            state = state,
                            onNavigationGestureStart = onNavigationGestureStart,
                            onNavigationStep = onNavigationStep,
                            onNavigationHoldStart = onNavigationHoldStart,
                            onNavigationGestureEnd = onNavigationGestureEnd,
                            modifier = Modifier.padding(start = 8.dp, top = 6.dp, end = 8.dp),
                        )
                        FrameTimeline(
                            state = state,
                            onTimelineRequest = onTimelineRequest,
                            modifier = Modifier.padding(horizontal = 8.dp),
                        )
                        CorrectionSection(
                            state = panelState,
                            onStateChange = { panelState = it },
                            comparingOriginal = comparingOriginal,
                            onComparingOriginalChange = { comparingOriginal = it },
                            modifier = Modifier.padding(start = 8.dp, end = 8.dp, bottom = 8.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CcrHeader(
    fileSelected: Boolean,
    canCancel: Boolean,
    onOpen: () -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
) {
    Surface(
        color = CcrColors.TopBar,
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 8.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_ccr_logo),
                contentDescription = null,
                tint = CcrColors.ActiveBlue,
                modifier = Modifier.size(30.dp),
            )
            Text(
                text = "CT Cine Reviewer",
                color = CcrColors.PrimaryText,
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 10.dp),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (fileSelected) {
                IconButton(onClick = onOpen, modifier = Modifier.size(48.dp)) {
                    Icon(
                        painter = painterResource(R.drawable.ic_folder_open),
                        contentDescription = "파일 열기",
                        tint = CcrColors.PrimaryText,
                    )
                }
            }
            OverflowMenu(
                fileSelected = fileSelected,
                canCancel = canCancel,
                onOpen = onOpen,
                onCancel = onCancel,
                onCopyDiagnostics = onCopyDiagnostics,
            )
        }
    }
}

@Composable
private fun OverflowMenu(
    fileSelected: Boolean,
    canCancel: Boolean,
    onOpen: () -> Unit,
    onCancel: () -> Unit,
    onCopyDiagnostics: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }, modifier = Modifier.size(48.dp)) {
            Icon(
                painter = painterResource(R.drawable.ic_more_vert),
                contentDescription = "더보기",
                tint = CcrColors.PrimaryText,
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(CcrColors.Raised),
        ) {
            DropdownMenuItem(
                text = { Text("파일 열기", color = CcrColors.PrimaryText) },
                onClick = {
                    expanded = false
                    onOpen()
                },
            )
            if (fileSelected && canCancel) {
                DropdownMenuItem(
                    text = { Text("현재 작업 취소", color = CcrColors.PrimaryText) },
                    onClick = {
                        expanded = false
                        onCancel()
                    },
                )
            }
            if (fileSelected && BuildConfig.DEBUG) {
                DropdownMenuItem(
                    text = { Text("진단 복사", color = CcrColors.PrimaryText) },
                    onClick = {
                        expanded = false
                        onCopyDiagnostics()
                    },
                )
            }
        }
    }
}

@Composable
private fun EmptyViewer(onOpen: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxWidth().testTag("viewer-empty"), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                painter = painterResource(R.drawable.ic_folder_open),
                contentDescription = null,
                tint = CcrColors.MutedText,
                modifier = Modifier.size(42.dp),
            )
            Text(
                text = "검토할 동영상 파일을 여세요",
                color = CcrColors.SecondaryText,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 14.dp, bottom = 16.dp),
            )
            Button(
                onClick = onOpen,
                shape = ControlShape,
                colors = ButtonDefaults.buttonColors(
                    containerColor = CcrColors.PrimaryBlue,
                    contentColor = CcrColors.PrimaryText,
                ),
                modifier = Modifier
                    .heightIn(min = 48.dp)
                    .testTag("empty-file-open"),
            ) {
                Text("파일 열기")
            }
        }
    }
}

@Composable
private fun VideoArea(
    state: ViewerUiState,
    correction: VideoCorrection,
    comparingOriginal: Boolean,
    viewTransform: ViewTransform?,
    onViewportCreated: (VideoViewport) -> Unit,
    onTransformChanged: (ViewTransform) -> Unit,
    onFitReset: () -> Unit,
    viewport: (android.content.Context) -> VideoViewport,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(ControlShape)
            .background(Color.Black)
            .border(1.dp, CcrColors.VideoBorder, ControlShape)
            .testTag("video-viewport"),
    ) {
        AndroidView(
            factory = { context ->
                viewport(context).also { view ->
                    view.onTransformChanged = onTransformChanged
                    onViewportCreated(view)
                }
            },
            update = { view ->
                view.onTransformChanged = onTransformChanged
                view.updateCorrection(correction, comparingOriginal)
            },
            modifier = Modifier.fillMaxSize(),
        )
        if (state.metadata == null) {
            Text(
                text = if (state.errorOrUnsupportedMessage == null) {
                    "동영상을 준비하고 있습니다"
                } else {
                    "동영상을 열 수 없습니다"
                },
                color = if (state.errorOrUnsupportedMessage == null) CcrColors.MutedText else CcrColors.Danger,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.align(Alignment.Center),
            )
        }
        viewTransform?.takeUnless(ViewTransform::isFit)?.let { transform ->
            ZoomOverlay(transform.zoom, onFitReset)
        }
    }
}

@Composable
private fun BoxScope.ZoomOverlay(zoom: Float, onFitReset: () -> Unit) {
    Surface(
        color = CcrColors.Shell.copy(alpha = 0.92f),
        shape = ControlShape,
        border = BorderStroke(1.dp, CcrColors.VideoBorder),
        modifier = Modifier
            .align(Alignment.BottomEnd)
            .padding(8.dp)
            .testTag("zoom-fit-overlay"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "${(zoom * 100f).roundToInt()}%",
                color = CcrColors.PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 10.dp, end = 4.dp),
            )
            IconButton(onClick = onFitReset, modifier = Modifier.size(48.dp)) {
                Icon(
                    painter = painterResource(R.drawable.ic_fit),
                    contentDescription = "화면 맞춤",
                    tint = CcrColors.PrimaryText,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

@Composable
private fun FrameControls(
    state: ViewerUiState,
    onNavigationGestureStart: () -> Long,
    onNavigationStep: (Int, Long) -> Unit,
    onNavigationHoldStart: (Int, Long) -> Unit,
    onNavigationGestureEnd: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val metadata = requireNotNull(state.metadata)
    val lastIndex = metadata.frameCount - 1
    val canNavigate = state.surfaceAvailable
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .testTag("frame-controls"),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        NavigationButton("−5", -5, canNavigate && state.requestedFrameIndex > 0, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
        NavigationButton("−1", -1, canNavigate && state.requestedFrameIndex > 0, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
        Surface(
            color = CcrColors.Card,
            shape = ControlShape,
            border = BorderStroke(1.dp, CcrColors.Border),
            modifier = Modifier
                .weight(1.9f)
                .height(48.dp)
                .testTag("frame-position-card")
                .semantics(mergeDescendants = true) {
                    contentDescription = "현재 프레임 ${displayedFrameText(state)}"
                },
        ) {
            Box(contentAlignment = Alignment.Center) {
                val current = state.displayedFrameIndex?.plus(1)?.toString() ?: "—"
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(current, color = CcrColors.ActiveBlue, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(" / ${metadata.frameCount}", color = CcrColors.MutedText, fontSize = 13.sp)
                }
            }
        }
        NavigationButton("+1", 1, canNavigate && state.requestedFrameIndex < lastIndex, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
        NavigationButton("+5", 5, canNavigate && state.requestedFrameIndex < lastIndex, onNavigationGestureStart, onNavigationStep, onNavigationHoldStart, onNavigationGestureEnd)
    }
}

@Composable
private fun FrameTimeline(
    state: ViewerUiState,
    onTimelineRequest: (Float, Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val ptsUs = state.framePtsUs
    if (ptsUs.isEmpty()) return
    val requestedFraction = timelineFractionForFrame(ptsUs, state.requestedFrameIndex)
    var dragFraction by remember(state.activeFileGeneration) { mutableFloatStateOf(requestedFraction) }
    var dragging by remember(state.activeFileGeneration) { mutableStateOf(false) }
    LaunchedEffect(requestedFraction, dragging) {
        if (!dragging) dragFraction = requestedFraction
    }
    CcrSlider(
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
        enabled = state.surfaceAvailable,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .testTag("pts-timeline"),
    )
}

@Composable
private fun CorrectionSection(
    state: CorrectionPanelState,
    onStateChange: (CorrectionPanelState) -> Unit,
    comparingOriginal: Boolean,
    onComparingOriginalChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = CcrColors.Panel,
        shape = ControlShape,
        border = BorderStroke(1.dp, CcrColors.Border),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .clickable(role = Role.Button) { onStateChange(state.toggled()) }
                    .padding(horizontal = 12.dp)
                    .testTag("correction-row"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "화면 보정",
                    color = CcrColors.PrimaryText,
                    style = MaterialTheme.typography.labelLarge,
                )
                if (!state.correction.isDefault) {
                    Box(
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .size(8.dp)
                            .background(CcrColors.ActiveBlue, CircleShape)
                            .testTag("correction-status-dot"),
                    )
                }
                Spacer(Modifier.weight(1f))
                Icon(
                    painter = painterResource(
                        if (state.expanded) R.drawable.ic_chevron_down else R.drawable.ic_chevron_up,
                    ),
                    contentDescription = if (state.expanded) "화면 보정 접기" else "화면 보정 펼치기",
                    tint = CcrColors.PrimaryText,
                    modifier = Modifier.size(24.dp),
                )
            }
            if (state.expanded) {
                HorizontalDivider(color = CcrColors.Border)
                CorrectionPanel(
                    correction = state.correction,
                    onCorrectionChange = { onStateChange(state.withCorrection(it)) },
                    comparingOriginal = comparingOriginal,
                    onComparingOriginalChange = onComparingOriginalChange,
                )
            }
        }
    }
}

@Composable
private fun CorrectionPanel(
    correction: VideoCorrection,
    onCorrectionChange: (VideoCorrection) -> Unit,
    comparingOriginal: Boolean,
    onComparingOriginalChange: (Boolean) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 228.dp)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .testTag("correction-panel"),
    ) {
        CorrectionSlider("밝기", "correction-level-slider", correction.level, VideoCorrectionLimits.Level) {
            onCorrectionChange(correction.withLevel(it))
        }
        CorrectionSlider("명암", "correction-width-slider", correction.width, VideoCorrectionLimits.Width) {
            onCorrectionChange(correction.withWidth(it))
        }
        CorrectionSlider("감마", "correction-gamma-slider", correction.gamma, VideoCorrectionLimits.Gamma) {
            onCorrectionChange(correction.withGamma(it))
        }
        CorrectionSlider(
            "선명도",
            "correction-sharp-slider",
            correction.sharpAmount,
            VideoCorrectionLimits.SharpAmount,
        ) {
            onCorrectionChange(correction.withSharpAmount(it))
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CorrectionActionButton(
                label = "반전",
                icon = R.drawable.ic_inverse,
                active = correction.invert,
                onClick = { onCorrectionChange(correction.toggledInvert()) },
            )
            OriginalCompareButton(
                comparingOriginal = comparingOriginal,
                onComparingOriginalChange = onComparingOriginalChange,
            )
            CorrectionActionButton(
                label = "초기화",
                icon = R.drawable.ic_reset,
                active = false,
                onClick = { onCorrectionChange(VideoCorrection.Default) },
            )
        }
    }
}

@Composable
private fun CorrectionSlider(
    label: String,
    testTag: String,
    value: Float,
    limit: CorrectionLimit,
    onValueChange: (Float) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = CcrColors.PrimaryText, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.widthIn(min = 48.dp))
        CcrSlider(
            value = value,
            onValueChange = onValueChange,
            valueRange = limit.min..limit.max,
            steps = (((limit.max - limit.min) / limit.step).roundToInt() - 1).coerceAtLeast(0),
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 48.dp)
                .testTag(testTag),
        )
        Text(
            text = String.format(Locale.US, "%.2f", value),
            color = CcrColors.PrimaryText,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.widthIn(min = 44.dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CcrSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    steps: Int = 0,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val colors = SliderDefaults.colors(
        thumbColor = CcrColors.ActiveBlue,
        activeTrackColor = CcrColors.ActiveBlue,
        inactiveTrackColor = CcrColors.StrongBorder,
        disabledThumbColor = CcrColors.MutedText,
        disabledActiveTrackColor = CcrColors.Border,
        disabledInactiveTrackColor = CcrColors.Border,
    )
    Slider(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        valueRange = valueRange,
        steps = steps,
        onValueChangeFinished = onValueChangeFinished,
        colors = colors,
        interactionSource = interactionSource,
        thumb = {
            SliderDefaults.Thumb(
                interactionSource = interactionSource,
                modifier = Modifier.testTag("ccr-slider-thumb"),
                colors = colors,
                enabled = enabled,
                thumbSize = DpSize(12.dp, 12.dp),
            )
        },
        track = { sliderState ->
            SliderDefaults.Track(
                sliderState = sliderState,
                modifier = Modifier
                    .height(2.dp)
                    .testTag("ccr-slider-track"),
                enabled = enabled,
                colors = colors,
                drawStopIndicator = null,
                drawTick = { _, _ -> },
                thumbTrackGapSize = 0.dp,
                trackInsideCornerSize = 1.dp,
            )
        },
    )
}

@Composable
private fun RowScope.CorrectionActionButton(
    label: String,
    icon: Int,
    active: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        shape = ControlShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (active) CcrColors.ActiveBlue.copy(alpha = 0.24f) else CcrColors.Control,
            contentColor = CcrColors.PrimaryText,
        ),
        border = BorderStroke(1.dp, if (active) CcrColors.ActiveBlue else CcrColors.Border),
        contentPadding = PaddingValues(horizontal = 6.dp),
        modifier = Modifier
            .weight(1f)
            .heightIn(min = 48.dp),
    ) {
        Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(18.dp))
        Text(label, fontSize = 13.sp, modifier = Modifier.padding(start = 4.dp), maxLines = 1)
    }
}

@Composable
internal fun RowScope.OriginalCompareButton(
    comparingOriginal: Boolean,
    onComparingOriginalChange: (Boolean) -> Unit,
) {
    val currentOnChange by rememberUpdatedState(onComparingOriginalChange)
    val previewScope = rememberCoroutineScope()
    var accessiblePreviewJob by remember { mutableStateOf<Job?>(null) }
    DisposableEffect(Unit) {
        onDispose {
            accessiblePreviewJob?.cancel()
            currentOnChange(false)
        }
    }
    Button(
        onClick = {
            accessiblePreviewJob?.cancel()
            currentOnChange(true)
            accessiblePreviewJob = previewScope.launch {
                delay(ACCESSIBLE_ORIGINAL_PREVIEW_MS)
                currentOnChange(false)
            }
        },
        shape = ControlShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (comparingOriginal) CcrColors.Pressed else CcrColors.Control,
            contentColor = CcrColors.PrimaryText,
        ),
        border = BorderStroke(1.dp, CcrColors.Border),
        contentPadding = PaddingValues(horizontal = 4.dp),
        modifier = Modifier
            .weight(1.35f)
            .heightIn(min = 48.dp)
            .testTag("original-compare")
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    accessiblePreviewJob?.cancel()
                    currentOnChange(true)
                    try {
                        while (true) {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            val primary = event.changes.firstOrNull { it.id == down.id }
                            val outside = primary == null || primary.position.isOutside(size.width, size.height)
                            val secondPointer = event.changes.any { it.id != down.id && it.pressed }
                            event.changes.forEach { it.consume() }
                            if (outside || secondPointer || !primary.pressed) break
                        }
                    } finally {
                        currentOnChange(false)
                    }
                }
            }
            .semantics { role = Role.Button },
    ) {
        Text("원본 비교", fontSize = 13.sp, maxLines = 1)
    }
}

@Composable
internal fun RowScope.NavigationButton(
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
        onClick = {
            val generation = currentOnGestureStart()
            try {
                currentOnTap(delta, generation)
            } finally {
                currentOnGestureEnd(generation)
            }
        },
        enabled = enabled,
        shape = ControlShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = CcrColors.Control,
            contentColor = CcrColors.PrimaryText,
            disabledContainerColor = CcrColors.Control,
            disabledContentColor = CcrColors.MutedText,
        ),
        border = BorderStroke(1.dp, CcrColors.Border),
        contentPadding = PaddingValues(0.dp),
        modifier = Modifier
            .weight(1f)
            .widthIn(min = 48.dp)
            .heightIn(min = 48.dp)
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
        Text(label, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

internal fun displayedFrameText(state: ViewerUiState): String {
    val total = state.metadata?.frameCount ?: return "— / —"
    val current = state.displayedFrameIndex?.plus(1)?.coerceIn(1, total)?.toString() ?: "—"
    return "$current / $total"
}

internal fun displayFileName(uri: Uri?): String? {
    val raw = uri?.lastPathSegment ?: return null
    return Uri.decode(raw)
        .substringAfterLast(':')
        .substringAfterLast('/')
        .takeIf(String::isNotBlank)
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

private val ControlShape = RoundedCornerShape(5.dp)

private const val ACCESSIBLE_ORIGINAL_PREVIEW_MS = 1_000L
