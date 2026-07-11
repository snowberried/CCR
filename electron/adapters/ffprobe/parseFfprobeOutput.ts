import { createVideoProbeResult, type Rational, type VideoProbeResult } from "../../../src/domain/videoProbe.js";

export type FfprobeParseErrorCode =
  | "INVALID_JSON"
  | "INVALID_OUTPUT"
  | "VIDEO_STREAM_NOT_FOUND"
  | "INVALID_VIDEO_STREAM";

export class FfprobeParseError extends Error {
  constructor(
    public readonly code: FfprobeParseErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "FfprobeParseError";
  }
}

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function optionalNumber(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") {
    return null;
  }

  if (typeof value === "string" && value.trim().length === 0) {
    return null;
  }

  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function optionalInteger(value: unknown): number | null {
  const parsed = optionalNumber(value);
  return parsed !== null && Number.isInteger(parsed) ? parsed : null;
}

function positiveInteger(value: unknown): number | null {
  const parsed = optionalInteger(value);
  return parsed !== null && parsed > 0 ? parsed : null;
}

function parseRational(value: unknown): Rational | null {
  if (typeof value !== "string") {
    return null;
  }

  const match = /^(-?\d+)\/(-?\d+)$/.exec(value);
  if (!match) {
    return null;
  }

  const numerator = Number(match[1]);
  const denominator = Number(match[2]);
  if (!Number.isSafeInteger(numerator) || !Number.isSafeInteger(denominator) || denominator === 0) {
    return null;
  }

  return { numerator, denominator };
}

function readRotation(stream: JsonRecord): number | null {
  if (Array.isArray(stream.side_data_list)) {
    for (const entry of stream.side_data_list) {
      if (isRecord(entry)) {
        const rotation = optionalNumber(entry.rotation);
        if (rotation !== null) {
          return rotation;
        }
      }
    }
  }

  if (isRecord(stream.tags)) {
    return optionalNumber(stream.tags.rotate);
  }

  return null;
}

function readRawPts(frame: JsonRecord): string | null {
  const value = frame.best_effort_timestamp ?? frame.pts;
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    return Number.isSafeInteger(value) ? String(value) : null;
  }
  return null;
}

function readPtsSeconds(frame: JsonRecord): number | null {
  return optionalNumber(frame.best_effort_timestamp_time ?? frame.pts_time);
}

export function parseFfprobeOutput(stdout: string): VideoProbeResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new FfprobeParseError("INVALID_JSON", "ffprobe output is not valid JSON.");
  }

  if (!isRecord(parsed)) {
    throw new FfprobeParseError("INVALID_OUTPUT", "ffprobe output must be a JSON object.");
  }

  const streams = Array.isArray(parsed.streams) ? parsed.streams.filter(isRecord) : [];
  const videoStream = streams.find((stream) => stream.codec_type === "video");
  if (!videoStream) {
    throw new FfprobeParseError("VIDEO_STREAM_NOT_FOUND", "ffprobe output has no video stream.");
  }

  const streamIndex = optionalInteger(videoStream.index);
  const width = positiveInteger(videoStream.width);
  const height = positiveInteger(videoStream.height);
  if (streamIndex === null || width === null || height === null) {
    throw new FfprobeParseError(
      "INVALID_VIDEO_STREAM",
      "The selected video stream is missing a valid index, width, or height.",
    );
  }

  const rawFrames = Array.isArray(parsed.frames) ? parsed.frames.filter(isRecord) : [];
  const frames = rawFrames
    .filter(
      (frame) =>
        frame.media_type === "video" && optionalInteger(frame.stream_index) === streamIndex,
    )
    .map((frame, frameIndex) => ({
      frameIndex,
      pts: readRawPts(frame),
      ptsSeconds: readPtsSeconds(frame),
      durationSeconds: optionalNumber(frame.duration_time ?? frame.pkt_duration_time),
      keyframe: frame.key_frame === 1 || frame.key_frame === true,
    }));

  const format = isRecord(parsed.format) ? parsed.format : null;

  return createVideoProbeResult({
    containerFormat: format ? optionalString(format.format_name) : null,
    stream: {
      streamIndex,
      codecName: optionalString(videoStream.codec_name),
      width,
      height,
      timeBase: parseRational(videoStream.time_base),
      nominalFrameRate: parseRational(videoStream.r_frame_rate),
      averageFrameRate: parseRational(videoStream.avg_frame_rate),
      durationSeconds: optionalNumber(videoStream.duration),
      reportedFrameCount: optionalInteger(videoStream.nb_frames),
      rotationDegrees: readRotation(videoStream),
      pixelFormat: optionalString(videoStream.pix_fmt),
      colorRange: optionalString(videoStream.color_range),
      colorSpace: optionalString(videoStream.color_space),
      colorPrimaries: optionalString(videoStream.color_primaries),
      colorTransfer: optionalString(videoStream.color_transfer),
    },
    frames,
  });
}
