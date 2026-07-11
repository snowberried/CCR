import path from "node:path";
import { stat } from "node:fs/promises";
import { runProcess } from "./process/runProcess.js";

export type QuickVideoProbe = {
  codecName: string | null;
  width: number;
  height: number;
  pixelFormat: string | null;
  durationSeconds: number | null;
  reportedFrameCount: number | null;
  nominalFrameRate: string | null;
  averageFrameRate: string | null;
  rotationDegrees: number | null;
  colorRange: string | null;
  colorSpace: string | null;
  colorPrimaries: string | null;
  colorTransfer: string | null;
};

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function optionalNumber(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : null;
}

export class FfmpegQuickProbeProvider {
  constructor(private readonly ffprobePath: string) {
    if (!path.isAbsolute(ffprobePath)) throw new RangeError("FFPROBE_PATH_INVALID");
  }

  async probe(filePath: string, signal?: AbortSignal): Promise<QuickVideoProbe> {
    const [probeStat, sourceStat] = await Promise.all([stat(this.ffprobePath), stat(filePath)]);
    if (!probeStat.isFile() || !sourceStat.isFile()) throw new Error("QUICK_PROBE_SOURCE_INVALID");
    const processResult = await runProcess({
      executablePath: this.ffprobePath,
      args: ["-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", filePath],
      timeoutMs: 10_000,
      maxOutputBytes: 1024 * 1024,
      signal,
    });
    const parsed = JSON.parse(processResult.stdout) as { streams?: Array<Record<string, unknown>> };
    const stream = parsed.streams?.[0];
    const width = optionalNumber(stream?.width);
    const height = optionalNumber(stream?.height);
    if (!stream || !width || !height || !Number.isInteger(width) || !Number.isInteger(height)) {
      throw new Error("QUICK_PROBE_VIDEO_STREAM_INVALID");
    }
    const sideData = Array.isArray(stream.side_data_list)
      ? stream.side_data_list.find((value) => typeof value === "object" && value !== null) as Record<string, unknown> | undefined
      : undefined;
    const reported = optionalNumber(stream.nb_frames);
    return {
      codecName: optionalString(stream.codec_name),
      width,
      height,
      pixelFormat: optionalString(stream.pix_fmt),
      durationSeconds: optionalNumber(stream.duration),
      reportedFrameCount: reported !== null && Number.isInteger(reported) && reported > 0 ? reported : null,
      nominalFrameRate: optionalString(stream.r_frame_rate),
      averageFrameRate: optionalString(stream.avg_frame_rate),
      rotationDegrees: optionalNumber(sideData?.rotation),
      colorRange: optionalString(stream.color_range),
      colorSpace: optionalString(stream.color_space),
      colorPrimaries: optionalString(stream.color_primaries),
      colorTransfer: optionalString(stream.color_transfer),
    };
  }
}
