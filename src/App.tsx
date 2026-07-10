import { useCallback, useEffect, useRef, useState, type WheelEvent } from "react";

type SessionMetadata = {
  frameCount: number;
  width: number;
  height: number;
  codecName: string | null;
};

export function App() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sessionIdRef = useRef<string | null>(null);
  const desiredFrameRef = useRef(0);
  const displayedFrameRef = useRef(-1);
  const pumpingRef = useRef(false);
  const wheelAccumulatorRef = useRef(0);
  const [metadata, setMetadata] = useState<SessionMetadata | null>(null);
  const [frameIndex, setFrameIndex] = useState(0);
  const [ptsSeconds, setPtsSeconds] = useState<number | null>(null);
  const [cacheLabel, setCacheLabel] = useState("-");
  const [cacheResult, setCacheResult] = useState("-");
  const [requestMs, setRequestMs] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
    const pixels = new Uint8ClampedArray(frame.pixels);
    context.putImageData(
      new ImageData(pixels, frame.descriptor.width, frame.descriptor.height),
      0,
      0,
    );
    displayedFrameRef.current = frame.descriptor.frameIndex;
    setFrameIndex(frame.descriptor.frameIndex);
    setPtsSeconds(frame.descriptor.ptsSeconds);
    setCacheResult(frame.cache ?? "-");
    setRequestMs(frame.requestMs ?? null);
    const status = frame.cacheStatus;
    setCacheLabel(
      !status || status.startFrameIndex === null || status.endFrameIndex === null
        ? "-"
        : `${status.startFrameIndex}-${status.endFrameIndex} (${status.frameCount})`,
    );
  }, []);

  const pump = useCallback(async () => {
    if (pumpingRef.current || !window.ccr?.getFrame || !sessionIdRef.current || !metadata) {
      return;
    }
    pumpingRef.current = true;
    setLoading(true);
    setError(null);
    try {
      while (desiredFrameRef.current !== displayedFrameRef.current) {
        const target = desiredFrameRef.current;
        const response = await window.ccr.getFrame(sessionIdRef.current, target);
        if (!response.accepted) {
          if (response.error && response.error !== "DECODE_CANCELLED") {
            setError(response.error);
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
    } finally {
      pumpingRef.current = false;
      setLoading(false);
    }
  }, [drawFrame, metadata]);

  const goToFrame = useCallback(
    (nextFrameIndex: number) => {
      if (!metadata) {
        return;
      }
      desiredFrameRef.current = Math.max(0, Math.min(metadata.frameCount - 1, nextFrameIndex));
      void pump();
    },
    [metadata, pump],
  );

  const openVideo = async () => {
    if (!window.ccr?.openVideo) {
      setError("Electron runtime required");
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const opened = await window.ccr.openVideo();
      if (opened.canceled) {
        return;
      }
      if (opened.error || !opened.sessionId || !opened.metadata || !opened.frame?.accepted) {
        setError(opened.error ?? "OPEN_FAILED");
        return;
      }
      sessionIdRef.current = opened.sessionId;
      setMetadata(opened.metadata);
      desiredFrameRef.current = 0;
      drawFrame(opened.frame);
    } finally {
      setLoading(false);
    }
  };

  const cancel = () => {
    desiredFrameRef.current = displayedFrameRef.current;
    void window.ccr?.cancelFrame?.();
  };

  const onWheel = (event: WheelEvent<HTMLElement>) => {
    event.preventDefault();
    const delta = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY;
    if (Math.abs(delta) >= 50) {
      wheelAccumulatorRef.current = 0;
      goToFrame(desiredFrameRef.current + Math.sign(delta));
      return;
    }
    wheelAccumulatorRef.current += delta;
    if (Math.abs(wheelAccumulatorRef.current) >= 50) {
      const direction = Math.sign(wheelAccumulatorRef.current);
      wheelAccumulatorRef.current -= direction * 50;
      goToFrame(desiredFrameRef.current + direction);
    }
  };

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!metadata || event.target instanceof HTMLInputElement) {
        return;
      }
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        const direction = event.key === "ArrowLeft" ? -1 : 1;
        goToFrame(desiredFrameRef.current + direction * (event.shiftKey ? 5 : 1));
      } else if (event.key === "Home") {
        event.preventDefault();
        goToFrame(0);
      } else if (event.key === "End") {
        event.preventDefault();
        goToFrame(metadata.frameCount - 1);
      } else if (event.key === "Escape") {
        cancel();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [goToFrame, metadata]);

  useEffect(
    () => () => {
      void window.ccr?.closeVideo?.();
    },
    [],
  );

  return (
    <main className="app-shell">
      <header className="topbar">
        <div>
          <p className="eyebrow">CT Cine Reviewer</p>
          <h1>Phase 1C Frame Spike</h1>
        </div>
        <button className="primary-button" type="button" onClick={() => void openVideo()}>
          Open video
        </button>
      </header>

      <section className="viewer-layout">
        <section className="viewer-surface" onWheel={onWheel} aria-label="Decoded video frame">
          <canvas ref={canvasRef} className={metadata ? "frame-canvas" : "frame-canvas empty"} />
          {!metadata && <span className="empty-label">No video</span>}
          {loading && <span className="loading-label">Decoding</span>}
        </section>

        <aside className="inspection-panel">
          <h2>Frame</h2>
          <dl>
            <div><dt>Index</dt><dd>{metadata ? `${frameIndex} / ${metadata.frameCount - 1}` : "-"}</dd></div>
            <div><dt>PTS</dt><dd>{ptsSeconds === null ? "-" : `${ptsSeconds.toFixed(6)}s`}</dd></div>
            <div><dt>Cache</dt><dd>{cacheLabel}</dd></div>
            <div><dt>Result</dt><dd>{cacheResult}</dd></div>
            <div><dt>Request</dt><dd>{requestMs === null ? "-" : `${requestMs.toFixed(1)}ms`}</dd></div>
            <div><dt>Format</dt><dd>{metadata ? `${metadata.width}x${metadata.height} RGBA` : "-"}</dd></div>
          </dl>
          {error && <p className="error-message">{error}</p>}
        </aside>
      </section>

      <nav className="frame-toolbar" aria-label="Frame navigation">
        <button type="button" title="First frame" onClick={() => goToFrame(0)}>|&lt;</button>
        <button type="button" title="Previous 5 frames" onClick={() => goToFrame(desiredFrameRef.current - 5)}>-5</button>
        <button type="button" title="Previous frame" onClick={() => goToFrame(desiredFrameRef.current - 1)}>&lt;</button>
        <input
          aria-label="Frame index"
          type="number"
          min={0}
          max={metadata ? metadata.frameCount - 1 : 0}
          value={frameIndex}
          disabled={!metadata}
          onChange={(event) => goToFrame(Number(event.target.value))}
        />
        <button type="button" title="Next frame" onClick={() => goToFrame(desiredFrameRef.current + 1)}>&gt;</button>
        <button type="button" title="Next 5 frames" onClick={() => goToFrame(desiredFrameRef.current + 5)}>+5</button>
        <button type="button" title="Last frame" onClick={() => metadata && goToFrame(metadata.frameCount - 1)}>&gt;|</button>
        <button type="button" title="Cancel decoding" onClick={cancel} disabled={!loading}>Cancel</button>
      </nav>
    </main>
  );
}
