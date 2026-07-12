import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { FfmpegCliProbeProvider } from "../electron/adapters/FfmpegCliProbeProvider.js";
import { FfmpegFrameIndexProvider } from "../electron/adapters/FfmpegFrameIndexProvider.js";
import { FfmpegYuvDecoder } from "../electron/adapters/FfmpegYuvDecoder.js";
import { runProcess } from "../electron/adapters/process/runProcess.js";
import { YuvSpikeSession } from "../electron/spike22/YuvSpikeSession.js";
import { createI420Layout } from "../src/domain/i420.js";

const ffmpegPath = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobePath = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase22-synthetic-qa.json");

type SyntheticCase = {
  name: string;
  filePath: string;
  expectedRotation?: number;
  expectedWebgl: boolean;
};

async function ffmpeg(args: string[]): Promise<void> {
  await runProcess({
    executablePath: ffmpegPath,
    args,
    timeoutMs: 120_000,
    maxOutputBytes: 8 * 1024 * 1024,
  });
}

const directory = await mkdtemp(path.join(os.tmpdir(), "ccr-phase22-qa-"));
const cases: SyntheticCase[] = [];
try {
  const add = async (
    name: string,
    extension: "mp4" | "mkv",
    args: string[],
    expectedWebgl: boolean,
    expectedRotation?: number,
  ) => {
    const filePath = path.join(directory, `${name}.${extension}`);
    await ffmpeg([...args, "-y", filePath]);
    cases.push({ name, filePath, expectedWebgl, expectedRotation });
  };

  await add("portrait-bt601-limited-overlay", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=30", "-t", "2",
    "-vf", "drawbox=x=40:y=60:w=120:h=80:color=red@1:t=fill",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p",
    "-color_range", "tv", "-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m",
  ], true);
  await add("landscape-1080p60-bt709", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p",
    "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
  ], false);
  await add("hevc", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-t", "1",
    "-an", "-c:v", "libkvazaar", "-pix_fmt", "yuv420p",
  ], true);
  await add("b-frame", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
    "-an", "-c:v", "mpeg4", "-bf", "2", "-g", "15", "-pix_fmt", "yuv420p",
  ], true);
  await add("vfr", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
    "-vf", "setpts='if(lt(N,30),N/(30*TB),1/TB+(N-30)/(15*TB))'", "-fps_mode", "vfr",
    "-an", "-c:v", "mpeg4", "-q:v", "4", "-pix_fmt", "yuv420p",
  ], true);
  await add("odd-i420", "mkv", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc=size=321x241:rate=12", "-t", "1",
    "-an", "-c:v", "ffv1", "-pix_fmt", "yuv420p",
  ], true);
  await add("bt601-full", "mp4", [
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p",
    "-color_range", "pc", "-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m",
  ], false);

  const rotationBase = path.join(directory, "rotation-base.mp4");
  await ffmpeg([
    "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "1",
    "-an", "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-y", rotationBase,
  ]);
  const rotationPath = path.join(directory, "rotation-90.mp4");
  await ffmpeg(["-v", "error", "-display_rotation:v:0", "90", "-i", rotationBase, "-c", "copy", "-y", rotationPath]);
  cases.push({ name: "rotation-90", filePath: rotationPath, expectedRotation: 90, expectedWebgl: true });

  const fullProvider = new FfmpegCliProbeProvider({ ffprobePath, timeoutMs: 180_000 });
  const frameIndexProvider = new FfmpegFrameIndexProvider(ffprobePath);
  const results = [];
  for (const item of cases) {
    const full = await fullProvider.probe({ filePath: item.filePath });
    const packetIndex = await frameIndexProvider.probe(item.filePath);
    const session = await YuvSpikeSession.open({ ffmpegPath, ffprobePath }, item.filePath);
    session.startBackground(() => undefined);
    await session.waitForBackground();
    const layout = createI420Layout(full.stream.width, full.stream.height);
    const decoder = new FfmpegYuvDecoder({
      ffmpegPath,
      sourcePath: item.filePath,
      width: full.stream.width,
      height: full.stream.height,
      blockFrames: 1,
      timeoutMs: 120_000,
    });
    const checkpoints = [...new Set([0, Math.floor(full.frames.length / 2), full.frames.length - 1])];
    let fingerprintErrors = 0;
    for (const frameIndex of checkpoints) {
      const cached = await session.requestFrame(frameIndex);
      let independent: Buffer | null = null;
      await decoder.decodeSequential({
        startFrameIndex: frameIndex,
        startPtsSeconds: frameIndex === 0 ? undefined : full.frames[frameIndex].ptsSeconds ?? undefined,
        frameCount: 1,
        onBlock: (block) => { independent = block.payload; },
      });
      const independentHash = independent ? createHash("sha256").update(independent).digest("hex") : null;
      if (cached.fingerprint !== independentHash) fingerprintErrors += 1;
    }
    const color = session.colorSpace;
    const webglSupported = !color.fullRange && color.matrix === "smpte170m";
    results.push({
      case: item.name,
      codec: full.stream.codecName,
      pixelFormat: full.stream.pixelFormat,
      width: full.stream.width,
      height: full.stream.height,
      frameCount: full.frames.length,
      rotationDegrees: full.stream.rotationDegrees,
      expectedRotation: item.expectedRotation ?? null,
      packetIndexIssues: packetIndex.issueCount,
      packetIndexMatches: packetIndex.frames.every((frame, index) =>
        frame.pts === full.frames[index]?.pts && frame.ptsSeconds === full.frames[index]?.ptsSeconds),
      layoutBytes: layout.byteLength,
      sessionLayoutBytes: session.layout.byteLength,
      fingerprintErrors,
      webglSupported,
      expectedWebgl: item.expectedWebgl,
      fallbackRequired: !webglSupported,
      cacheMode: session.status().cacheMode,
      cacheBytes: session.status().byteLength,
    });
    session.close();
    process.stdout.write(`${item.name} complete\n`);
  }

  const summary = {
    caseCount: results.length,
    packetIndexErrors: results.filter((result) => result.packetIndexIssues > 0 || !result.packetIndexMatches).length,
    layoutErrors: results.filter((result) => result.layoutBytes !== result.sessionLayoutBytes).length,
    fingerprintErrors: results.reduce((total, result) => total + result.fingerprintErrors, 0),
    colorPolicyErrors: results.filter((result) => result.webglSupported !== result.expectedWebgl).length,
    rotationErrors: results.filter((result) =>
      result.expectedRotation !== null && result.rotationDegrees !== result.expectedRotation).length,
  };
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify({ summary, results }, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
