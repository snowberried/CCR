export type ProductDecoderMode = "i420-cache" | "rgba-rollback";

export function selectProductDecoderMode(forceRgba: string | undefined): ProductDecoderMode {
  return forceRgba === "1" ? "rgba-rollback" : "i420-cache";
}
