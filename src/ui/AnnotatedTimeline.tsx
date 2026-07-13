import { forwardRef, useEffect, useMemo, useRef, useState, type PointerEvent } from "react";
import type { Annotation } from "../domain/annotation";
import { aggregateTimelineMarkers, type TimelineMarkerBucket } from "../domain/annotatedTimeline";

type AnnotatedTimelineProps = {
  annotations: readonly Annotation[];
  frameIndex: number;
  frameCount: number;
  disabled: boolean;
  onPointerDown: (event: PointerEvent<HTMLDivElement>) => void;
  onPointerMove: (event: PointerEvent<HTMLDivElement>) => void;
  onPointerEnd: (event: PointerEvent<HTMLDivElement>) => void;
  onPointerCancel: (event: PointerEvent<HTMLDivElement>) => void;
  onMarkerSelect: (event: PointerEvent<HTMLButtonElement>, bucket: TimelineMarkerBucket) => void;
};

export const AnnotatedTimeline = forwardRef<HTMLDivElement, AnnotatedTimelineProps>(function AnnotatedTimeline({
  annotations,
  frameIndex,
  frameCount,
  disabled,
  onPointerDown,
  onPointerMove,
  onPointerEnd,
  onPointerCancel,
  onMarkerSelect,
}, forwardedRef) {
  const measureRef = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(1);
  useEffect(() => {
    const element = measureRef.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(1, Math.round(entry.contentRect.width))));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const markers = useMemo(() => aggregateTimelineMarkers(annotations, width, frameCount), [annotations, frameCount, width]);
  const progress = frameCount > 1 ? frameIndex / (frameCount - 1) : 0;
  const setRefs = (element: HTMLDivElement | null) => {
    measureRef.current = element;
    if (typeof forwardedRef === "function") forwardedRef(element);
    else if (forwardedRef) forwardedRef.current = element;
  };
  return <div className="annotated-timeline" aria-label="주석 타임라인">
    <div
      ref={setRefs}
      className="timeline-track"
      aria-disabled={disabled}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerEnd}
      onPointerCancel={onPointerCancel}
    >
      <span className="timeline-progress" style={{ width: `${progress * 100}%` }} />
      {markers.map((bucket) => {
        const current = bucket.frames.some((frame) => frame.frameIndex === frameIndex);
        const first = bucket.frames[0].frameIndex + 1;
        const last = bucket.frames.at(-1)!.frameIndex + 1;
        const title = bucket.frames.length === 1
          ? `프레임 ${first.toLocaleString()} · 주석 ${bucket.annotationCount}개`
          : `프레임 ${first.toLocaleString()}–${last.toLocaleString()} · 주석 ${bucket.annotationCount}개`;
        return <button
          key={bucket.column}
          type="button"
          className={`timeline-marker${current ? " is-current" : ""}`}
          style={{ left: bucket.column }}
          title={title}
          aria-label={title}
          onPointerDown={(event) => onMarkerSelect(event, bucket)}
          disabled={disabled}
        />;
      })}
      <span className="timeline-playhead" style={{ left: `${progress * 100}%` }} />
    </div>
  </div>;
});
