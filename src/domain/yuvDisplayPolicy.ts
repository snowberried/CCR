export type YuvDisplayPolicyInput = {
  codecName: string | null;
  pixelFormat: string | null;
  colorRange: string | null;
  colorSpace: string | null;
  colorPrimaries: string | null;
  colorTransfer: string | null;
};

export type YuvDisplayPolicy =
  | { mode: "bt601-limited"; reason: "explicit-bt601-limited" }
  | { mode: "candidate-bt601-limited"; reason: "approved-h264-yuv420p-profile" }
  | { mode: "rgba-fallback"; reason: "unsupported-pixel-format" | "unsupported-color-policy" };

export function selectYuvDisplayPolicy(input: YuvDisplayPolicyInput): YuvDisplayPolicy {
  if (input.pixelFormat !== "yuv420p") {
    return { mode: "rgba-fallback", reason: "unsupported-pixel-format" };
  }

  const metadata = [input.colorRange, input.colorSpace, input.colorPrimaries, input.colorTransfer];
  if (metadata.every((value) => value === null)) {
    return input.codecName === "h264"
      ? { mode: "candidate-bt601-limited", reason: "approved-h264-yuv420p-profile" }
      : { mode: "rgba-fallback", reason: "unsupported-color-policy" };
  }

  const limitedRange = input.colorRange === "tv" || input.colorRange === "mpeg";
  const bt601Matrix = input.colorSpace === "smpte170m";
  const conflicting709 = input.colorPrimaries === "bt709" || input.colorTransfer === "bt709";
  return limitedRange && bt601Matrix && !conflicting709
    ? { mode: "bt601-limited", reason: "explicit-bt601-limited" }
    : { mode: "rgba-fallback", reason: "unsupported-color-policy" };
}
