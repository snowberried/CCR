import type { Annotation } from "./annotation.js";
import { imageToViewport, type Size, type ViewTransform } from "./viewTransform.js";

export type FrameExportMode = "full-frame" | "current-view";

export type ExportFrameIdentity = {
  frameIndex: number;
  fingerprint: string;
  width: number;
  height: number;
};

export function exportOutputSize(mode: FrameExportMode, imageSize: Size, viewportSize: Size, devicePixelRatio: number): Size {
  if (mode === "full-frame") return { ...imageSize };
  const dpr = Number.isFinite(devicePixelRatio) && devicePixelRatio > 0 ? devicePixelRatio : 1;
  return {
    width: Math.max(1, Math.round(viewportSize.width * dpr)),
    height: Math.max(1, Math.round(viewportSize.height * dpr)),
  };
}

export function isStableExportFrame(input: {
  accepted: boolean;
  hasPixels: boolean;
  identity?: ExportFrameIdentity;
  displayedFrameIndex: number;
  viewerStatus: string;
  pumping: boolean;
}): boolean {
  return input.accepted && input.hasPixels && Boolean(input.identity) &&
    input.identity!.frameIndex === input.displayedFrameIndex &&
    input.viewerStatus === "ready" && !input.pumping;
}

export function defaultPngFileName(sourceBaseName: string | undefined, frameIndex: number, frameCount: number): string {
  const safeBase = (sourceBaseName ?? "")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
    .replace(/[. ]+$/g, "")
    .trim() || "ct-cine";
  const digits = Math.max(4, String(Math.max(1, frameCount)).length);
  return `${safeBase}_f${String(frameIndex + 1).padStart(digits, "0")}.png`;
}

export function projectAnnotation(annotation: Annotation, mode: FrameExportMode, transform: ViewTransform): Annotation {
  if (mode === "full-frame") return annotation;
  if (annotation.kind === "arrow") {
    return {
      ...annotation,
      geometry: {
        start: imageToViewport(transform, annotation.geometry.start),
        end: imageToViewport(transform, annotation.geometry.end),
      },
    };
  }
  if (annotation.kind === "text") {
    return { ...annotation, geometry: { ...annotation.geometry, anchor: imageToViewport(transform, annotation.geometry.anchor) } };
  }
  const topLeft = imageToViewport(transform, { x: annotation.geometry.x, y: annotation.geometry.y });
  const bottomRight = imageToViewport(transform, {
    x: annotation.geometry.x + annotation.geometry.width,
    y: annotation.geometry.y + annotation.geometry.height,
  });
  return {
    ...annotation,
    geometry: {
      x: topLeft.x,
      y: topLeft.y,
      width: bottomRight.x - topLeft.x,
      height: bottomRight.y - topLeft.y,
    },
  };
}
