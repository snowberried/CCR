import {
  validateFrameSequence,
  type FramePoint,
  type FrameSequenceValidation,
} from "./frameSequence.js";

export type Rational = {
  numerator: number;
  denominator: number;
};

export type VideoStreamMetadata = {
  streamIndex: number;
  codecName: string | null;
  width: number;
  height: number;
  timeBase: Rational | null;
  nominalFrameRate: Rational | null;
  averageFrameRate: Rational | null;
  durationSeconds: number | null;
  reportedFrameCount: number | null;
  rotationDegrees: number | null;
  pixelFormat: string | null;
  colorRange: string | null;
  colorSpace: string | null;
  colorPrimaries: string | null;
  colorTransfer: string | null;
};

export type VideoProbeResult = {
  containerFormat: string | null;
  stream: VideoStreamMetadata;
  frames: readonly FramePoint[];
  validation: FrameSequenceValidation;
};

export type VideoProbeResultInput = Omit<VideoProbeResult, "validation">;

export function createVideoProbeResult(input: VideoProbeResultInput): VideoProbeResult {
  return {
    ...input,
    validation: validateFrameSequence(input.frames),
  };
}
