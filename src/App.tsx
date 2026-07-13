import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent,
} from "react";
import {
  actualSizeViewTransform,
  createViewTransform,
  fitViewTransform,
  viewportToImage,
  panByViewportDelta,
  resizeViewTransform,
  stepViewZoom,
  viewPlacement,
  zoomAtViewportPoint,
  type ViewTransform,
} from "./domain/viewTransform";
import {
  annotationsForFrame,
  commitAnnotationChange,
  createAnnotation,
  createAnnotationSession,
  discardAnnotationPreview,
  moveAnnotation,
  pointInImage,
  previewAnnotation,
  redoAnnotation,
  resizeAnnotation,
  selectAnnotation,
  undoAnnotation,
  updateAnnotationDefaults,
  updateAnnotationStyle,
  type Annotation,
  type AnnotationHandle,
  type AnnotationSession,
  type DrawingAnnotationKind,
} from "./domain/annotation";
import { frameIndexFromTimelinePosition, nearestAnnotatedFrame, type TimelineMarkerBucket } from "./domain/annotatedTimeline";
import {
  beginPan,
  beginZoomDrag,
  fullscreenShortcut,
  movePan,
  viewWheelIntent,
  WheelZoomAccumulator,
  zoomForVerticalDrag,
  zoomShortcut,
  type PanGesture,
  type ZoomDragGesture,
} from "./domain/viewInteraction";
import {
  VIDEO_DISPLAY_PRESETS,
  applyVideoDisplayPreset,
  beginDisplayDrag,
  moveDisplayDrag,
  originalVideoDisplay,
  temporaryOriginalDisplay,
  toggleVideoDisplayInvert,
  updateVideoDisplay,
  videoDisplayEqual,
  videoDisplayShortcut,
  type DisplayDragGesture,
  type VideoDisplayPresetId,
  type VideoDisplayState,
} from "./domain/videoDisplay";
import { applyVideoDisplayToRgba } from "./domain/videoDisplayReference";
import {
  WheelFrameAccumulator,
  clampFrameIndex,
  displayToInternalFrame,
  internalToDisplayFrame,
  isOpenVideoShortcut,
  isTextEntryElement,
  navigationTargetForKey,
} from "./ui/frameNavigation";
import { releaseCanvas } from "./ui/viewerGeometry";
import { I420WebglRenderer } from "./ui/I420WebglRenderer";
import { AnnotationOverlay, type TextEditorState } from "./ui/AnnotationOverlay";
import { AnnotatedTimeline } from "./ui/AnnotatedTimeline";
import { defaultPngFileName, isStableExportFrame, type FrameExportMode } from "./domain/frameExport";
import { canvasToPngBytes, captureDisplayedFrameCanvas, renderFrameExport } from "./ui/frameExport";

type ViewerStatus = "idle" | "probing" | "ready" | "decoding" | "cancelled" | "error";

type SessionMetadata = NonNullable<CcrOpenVideoResponse["metadata"]>;

type KeyboardHoldIntent = {
  direction: -1 | 1;
  targetFrame: number;
  startedAt: number;
  holdDurationMs: number;
};

type ViewTool = "pan" | "zoom" | "select" | "arrow" | "text" | "ellipse" | "rectangle";

type AnnotationCreateGesture = {
  pointerId: number;
  annotationId: string;
  start: { x: number; y: number };
  startClient: { x: number; y: number };
  lastClient: { x: number; y: number };
  selectionBefore: string | null;
  kind: DrawingAnnotationKind;
};

type AnnotationEditGesture = {
  pointerId: number;
  before: Annotation;
  start: { x: number; y: number };
  handle?: AnnotationHandle;
};

type ActivePointerGesture =
  | { kind: "pan"; gesture: PanGesture }
  | { kind: "zoom"; gesture: ZoomDragGesture }
  | { kind: "display"; gesture: DisplayDragGesture }
  | { kind: "annotation-create"; gesture: AnnotationCreateGesture }
  | { kind: "annotation-move"; gesture: AnnotationEditGesture }
  | { kind: "annotation-resize"; gesture: AnnotationEditGesture }
  | { kind: "timeline"; gesture: { pointerId: number } };

const STATUS_LABELS: Record<ViewerStatus, string> = {
  idle: "대기",
  probing: "분석 중",
  ready: "준비",
  decoding: "디코딩 중",
  cancelled: "취소됨",
  error: "오류",
};

function readableTime(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) {
    return "-";
  }
  const minutes = Math.floor(seconds / 60);
  return `${String(minutes).padStart(2, "0")}:${(seconds % 60).toFixed(3).padStart(6, "0")}`;
}

