export type I420PlaneLayout = {
  offset: number;
  stride: number;
};

export type I420Layout = {
  y: I420PlaneLayout;
  u: I420PlaneLayout;
  v: I420PlaneLayout;
  byteLength: number;
};

export function createI420Layout(width: number, height: number): I420Layout {
  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0) {
    throw new RangeError("INVALID_I420_DIMENSIONS");
  }
  const yBytes = width * height;
  const chromaStride = Math.ceil(width / 2);
  const chromaBytes = chromaStride * Math.ceil(height / 2);
  return {
    y: { offset: 0, stride: width },
    u: { offset: yBytes, stride: chromaStride },
    v: { offset: yBytes + chromaBytes, stride: chromaStride },
    byteLength: yBytes + chromaBytes * 2,
  };
}

export function chooseI420BlockFrames(frameBytes: number, targetBlockBytes = 32 * 1024 * 1024): number {
  if (!Number.isInteger(frameBytes) || frameBytes <= 0 || !Number.isInteger(targetBlockBytes) || targetBlockBytes <= 0) {
    throw new RangeError("INVALID_I420_BLOCK_POLICY");
  }
  return Math.max(8, Math.min(64, Math.floor(targetBlockBytes / frameBytes)));
}
