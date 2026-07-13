import { mapDisplayLuminance, temporaryOriginalDisplay, videoDisplayEqual, type VideoDisplayState } from "./videoDisplay.js";

const luma = (red: number, green: number, blue: number) => 0.299 * red + 0.587 * green + 0.114 * blue;
const byte = (value: number) => Math.max(0, Math.min(255, Math.round(value * 255)));

export function applyVideoDisplayToRgba(
  source: Uint8Array | Uint8ClampedArray,
  width: number,
  height: number,
  state: VideoDisplayState,
  comparing = false,
): Uint8ClampedArray<ArrayBuffer> {
  const effective = temporaryOriginalDisplay(state, comparing);
  const output = new Uint8ClampedArray(source.length);
  output.set(source);
  if (videoDisplayEqual(effective, temporaryOriginalDisplay(effective, true))) return output;

  const mapped = new Float32Array(width * height);
  for (let pixel = 0; pixel < mapped.length; pixel += 1) {
    const offset = pixel * 4;
    mapped[pixel] = mapDisplayLuminance(luma(source[offset], source[offset + 1], source[offset + 2]) / 255, effective);
  }

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const pixel = y * width + x;
      const offset = pixel * 4;
      const originalLuma = luma(source[offset], source[offset + 1], source[offset + 2]) / 255;
      let adjustedLuma = mapped[pixel];
      if (effective.sharpAmount > 0) {
        const left = mapped[y * width + Math.max(0, x - 1)];
        const right = mapped[y * width + Math.min(width - 1, x + 1)];
        const up = mapped[Math.max(0, y - 1) * width + x];
        const down = mapped[Math.min(height - 1, y + 1) * width + x];
        adjustedLuma = Math.max(0, Math.min(1, adjustedLuma + effective.sharpAmount * 0.25 * (4 * adjustedLuma - left - right - up - down)));
      }
      const delta = adjustedLuma - originalLuma;
      output[offset] = byte(source[offset] / 255 + delta);
      output[offset + 1] = byte(source[offset + 1] / 255 + delta);
      output[offset + 2] = byte(source[offset + 2] / 255 + delta);
    }
  }
  return output;
}
