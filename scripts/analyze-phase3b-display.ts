import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { applyVideoDisplayPreset, originalVideoDisplay, VIDEO_DISPLAY_PRESETS } from "../src/domain/videoDisplay.js";
import { applyVideoDisplayToRgba } from "../src/domain/videoDisplayReference.js";

const root = process.cwd();
const sampleRoot = path.join(root, "local-samples");
const ffmpeg = path.join(root, "tools", "ffmpeg", "bin", "ffmpeg.exe");
const ffprobe = path.join(root, "tools", "ffmpeg", "bin", "ffprobe.exe");
const outputPath = path.join(root, "temp", "phase3b-sample-display.json");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);

function mediaFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }).sort((left, right) => left.localeCompare(right));
}

function run(executable: string, args: string[], maxBuffer: number): Buffer {
  try {
    return execFileSync(executable, args, { windowsHide: true, maxBuffer, encoding: "buffer" });
  } catch {
    throw new Error("PHASE3B_SAMPLE_PROCESS_FAILED");
  }
}

function probe(filePath: string) {
  const output = run(ffprobe, [
    "-v", "error", "-select_streams", "v:0", "-show_streams",
    "-show_entries", "frame=best_effort_timestamp_time", "-show_frames", "-of", "json", filePath,
  ], 64 * 1024 * 1024);
  const value = JSON.parse(output.toString("utf8"));
  return {
    width: Number(value.streams[0].width),
    height: Number(value.streams[0].height),
    pts: value.frames.map((frame: { best_effort_timestamp_time?: string }) => Number(frame.best_effort_timestamp_time)),
  };
}

function decode(filePath: string, ptsSeconds: number, width: number, height: number): Uint8Array {
  return new Uint8Array(run(ffmpeg, [
    "-v", "error", "-ss", String(ptsSeconds), "-noautorotate", "-i", filePath,
    "-map", "0:v:0", "-an", "-sn", "-dn", "-frames:v", "1",
    "-pix_fmt", "rgba", "-f", "rawvideo", "pipe:1",
  ], width * height * 5));
}

function statistics(source: Uint8Array, output: Uint8ClampedArray<ArrayBuffer>) {
  let black = 0;
  let white = 0;
  let luminance = 0;
  let coloredSource = 0;
  let coloredPreserved = 0;
  const pixels = output.length / 4;
  for (let offset = 0; offset < output.length; offset += 4) {
    const value = 0.299 * output[offset] + 0.587 * output[offset + 1] + 0.114 * output[offset + 2];
    if (value <= 1) black += 1;
    if (value >= 254) white += 1;
    luminance += value / 255;
    const sourceChroma = Math.max(source[offset], source[offset + 1], source[offset + 2]) - Math.min(source[offset], source[offset + 1], source[offset + 2]);
    if (sourceChroma >= 20) {
      coloredSource += 1;
      const outputChroma = Math.max(output[offset], output[offset + 1], output[offset + 2]) - Math.min(output[offset], output[offset + 1], output[offset + 2]);
      if (outputChroma >= 10) coloredPreserved += 1;
    }
  }
  return {
    blackClipRatio: black / pixels,
    whiteClipRatio: white / pixels,
    meanLuminance: luminance / pixels,
    coloredOverlayPreservedRatio: coloredSource === 0 ? 1 : coloredPreserved / coloredSource,
  };
}

const files = mediaFiles(sampleRoot);
if (files.length !== 11) throw new Error(`PHASE3B_EXPECTED_11_SAMPLES_GOT_${files.length}`);
const presetIds = VIDEO_DISPLAY_PRESETS.map((preset) => preset.presetId);
const samples = files.map((filePath, sampleIndex) => {
  const metadata = probe(filePath);
  const indexes = [...new Set([0, Math.floor(metadata.pts.length / 2), metadata.pts.length - 1])];
  const frames = indexes.map((frameIndex) => {
    const source = decode(filePath, metadata.pts[frameIndex], metadata.width, metadata.height);
    return {
      position: frameIndex === 0 ? "first" : frameIndex === metadata.pts.length - 1 ? "last" : "middle",
      presets: presetIds.map((presetId) => {
        const state = applyVideoDisplayPreset(originalVideoDisplay(), presetId);
        return { presetId, ...statistics(source, applyVideoDisplayToRgba(source, metadata.width, metadata.height, state)) };
      }),
    };
  });
  process.stdout.write(`Sample ${String.fromCharCode(65 + sampleIndex)} display analysis complete\n`);
  return { sample: `Sample ${String.fromCharCode(65 + sampleIndex)}`, frames };
});

const summary = presetIds.map((presetId) => {
  const values = samples.flatMap((sample) => sample.frames.flatMap((frame) => frame.presets.filter((preset) => preset.presetId === presetId)));
  return {
    presetId,
    blackClipRatioMin: Math.min(...values.map((value) => value.blackClipRatio)),
    blackClipRatioMax: Math.max(...values.map((value) => value.blackClipRatio)),
    whiteClipRatioMin: Math.min(...values.map((value) => value.whiteClipRatio)),
    whiteClipRatioMax: Math.max(...values.map((value) => value.whiteClipRatio)),
    meanLuminanceMin: Math.min(...values.map((value) => value.meanLuminance)),
    meanLuminanceMax: Math.max(...values.map((value) => value.meanLuminance)),
    coloredOverlayPreservedRatioMin: Math.min(...values.map((value) => value.coloredOverlayPreservedRatio)),
  };
});

mkdirSync(path.dirname(outputPath), { recursive: true });
writeFileSync(outputPath, `${JSON.stringify({ sampleCount: samples.length, presetValuesAreStaticAcrossFrames: true, summary, samples }, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
