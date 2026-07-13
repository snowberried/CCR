import { useEffect, useRef, type KeyboardEvent } from "react";
import type { Annotation, AnnotationHandle, BoxAnnotation } from "../domain/annotation";
import { imageToViewport, type Point, type ViewTransform } from "../domain/viewTransform";

export type TextEditorState = {
  annotationId: string | null;
  frameIndex: number;
  anchor: Point;
  value: string;
};

type AnnotationOverlayProps = {
  annotations: readonly Annotation[];
  selectedId: string | null;
  transform: ViewTransform;
  textEditor: TextEditorState | null;
  onTextChange: (value: string) => void;
  onTextCommit: () => void;
  onTextCancel: () => void;
};

const boxHandles: AnnotationHandle[] = ["nw", "n", "ne", "e", "se", "s", "sw", "w"];

function boxHandlePoint(annotation: BoxAnnotation, handle: AnnotationHandle): Point {
  const { x, y, width, height } = annotation.geometry;
  const xByHandle = handle.includes("w") ? x : handle.includes("e") ? x + width : x + width / 2;
  const yByHandle = handle.includes("n") ? y : handle.includes("s") ? y + height : y + height / 2;
  return { x: xByHandle, y: yByHandle };
}

function ArrowShape({ annotation, selected }: { annotation: Extract<Annotation, { kind: "arrow" }>; selected: boolean }) {
  const start = annotation.geometry.start;
  const end = annotation.geometry.end;
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const length = Math.hypot(dx, dy) || 1;
  const ux = dx / length;
  const uy = dy / length;
  const head = Math.max(10, annotation.style.lineWidth * 4);
  const wing = head * 0.45;
  const points = `${end.x},${end.y} ${end.x - ux * head - uy * wing},${end.y - uy * head + ux * wing} ${end.x - ux * head + uy * wing},${end.y - uy * head - ux * wing}`;
  return <>
    <line className="annotation-hit" data-annotation-id={annotation.id} x1={start.x} y1={start.y} x2={end.x} y2={end.y} />
    <line className="annotation-visible" data-annotation-id={annotation.id} x1={start.x} y1={start.y} x2={end.x} y2={end.y} stroke={annotation.style.color} strokeWidth={annotation.style.lineWidth} />
    <polygon className="annotation-visible" data-annotation-id={annotation.id} points={points} fill={annotation.style.color} />
    {selected && <>
      <line className="annotation-selection" x1={start.x} y1={start.y} x2={end.x} y2={end.y} />
      {(["start", "end"] as const).map((handle) => {
        const point = annotation.geometry[handle];
        return <circle key={handle} className="annotation-handle" data-annotation-id={annotation.id} data-annotation-handle={handle} cx={point.x} cy={point.y} r="4" />;
      })}
    </>}
  </>;
}

function BoxShape({ annotation, selected }: { annotation: BoxAnnotation; selected: boolean }) {
  const { x, y, width, height } = annotation.geometry;
  const common = {
    className: "annotation-visible",
    "data-annotation-id": annotation.id,
    stroke: annotation.style.color,
    strokeWidth: annotation.style.lineWidth,
    fill: "none",
  };
  const hitCommon = { className: "annotation-hit", "data-annotation-id": annotation.id, fill: "transparent" };
  const shape = annotation.kind === "ellipse"
    ? <><ellipse {...hitCommon} cx={x + width / 2} cy={y + height / 2} rx={width / 2} ry={height / 2} /><ellipse {...common} cx={x + width / 2} cy={y + height / 2} rx={width / 2} ry={height / 2} /></>
    : <><rect {...hitCommon} x={x} y={y} width={width} height={height} /><rect {...common} x={x} y={y} width={width} height={height} /></>;
  return <>
    {shape}
    {selected && <>
      <rect className="annotation-selection" x={x} y={y} width={width} height={height} />
      {boxHandles.map((handle) => {
        const point = boxHandlePoint(annotation, handle);
        return <circle key={handle} className="annotation-handle" data-annotation-id={annotation.id} data-annotation-handle={handle} cx={point.x} cy={point.y} r="4" />;
      })}
    </>}
  </>;
}

