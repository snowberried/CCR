import { stat } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import type { VideoProbeProvider } from "../../src/application/ports/VideoProbeProvider.js";
import type { VideoProbeResult } from "../../src/domain/videoProbe.js";
import { FfprobeParseError, parseFfprobeOutput } from "./ffprobe/parseFfprobeOutput.js";
import {
  ProcessRunError,
  runProcess,
  type ProcessRunner,
} from "./process/runProcess.js";

const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024 * 1024;

const PROBE_ARGS = [
  "-v",
  "error",
  "-print_format",
  "json",
  "-show_format",
  "-show_streams",
  "-show_frames",
] as const;

export type LocalVideoFileSource = {
  filePath: string;
  signal?: AbortSignal;
};

export type FfmpegCliProbeProviderOptions = {
  ffprobePath: string;
  timeoutMs?: number;
  maxOutputBytes?: number;
};

export type FfprobeDiagnostics = {
  executionMs: number;
  jsonBytes: number;
  parseMs: number;
  totalMs: number;
  audioStreamCount: number;
};

export type FfprobeResultWithDiagnostics = {
  result: VideoProbeResult;
  diagnostics: FfprobeDiagnostics;
};

export type FfmpegCliProbeProviderErrorCode =
  | "FFPROBE_PATH_INVALID"
  | "FFPROBE_NOT_FOUND"
  | "SOURCE_NOT_FOUND"
  | "SOURCE_NOT_FILE"
  | "FFPROBE_START_FAILED"
  | "FFPROBE_EXIT_FAILED"
  | "FFPROBE_TIMEOUT"
  | "FFPROBE_CANCELLED"
  | "FFPROBE_OUTPUT_LIMIT"
  | "FFPROBE_INVALID_OUTPUT";

export class FfmpegCliProbeProviderError extends Error {
  constructor(
    public readonly code: FfmpegCliProbeProviderErrorCode,
    public readonly exitCode: number | null = null,
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "FfmpegCliProbeProviderError";
  }
}

function countAudioStreams(stdout: string): number {
  const parsed: unknown = JSON.parse(stdout);
  if (typeof parsed !== "object" || parsed === null || !("streams" in parsed)) {
    return 0;
  }
  const streams = (parsed as { streams?: unknown }).streams;
  if (!Array.isArray(streams)) {
    return 0;
  }
  return streams.filter(
    (stream) =>
      typeof stream === "object" &&
      stream !== null &&
      "codec_type" in stream &&
      (stream as { codec_type?: unknown }).codec_type === "audio",
  ).length;
}

function mapProcessError(error: ProcessRunError): FfmpegCliProbeProviderError {
  const codeMap: Record<ProcessRunError["code"], FfmpegCliProbeProviderErrorCode> = {
    PROCESS_START_FAILED: "FFPROBE_START_FAILED",
    PROCESS_EXIT_FAILED: "FFPROBE_EXIT_FAILED",
    PROCESS_TIMEOUT: "FFPROBE_TIMEOUT",
    PROCESS_CANCELLED: "FFPROBE_CANCELLED",
    PROCESS_OUTPUT_LIMIT: "FFPROBE_OUTPUT_LIMIT",
  };
  return new FfmpegCliProbeProviderError(codeMap[error.code], error.exitCode, { cause: error });
}

async function assertRegularFile(
  filePath: string,
  missingCode: "FFPROBE_NOT_FOUND" | "SOURCE_NOT_FOUND",
  notFileCode: "FFPROBE_PATH_INVALID" | "SOURCE_NOT_FILE",
): Promise<void> {
  try {
    const fileStat = await stat(filePath);
    if (!fileStat.isFile()) {
      throw new FfmpegCliProbeProviderError(notFileCode);
    }
  } catch (error) {
    if (error instanceof FfmpegCliProbeProviderError) {
      throw error;
    }
    throw new FfmpegCliProbeProviderError(missingCode, null, { cause: error });
  }
}

export class FfmpegCliProbeProvider implements VideoProbeProvider<LocalVideoFileSource> {
  private readonly ffprobePath: string;
  private readonly timeoutMs: number;
  private readonly maxOutputBytes: number;

  constructor(
    options: FfmpegCliProbeProviderOptions,
    private readonly runner: ProcessRunner = runProcess,
  ) {
    if (
      !path.isAbsolute(options.ffprobePath) ||
      (options.timeoutMs !== undefined && options.timeoutMs <= 0) ||
      (options.maxOutputBytes !== undefined && options.maxOutputBytes <= 0)
    ) {
      throw new FfmpegCliProbeProviderError("FFPROBE_PATH_INVALID");
    }
    this.ffprobePath = options.ffprobePath;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.maxOutputBytes = options.maxOutputBytes ?? DEFAULT_MAX_OUTPUT_BYTES;
  }

  async probe(source: LocalVideoFileSource): Promise<VideoProbeResult> {
    return (await this.probeWithDiagnostics(source)).result;
  }

  async probeWithDiagnostics(source: LocalVideoFileSource): Promise<FfprobeResultWithDiagnostics> {
    await assertRegularFile(this.ffprobePath, "FFPROBE_NOT_FOUND", "FFPROBE_PATH_INVALID");
    await assertRegularFile(source.filePath, "SOURCE_NOT_FOUND", "SOURCE_NOT_FILE");

    const totalStartedAt = performance.now();
    let processResult;
    try {
      processResult = await this.runner({
        executablePath: this.ffprobePath,
        args: [...PROBE_ARGS, source.filePath],
        timeoutMs: this.timeoutMs,
        maxOutputBytes: this.maxOutputBytes,
        signal: source.signal,
      });
    } catch (error) {
      if (error instanceof ProcessRunError) {
        throw mapProcessError(error);
      }
      throw error;
    }

    const parseStartedAt = performance.now();
    try {
      const result = parseFfprobeOutput(processResult.stdout);
      const audioStreamCount = countAudioStreams(processResult.stdout);
      const parseMs = performance.now() - parseStartedAt;
      return {
        result,
        diagnostics: {
          executionMs: processResult.elapsedMs,
          jsonBytes: Buffer.byteLength(processResult.stdout, "utf8"),
          parseMs,
          totalMs: performance.now() - totalStartedAt,
          audioStreamCount,
        },
      };
    } catch (error) {
      if (error instanceof FfprobeParseError || error instanceof SyntaxError) {
        throw new FfmpegCliProbeProviderError("FFPROBE_INVALID_OUTPUT", null, { cause: error });
      }
      throw error;
    }
  }
}
