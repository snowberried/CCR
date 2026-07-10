import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegRawFrameDecoder } from "../electron/adapters/FfmpegRawFrameDecoder.js";
import { runProcess } from "../electron/adapters/process/runProcess.js";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase2-synthetic-qa.json");

async function ffmpeg(args: readonly string[]) {
  return runProcess({ executablePath: ffmpegPath, args, timeoutMs: 120_000, maxOutputBytes: 8 * 1024 * 1024 });
}

const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "ccr-phase2-qa-"));
const cases: Array<{ name: string; filePath: string; expectedRotation?: number }> = [];
try {
  const add = async (name: string, args: readonly string[], expectedRotation?: number) => {
    const filePath = path.join(tempDirectory, `${name}.mp4`);
    await ffmpeg([...args, "-y", filePath]);
    cases.push({ name, filePath, expectedRotation });
  };

  await add("portrait-h264-no-audio", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=30", "-t", "2",
    "-an", "-c:v", "libopenh264", "-g", "30", "-pix_fmt", "yuv420p",
  ]);
  await add("landscape-1080p-60", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60", "-t", "1",
    "-an", "-c:v", "libopenh264", "-g", "60", "-pix_fmt", "yuv420p",
  ]);
  await add("hevc", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-t", "1",
    "-an", "-c:v", "libkvazaar", "-pix_fmt", "yuv420p",
  ]);
  await add("b-frame", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
    "-an", "-c:v", "mpeg4", "-bf", "2", "-g", "15",
  ]);
  await add("vfr", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
    "-vf", "setpts='if(lt(N,30),N/(30*TB),1/TB+(N-30)/(15*TB))'", "-fps_mode", "vfr",
    "-an", "-c:v", "mpeg4", "-q:v", "4",
  ]);

  const rotationBase = path.join(tempDirectory, "rotation-base.mp4");
  await ffmpeg([
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", rotationBase,
  ]);
  const rotationPath = path.join(tempDirectory, "rotation-90.mp4");
  await ffmpeg(["-v", "error", "-display_rotation:v:0", "90", "-i", rotationBase, "-c", "copy", "-y", rotationPath]);
  cases.push({ name: "rotation-90", filePath: rotationPath, expectedRotation: 90 });

  const probeProvider = new FfmpegCliProbeProvider({ ffprobePath });
  const results = [];
  for (const item of cases) {
    const probe = await probeProvider.probe({ filePath: item.filePath });
    const decoder = new FfmpegRawFrameDecoder({
      ffmpegPath,
      sourcePath: item.filePath,
      frames: probe.frames,
      width: probe.stream.width,
      height: probe.stream.height,
    });
    const indexes = [...new Set([0, Math.floor(probe.frames.length / 2), probe.frames.length - 1])];
    const fingerprints = [];
    for (const frameIndex of indexes) {
      const decoded = await decoder.decodeRange(frameIndex, 1, { retainPixels: false });
      fingerprints.push(decoded.descriptors[0].fingerprint.length === 64);
    }
    results.push({
      case: item.name,
      codec: probe.stream.codecName,
      width: probe.stream.width,
      height: probe.stream.height,
      frameCount: probe.frames.length,
      nominalFps: probe.stream.nominalFrameRate,
      averageFps: probe.stream.averageFrameRate,
      rotationDegrees: probe.stream.rotationDegrees,
      expectedRotation: item.expectedRotation ?? null,
      ptsIssues: probe.validation.issues.length,
      decodedCheckpoints: fingerprints.every(Boolean),
    });
  }
  const output = { generatedAt: new Date().toISOString(), results };
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
} finally {
  await rm(tempDirectory, { recursive: true, force: true });
}
