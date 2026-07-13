import type { Annotation } from "../domain/annotation.js";
import { exportOutputSize, projectAnnotation, type ExportFrameIdentity, type FrameExportMode } from "../domain/frameExport.js";
import type { VideoDisplayState } from "../domain/videoDisplay.js";
import { applyVideoDisplayToRgba } from "../domain/videoDisplayReference.js";
import { viewPlacement, type ViewTransform } from "../domain/viewTransform.js";
import type { I420WebglRenderer } from "./I420WebglRenderer.js";

export type FrameExportSnapshot = {
  mode: FrameExportMode;
  identity: ExportFrameIdentity;
  source: HTMLCanvasElement;
  transform: ViewTransform;
  annotations: Annotation[];
  devicePixelRatio: number;
};

export function captureDisplayedFrameCanvas(
  frame: CcrFrameResponse,
  display: VideoDisplayState,
  i420Renderer: I420WebglRenderer | null,
): HTMLCanvasElement {
  const descriptor = frame.descriptor;
  if (!frame.accepted || !descriptor || !frame.pixels) throw new Error("EXPORT_FRAME_UNAVAILABLE");
  const canvas = document.createElement("canvas");
  canvas.width = descriptor.width;
  canvas.height = descriptor.height;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("EXPORT_CANVAS_UNAVAILABLE");
  if (descriptor.pixelFormat === "i420") {
    if (!i420Renderer) throw new Error("EXPORT_RENDERER_UNAVAILABLE");
    context.drawImage(i420Renderer.redraw(display), 0, 0);
  } else {
    const adjusted = applyVideoDisplayToRgba(frame.pixels, descriptor.width, descriptor.height, display, false);
    context.putImageData(new ImageData(adjusted, descriptor.width, descriptor.height), 0, 0);
  }
  return canvas;
}

function drawArrow(context: CanvasRenderingContext2D, annotation: Extract<Annotation, { kind: "arrow" }>) {
  const { start, end } = annotation.geometry;
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const length = Math.hypot(dx, dy) || 1;
  const ux = dx / length;
  const uy = dy / length;
  const head = Math.max(10, annotation.style.lineWidth * 4);
  const wing = head * 0.45;
  context.strokeStyle = annotation.style.color;
  context.fillStyle = annotation.style.color;
  context.lineWidth = annotation.style.lineWidth;
  context.beginPath();
  context.moveTo(start.x, start.y);
  context.lineTo(end.x, end.y);
  context.stroke();
  context.beginPath();
  context.moveTo(end.x, end.y);
  context.lineTo(end.x - ux * head - uy * wing, end.y - uy * head + ux * wing);
  context.lineTo(end.x - ux * head + uy * wing, end.y - uy * head - ux * wing);
  context.closePath();
  context.fill();
}

function drawAnnotation(context: CanvasRenderingContext2D, annotation: Annotation) {
  context.save();
  context.lineJoin = "round";
  context.lineCap = "round";
  if (annotation.kind === "arrow") {
    drawArrow(context, annotation);
  } else if (annotation.kind === "text") {
    context.font = `${annotation.style.fontSize}px "Segoe UI", sans-serif`;
    context.textBaseline = "top";
    context.lineWidth = 2;
    context.strokeStyle = "rgba(0, 0, 0, 0.75)";
    context.fillStyle = annotation.style.color;
    context.strokeText(annotation.geometry.text, annotation.geometry.anchor.x, annotation.geometry.anchor.y);
    context.fillText(annotation.geometry.text, annotation.geometry.anchor.x, annotation.geometry.anchor.y);
  } else {
    const { x, y, width, height } = annotation.geometry;
    context.strokeStyle = annotation.style.color;
    context.lineWidth = annotation.style.lineWidth;
    context.beginPath();
    if (annotation.kind === "ellipse") {
      context.ellipse(x + width / 2, y + height / 2, width / 2, height / 2, 0, 0, Math.PI * 2);
    } else {
      context.rect(x, y, width, height);
    }
    context.stroke();
  }
  context.restore();
}

export function renderFrameExport(snapshot: FrameExportSnapshot): HTMLCanvasElement {
  const { mode, source, transform, devicePixelRatio } = snapshot;
  const outputSize = exportOutputSize(mode, transform.imageSize, transform.viewportSize, devicePixelRatio);
  const canvas = document.createElement("canvas");
  canvas.width = outputSize.width;
  canvas.height = outputSize.height;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("EXPORT_CANVAS_UNAVAILABLE");
  context.imageSmoothingEnabled = true;

  if (mode === "full-frame") {
    context.drawImage(source, 0, 0, transform.imageSize.width, transform.imageSize.height);
  } else {
    const scaleX = outputSize.width / transform.viewportSize.width;
    const scaleY = outputSize.height / transform.viewportSize.height;
    context.fillStyle = "#000";
    context.fillRect(0, 0, outputSize.width, outputSize.height);
    context.scale(scaleX, scaleY);
    const placement = viewPlacement(transform);
    context.drawImage(source, placement.left, placement.top, placement.width, placement.height);
  }

  for (const annotation of snapshot.annotations) {
    drawAnnotation(context, projectAnnotation(annotation, mode, transform));
  }
  return canvas;
}

export function canvasToPngBytes(canvas: HTMLCanvasElement): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("EXPORT_PNG_ENCODE_FAILED"));
        return;
      }
      void blob.arrayBuffer().then((buffer) => resolve(new Uint8Array(buffer)), () => reject(new Error("EXPORT_PNG_ENCODE_FAILED")));
    }, "image/png");
  });
}
