import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent,
} from "react";
import {
  createViewTransform,
  fitViewTransform,
  panByViewportDelta,
  resizeViewTransform,
  viewPlacement,
  zoomAtViewportPoint,
  type ViewTransform,
} from "./domain/viewTransform";
import {
  beginPan,
  endsPan,
  fullscreenShortcut,
  movePan,
  viewWheelIntent,
  zoomShortcut,
  type PanGesture,
} from "./domain/viewInteraction";
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

type ViewerStatus = "idle" | "probing" | "ready" | "decoding" | "cancelled" | "error";

type SessionMetadata = NonNullable<CcrOpenVideoResponse["metadata"]>;

type KeyboardHoldIntent = {
  direction: -1 | 1;
  targetFrame: number;
  startedAt: number;
  holdDurationMs: number;
};

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

export function App() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const viewerSurfaceRef = useRef<HTMLElement>(null);
  const sessionIdRef = useRef<string | null>(null);
  const desiredFrameRef = useRef(0);
  const displayedFrameRef = useRef(-1);
  const pumpingRef = useRef(false);
  const uiGenerationRef = useRef(0);
  const wheelRef = useRef(new WheelFrameAccumulator());
  const navigationFrameRef = useRef<number | null>(null);
  const keyboardHoldRef = useRef<KeyboardHoldIntent | null>(null);
  const forceRgbaRef = useRef(false);
  const i420RendererRef = useRef<I420WebglRenderer | null>(null);
  const panGestureRef = useRef<PanGesture | null>(null);
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
  const [isPanning, setIsPanning] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);

  const clearViewer = useCallback(() => {
    sessionIdRef.current = null;
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
    panGestureRef.current = null;
    setIsPanning(false);
    setViewTransform(null);
    i420RendererRef.current?.dispose();
    i420RendererRef.current = null;
    releaseCanvas(canvasRef.current);
    if (window.ccr?.openQaVideo) {
      delete document.documentElement.dataset.qaSampleIndex;
      delete document.documentElement.dataset.qaPixelFormat;
      delete document.documentElement.dataset.qaViewZoom;
      delete document.documentElement.dataset.qaViewCenter;
      delete document.documentElement.dataset.qaViewRevision;
      document.documentElement.dataset.qaBackgroundComplete = "false";
      document.documentElement.dataset.qaSeekDecodeCount = "0";
    }
  }, []);

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
    if (frame.descriptor.pixelFormat === "i420" && frame.layout && frame.colorSpace) {
      try {
        i420RendererRef.current ??= new I420WebglRenderer();
        const renderedCanvas = i420RendererRef.current.render({
          pixels: frame.pixels,
          width: frame.descriptor.width,
          height: frame.descriptor.height,
          layout: frame.layout,
          colorSpace: frame.colorSpace,
        });
        context.drawImage(renderedCanvas, 0, 0);
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
        context.putImageData(new ImageData(
          new Uint8ClampedArray(fallback.pixels),
          fallback.descriptor.width,
          fallback.descriptor.height,
        ), 0, 0);
      }
    } else {
      context.putImageData(new ImageData(
        new Uint8ClampedArray(frame.pixels),
        frame.descriptor.width,
        frame.descriptor.height,
      ), 0, 0);
    }
    if (!rendered.descriptor) return;
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
  }, []);

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
    desiredFrameRef.current = clampFrameIndex(nextFrameIndex, metadata.frameCount);
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
  }, [metadata, pump]);

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
    setMetadata(opened.metadata);
    const viewport = viewerSurfaceRef.current?.getBoundingClientRect();
    setViewTransform(createViewTransform(
      { width: opened.metadata.width, height: opened.metadata.height },
      { width: viewport?.width ?? 1, height: viewport?.height ?? 1 },
    ));
    desiredFrameRef.current = 0;
    displayedFrameRef.current = -1;
    wheelRef.current.reset();
    forceRgbaRef.current = false;
    await renderFrame(opened.frame);
    if (opened.qaSampleIndex !== undefined && window.ccr?.openQaVideo) {
      document.documentElement.dataset.qaSampleIndex = String(opened.qaSampleIndex);
    }
    if (opened.metadata.productCache) {
      await window.ccr?.ackFirstFrame?.(opened.sessionId);
    }
    setStatus("ready");
  }, [clearViewer, metadata, renderFrame]);

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
      const bounds = event.currentTarget.getBoundingClientRect();
      const anchor = { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
      setViewTransform((current) => current
        ? zoomAtViewportPoint(current, current.zoom * intent.factor, anchor)
        : current);
      return;
    }
    if (panGestureRef.current) return;
    const direction = wheelRef.current.consume(event.deltaY, event.deltaMode);
    if (direction !== 0) {
      goToFrame(desiredFrameRef.current + direction);
    }
  };

  const zoomBy = useCallback((factor: number) => {
    setViewTransform((current) => current
      ? zoomAtViewportPoint(current, current.zoom * factor, {
        x: current.viewportSize.width / 2,
        y: current.viewportSize.height / 2,
      })
      : current);
  }, []);

  const fitView = useCallback(() => {
    setViewTransform((current) => current ? fitViewTransform(current) : current);
  }, []);

  const toggleFullscreen = useCallback(() => {
    void window.ccr?.toggleFullscreen?.().then(setIsFullscreen);
  }, []);

  const exitFullscreen = useCallback(() => {
    void window.ccr?.setFullscreen?.(false).then(setIsFullscreen);
  }, []);

  const endPan = useCallback((element?: HTMLElement, pointerId?: number) => {
    if (element && pointerId !== undefined && element.hasPointerCapture(pointerId)) {
      element.releasePointerCapture(pointerId);
    }
    panGestureRef.current = null;
    setIsPanning(false);
  }, []);

  const onPointerDown = (event: ReactPointerEvent<HTMLElement>) => {
    if (!metadata || event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    panGestureRef.current = beginPan(event.pointerId, event.clientX, event.clientY);
    setIsPanning(true);
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLElement>) => {
    const gesture = panGestureRef.current;
    if (!gesture) return;
    const moved = movePan(gesture, event.pointerId, event.clientX, event.clientY);
    if (!moved.delta) return;
    panGestureRef.current = moved.gesture;
    setViewTransform((current) => current ? panByViewportDelta(current, moved.delta!) : current);
  };

  const onPointerEnd = (event: ReactPointerEvent<HTMLElement>) => {
    if (endsPan(panGestureRef.current, event.pointerId)) endPan(event.currentTarget, event.pointerId);
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
        if (panGestureRef.current) {
          event.preventDefault();
          endPan(viewerSurfaceRef.current ?? undefined, panGestureRef.current.pointerId);
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
      const viewShortcut = zoomShortcut({ key: event.key, editing });
      if (viewShortcut !== 0) {
        event.preventDefault();
        if (viewShortcut === "fit") fitView();
        else zoomBy(viewShortcut > 0 ? 1.25 : 0.8);
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
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
    };
  }, [cancel, endPan, exitFullscreen, fitView, goToFrame, isFullscreen, metadata, openVideo, pump, toggleFullscreen, zoomBy]);

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

  useEffect(() => () => {
    uiGenerationRef.current += 1;
    void window.ccr?.closeVideo?.();
    i420RendererRef.current?.dispose();
    i420RendererRef.current = null;
    releaseCanvas(canvasRef.current);
  }, []);

  const frameDisplay = metadata
    ? `${internalToDisplayFrame(frameIndex).toLocaleString()} / ${metadata.frameCount.toLocaleString()}`
    : "-";
  const placement = viewTransform ? viewPlacement(viewTransform) : null;
  const canvasStyle = placement ? {
    width: `${placement.width}px`,
    height: `${placement.height}px`,
    transform: `translate3d(${placement.left}px, ${placement.top}px, 0)`,
  } : undefined;

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
            <button type="button" title="축소 (-)" onClick={() => zoomBy(0.8)} disabled={!metadata}>−</button>
            <output aria-label="현재 확대율">{Math.round((viewTransform?.zoom ?? 1) * 100)}%</output>
            <button type="button" title="확대 (+)" onClick={() => zoomBy(1.25)} disabled={!metadata}>+</button>
            <button type="button" title="화면 맞춤 (0)" onClick={fitView} disabled={!metadata}>Fit</button>
            <button type="button" title="전체화면 (F)" onClick={toggleFullscreen}>{isFullscreen ? "창" : "전체"}</button>
          </div>
          <button className="primary-button" type="button" onClick={openVideo}>열기</button>
        </div>
      </header>

      <section className="viewer-layout">
        <section
          ref={viewerSurfaceRef}
          className={`viewer-surface${isPanning ? " is-panning" : ""}`}
          onWheel={onWheel}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerEnd}
          onPointerCancel={onPointerEnd}
          onLostPointerCapture={() => endPan()}
          onDoubleClick={fitView}
          aria-label="CT cine frame"
        >
          <canvas ref={canvasRef} className={metadata ? "frame-canvas" : "frame-canvas empty"} style={canvasStyle} draggable={false} />
          {!metadata && <span className="empty-label">CT Cine Reviewer</span>}
          {status === "decoding" && <span className="loading-label">디코딩 중</span>}
          {dragging && <div className="drop-overlay">동영상 놓기</div>}
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
            </dl>
          </details>
          {error && <p className="error-message">{error}</p>}
        </aside>
      </section>

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
    </main>
  );
}