function TextShape({ annotation, selected }: { annotation: Extract<Annotation, { kind: "text" }>; selected: boolean }) {
  const { anchor, text } = annotation.geometry;
  const estimatedWidth = Math.max(annotation.style.fontSize * 0.6, text.length * annotation.style.fontSize * 0.62);
  const height = annotation.style.fontSize * 1.25;
  return <>
    <rect className="annotation-hit" data-annotation-id={annotation.id} x={anchor.x} y={anchor.y} width={estimatedWidth} height={height} fill="transparent" />
    <text
      className="annotation-text"
      data-annotation-id={annotation.id}
      x={anchor.x}
      y={anchor.y}
      fill={annotation.style.color}
      fontSize={annotation.style.fontSize}
      dominantBaseline="hanging"
    >{text}</text>
    {selected && <rect className="annotation-selection" x={anchor.x - 2} y={anchor.y - 2} width={estimatedWidth + 4} height={height + 4} />}
  </>;
}

function TextEditor({ editor, transform, onChange, onCommit, onCancel }: {
  editor: TextEditorState;
  transform: ViewTransform;
  onChange: (value: string) => void;
  onCommit: () => void;
  onCancel: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const composingRef = useRef(false);
  const anchor = imageToViewport(transform, editor.anchor);
  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.select();
  }, [editor.annotationId, editor.anchor.x, editor.anchor.y]);
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" && !composingRef.current && !event.nativeEvent.isComposing) {
      event.preventDefault();
      onCommit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      onCancel();
    }
  };
  return <input
    ref={inputRef}
    className="annotation-text-editor"
    aria-label="텍스트 주석 입력"
    value={editor.value}
    style={{ left: anchor.x, top: anchor.y, width: Math.max(120, editor.value.length * 12 + 28) }}
    onChange={(event) => onChange(event.target.value)}
    onKeyDown={onKeyDown}
    onCompositionStart={() => { composingRef.current = true; }}
    onCompositionEnd={() => { composingRef.current = false; }}
    onBlur={onCommit}
    onPointerDown={(event) => event.stopPropagation()}
  />;
}

export function AnnotationOverlay({
  annotations,
  selectedId,
  transform,
  textEditor,
  onTextChange,
  onTextCommit,
  onTextCancel,
}: AnnotationOverlayProps) {
  const viewportAnnotations = annotations.map((annotation) => {
    if (annotation.kind === "arrow") {
      return { ...annotation, geometry: { start: imageToViewport(transform, annotation.geometry.start), end: imageToViewport(transform, annotation.geometry.end) } };
    }
    if (annotation.kind === "text") {
      return { ...annotation, geometry: { ...annotation.geometry, anchor: imageToViewport(transform, annotation.geometry.anchor) } };
    }
    const topLeft = imageToViewport(transform, { x: annotation.geometry.x, y: annotation.geometry.y });
    const bottomRight = imageToViewport(transform, { x: annotation.geometry.x + annotation.geometry.width, y: annotation.geometry.y + annotation.geometry.height });
    return { ...annotation, geometry: { x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y } };
  });
  return <>
    <svg className="annotation-overlay" width={transform.viewportSize.width} height={transform.viewportSize.height} aria-hidden="true">
      {viewportAnnotations.map((annotation) => {
        const selected = annotation.id === selectedId;
        if (annotation.kind === "arrow") return <ArrowShape key={annotation.id} annotation={annotation} selected={selected} />;
        if (annotation.kind === "text") return <TextShape key={annotation.id} annotation={annotation} selected={selected} />;
        return <BoxShape key={annotation.id} annotation={annotation} selected={selected} />;
      })}
    </svg>
    {textEditor && <TextEditor editor={textEditor} transform={transform} onChange={onTextChange} onCommit={onTextCommit} onCancel={onTextCancel} />}
  </>;
}
