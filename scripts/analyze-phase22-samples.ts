import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { createI420Layout } from "../src/domain/i420.js";
import type { Rational } from "../src/domain/videoProbe.js";

const root = path.resolve("local-samples");
const outputPath = path.resolve("temp/phase22-sample-analysis.json");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

async function mediaFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right));
}

function rationalValue(value: Rational | null): number | null {
  return value && value.denominator !== 0 ? value.numerator / value.denominator : null;
}

async function hashFile(filePath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.once("error", reject);
    stream.once("end", () => resolve(hash.digest("hex")));
  });
}

function maxKeyframeInterval(frameCount: number, keyframes: number[]): number | null {
  if (keyframes.length === 0) return null;
  if (keyframes.length === 1) return frameCount;
  let maximum = 0;
  for (let index = 1; index < keyframes.length; index += 1) {
    maximum = Math.max(maximum, keyframes[index] - keyframes[index - 1]);
  }
  return maximum;
}

const files = await mediaFiles(root);
if (files.length < 2) throw new Error(`PHASE22_NEEDS_MULTIPLE_SAMPLES_GOT_${files.length}`);

const hashes = await Promise.all(files.map(hashFile));
const duplicateLabels = new Map<string, string>();
let duplicateGroup = 1;
for (const hash of new Set(hashes)) {
  if (hashes.filter((candidate) => candidate === hash).length > 1) {
    duplicateLabels.set(hash, `Duplicate Group ${duplicateGroup++}`);
  }
}

const provider = new FfmpegCliProbeProvider({ ffprobePath, timeoutMs: 180_000 });
const samples = [];
for (let index = 0; index < files.length; index += 1) {
  const label = `Sample ${String.fromCharCode(65 + index)}`;
  const { result, diagnostics } = await provider.probeWithDiagnostics({ filePath: files[index] });
  const keyframes = result.frames.filter((frame) => frame.keyframe).map((frame) => frame.frameIndex);
  const layout = createI420Layout(result.stream.width, result.stream.height);
  samples.push({
    sample: label,
    duplicate: duplicateLabels.get(hashes[index]) ?? "Unique",
    durationSeconds: result.stream.durationSeconds,
    frameCount: result.frames.length,
    reportedFrameCount: result.stream.reportedFrameCount,
    width: result.stream.width,
    height: result.stream.height,
    codec: result.stream.codecName,
    pixelFormat: result.stream.pixelFormat,
    nominalFps: rationalValue(result.stream.nominalFrameRate),
    averageFps: rationalValue(result.stream.averageFrameRate),
    keyframeCount: keyframes.length,
    maxKeyframeIntervalFrames: maxKeyframeInterval(result.frames.length, keyframes),
    colorRange: result.stream.colorRange,
    colorSpace: result.stream.colorSpace,
    colorPrimaries: result.stream.colorPrimaries,
    colorTransfer: result.stream.colorTransfer,
    estimatedI420Bytes: layout.byteLength * result.frames.length,
    validation: {
      contiguousFrameIndex: result.validation.contiguousFrameIndex,
      completePts: result.validation.completePts,
      validPts: result.validation.validPts,
      monotonicPts: result.validation.monotonicPts,
      duplicatePts: result.validation.duplicatePts,
      issueCount: result.validation.issues.length,
    },
    probe: diagnostics,
  });
  process.stdout.write(`${label} analyzed\n`);
}

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify({ sampleCount: samples.length, samples }, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify({ sampleCount: samples.length }, null, 2)}\n`);
