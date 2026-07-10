import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type WheelEvent,
} from "react";
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

type ViewerStatus = "idle" | "probing" | "ready" | "decoding" | "cancelled" | "error";

type SessionMetadata = NonNullable<CcrOpenVideoResponse["metadata"]>;

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
  const sessionIdRef = useRef<string | null>(null);
  const desiredFrameRef = useRef(0);
  const displayedFrameRef = useRef(-1);
  const pumpingRef = useRef(false);
  const uiGenerationRef = useRef(0);
  const wheelRef = useRef(new WheelFrameAccumulator());
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

  const clearViewer = useCallback(() => {
    sessionIdRef.current = null;
    desiredFrameRef.current = 0;
    displayedFrameRef.current = -1;
    setMetadata(null);
    setFrameIndex(0);
    setFrameInput("1");
    setPtsSeconds(null);
    setCacheStatus(null);
    setCacheResult("-");
    setRequestMs(null);
    setDiagnostics(null);
    releaseCanvas(canvasRef.current);
  }, []);

  const drawFrame = useCallback((frame: CcrFrameResponse) => {
    if (!frame.accepted || !frame.descriptor || !frame.pixels) {
      return;
    }
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context) {
      return;
    }
    canvas.width = frame.descriptor.width;
    canvas.height = frame.descriptor.height;
    context.putImageData(
      new ImageData(
        new Uint8ClampedArray(frame.pixels),
        frame.descriptor.width,
        frame.descriptor.height,
      ),
      0,
      0,
    );
    displayedFrameRef.current = frame.descriptor.frameIndex;
    setFrameIndex(frame.descriptor.frameIndex);
    setFrameInput(String(internalToDisplayFrame(frame.descriptor.frameIndex)));
    setPtsSeconds(frame.descriptor.ptsSeconds);
    setCacheResult(frame.cache ?? "-");
    setRequestMs(frame.requestMs ?? null);
    setCacheStatus(frame.cacheStatus ?? null);
    setDiagnostics(frame.diagnostics ?? null);
  }, []);

  const pump = useCallback(async () => {
    if (pumpingRef.current || !window.ccr?.getFrame || !sessionIdRef.current || !metadata) {
      return;
    }
    const uiGeneration = uiGenerationRef.current;
    const sessionId = sessionIdRef.current;
    pumpingRef.current = true;
    setStatus("decoding");
    setError(null);
    let failed = false;
    try {
      while (
        uiGeneration === uiGenerationRef.current &&
        sessionId === sessionIdRef.current &&
        desiredFrameRef.current !== displayedFrameRef.current
      ) {
        const target = desiredFrameRef.current;
        const response = await window.ccr.getFrame(sessionId, target);
        if (uiGeneration !== uiGenerationRef.current || sessionId !== sessionIdRef.current) {
          return;
        }
        if (!response.accepted) {
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
          drawFrame(response);
        }
      }
      if (uiGeneration === uiGenerationRef.current && !failed) {
        setStatus("ready");
      }
    } finally {
      pumpingRef.current = false;
    }
  }, [drawFrame, metadata]);

  const goToFrame = useCallback((nextFrameIndex: number) => {
    if (!metadata) {
      return;
    }
    desiredFrameRef.current = clampFrameIndex(nextFrameIndex, metadata.frameCount);
    void pump();
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
    desiredFrameRef.current = 0;
    displayedFrameRef.current = -1;
    wheelRef.current.reset();
    drawFrame(opened.frame);
    setStatus("ready");
  }, [clearViewer, drawFrame, metadata]);

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
    const direction = wheelRef.current.consume(event.deltaY, event.deltaMode);
    if (direction !== 0) {
      goToFrame(desiredFrameRef.current + direction);
    }
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
      if (!metadata) {
        return;
      }
      const target = navigationTargetForKey(
        event,
        desiredFrameRef.current,
        metadata.frameCount,
        isTextEntryElement(event.target),
      );
      if (target !== null) {
        event.preventDefault();
        goToFrame(target);
      } else if (event.key === "Escape" && !isTextEntryElement(event.target)) {
        cancel();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [cancel, goToFrame, metadata, openVideo]);

  useEffect(() => () => {
    uiGenerationRef.current += 1;
    void window.ccr?.closeVideo?.();
    releaseCanvas(canvasRef.current);
  }, []);

  const frameDisplay = metadata
    ? `${internalToDisplayFrame(frameIndex).toLocaleString()} / ${metadata.frameCount.toLocaleString()}`
    : "-";

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
        <button className="primary-button" type="button" onClick={openVideo}>열기</button>
      </header>

      <section className="viewer-layout">
        <section className="viewer-surface" onWheel={onWheel} aria-label="CT cine frame">
          <canvas ref={canvasRef} className={metadata ? "frame-canvas" : "frame-canvas empty"} />
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
              <div><dt>재사용 / 디코드</dt><dd>{cacheStatus ? `${cacheStatus.reusedFrames} / ${cacheStatus.decodedFrames}` : "-"}</dd></div>
              <div><dt>결과</dt><dd>{cacheResult}</dd></div>
              <div><dt>요청</dt><dd>{requestMs === null ? "-" : `${requestMs.toFixed(1)} ms`}</dd></div>
              <div><dt>Probe</dt><dd>{metadata ? `${metadata.probeMs.toFixed(1)} ms` : "-"}</dd></div>
              <div><dt>세션 / 세대</dt><dd>{diagnostics ? `${diagnostics.session} / ${diagnostics.generation}` : "-"}</dd></div>
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
            disabled={!metadata}
            onChange={(event) => setFrameInput(event.target.value)}
            onBlur={submitFrameInput}
            onKeyDown={onFrameInputKeyDown}
          />
          <span>/ {metadata?.frameCount.toLocaleString() ?? "-"}</span>
        </div>
        <button type="button" title="다음 프레임" onClick={() => goToFrame(desiredFrameRef.current + 1)} disabled={!metadata}>&gt;</button>
        <button type="button" title="5프레임 다음" onClick={() => goToFrame(desiredFrameRef.current + 5)} disabled={!metadata}>+5</button>
        <button type="button" title="마지막 프레임" onClick={() => metadata && goToFrame(metadata.frameCount - 1)} disabled={!metadata}>&gt;|</button>
        <button type="button" title="디코딩 취소" onClick={cancel} disabled={status !== "decoding" && status !== "probing"}>취소</button>
      </nav>
    </main>
  );
}