function formatBytes(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

function formatZoomPercent(zoom: number): string {
  return `${Number((zoom * 100).toFixed(2))}%`;
}

function exportFailureMessage(error: unknown, action: "save" | "copy"): string {
  const code = error instanceof Error ? error.message : "";
  if (code === "EXPORT_PNG_ENCODE_FAILED") return "PNG 인코딩에 실패했습니다.";
  if (action === "save") return "파일을 저장하지 못했습니다. 권한과 여유 공간을 확인하세요.";
  return "시스템 클립보드에 이미지를 복사하지 못했습니다.";
}

export function App() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const viewerSurfaceRef = useRef<HTMLElement>(null);
  const timelineRef = useRef<HTMLDivElement>(null);
  const sessionIdRef = useRef<string | null>(null);
  const sourceBaseNameRef = useRef<string | undefined>(undefined);
  const desiredFrameRef = useRef(0);
  const displayedFrameRef = useRef(-1);
  const pumpingRef = useRef(false);
  const uiGenerationRef = useRef(0);
  const wheelRef = useRef(new WheelFrameAccumulator());
  const zoomWheelRef = useRef(new WheelZoomAccumulator());
  const navigationFrameRef = useRef<number | null>(null);
  const keyboardHoldRef = useRef<KeyboardHoldIntent | null>(null);
  const forceRgbaRef = useRef(false);
  const i420RendererRef = useRef<I420WebglRenderer | null>(null);
  const activePointerRef = useRef<ActivePointerGesture | null>(null);
  const lastFrameRef = useRef<CcrFrameResponse | null>(null);
  const displayStateRef = useRef<VideoDisplayState>(originalVideoDisplay());
  const comparingOriginalRef = useRef(false);
  const annotationSessionRef = useRef<AnnotationSession>(createAnnotationSession());
  const [metadata, setMetadata] = useState<SessionMetadata | null>(null);
  const [frameIndex, setFrameIndex] = useState(0);
  const [frameInput, setFrameInput] = useState("1");
  const [ptsSeconds, setPtsSeconds] = useState<number | null>(null);
  const [cacheStatus, setCacheStatus] = useState<CcrCacheStatus | null>(null);
  const [cacheResult, setCacheResult] = useState("-");
  const [requestMs, setRequestMs] = useState<number | null>(null);
  const [diagnostics, setDiagnostics] = useState<CcrFrameDiagnostics | null>(null);
  const [status, setStatus] = useState<ViewerStatus>("idle");
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [viewTransform, setViewTransform] = useState<ViewTransform | null>(null);
  const [viewTool, setViewTool] = useState<ViewTool>("pan");
  const [activePointerKind, setActivePointerKind] = useState<ActivePointerGesture["kind"] | null>(null);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [displayState, setDisplayState] = useState<VideoDisplayState>(originalVideoDisplay);
  const [comparingOriginal, setComparingOriginal] = useState(false);
  const [annotationSession, setAnnotationSessionState] = useState<AnnotationSession>(annotationSessionRef.current);
  const [textEditor, setTextEditor] = useState<TextEditorState | null>(null);
  const [exportMode, setExportMode] = useState<FrameExportMode>("full-frame");
  const [includeExportAnnotations, setIncludeExportAnnotations] = useState(true);
  const [exportBusy, setExportBusy] = useState(false);
  const [exportMessage, setExportMessage] = useState<string | null>(null);

  const setAnnotationSession = useCallback((next: AnnotationSession) => {
    annotationSessionRef.current = next;
    setAnnotationSessionState(next);
  }, []);

  const clearViewer = useCallback(() => {
    sessionIdRef.current = null;
    sourceBaseNameRef.current = undefined;
    desiredFrameRef.current = 0;
    displayedFrameRef.current = -1;
    keyboardHoldRef.current = null;
    setMetadata(null);
    setFrameIndex(0);
    setFrameInput("1");
    setPtsSeconds(null);
    setCacheStatus(null);
    setCacheResult("-");
    setRequestMs(null);
    setDiagnostics(null);
    activePointerRef.current = null;
    lastFrameRef.current = null;
    setActivePointerKind(null);
    setViewTool("pan");
    setViewTransform(null);
    setTextEditor(null);
    setExportBusy(false);
    setExportMessage(null);
    setAnnotationSession(createAnnotationSession());
    wheelRef.current.reset();
    zoomWheelRef.current.reset();
    displayStateRef.current = originalVideoDisplay();
    comparingOriginalRef.current = false;
    setDisplayState(displayStateRef.current);
    setComparingOriginal(false);
    i420RendererRef.current?.dispose();
    i420RendererRef.current = null;
    releaseCanvas(canvasRef.current);
    if (window.ccr?.openQaVideo) {
      delete document.documentElement.dataset.qaSampleIndex;
      delete document.documentElement.dataset.qaPixelFormat;
      delete document.documentElement.dataset.qaViewZoom;
      delete document.documentElement.dataset.qaViewCenter;
      delete document.documentElement.dataset.qaViewRevision;
      document.documentElement.dataset.qaViewTool = "pan";
      document.documentElement.dataset.qaPointerGesture = "none";
      document.documentElement.dataset.qaAnnotationCount = "0";
      document.documentElement.dataset.qaAnnotationHistory = "0,0";
      delete document.documentElement.dataset.qaDisplayState;
      delete document.documentElement.dataset.qaDisplayDrawMs;
      delete document.documentElement.dataset.qaTextureUploads;
      document.documentElement.dataset.qaBackgroundComplete = "false";
      document.documentElement.dataset.qaSeekDecodeCount = "0";
    }
  }, []);

  const recordDisplayQa = useCallback((drawMs: number) => {
    if (!window.ccr?.openQaVideo) return;
    document.documentElement.dataset.qaDisplayDrawMs = String(drawMs);
    document.documentElement.dataset.qaTextureUploads = String(i420RendererRef.current?.getStats().textureUploadCount ?? 0);
  }, [setAnnotationSession]);

  const redrawCurrentFrame = useCallback(() => {
    const frame = lastFrameRef.current;
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!frame?.descriptor || !frame.pixels || !canvas || !context) return;
    const effective = temporaryOriginalDisplay(displayStateRef.current, comparingOriginalRef.current);
    const startedAt = performance.now();
    if (frame.descriptor.pixelFormat === "i420" && i420RendererRef.current) {
      try {
        context.drawImage(i420RendererRef.current.redraw(effective), 0, 0);
      } catch {
        return;
      }
    } else {
      const adjusted = applyVideoDisplayToRgba(
        frame.pixels,
        frame.descriptor.width,
        frame.descriptor.height,
        displayStateRef.current,
        comparingOriginalRef.current,
      );
      context.putImageData(new ImageData(adjusted, frame.descriptor.width, frame.descriptor.height), 0, 0);
    }
    recordDisplayQa(performance.now() - startedAt);
  }, [recordDisplayQa]);

  const renderFrame = useCallback(async (frame: CcrFrameResponse) => {
    if (!frame.accepted || !frame.descriptor || !frame.pixels) {
      return;
    }
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context) {
      return;
    }
    let rendered = frame;
    canvas.width = frame.descriptor.width;
    canvas.height = frame.descriptor.height;
    const effective = temporaryOriginalDisplay(displayStateRef.current, comparingOriginalRef.current);
    if (frame.descriptor.pixelFormat === "i420" && frame.layout && frame.colorSpace) {
      try {
        i420RendererRef.current ??= new I420WebglRenderer();
        const startedAt = performance.now();
        const renderedCanvas = i420RendererRef.current.render({
          pixels: frame.pixels,
          width: frame.descriptor.width,
          height: frame.descriptor.height,
          layout: frame.layout,
          colorSpace: frame.colorSpace,
          display: effective,
        });
        context.drawImage(renderedCanvas, 0, 0);
        recordDisplayQa(performance.now() - startedAt);
      } catch {
        i420RendererRef.current?.dispose();
        i420RendererRef.current = null;
        forceRgbaRef.current = true;
        const sessionId = sessionIdRef.current;
        if (sessionId) await window.ccr?.ackFirstFrame?.(sessionId);
        let fallback = sessionId
          ? await window.ccr?.getFrame?.(sessionId, frame.descriptor.frameIndex, "rgba")
          : null;
        const fallbackDeadline = performance.now() + 5_000;
        while (
          fallback?.error === "FRAME_NOT_READY" &&
          sessionId === sessionIdRef.current &&
          performance.now() < fallbackDeadline
        ) {
          await new Promise((resolve) => setTimeout(resolve, 16));
          fallback = await window.ccr?.getFrame?.(sessionId!, frame.descriptor.frameIndex, "rgba");
        }
        if (!fallback?.accepted || !fallback.descriptor || !fallback.pixels) {
          setError("I420_WEBGL_RENDER_FAILED");
          setStatus("error");
          return;
        }
        rendered = fallback;
        const startedAt = performance.now();
        const adjusted = applyVideoDisplayToRgba(
          fallback.pixels,
          fallback.descriptor.width,
          fallback.descriptor.height,
          displayStateRef.current,
          comparingOriginalRef.current,
        );
        context.putImageData(new ImageData(adjusted, fallback.descriptor.width, fallback.descriptor.height), 0, 0);
        recordDisplayQa(performance.now() - startedAt);
      }
    } else {
      const startedAt = performance.now();
      const adjusted = applyVideoDisplayToRgba(
        frame.pixels,
        frame.descriptor.width,
        frame.descriptor.height,
        displayStateRef.current,
        comparingOriginalRef.current,
      );
      context.putImageData(new ImageData(adjusted, frame.descriptor.width, frame.descriptor.height), 0, 0);
      recordDisplayQa(performance.now() - startedAt);
    }
    if (!rendered.descriptor) return;
    lastFrameRef.current = rendered;
    displayedFrameRef.current = rendered.descriptor.frameIndex;
    if (window.ccr?.openQaVideo) {
      document.documentElement.dataset.qaPixelFormat = rendered.descriptor.pixelFormat;
    }
    setFrameIndex(rendered.descriptor.frameIndex);
    setFrameInput(String(internalToDisplayFrame(rendered.descriptor.frameIndex)));
    setPtsSeconds(rendered.descriptor.ptsSeconds);
    setCacheResult(rendered.cache ?? "-");
    setRequestMs(rendered.requestMs ?? null);
    setCacheStatus(rendered.cacheStatus ?? null);
    setDiagnostics(rendered.diagnostics ?? null);
  }, [recordDisplayQa]);

  const pump = useCallback(async () => {
    if (pumpingRef.current || !window.ccr?.getFrame || !sessionIdRef.current || !metadata) {
      return;
    }
    const uiGeneration = uiGenerationRef.current;
    const sessionId = sessionIdRef.current;
    pumpingRef.current = true;
    const loadingTimer = metadata.productCache
      ? window.setTimeout(() => setStatus("decoding"), 100)
      : null;
    if (!metadata.productCache) setStatus("decoding");
    setError(null);
    let failed = false;
    try {
      while (
        uiGeneration === uiGenerationRef.current &&
        sessionId === sessionIdRef.current &&
        desiredFrameRef.current !== displayedFrameRef.current
      ) {
        const target = desiredFrameRef.current;
        const response = await window.ccr.getFrame(sessionId, target, forceRgbaRef.current ? "rgba" : "i420");
        if (uiGeneration !== uiGenerationRef.current || sessionId !== sessionIdRef.current) {
          return;
        }
        if (!response.accepted) {
          if (response.error === "FRAME_NOT_READY" && target === desiredFrameRef.current) {
            await new Promise((resolve) => setTimeout(resolve, 16));
            continue;
          }
          if (response.error && response.error !== "DECODE_CANCELLED") {
            setError(response.error);
            setStatus("error");
            failed = true;
          }
          if (target === desiredFrameRef.current) {
            break;
          }
          continue;
        }
        if (target === desiredFrameRef.current) {
          await renderFrame(response);
        }
      }
      if (uiGeneration === uiGenerationRef.current && !failed) {
        setStatus("ready");
      }
    } finally {
      if (loadingTimer !== null) window.clearTimeout(loadingTimer);
      pumpingRef.current = false;
    }
  }, [metadata, renderFrame]);

  const goToFrame = useCallback((nextFrameIndex: number, defer = false) => {
    if (!metadata) {
      return;
    }
    const target = clampFrameIndex(nextFrameIndex, metadata.frameCount);
    desiredFrameRef.current = target;
    const selected = annotationSessionRef.current.annotations.find((annotation) => annotation.id === annotationSessionRef.current.selectedId);
    if (selected && selected.frameIndex !== target) {
      setAnnotationSession(selectAnnotation(annotationSessionRef.current, null));
    }
    if (!defer) {
      void pump();
      return;
    }
    if (navigationFrameRef.current === null) {
      navigationFrameRef.current = requestAnimationFrame(() => {
        navigationFrameRef.current = null;
        void pump();
      });
    }
  }, [metadata, pump, setAnnotationSession]);

  const acceptOpenedVideo = useCallback(async (promise: Promise<CcrOpenVideoResponse>) => {
    const uiGeneration = ++uiGenerationRef.current;
    setStatus("probing");
    setError(null);
    let opened: CcrOpenVideoResponse;
    try {
      opened = await promise;
    } catch {
      if (uiGeneration === uiGenerationRef.current) {
        clearViewer();
        setError("OPEN_FAILED");
        setStatus("error");
      }
      return;
    }
    if (uiGeneration !== uiGenerationRef.current || opened.error === "OPEN_SUPERSEDED") {
      return;
    }
    if (opened.canceled) {
      setStatus(metadata ? "ready" : "idle");
      return;
    }
    if (opened.error || !opened.sessionId || !opened.metadata || !opened.frame?.accepted) {
      clearViewer();
      setError(opened.error ?? "OPEN_FAILED");
      setStatus(opened.error?.includes("CANCELLED") ? "cancelled" : "error");
      return;
    }
    sessionIdRef.current = opened.sessionId;
    sourceBaseNameRef.current = opened.sourceBaseName;
    setMetadata(opened.metadata);
    setTextEditor(null);
    setAnnotationSession(createAnnotationSession());
    setViewTool("pan");
    setExportMessage(null);
    displayStateRef.current = originalVideoDisplay();
    comparingOriginalRef.current = false;
    setDisplayState(displayStateRef.current);
    setComparingOriginal(false);
    const viewport = viewerSurfaceRef.current?.getBoundingClientRect();
    setViewTransform(createViewTransform(
      { width: opened.metadata.width, height: opened.metadata.height },
      { width: viewport?.width ?? 1, height: viewport?.height ?? 1 },
    ));
    desiredFrameRef.current = 0;
    displayedFrameRef.current = -1;
    wheelRef.current.reset();
    zoomWheelRef.current.reset();
    forceRgbaRef.current = false;
    await renderFrame(opened.frame);
    if (opened.qaSampleIndex !== undefined && window.ccr?.openQaVideo) {
      document.documentElement.dataset.qaSampleIndex = String(opened.qaSampleIndex);
    }
    if (opened.metadata.productCache) {
      await window.ccr?.ackFirstFrame?.(opened.sessionId);
    }
    setStatus("ready");
  }, [clearViewer, metadata, renderFrame, setAnnotationSession]);

  useEffect(() => {
    if (!window.ccr?.openQaVideo) return;
    const openQaSample = (sampleIndex: number) => {
      clearViewer();
      void acceptOpenedVideo(window.ccr!.openQaVideo!(sampleIndex));
    };
    const onQaOpen = (event: Event) => {
      const sampleIndex = (event as CustomEvent<number>).detail;
      if (Number.isInteger(sampleIndex)) openQaSample(sampleIndex);
    };
    const onQaLoseContext = () => i420RendererRef.current?.loseContext();
    window.addEventListener("ccr:qaOpen", onQaOpen);
    window.addEventListener("ccr:qaLoseContext", onQaLoseContext);
    return () => {
      window.removeEventListener("ccr:qaOpen", onQaOpen);
      window.removeEventListener("ccr:qaLoseContext", onQaLoseContext);
    };
  }, [acceptOpenedVideo, clearViewer]);

  const openVideo = useCallback(() => {
    if (!window.ccr?.openVideo) {
      setError("ELECTRON_RUNTIME_REQUIRED");
      setStatus("error");
      return;
    }
    void acceptOpenedVideo(window.ccr.openVideo());
  }, [acceptOpenedVideo]);

  const cancel = useCallback(() => {
    uiGenerationRef.current += 1;
    desiredFrameRef.current = displayedFrameRef.current;
    void window.ccr?.cancelFrame?.();
    if (status === "probing") {
      clearViewer();
    }
    setStatus("cancelled");
  }, [clearViewer, status]);

  const submitFrameInput = useCallback(() => {
    if (!metadata) {
      return;
    }
    const parsed = Number(frameInput);
    const next = displayToInternalFrame(Number.isFinite(parsed) ? parsed : 1, metadata.frameCount);
    setFrameInput(String(internalToDisplayFrame(next)));
    goToFrame(next);
  }, [frameInput, goToFrame, metadata]);

  const onFrameInputKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      submitFrameInput();
      event.currentTarget.blur();
    }
  };

  const onWheel = (event: WheelEvent<HTMLElement>) => {
    event.preventDefault();
    const intent = viewWheelIntent(event);
    if (intent.type === "zoom") {
      const wheelDirection = zoomWheelRef.current.consume(event.deltaY, event.deltaMode);
      if (wheelDirection === 0) return;
      const bounds = event.currentTarget.getBoundingClientRect();
      const anchor = { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
      setViewTransform((current) => current
        ? stepViewZoom(current, wheelDirection < 0 ? 1 : -1, anchor)
        : current);
      return;
    }
    zoomWheelRef.current.reset();
    if (activePointerRef.current) return;
    const direction = wheelRef.current.consume(event.deltaY, event.deltaMode);
    if (direction !== 0) {
      goToFrame(desiredFrameRef.current + direction);
    }
  };

  const zoomByStep = useCallback((direction: -1 | 1) => {
    setViewTransform((current) => current
      ? stepViewZoom(current, direction, {
        x: current.viewportSize.width / 2,
        y: current.viewportSize.height / 2,
      })
      : current);
  }, []);

  const fitView = useCallback(() => {
    setViewTransform((current) => current ? fitViewTransform(current) : current);
  }, []);

  const actualSizeView = useCallback(() => {
    setViewTransform((current) => current ? actualSizeViewTransform(current) : current);
  }, []);

  const toggleFullscreen = useCallback(() => {
    void window.ccr?.toggleFullscreen?.().then(setIsFullscreen);
  }, []);

  const exitFullscreen = useCallback(() => {
    void window.ccr?.setFullscreen?.(false).then(setIsFullscreen);
  }, []);

  const endPointerGesture = useCallback((pointerId?: number) => {
    activePointerRef.current = null;
    setActivePointerKind(null);
    if (pointerId === undefined) return;
    for (const element of [viewerSurfaceRef.current, timelineRef.current]) {
      if (element?.hasPointerCapture(pointerId)) element.releasePointerCapture(pointerId);
    }
  }, []);

  const cancelPointerGesture = useCallback(() => {
    const active = activePointerRef.current;
    if (!active) return;
    if (active.kind === "annotation-create") {
      setAnnotationSession(discardAnnotationPreview(
        annotationSessionRef.current,
        active.gesture.annotationId,
        active.gesture.selectionBefore,
      ));
    } else if (active.kind === "annotation-move" || active.kind === "annotation-resize") {
      setAnnotationSession(selectAnnotation(previewAnnotation(annotationSessionRef.current, active.gesture.before), active.gesture.before.id));
    }
    endPointerGesture(active.gesture.pointerId);
  }, [endPointerGesture, setAnnotationSession]);

  const finishPointerGesture = useCallback((pointerId: number) => {
    const active = activePointerRef.current;
    if (!active || active.gesture.pointerId !== pointerId) return;
    if (active.kind === "annotation-create") {
      const draft = annotationSessionRef.current.annotations.find((annotation) => annotation.id === active.gesture.annotationId);
      const dragDistance = Math.hypot(
        active.gesture.lastClient.x - active.gesture.startClient.x,
        active.gesture.lastClient.y - active.gesture.startClient.y,
      );
      if (!draft || dragDistance < 4) {
        setAnnotationSession(discardAnnotationPreview(
          annotationSessionRef.current,
          active.gesture.annotationId,
          active.gesture.selectionBefore,
        ));
      } else {
        const base = { ...annotationSessionRef.current, selectedId: active.gesture.selectionBefore };
        setAnnotationSession(commitAnnotationChange(base, null, draft, draft.id));
      }
    } else if (active.kind === "annotation-move" || active.kind === "annotation-resize") {
      const after = annotationSessionRef.current.annotations.find((annotation) => annotation.id === active.gesture.before.id);
      if (after && JSON.stringify(after.geometry) !== JSON.stringify(active.gesture.before.geometry)) {
        setAnnotationSession(commitAnnotationChange(annotationSessionRef.current, active.gesture.before, after, after.id));
      }
    } else if (active.kind === "timeline") {
      goToFrame(desiredFrameRef.current);
    }
    endPointerGesture(pointerId);
  }, [endPointerGesture, goToFrame, setAnnotationSession]);

  const surfacePoint = (event: ReactPointerEvent<HTMLElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    return {
      x: event.clientX - bounds.left - event.currentTarget.clientLeft,
      y: event.clientY - bounds.top - event.currentTarget.clientTop,
    };
  };

  const annotationEventTarget = (target: EventTarget | null) => {
    const element = target instanceof Element ? target.closest<SVGElement>("[data-annotation-id]") : null;
    return {
      id: element?.dataset.annotationId ?? null,
      handle: (element?.dataset.annotationHandle as AnnotationHandle | undefined) ?? null,
    };
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLElement>) => {
    if (!metadata || activePointerRef.current || (event.button !== 0 && event.button !== 2)) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    if (event.button === 2) {
      activePointerRef.current = {
        kind: "display",
        gesture: beginDisplayDrag(event.pointerId, event.clientX, event.clientY, displayStateRef.current),
      };
      setActivePointerKind("display");
      return;
    }
    const viewportPoint = surfacePoint(event);
    const imagePoint = viewTransform ? viewportToImage(viewTransform, viewportPoint) : null;
    const target = annotationEventTarget(event.target);
    if (viewTool === "select") {
      const annotation = annotationSessionRef.current.annotations.find((candidate) => candidate.id === target.id && candidate.frameIndex === frameIndex);
      if (!annotation || !imagePoint) {
        setAnnotationSession(selectAnnotation(annotationSessionRef.current, null));
        endPointerGesture(event.pointerId);
        return;
      }
      setAnnotationSession(selectAnnotation(annotationSessionRef.current, annotation.id));
      activePointerRef.current = {
        kind: target.handle ? "annotation-resize" : "annotation-move",
        gesture: { pointerId: event.pointerId, before: annotation, start: imagePoint, handle: target.handle ?? undefined },
      };
      setActivePointerKind(target.handle ? "annotation-resize" : "annotation-move");
      return;
    }
    if (viewTool === "text") {
      if (!imagePoint || !viewTransform || !pointInImage(imagePoint, viewTransform.imageSize)) {
        endPointerGesture(event.pointerId);
        return;
      }
      setTextEditor({ annotationId: null, frameIndex, anchor: imagePoint, value: "" });
      endPointerGesture(event.pointerId);
      return;
    }
    if ((viewTool === "arrow" || viewTool === "ellipse" || viewTool === "rectangle") && viewTransform && imagePoint) {
      if (!pointInImage(imagePoint, viewTransform.imageSize)) {
        endPointerGesture(event.pointerId);
        return;
      }
      const draft = createAnnotation(annotationSessionRef.current, frameIndex, viewTool, imagePoint, imagePoint, viewTransform.imageSize);
      const selectionBefore = annotationSessionRef.current.selectedId;
      setAnnotationSession(selectAnnotation(previewAnnotation(annotationSessionRef.current, draft), draft.id));
      activePointerRef.current = {
        kind: "annotation-create",
        gesture: {
          pointerId: event.pointerId,
          annotationId: draft.id,
          start: imagePoint,
          startClient: { x: event.clientX, y: event.clientY },
          lastClient: { x: event.clientX, y: event.clientY },
          selectionBefore,
          kind: viewTool,
        },
      };
      setActivePointerKind("annotation-create");
      return;
    }
    if (viewTool === "zoom" && viewTransform) {
      const bounds = event.currentTarget.getBoundingClientRect();
      activePointerRef.current = {
        kind: "zoom",
        gesture: beginZoomDrag(event.pointerId, event.clientY, viewTransform.zoom, {
          x: event.clientX - bounds.left,
          y: event.clientY - bounds.top,
        }),
      };
      setActivePointerKind("zoom");
      return;
    }
    activePointerRef.current = { kind: "pan", gesture: beginPan(event.pointerId, event.clientX, event.clientY) };
    setActivePointerKind("pan");
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLElement>) => {
    const active = activePointerRef.current;
    if (!active || active.gesture.pointerId !== event.pointerId) return;
    if (active.kind === "display") {
      const next = moveDisplayDrag(active.gesture, event.pointerId, event.clientX, event.clientY);
      if (next) setDisplayState(next);
      return;
    }
    if (active.kind === "zoom") {
      const nextZoom = zoomForVerticalDrag(active.gesture, event.pointerId, event.clientY);
      if (nextZoom !== null) {
        setViewTransform((current) => current
          ? zoomAtViewportPoint(current, nextZoom, active.gesture.anchor)
          : current);
      }
      return;
    }
    if (active.kind === "annotation-create") {
      if (viewTransform) {
        const point = viewportToImage(viewTransform, surfacePoint(event));
        const current = annotationSessionRef.current.annotations.find((annotation) => annotation.id === active.gesture.annotationId);
        if (current) {
        const draft = createAnnotation(
          { ...annotationSessionRef.current, nextOrder: current.order },
          current.frameIndex,
          active.gesture.kind,
          active.gesture.start,
          point,
          viewTransform.imageSize,
          event.shiftKey,
        );
        activePointerRef.current = {
          ...active,
          gesture: { ...active.gesture, lastClient: { x: event.clientX, y: event.clientY } },
        };
          setAnnotationSession(selectAnnotation(previewAnnotation(annotationSessionRef.current, draft), draft.id));
        }
      }
      return;
    }
    if (active.kind === "annotation-move" || active.kind === "annotation-resize") {
      if (viewTransform) {
        const point = viewportToImage(viewTransform, surfacePoint(event));
        const next = active.kind === "annotation-move"
          ? moveAnnotation(active.gesture.before, { x: point.x - active.gesture.start.x, y: point.y - active.gesture.start.y }, viewTransform.imageSize)
          : resizeAnnotation(active.gesture.before, active.gesture.handle!, point, viewTransform.imageSize, event.shiftKey);
        setAnnotationSession(selectAnnotation(previewAnnotation(annotationSessionRef.current, next), next.id));
      }
      return;
    }
    if (active.kind === "timeline") return;
    const moved = movePan(active.gesture, event.pointerId, event.clientX, event.clientY);
    if (moved.delta) {
      activePointerRef.current = { kind: "pan", gesture: moved.gesture };
      setViewTransform((current) => current ? panByViewportDelta(current, moved.delta!) : current);
    }
  };

  const onPointerEnd = (event: ReactPointerEvent<HTMLElement>) => {
    finishPointerGesture(event.pointerId);
  };

  const onPointerCancel = (event: ReactPointerEvent<HTMLElement>) => {
    if (activePointerRef.current?.gesture.pointerId === event.pointerId) cancelPointerGesture();
  };

  const commitTextEditor = () => {
    if (!textEditor) return;
    const value = textEditor.value;
    if (textEditor.annotationId) {
      const before = annotationSessionRef.current.annotations.find((annotation) => annotation.id === textEditor.annotationId);
      if (before?.kind === "text" && value.trim() && value !== before.geometry.text) {
        const after = { ...before, geometry: { ...before.geometry, text: value } };
        setAnnotationSession(commitAnnotationChange(annotationSessionRef.current, before, after, after.id));
      }
    } else if (value.trim()) {
      const annotation = createAnnotation(
        annotationSessionRef.current,
        textEditor.frameIndex,
        "text",
        textEditor.anchor,
        textEditor.anchor,
        undefined,
        false,
        value,
      );
      setAnnotationSession(commitAnnotationChange(annotationSessionRef.current, null, annotation, annotation.id));
    }
    setTextEditor(null);
  };

  const editTextAnnotation = (annotation: Annotation) => {
    if (annotation.kind !== "text") return;
    setAnnotationSession(selectAnnotation(annotationSessionRef.current, annotation.id));
    setTextEditor({
      annotationId: annotation.id,
      frameIndex: annotation.frameIndex,
      anchor: annotation.geometry.anchor,
      value: annotation.geometry.text,
    });
  };

  const onViewerDoubleClick = (event: ReactMouseEvent<HTMLElement>) => {
    const target = annotationEventTarget(event.target);
    const annotation = annotationSessionRef.current.annotations.find((candidate) => candidate.id === target.id);
    if (annotation?.kind === "text") {
      event.preventDefault();
      editTextAnnotation(annotation);
    } else if (viewTool === "pan" || viewTool === "zoom" || viewTool === "select") {
      fitView();
    }
  };

  const changeAnnotationStyle = (style: Partial<Annotation["style"]>) => {
    const selected = annotationSessionRef.current.annotations.find((annotation) => annotation.id === annotationSessionRef.current.selectedId);
    if (!selected) {
      setAnnotationSession(updateAnnotationDefaults(annotationSessionRef.current, style));
      return;
    }
    const after = updateAnnotationStyle(selected, style);
    setAnnotationSession(commitAnnotationChange(annotationSessionRef.current, selected, after, after.id));
  };

  const applyHistoryResult = (result: ReturnType<typeof undoAnnotation>) => {
    if (!result) return;
    setTextEditor(null);
    setAnnotationSession(result.session);
    goToFrame(result.frameIndex);
  };

  const timelineFrameAtEvent = (event: ReactPointerEvent<HTMLElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    return metadata
      ? frameIndexFromTimelinePosition(event.clientX - bounds.left - event.currentTarget.clientLeft, event.currentTarget.clientWidth, metadata.frameCount)
      : 0;
  };

  const onTimelinePointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!metadata || activePointerRef.current || event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    activePointerRef.current = { kind: "timeline", gesture: { pointerId: event.pointerId } };
    setActivePointerKind("timeline");
    goToFrame(timelineFrameAtEvent(event), true);
  };

  const onTimelinePointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (activePointerRef.current?.kind === "timeline" && activePointerRef.current.gesture.pointerId === event.pointerId) {
      goToFrame(timelineFrameAtEvent(event), true);
    }
  };

  const onTimelinePointerEnd = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (activePointerRef.current?.kind === "timeline" && activePointerRef.current.gesture.pointerId === event.pointerId) {
      goToFrame(timelineFrameAtEvent(event));
      endPointerGesture(event.pointerId);
    }
  };

  const onTimelineMarkerSelect = (event: ReactPointerEvent<HTMLButtonElement>, bucket: TimelineMarkerBucket) => {
    event.preventDefault();
    event.stopPropagation();
    if (!metadata || activePointerRef.current) return;
    const track = timelineRef.current;
    const bounds = track?.getBoundingClientRect();
    const target = nearestAnnotatedFrame(bucket, bounds && track
      ? frameIndexFromTimelinePosition(event.clientX - bounds.left - track.clientLeft, track.clientWidth, metadata.frameCount)
      : bucket.frames[0].frameIndex);
    setAnnotationSession(selectAnnotation(annotationSessionRef.current, target.firstAnnotationId));
    goToFrame(target.frameIndex);
  };

  const onDrop = (event: DragEvent<HTMLElement>) => {
    event.preventDefault();
    setDragging(false);
    const file = event.dataTransfer.files.item(0);
    if (!file || !window.ccr?.openDroppedVideo) {
      setError("INVALID_VIDEO_SOURCE");
      setStatus("error");
      return;
    }
    clearViewer();
    void acceptOpenedVideo(window.ccr.openDroppedVideo(file));
  };

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (isOpenVideoShortcut(event)) {
        event.preventDefault();
        openVideo();
        return;
      }
      const editing = isTextEntryElement(event.target);
      if (event.key === "Escape" && !editing) {
        if (comparingOriginalRef.current) {
          event.preventDefault();
          setComparingOriginal(false);
        } else if (activePointerRef.current) {
          event.preventDefault();
          cancelPointerGesture();
        } else if (isFullscreen) {
          event.preventDefault();
          exitFullscreen();
        } else if (metadata) {
          cancel();
        }
        return;
      }
      if (fullscreenShortcut({ key: event.key, editing })) {
        event.preventDefault();
        toggleFullscreen();
        return;
      }
      if (!metadata) {
        return;
      }
      const historyShortcut = event.ctrlKey && !event.altKey && !editing && (
        event.key.toLowerCase() === "z" || event.key.toLowerCase() === "y"
      );
      if (historyShortcut) {
        event.preventDefault();
        const redo = event.key.toLowerCase() === "y" || (event.key.toLowerCase() === "z" && event.shiftKey);
        applyHistoryResult(redo ? redoAnnotation(annotationSessionRef.current) : undoAnnotation(annotationSessionRef.current));
        return;
      }
      if (!editing && (event.key === "Delete" || event.key === "Backspace")) {
        const selected = annotationSessionRef.current.annotations.find((annotation) => annotation.id === annotationSessionRef.current.selectedId);
        if (selected) {
          event.preventDefault();
          setAnnotationSession(commitAnnotationChange(annotationSessionRef.current, selected, null, null));
          return;
        }
      }
      const displayShortcut = videoDisplayShortcut({ key: event.key, editing });
      if (displayShortcut) {
        event.preventDefault();
        if (displayShortcut === "reset") {
          setDisplayState((current) => applyVideoDisplayPreset(current, "original"));
        } else if (displayShortcut === "invert") {
          setDisplayState(toggleVideoDisplayInvert);
        } else if (!event.repeat) {
          setComparingOriginal(true);
        }
        return;
      }
      const viewShortcut = zoomShortcut({ key: event.key, editing });
      if (viewShortcut !== 0) {
        event.preventDefault();
        if (viewShortcut === "fit") fitView();
        else zoomByStep(viewShortcut);
        return;
      }
      if (metadata.productCache && metadata.analysisReady === false && event.key === "End") {
        event.preventDefault();
        return;
      }
      const target = navigationTargetForKey(
        event,
        desiredFrameRef.current,
        metadata.frameCount,
        editing,
      );
      if (target !== null) {
        event.preventDefault();
        if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
          const direction = event.key === "ArrowLeft" ? -1 : 1;
          if (!event.repeat || keyboardHoldRef.current?.direction !== direction) {
            keyboardHoldRef.current = {
              direction,
              targetFrame: target,
              startedAt: performance.now(),
              holdDurationMs: 0,
            };
          } else if (keyboardHoldRef.current) {
            keyboardHoldRef.current.targetFrame = target;
            keyboardHoldRef.current.holdDurationMs = performance.now() - keyboardHoldRef.current.startedAt;
          }
        }
        goToFrame(target, event.repeat);
      }
    };
    const onKeyUp = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() === "o") setComparingOriginal(false);
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        if (keyboardHoldRef.current) {
          keyboardHoldRef.current.targetFrame = desiredFrameRef.current;
          keyboardHoldRef.current.holdDurationMs = performance.now() - keyboardHoldRef.current.startedAt;
        }
        keyboardHoldRef.current = null;
        if (navigationFrameRef.current !== null) {
          cancelAnimationFrame(navigationFrameRef.current);
          navigationFrameRef.current = null;
        }
        void pump();
      }
    };
    const releaseTemporaryInput = (event?: PointerEvent) => {
      setComparingOriginal(false);
      const active = activePointerRef.current;
      if (active && (!event || active.gesture.pointerId === event.pointerId)) {
        if (event) finishPointerGesture(active.gesture.pointerId);
        else cancelPointerGesture();
      }
    };
    const onWindowPointerUp = (event: PointerEvent) => releaseTemporaryInput(event);
    const onWindowBlur = () => releaseTemporaryInput();
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    window.addEventListener("blur", onWindowBlur);
    window.addEventListener("pointerup", onWindowPointerUp);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
      window.removeEventListener("blur", onWindowBlur);
      window.removeEventListener("pointerup", onWindowPointerUp);
    };
  }, [cancel, cancelPointerGesture, exitFullscreen, finishPointerGesture, fitView, goToFrame, isFullscreen, metadata, openVideo, pump, setAnnotationSession, toggleFullscreen, zoomByStep]);

  useEffect(() => {
    const surface = viewerSurfaceRef.current;
    if (!surface) return;
    const observer = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setViewTransform((current) => current
        ? resizeViewTransform(current, { width, height })
        : current);
    });
    observer.observe(surface);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    void window.ccr?.getFullscreen?.().then(setIsFullscreen);
    return window.ccr?.onFullscreenChanged?.(setIsFullscreen);
  }, []);

  useEffect(() => window.ccr?.onCacheMetadata?.((update) => {
    if (update.sessionId !== sessionIdRef.current || !update.metadata) return;
    setMetadata((current) => current ? { ...current, ...update.metadata } : current);
    setCacheStatus(update.cacheStatus);
    if (update.cacheStatus.backgroundError) {
      setError(update.cacheStatus.backgroundError);
      setStatus("error");
    }
  }), []);

  useEffect(() => {
    if (!window.ccr?.openQaVideo) return;
    document.documentElement.dataset.qaBackgroundComplete = String(cacheStatus?.backgroundComplete === true);
    document.documentElement.dataset.qaSeekDecodeCount = String(cacheStatus?.seekDecodeCount ?? 0);
  }, [cacheStatus]);

  useEffect(() => {
    if (!window.ccr?.openQaVideo || !viewTransform) return;
    document.documentElement.dataset.qaViewZoom = String(viewTransform.zoom);
    document.documentElement.dataset.qaViewCenter = `${viewTransform.center.x},${viewTransform.center.y}`;
    document.documentElement.dataset.qaViewRevision = String(viewTransform.revision);
  }, [viewTransform]);

  useEffect(() => {
    document.documentElement.dataset.qaViewTool = viewTool;
    document.documentElement.dataset.qaPointerGesture = activePointerKind ?? "none";
  }, [activePointerKind, viewTool]);

  useEffect(() => {
    if (!window.ccr?.openQaVideo) return;
    document.documentElement.dataset.qaAnnotationCount = String(annotationSession.annotations.length);
    document.documentElement.dataset.qaAnnotationHistory = `${annotationSession.undoStack.length},${annotationSession.redoStack.length}`;
    document.documentElement.dataset.qaAnnotationState = JSON.stringify({
      annotations: annotationSession.annotations,
      selectedId: annotationSession.selectedId,
      defaults: annotationSession.defaults,
    });
  }, [annotationSession]);

  useEffect(() => {
    displayStateRef.current = displayState;
    comparingOriginalRef.current = comparingOriginal;
    if (window.ccr?.openQaVideo) {
      document.documentElement.dataset.qaDisplayState = JSON.stringify({ ...displayState, comparingOriginal });
    }
    redrawCurrentFrame();
  }, [comparingOriginal, displayState, redrawCurrentFrame]);

  useEffect(() => () => {
    uiGenerationRef.current += 1;
    void window.ccr?.closeVideo?.();
    i420RendererRef.current?.dispose();
    i420RendererRef.current = null;
    releaseCanvas(canvasRef.current);
  }, []);

  const exportFrame = useCallback(async (action: "save" | "copy") => {
    if (exportBusy || !metadata || !viewTransform) return;
    const frame = lastFrameRef.current;
    const descriptor = frame?.descriptor;
    const stable = Boolean(frame && descriptor) && isStableExportFrame({
      accepted: frame!.accepted,
      hasPixels: Boolean(frame!.pixels),
      identity: descriptor ? {
        frameIndex: descriptor.frameIndex,
        fingerprint: descriptor.fingerprint,
        width: descriptor.width,
        height: descriptor.height,
      } : undefined,
      displayedFrameIndex: displayedFrameRef.current,
      viewerStatus: status,
      pumping: pumpingRef.current,
    });
    if (!stable || !frame || !descriptor) {
      setExportMessage("표시 프레임이 안정된 뒤 다시 시도하세요.");
      return;
    }

    const exportGeneration = uiGenerationRef.current;
    setExportBusy(true);
    try {
      const textureUploadsBefore = i420RendererRef.current?.getStats().textureUploadCount ?? 0;
      const source = captureDisplayedFrameCanvas(frame, displayStateRef.current, i420RendererRef.current);
      const snapshotTransform = structuredClone(viewTransform);
      const snapshotAnnotations = includeExportAnnotations
        ? structuredClone(annotationsForFrame(annotationSessionRef.current, descriptor.frameIndex))
        : [];
      const identity = {
        frameIndex: descriptor.frameIndex,
        fingerprint: descriptor.fingerprint,
        width: descriptor.width,
        height: descriptor.height,
      };
      const output = renderFrameExport({
        mode: exportMode,
        identity,
        source,
        transform: snapshotTransform,
        annotations: snapshotAnnotations,
        devicePixelRatio: window.devicePixelRatio,
      });
      const bytes = await canvasToPngBytes(output);
      const textureUploadsAfter = i420RendererRef.current?.getStats().textureUploadCount ?? 0;
      if (window.ccr?.openQaVideo) {
        document.documentElement.dataset.qaExport = JSON.stringify({
          mode: exportMode,
          frameIndex: identity.frameIndex,
          fingerprint: identity.fingerprint,
          width: output.width,
          height: output.height,
          dpr: window.devicePixelRatio,
          annotationCount: snapshotAnnotations.length,
          byteLength: bytes.byteLength,
          textureUploadDelta: textureUploadsAfter - textureUploadsBefore,
        });
      }
      if (action === "save") {
        if (!window.ccr?.savePng) throw new Error("EXPORT_RUNTIME_REQUIRED");
        const result = await window.ccr.savePng(bytes, defaultPngFileName(sourceBaseNameRef.current, identity.frameIndex, metadata.frameCount));
        if (result.canceled) return;
        if (!result.saved) throw new Error(result.error ?? "EXPORT_SAVE_FAILED");
        if (exportGeneration === uiGenerationRef.current) setExportMessage(`PNG 저장 완료 · ${output.width}×${output.height}`);
      } else {
        if (!window.ccr?.copyPng) throw new Error("EXPORT_RUNTIME_REQUIRED");
        const result = await window.ccr.copyPng(bytes);
        if (!result.copied) throw new Error(result.error ?? "EXPORT_CLIPBOARD_FAILED");
        if (exportGeneration === uiGenerationRef.current) setExportMessage(`클립보드 복사 완료 · ${output.width}×${output.height} · 앱 종료 후 유지될 수 있음`);
      }
    } catch (exportError) {
      if (exportGeneration === uiGenerationRef.current) setExportMessage(exportFailureMessage(exportError, action));
    } finally {
      if (exportGeneration === uiGenerationRef.current) setExportBusy(false);
    }
  }, [exportBusy, exportMode, includeExportAnnotations, metadata, status, viewTransform]);

  const frameDisplay = metadata
    ? `${internalToDisplayFrame(frameIndex).toLocaleString()} / ${metadata.frameCount.toLocaleString()}`
    : "-";
  const placement = viewTransform ? viewPlacement(viewTransform) : null;
  const canvasStyle = placement ? {
    width: `${placement.width}px`,
    height: `${placement.height}px`,
    transform: `translate3d(${placement.left}px, ${placement.top}px, 0)`,
  } : undefined;
  const displayActive = !videoDisplayEqual(displayState, originalVideoDisplay());
  const displayLabel = comparingOriginal
    ? "Original 비교"
    : displayActive ? "보정 적용" : "Original";
  const frameAnnotations = annotationsForFrame(annotationSession, frameIndex);
  const selectedAnnotation = annotationSession.annotations.find((annotation) => annotation.id === annotationSession.selectedId) ?? null;
  const exportAvailable = Boolean(metadata && viewTransform && lastFrameRef.current?.descriptor) && isStableExportFrame({
    accepted: lastFrameRef.current?.accepted === true,
    hasPixels: Boolean(lastFrameRef.current?.pixels),
    identity: lastFrameRef.current?.descriptor,
    displayedFrameIndex: displayedFrameRef.current,
    viewerStatus: status,
    pumping: pumpingRef.current,
  });

  return (
    <main
      className={`app-shell${dragging ? " is-dragging" : ""}`}
      onDragEnter={(event) => { event.preventDefault(); setDragging(true); }}
      onDragOver={(event) => event.preventDefault()}
      onDragLeave={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragging(false);
      }}
      onDrop={onDrop}
    >
      <header className="topbar">
        <div className="brand-block">
          <h1>CT Cine Reviewer</h1>
          <span className={`status-indicator status-${status}`}>{STATUS_LABELS[status]}</span>
        </div>
        <div className="source-summary">
          {metadata
            ? `${metadata.width} x ${metadata.height}  |  ${metadata.fps?.toFixed(2) ?? "-"} fps  |  ${metadata.codecName?.toUpperCase() ?? "-"}`
            : "영상 없음"}
        </div>
        <div className="topbar-actions">
          <div className="view-toolbar" aria-label="화면 조작">
            <button type="button" title="10%p 축소 (-)" onClick={() => zoomByStep(-1)} disabled={!metadata}>−</button>
            <output aria-label="현재 확대율">{formatZoomPercent(viewTransform?.zoom ?? 1)}</output>
            <button type="button" title="10%p 확대 (+)" onClick={() => zoomByStep(1)} disabled={!metadata}>+</button>
            <button type="button" title="화면 맞춤 (0)" onClick={fitView} disabled={!metadata}>Fit</button>
            <button type="button" title="전체화면 (F)" onClick={toggleFullscreen}>{isFullscreen ? "창" : "전체"}</button>
          </div>
          <button className="primary-button" type="button" onClick={openVideo}>열기</button>
        </div>
      </header>

      <section className="viewer-layout">
        <section className="viewer-workspace">
          <div className="viewer-tool-rail" role="toolbar" aria-label="뷰어 도구" aria-orientation="vertical">
            {([
              ["pan", "✥", "Pan 도구", "Pan: 좌클릭 드래그로 영상 이동"],
              ["zoom", "⌕", "Zoom 도구", "Zoom: 좌클릭 후 위/아래 드래그"],
              ["select", "↖", "Select 도구", "Select: 주석 선택·이동·크기 조절"],
              ["arrow", "→", "Arrow 도구", "Arrow: 좌클릭 드래그로 화살표 생성"],
              ["text", "T", "Text 도구", "Text: 영상 위를 클릭해 한 줄 입력"],
              ["ellipse", "○", "Ellipse 도구", "Ellipse: 좌클릭 드래그로 타원 생성"],
              ["rectangle", "▭", "Rectangle 도구", "Rectangle: 좌클릭 드래그로 사각형 생성"],
            ] as const).map(([tool, icon, label, title]) => <button
              key={tool}
              type="button"
              className={viewTool === tool ? "is-active" : ""}
              aria-label={label}
              aria-pressed={viewTool === tool}
              title={title}
              onClick={() => setViewTool(tool)}
              disabled={!metadata}
            ><span aria-hidden="true">{icon}</span></button>)}
            <button type="button" aria-label="화면 맞춤" title="Fit: 화면 맞춤" onClick={fitView} disabled={!metadata}>Fit</button>
            <button type="button" aria-label="원본 픽셀 100%" title="100%: 원본 픽셀 1:1" onClick={actualSizeView} disabled={!metadata}>100%</button>
          </div>
          <section
            ref={viewerSurfaceRef}
            className={`viewer-surface tool-${viewTool}${activePointerKind === "pan" ? " is-panning" : ""}${activePointerKind === "zoom" ? " is-zooming" : ""}${activePointerKind === "display" ? " is-display-dragging" : ""}`}
            onWheel={onWheel}
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={onPointerEnd}
            onPointerCancel={onPointerCancel}
            onLostPointerCapture={() => { if (activePointerRef.current) cancelPointerGesture(); }}
            onDoubleClick={onViewerDoubleClick}
            onContextMenu={(event) => event.preventDefault()}
            aria-label="CT cine frame"
          >
            <canvas ref={canvasRef} className={metadata ? "frame-canvas" : "frame-canvas empty"} style={canvasStyle} draggable={false} />
            {metadata && viewTransform && <AnnotationOverlay
              annotations={frameAnnotations}
              selectedId={annotationSession.selectedId}
              transform={viewTransform}
              textEditor={textEditor}
              onTextChange={(value) => setTextEditor((current) => current ? { ...current, value } : current)}
              onTextCommit={commitTextEditor}
              onTextCancel={() => setTextEditor(null)}
            />}
            {!metadata && <span className="empty-label">CT Cine Reviewer</span>}
            {status === "decoding" && <span className="loading-label">디코딩 중</span>}
            {dragging && <div className="drop-overlay">동영상 놓기</div>}
          </section>
        </section>

        <aside className="inspection-panel">
          <div className="primary-readout">
            <span>프레임</span>
            <strong>{frameDisplay}</strong>
          </div>
          <dl className="metadata-list">
            <div><dt>시간</dt><dd>{readableTime(ptsSeconds)}</dd></div>
            <div><dt>길이</dt><dd>{readableTime(metadata?.durationSeconds ?? null)}</dd></div>
            <div><dt>해상도</dt><dd>{metadata ? `${metadata.width} x ${metadata.height}` : "-"}</dd></div>
            <div><dt>FPS</dt><dd>{metadata?.fps?.toFixed(3) ?? "-"}</dd></div>
            <div><dt>코덱</dt><dd>{metadata?.codecName?.toUpperCase() ?? "-"}</dd></div>
          </dl>

          <details className="display-panel" open>
            <summary>
              <span>Video Display</span>
              <small className={displayActive ? "display-active" : ""}>{displayLabel}</small>
            </summary>
            <p className="display-help" title="MP4 화면 픽셀 보정이며 DICOM HU Window가 아닙니다.">
              MP4 화면 픽셀 보정 · HU Window 아님
            </p>
            <label>
              <span>Preset</span>
              <select
                aria-label="Display Preset"
                value={displayState.presetId}
                disabled={!metadata}
                onChange={(event) => {
                  const presetId = event.target.value as VideoDisplayPresetId;
                  if (presetId !== "custom") setDisplayState((current) => applyVideoDisplayPreset(current, presetId));
                }}
              >
                {VIDEO_DISPLAY_PRESETS.map((preset) => <option key={preset.presetId} value={preset.presetId}>{preset.label}</option>)}
                <option value="custom" disabled>Custom</option>
              </select>
            </label>
            {([
              ["level", "Level", 0, 1, 0.01],
              ["width", "Width", 0.02, 2, 0.01],
              ["gamma", "Gamma", 0.25, 4, 0.05],
              ["sharpAmount", "Sharp", 0, 1, 0.05],
            ] as const).map(([key, label, min, max, step]) => (
              <label key={key}>
                <span>{label}<output>{displayState[key].toFixed(2)}</output></span>
                <input
                  aria-label={`Video ${label}`}
                  type="range"
                  min={min}
                  max={max}
                  step={step}
                  value={displayState[key]}
                  disabled={!metadata}
                  onChange={(event) => setDisplayState((current) => updateVideoDisplay(current, { [key]: Number(event.target.value) }))}
                />
              </label>
            ))}
            <div className="display-buttons">
              <button type="button" onClick={() => setDisplayState(toggleVideoDisplayInvert)} disabled={!metadata} aria-pressed={displayState.invert}>Inverse</button>
              <button type="button" onClick={() => setDisplayState((current) => applyVideoDisplayPreset(current, "original"))} disabled={!metadata}>Original</button>
              <button
                type="button"
                className={comparingOriginal ? "is-comparing" : ""}
                disabled={!metadata}
                onPointerDown={(event) => { event.preventDefault(); setComparingOriginal(true); }}
                onPointerUp={() => setComparingOriginal(false)}
                onPointerLeave={() => setComparingOriginal(false)}
                onPointerCancel={() => setComparingOriginal(false)}
              >원본 비교 (O)</button>
            </div>
          </details>

          <details className="annotation-panel" open>
            <summary>
              <span>Annotation</span>
              <small>{frameAnnotations.length}개</small>
            </summary>
            <label>
              <span>Color</span>
              <input
                aria-label="Annotation Color"
                type="color"
                value={selectedAnnotation?.style.color ?? annotationSession.defaults.color}
                disabled={!metadata}
                onChange={(event) => changeAnnotationStyle({ color: event.target.value })}
              />
            </label>
            <label>
              <span>Line width <output>{selectedAnnotation?.style.lineWidth ?? annotationSession.defaults.lineWidth}</output></span>
              <input
                aria-label="Annotation Line Width"
                type="range"
                min="1"
                max="6"
                step="1"
                value={selectedAnnotation?.style.lineWidth ?? annotationSession.defaults.lineWidth}
                disabled={!metadata || selectedAnnotation?.kind === "text"}
                onChange={(event) => changeAnnotationStyle({ lineWidth: Number(event.target.value) })}
              />
            </label>
            <label>
              <span>Font size <output>{selectedAnnotation?.style.fontSize ?? annotationSession.defaults.fontSize}</output></span>
              <input
                aria-label="Annotation Font Size"
                type="range"
                min="12"
                max="32"
                step="2"
                value={selectedAnnotation?.style.fontSize ?? annotationSession.defaults.fontSize}
                disabled={!metadata || (selectedAnnotation !== null && selectedAnnotation.kind !== "text")}
                onChange={(event) => changeAnnotationStyle({ fontSize: Number(event.target.value) })}
              />
            </label>
            <div className="annotation-history-buttons">
              <button type="button" onClick={() => applyHistoryResult(undoAnnotation(annotationSessionRef.current))} disabled={!annotationSession.undoStack.length}>Undo</button>
              <button type="button" onClick={() => applyHistoryResult(redoAnnotation(annotationSessionRef.current))} disabled={!annotationSession.redoStack.length}>Redo</button>
            </div>
          </details>

          <details className="export-panel" open>
            <summary>
              <span>내보내기</span>
              <small>PNG</small>
            </summary>
            <fieldset disabled={!metadata || exportBusy}>
              <legend>범위</legend>
              <label><input
                type="radio"
                name="export-mode"
                value="full-frame"
                checked={exportMode === "full-frame"}
                onChange={() => { setExportMode("full-frame"); setExportMessage(null); }}
              />전체 프레임</label>
              <label><input
                type="radio"
                name="export-mode"
                value="current-view"
                checked={exportMode === "current-view"}
                onChange={() => { setExportMode("current-view"); setExportMessage(null); }}
              />현재 보기</label>
            </fieldset>
            <label className="export-annotation-option"><input
              type="checkbox"
              checked={includeExportAnnotations}
              disabled={!metadata || exportBusy}
              onChange={(event) => { setIncludeExportAnnotations(event.target.checked); setExportMessage(null); }}
            />현재 프레임 주석 포함</label>
            <p className="export-help">전체: 원본 해상도 · 현재 보기: 화면 DPR 적용</p>
            <div className="export-buttons">
              <button type="button" disabled={!exportAvailable || exportBusy} onClick={() => void exportFrame("save")}>{exportBusy ? "처리 중" : "PNG 저장"}</button>
              <button type="button" disabled={!exportAvailable || exportBusy} onClick={() => void exportFrame("copy")}>복사</button>
            </div>
            <p className="export-result" aria-live="polite">{exportMessage ?? " "}</p>
          </details>

          <details className="diagnostics" open>
            <summary>진단</summary>
            <dl>
              <div><dt>캐시</dt><dd>{cacheStatus?.startFrameIndex == null ? "-" : `${cacheStatus.startFrameIndex + 1}-${(cacheStatus.endFrameIndex ?? 0) + 1}`}</dd></div>
              <div><dt>방향</dt><dd>{cacheStatus?.direction ?? "-"}</dd></div>
              <div><dt>Hit / Miss</dt><dd>{cacheStatus ? `${cacheStatus.hits} / ${cacheStatus.misses}` : "-"}</dd></div>
              <div><dt>메모리</dt><dd>{cacheStatus ? `${formatBytes(cacheStatus.byteLength)} / ${formatBytes(cacheStatus.budgetBytes)}` : "-"}</dd></div>
              <div><dt>모드</dt><dd>{cacheStatus?.cacheMode ?? "-"}</dd></div>
              <div><dt>색 정책</dt><dd>{metadata?.colorSource ?? "-"}</dd></div>
              <div><dt>재사용 / 디코드</dt><dd>{cacheStatus ? `${cacheStatus.reusedFrames} / ${cacheStatus.decodedFrames}` : "-"}</dd></div>
              <div><dt>결과</dt><dd>{cacheResult}</dd></div>
              <div><dt>요청</dt><dd>{requestMs === null ? "-" : `${requestMs.toFixed(1)} ms`}</dd></div>
              <div><dt>Probe</dt><dd>{metadata ? `${metadata.probeMs.toFixed(1)} ms` : "-"}</dd></div>
              <div><dt>세션 / 세대</dt><dd>{diagnostics ? `${diagnostics.session} / ${diagnostics.generation}` : "-"}</dd></div>
              <div><dt>Zoom</dt><dd>{viewTransform ? `${(viewTransform.zoom * 100).toFixed(0)}%` : "-"}</dd></div>
              <div><dt>View center</dt><dd>{viewTransform ? `${viewTransform.center.x.toFixed(1)}, ${viewTransform.center.y.toFixed(1)}` : "-"}</dd></div>
              <div><dt>View revision</dt><dd>{viewTransform?.revision ?? "-"}</dd></div>
              <div><dt>Display</dt><dd>{displayState.presetId}</dd></div>
              <div><dt>L / W</dt><dd>{displayState.level.toFixed(2)} / {displayState.width.toFixed(2)}</dd></div>
              <div><dt>Gamma / Sharp</dt><dd>{displayState.gamma.toFixed(2)} / {displayState.sharpAmount.toFixed(2)}</dd></div>
              <div><dt>Display revision</dt><dd>{displayState.revision}</dd></div>
            </dl>
          </details>
          {error && <p className="error-message">{error}</p>}
        </aside>
      </section>

      <footer className="navigation-footer">
        <AnnotatedTimeline
          ref={timelineRef}
          annotations={annotationSession.annotations}
          frameIndex={frameIndex}
          frameCount={metadata?.frameCount ?? 1}
          disabled={!metadata}
          onPointerDown={onTimelinePointerDown}
          onPointerMove={onTimelinePointerMove}
          onPointerEnd={onTimelinePointerEnd}
          onPointerCancel={() => cancelPointerGesture()}
          onMarkerSelect={onTimelineMarkerSelect}
        />
        <nav className="frame-toolbar" aria-label="프레임 탐색">
        <button type="button" title="첫 프레임" onClick={() => goToFrame(0)} disabled={!metadata}>|&lt;</button>
        <button type="button" title="5프레임 이전" onClick={() => goToFrame(desiredFrameRef.current - 5)} disabled={!metadata}>-5</button>
        <button type="button" title="이전 프레임" onClick={() => goToFrame(desiredFrameRef.current - 1)} disabled={!metadata}>&lt;</button>
        <div className="frame-input-group">
          <input
            aria-label="프레임 번호"
            type="number"
            min={1}
            max={metadata?.frameCount ?? 1}
            value={frameInput}
            disabled={!metadata || (metadata.productCache === true && metadata.analysisReady === false)}
            onChange={(event) => setFrameInput(event.target.value)}
            onBlur={submitFrameInput}
            onKeyDown={onFrameInputKeyDown}
          />
          <span>/ {metadata?.frameCount.toLocaleString() ?? "-"}</span>
        </div>
        <button type="button" title="다음 프레임" onClick={() => goToFrame(desiredFrameRef.current + 1)} disabled={!metadata}>&gt;</button>
        <button type="button" title="5프레임 다음" onClick={() => goToFrame(desiredFrameRef.current + 5)} disabled={!metadata}>+5</button>
        <button type="button" title="마지막 프레임" onClick={() => metadata && goToFrame(metadata.frameCount - 1)} disabled={!metadata || (metadata.productCache === true && metadata.analysisReady === false)}>&gt;|</button>
        <button type="button" title="디코딩 취소" onClick={cancel} disabled={status !== "decoding" && status !== "probing"}>취소</button>
        </nav>
      </footer>
    </main>
  );
}
