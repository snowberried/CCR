import { mkdir, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import type { Rational } from "../src/domain/videoProbe.js";

function rationalToNumber(value: Rational | null): number | null {
  return value && value.denominator !== 0 ? value.numerator / value.denominator : null;
}

function median(values: readonly number[]): number | null {
  if (values.length === 0) {
    return null;
  }
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

const samplePath = path.resolve("local-samples/Sample_A.mp4");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputDirectory = path.resolve("temp");
const outputPath = path.join(outputDirectory, "phase1b-sample-a-summary.json");

const provider = new FfmpegCliProbeProvider({ ffprobePath });
const sourceStat = await stat(samplePath);
const { result, diagnostics } = await provider.probeWithDiagnostics({ filePath: samplePath });

const validPtsSeconds = result.frames
  .map((frame) => frame.ptsSeconds)
  .filter((value): value is number => value !== null && Number.isFinite(value));
const positivePtsGaps = validPtsSeconds
  .slice(1)
  .map((value, index) => value - validPtsSeconds[index])
  .filter((value) => value > 0);
const medianPtsGapSeconds = median(positivePtsGaps);
const largePtsGapThresholdSeconds =
  medianPtsGapSeconds === null ? null : medianPtsGapSeconds * 3;
const largePtsGapCount =
  largePtsGapThresholdSeconds === null
    ? 0
    : positivePtsGaps.filter((gap) => gap > largePtsGapThresholdSeconds).length;

const keyframeIndexes = result.frames
  .filter((frame) => frame.keyframe)
  .map((frame) => frame.frameIndex);
const keyframeIntervals = keyframeIndexes
  .slice(1)
  .map((frameIndex, index) => frameIndex - keyframeIndexes[index]);

const issueCounts = Object.fromEntries(
  ["FRAME_INDEX_GAP", "PTS_MISSING", "PTS_INVALID", "PTS_DUPLICATE", "PTS_BACKWARD"].map(
    (code) => [code, result.validation.issues.filter((issue) => issue.code === code).length],
  ),
);

const averageFps = rationalToNumber(result.stream.averageFrameRate);
const durationTimesAverageFps =
  averageFps !== null && result.stream.durationSeconds !== null
    ? averageFps * result.stream.durationSeconds
    : null;

const summary = {
  sample: "Sample A",
  sourceBytes: sourceStat.size,
  environment: {
    platform: process.platform,
    architecture: process.arch,
    osRelease: os.release(),
    cpu: os.cpus()[0]?.model ?? null,
    ramBytes: os.totalmem(),
    nodeVersion: process.version,
  },
  performance: diagnostics,
  media: {
    containerFormat: result.containerFormat,
    codecName: result.stream.codecName,
    audioStreamCount: diagnostics.audioStreamCount,
    width: result.stream.width,
    height: result.stream.height,
    rotationDegrees: result.stream.rotationDegrees,
    durationSeconds: result.stream.durationSeconds,
    nominalFrameRate: result.stream.nominalFrameRate,
    averageFrameRate: result.stream.averageFrameRate,
    reportedFrameCount: result.stream.reportedFrameCount,
    actualFrameEntryCount: result.frames.length,
    durationTimesAverageFps,
    timeBase: result.stream.timeBase,
  },
  pts: {
    firstRaw: result.frames[0]?.pts ?? null,
    firstSeconds: result.frames[0]?.ptsSeconds ?? null,
    lastRaw: result.frames.at(-1)?.pts ?? null,
    lastSeconds: result.frames.at(-1)?.ptsSeconds ?? null,
    medianPositiveGapSeconds: medianPtsGapSeconds,
    largeGapRule: "positive PTS gap greater than 3x the median positive gap",
    largeGapThresholdSeconds: largePtsGapThresholdSeconds,
    largeGapCount: largePtsGapCount,
    framesWithMissingPts: result.frames.filter(
      (frame) => frame.pts === null || frame.ptsSeconds === null,
    ).length,
    framesWithMissingDuration: result.frames.filter(
      (frame) => frame.durationSeconds === null,
    ).length,
  },
  keyframes: {
    count: keyframeIndexes.length,
    medianIntervalFrames: median(keyframeIntervals),
    maximumIntervalFrames: keyframeIntervals.length > 0 ? Math.max(...keyframeIntervals) : null,
  },
  validation: {
    ...result.validation,
    issues: issueCounts,
  },
};

await mkdir(outputDirectory, { recursive: true });
await writeFile(outputPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
