export type Size = { width: number; height: number };

export function calculateContainedSize(content: Size, container: Size): Size {
  if (content.width <= 0 || content.height <= 0 || container.width <= 0 || container.height <= 0) {
    return { width: 0, height: 0 };
  }
  const scale = Math.min(container.width / content.width, container.height / content.height);
  return { width: content.width * scale, height: content.height * scale };
}

export type ReleasableCanvas = {
  width: number;
  height: number;
  getContext(contextId: "2d"): { clearRect(x: number, y: number, width: number, height: number): void } | null;
};

export function releaseCanvas(canvas: ReleasableCanvas | null): void {
  if (!canvas) {
    return;
  }
  canvas.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
  canvas.width = 0;
  canvas.height = 0;
}
