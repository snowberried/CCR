export type Point = { x: number; y: number };
export type Size = { width: number; height: number };

export type ViewTransform = {
  imageSize: Size;
  viewportSize: Size;
  center: Point;
  zoom: number;
  minZoom: number;
  maxZoom: number;
  fitMode: "contain";
  revision: number;
};

export const VIEW_ZOOM_MIN = 1;
export const VIEW_ZOOM_MAX = 10;
export const VIEW_ZOOM_STEP = 0.1;

function validSize(size: Size): boolean {
  return Number.isFinite(size.width) && Number.isFinite(size.height) && size.width > 0 && size.height > 0;
}

export function fitScale(imageSize: Size, viewportSize: Size): number {
  if (!validSize(imageSize) || !validSize(viewportSize)) return 0;
  return Math.min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height);
}

export function effectiveScale(transform: ViewTransform): number {
  return fitScale(transform.imageSize, transform.viewportSize) * transform.zoom;
}

function clampCenter(transform: ViewTransform, center: Point): Point {
  const scale = effectiveScale(transform);
  if (scale <= 0) return { x: transform.imageSize.width / 2, y: transform.imageSize.height / 2 };
  const halfVisibleWidth = transform.viewportSize.width / (2 * scale);
  const halfVisibleHeight = transform.viewportSize.height / (2 * scale);
  const centerAxis = (value: number, imageLength: number, halfVisible: number) =>
    halfVisible * 2 >= imageLength
      ? imageLength / 2
      : Math.max(halfVisible, Math.min(imageLength - halfVisible, value));
  return {
    x: centerAxis(center.x, transform.imageSize.width, halfVisibleWidth),
    y: centerAxis(center.y, transform.imageSize.height, halfVisibleHeight),
  };
}

export function createViewTransform(
  imageSize: Size,
  viewportSize: Size,
  minZoom = VIEW_ZOOM_MIN,
  maxZoom = VIEW_ZOOM_MAX,
): ViewTransform {
  if (!validSize(imageSize) || minZoom <= 0 || maxZoom < minZoom) throw new RangeError("INVALID_VIEW_TRANSFORM");
  const transform: ViewTransform = {
    imageSize,
    viewportSize,
    center: { x: imageSize.width / 2, y: imageSize.height / 2 },
    zoom: minZoom,
    minZoom,
    maxZoom,
    fitMode: "contain",
    revision: 0,
  };
  return { ...transform, center: clampCenter(transform, transform.center) };
}

export function imageToViewport(transform: ViewTransform, point: Point): Point {
  const scale = effectiveScale(transform);
  return {
    x: (point.x - transform.center.x) * scale + transform.viewportSize.width / 2,
    y: (point.y - transform.center.y) * scale + transform.viewportSize.height / 2,
  };
}

export function viewportToImage(transform: ViewTransform, point: Point): Point {
  const scale = effectiveScale(transform);
  if (scale <= 0) return transform.center;
  return {
    x: transform.center.x + (point.x - transform.viewportSize.width / 2) / scale,
    y: transform.center.y + (point.y - transform.viewportSize.height / 2) / scale,
  };
}

export function zoomAtViewportPoint(transform: ViewTransform, nextZoom: number, anchor: Point): ViewTransform {
  const zoom = Math.max(transform.minZoom, Math.min(transform.maxZoom, nextZoom));
  if (zoom === transform.zoom) return transform;
  const anchoredImagePoint = viewportToImage(transform, anchor);
  const next = { ...transform, zoom, revision: transform.revision + 1 };
  const scale = effectiveScale(next);
  const center = {
    x: anchoredImagePoint.x - (anchor.x - next.viewportSize.width / 2) / scale,
    y: anchoredImagePoint.y - (anchor.y - next.viewportSize.height / 2) / scale,
  };
  return { ...next, center: clampCenter(next, center) };
}

export function stepViewZoom(transform: ViewTransform, direction: -1 | 1, anchor: Point): ViewTransform {
  const nextZoom = Math.round((transform.zoom + direction * VIEW_ZOOM_STEP) * 1_000_000) / 1_000_000;
  return zoomAtViewportPoint(transform, nextZoom, anchor);
}

export function actualSizeViewTransform(transform: ViewTransform): ViewTransform {
  const scale = fitScale(transform.imageSize, transform.viewportSize);
  if (scale <= 0) return transform;
  return zoomAtViewportPoint(transform, 1 / scale, {
    x: transform.viewportSize.width / 2,
    y: transform.viewportSize.height / 2,
  });
}

export function panByViewportDelta(transform: ViewTransform, delta: Point): ViewTransform {
  const scale = effectiveScale(transform);
  if (scale <= 0 || (delta.x === 0 && delta.y === 0)) return transform;
  const next = { ...transform, revision: transform.revision + 1 };
  return {
    ...next,
    center: clampCenter(next, {
      x: transform.center.x - delta.x / scale,
      y: transform.center.y - delta.y / scale,
    }),
  };
}

export function resizeViewTransform(transform: ViewTransform, viewportSize: Size): ViewTransform {
  if (viewportSize.width === transform.viewportSize.width && viewportSize.height === transform.viewportSize.height) {
    return transform;
  }
  const next = { ...transform, viewportSize, revision: transform.revision + 1 };
  return { ...next, center: clampCenter(next, transform.center) };
}

export function fitViewTransform(transform: ViewTransform): ViewTransform {
  const center = { x: transform.imageSize.width / 2, y: transform.imageSize.height / 2 };
  if (transform.zoom === transform.minZoom && transform.center.x === center.x && transform.center.y === center.y) {
    return transform;
  }
  return { ...transform, zoom: transform.minZoom, center, revision: transform.revision + 1 };
}

export function viewPlacement(transform: ViewTransform) {
  const scale = effectiveScale(transform);
  const topLeft = imageToViewport(transform, { x: 0, y: 0 });
  return {
    left: topLeft.x,
    top: topLeft.y,
    width: transform.imageSize.width * scale,
    height: transform.imageSize.height * scale,
  };
}
