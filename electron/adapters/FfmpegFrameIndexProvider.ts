import path from "node:path";
import { performance } from "node:perf_hooks";
import { validateFrameSequence, type FramePoint } from "../../src/domain/frameSequence.js";
import { runProcess } from "./process/runProcess.js";

type FfprobePacket = {
  pts?: unknown;
  pts_time?: unknown;
  duration_time?: unknown;
  flags?: unknown;
};

export type FrameIndexProbeResult = {
  frames: FramePoint[];
  executionMs: number;
  totalMs: number;
  jsonBytes: number;
  issueCount: number;
};

function optionalNumber(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function rawTimestamp(value: unknown): string | null {
  if (typeof value === "string" && /^-?\d+$/.test(value)) return value;
  if (typeof value === "number" && Number.isInteger(value)) return String(value);
  return null;
}

export class FfmpegFrameIndexProvider {
  constructor(private readonly ffprobePath: string, private readonly timeoutMs = 180_000) {
    if (!path.isAbsolute(ffprobePath) || timeoutMs <= 0) {
      throw new RangeError("FRAME_INDEX_PROBE_CONFIG_INVALID");
    }
  }

  async probe(filePath: string, signal?: AbortSignal): Promise<FrameIndexProbeResult> {
    const totalStartedAt = performance.now();
    const result = await runProcess({
      executablePath: this.ffprobePath,
      args: [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "packet=pts,pts_time,duration_time,flags", "-show_packets",
        "-of", "json", filePath,
      ],
      timeoutMs: this.timeoutMs,
      maxOutputBytes: 16 * 1024 * 1024,
      signal,
    });
    const parsed: unknown = JSON.parse(result.stdout);
    if (typeof parsed !== "object" || parsed === null || !("packets" in parsed) || !Array.isArray(parsed.packets)) {
      throw new Error("FRAME_INDEX_PROBE_INVALID_OUTPUT");
    }
    const packets = (parsed.packets as FfprobePacket[]).map((packet) => ({
      pts: rawTimestamp(packet.pts),
      ptsSeconds: optionalNumber(packet.pts_time),
      durationSeconds: optionalNumber(packet.duration_time),
      keyframe: typeof packet.flags === "string" && packet.flags.includes("K"),
    })).sort((left, right) => {
      if (left.pts === null) return 1;
      if (right.pts === null) return -1;
      const leftPts = BigInt(left.pts);
      const rightPts = BigInt(right.pts);
      return leftPts < rightPts ? -1 : leftPts > rightPts ? 1 : 0;
    });
    const frames = packets.map((packet, frameIndex): FramePoint => ({
      frameIndex,
      ...packet,
    }));
    const validation = validateFrameSequence(frames);
    return {
      frames,
      executionMs: result.elapsedMs,
      totalMs: performance.now() - totalStartedAt,
      jsonBytes: Buffer.byteLength(result.stdout, "utf8"),
      issueCount: validation.issues.length,
    };
  }
}
