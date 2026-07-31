import { createHash } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { once } from "node:events";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, spawnSync } from "node:child_process";

const toolDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(toolDir, "../..");
const generatedRoot = join(root, "android/.generated/testdata");
const outputDir = join(generatedRoot, "representative-resolution");
const lockPath = join(root, "android/testdata/representative-resolution/manifest.lock.json");
const ffmpeg = join(root, "tools/ffmpeg/bin/ffmpeg.exe");
const ffprobe = join(root, "tools/ffmpeg/bin/ffprobe.exe");
const fps = 12;
const vfrCadenceSegmentFrames = 120;
const marker = { x: 8, y: 8, cells: 8, cellSize: 12 };
const archive = {
  name: "ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip",
  sha256: "27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da",
};

const fixtures = [
  { basename: "720p-h264-bframes", width: 1280, height: 720, frames: 360, idBase: 10000, encoder: "h264_nvenc", codec: "h264", profile: "Main", gop: 48, bFrames: 2 },
  { basename: "1080p-h264-bframes", width: 1920, height: 1080, frames: 360, idBase: 11000, encoder: "h264_nvenc", codec: "h264", profile: "Main", gop: 48, bFrames: 2 },
  { basename: "1080p-h264-long-gop", width: 1920, height: 1080, frames: 360, idBase: 12000, encoder: "h264_nvenc", codec: "h264", profile: "Main", gop: 240, bFrames: 0 },
  { basename: "1080p-hevc-main8", width: 1920, height: 1080, frames: 360, idBase: 13000, encoder: "hevc_nvenc", codec: "hevc", profile: "Main", gop: 48, bFrames: 2 },
  { basename: "1080p-vfr", width: 1920, height: 1080, frames: 360, idBase: 14000, encoder: "h264_nvenc", codec: "h264", profile: "Main", gop: 48, bFrames: 0, vfr: true },
  { basename: "1080p-switch-a", width: 1920, height: 1080, frames: 360, idBase: 15000, encoder: "h264_nvenc", codec: "h264", profile: "Main", gop: 48, bFrames: 2 },
  { basename: "1080p-switch-b", width: 1920, height: 1080, frames: 360, idBase: 16000, encoder: "hevc_nvenc", codec: "hevc", profile: "Main", gop: 48, bFrames: 2 },
];

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha256File(path) {
  return sha256Bytes(readFileSync(path));
}

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    cwd: root,
    encoding: options.binary ? null : "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : result.stderr;
    throw new Error(`${relative(root, executable)} failed (${result.status}): ${stderr}`);
  }
  return result.stdout;
}

function firstLine(executable, args) {
  return String(run(executable, args)).split(/\r?\n/, 1)[0];
}

function crc8(value) {
  let crc = 0;
  for (const byte of [(value >>> 8) & 0xff, value & 0xff]) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
    }
  }
  return crc;
}

function markerBits(id) {
  const bits = Array(64).fill(0);
  const top = [1, 0, 1, 1, 0, 0, 1, 0];
  const bottom = [1, 1, 0, 0, 1, 0, 1, 1];
  const left = [1, 0, 1, 0, 1, 1];
  const right = [0, 1, 1, 0, 0, 1];
  top.forEach((value, column) => { bits[column] = value; });
  bottom.forEach((value, column) => { bits[56 + column] = value; });
  left.forEach((value, row) => { bits[(row + 1) * 8] = value; });
  right.forEach((value, row) => { bits[(row + 1) * 8 + 7] = value; });
  const payload = [];
  for (let bit = 15; bit >= 0; bit -= 1) payload.push((id >>> bit) & 1);
  const crc = crc8(id);
  for (let bit = 7; bit >= 0; bit -= 1) payload.push((crc >>> bit) & 1);
  for (let bit = 0; bit < 12; bit += 1) payload.push(bit % 2);
  let cursor = 0;
  for (let row = 1; row < 7; row += 1) {
    for (let column = 1; column < 7; column += 1) bits[row * 8 + column] = payload[cursor++];
  }
  return bits;
}

function markerFrame(id) {
  const size = marker.cells * marker.cellSize;
  const frame = Buffer.alloc(size * size * 3);
  const bits = markerBits(id);
  for (let row = 0; row < marker.cells; row += 1) {
    for (let column = 0; column < marker.cells; column += 1) {
      const value = bits[row * marker.cells + column] ? 240 : 16;
      for (let y = row * marker.cellSize; y < (row + 1) * marker.cellSize; y += 1) {
        const start = (y * size + column * marker.cellSize) * 3;
        frame.fill(value, start, start + marker.cellSize * 3);
      }
    }
  }
  return frame;
}

function encoderArgs(spec) {
  const colorMetadata = spec.codec === "h264"
    ? "h264_metadata=video_full_range_flag=0:colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1"
    : "hevc_metadata=video_full_range_flag=0:colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1";
  return [
    "-c:v", spec.encoder,
    "-preset", "p7",
    "-tune", "hq",
    "-rc", "constqp",
    "-qp", "18",
    "-profile:v", "main",
    "-g", String(spec.gop),
    "-bf", String(spec.bFrames),
    "-rc-lookahead", "16",
    "-no-scenecut", "1",
    "-strict_gop", "1",
    "-pix_fmt", "yuv420p",
    "-color_range", "tv",
    "-colorspace", "bt709",
    "-bsf:v", colorMetadata,
  ];
}

function encodeArgs(spec, outputPath) {
  const markerSize = marker.cells * marker.cellSize;
  const setPts = spec.vfr
    ? `,setpts=(N+clip(N-${vfrCadenceSegmentFrames}\\,0\\,${vfrCadenceSegmentFrames}))/(${fps}*TB)`
    : "";
  return [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `testsrc2=size=${spec.width}x${spec.height}:rate=${fps}`,
    "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", `${markerSize}x${markerSize}`, "-framerate", String(fps), "-i", "pipe:0",
    "-filter_complex", `[0:v][1:v]overlay=${marker.x}:${marker.y}:shortest=1:format=auto${setPts}[video]`,
    "-map", "[video]", "-frames:v", String(spec.frames), "-an",
    ...(spec.vfr ? ["-fps_mode", "vfr"] : []),
    ...encoderArgs(spec),
    "-map_metadata", "-1",
    "-video_track_timescale", "12000",
    "-movflags", "+faststart",
    outputPath,
  ];
}

async function encode(spec, outputPath) {
  const args = encodeArgs(spec, outputPath);
  const child = spawn(ffmpeg, args, { cwd: root, stdio: ["pipe", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const completion = new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("close", (code) => code === 0
      ? resolvePromise()
      : rejectPromise(new Error(`ffmpeg encode failed (${code}): ${stderr}`)));
  });
  try {
    for (let index = 0; index < spec.frames; index += 1) {
      if (!child.stdin.write(markerFrame(spec.idBase + index))) await once(child.stdin, "drain");
    }
    child.stdin.end();
    await completion;
  } catch (error) {
    child.stdin.destroy();
    child.kill();
    await completion.catch(() => {});
    throw error;
  }
  return args;
}

function redactArgs(args, outputPath) {
  return args.map((arg) => {
    if (arg === outputPath) return "<fixture.mp4>";
    if (arg === "pipe:0") return "pipe:<synthetic-marker-rgb>";
    return arg;
  });
}

function probe(path) {
  const entries = "stream=codec_name,profile,width,height,coded_width,coded_height,time_base,sample_aspect_ratio:packet=pts,flags:frame=pts,key_frame";
  const result = JSON.parse(run(ffprobe, [
    "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_packets", "-show_frames",
    "-show_entries", entries, "-of", "json", path,
  ]));
  const combined = result.packets_and_frames ?? [];
  result.packets = result.packets ?? combined.filter((entry) => entry.type === "packet");
  result.frames = result.frames ?? combined.filter((entry) => entry.type === "frame");
  return result;
}

function rescaleToUs(rawPts, timeBase) {
  const [numerator, denominator] = timeBase.split("/").map(BigInt);
  return Number(BigInt(rawPts) * numerator * 1_000_000n / denominator);
}

function decodeMarker(frame) {
  const size = marker.cells * marker.cellSize;
  const bits = [];
  for (let row = 0; row < marker.cells; row += 1) {
    for (let column = 0; column < marker.cells; column += 1) {
      let luminance = 0;
      let count = 0;
      for (const fractionY of [0.3, 0.5, 0.7]) {
        for (const fractionX of [0.3, 0.5, 0.7]) {
          const x = Math.round((column + fractionX) * marker.cellSize);
          const y = Math.round((row + fractionY) * marker.cellSize);
          const offset = (Math.min(size - 1, y) * size + Math.min(size - 1, x)) * 3;
          luminance += frame[offset] + frame[offset + 1] + frame[offset + 2];
          count += 3;
        }
      }
      bits.push(luminance / count >= 128 ? 1 : 0);
    }
  }
  const expectedFinder = markerBits(0);
  for (let row = 0; row < 8; row += 1) {
    for (let column = 0; column < 8; column += 1) {
      if (row !== 0 && row !== 7 && column !== 0 && column !== 7) continue;
      const index = row * 8 + column;
      if (bits[index] !== expectedFinder[index]) throw new Error("embedded finder pattern mismatch");
    }
  }
  const payload = [];
  for (let row = 1; row < 7; row += 1) {
    for (let column = 1; column < 7; column += 1) payload.push(bits[row * 8 + column]);
  }
  const id = payload.slice(0, 16).reduce((value, bit) => value * 2 + bit, 0);
  const embeddedCrc = payload.slice(16, 24).reduce((value, bit) => value * 2 + bit, 0);
  if (crc8(id) !== embeddedCrc) throw new Error(`embedded CRC mismatch for ${id}`);
  return id;
}

function imageSignature(frame, width, height) {
  const signature = [];
  for (let blockY = 0; blockY < 16; blockY += 1) {
    const y0 = Math.floor(blockY * height / 16);
    const y1 = Math.floor((blockY + 1) * height / 16);
    for (let blockX = 0; blockX < 16; blockX += 1) {
      const x0 = Math.floor(blockX * width / 16);
      const x1 = Math.floor((blockX + 1) * width / 16);
      const sums = [0, 0, 0];
      let count = 0;
      for (let y = y0; y < y1; y += 1) {
        for (let x = x0; x < x1; x += 1) {
          const offset = (y * width + x) * 3;
          sums[0] += frame[offset];
          sums[1] += frame[offset + 1];
          sums[2] += frame[offset + 2];
          count += 1;
        }
      }
      signature.push(...sums.map((sum) => Math.floor((sum + count / 2) / count)));
    }
  }
  return signature;
}

function markerFromCanonicalFrame(frame, width) {
  const markerSize = marker.cells * marker.cellSize;
  const markerFrameBytes = Buffer.allocUnsafe(markerSize * markerSize * 3);
  const rowBytes = markerSize * 3;
  for (let y = 0; y < markerSize; y += 1) {
    const sourceStart = ((marker.y + y) * width + marker.x) * 3;
    frame.copy(markerFrameBytes, y * rowBytes, sourceStart, sourceStart + rowBytes);
  }
  return markerFrameBytes;
}

async function decodeProbes(path, spec) {
  const args = [
    "-hide_banner", "-loglevel", "error", "-noautorotate", "-i", path,
    "-map", "0:v:0", "-an", "-vf", `crop=${spec.width}:${spec.height}:0:0,scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24`,
    "-fps_mode", "passthrough", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1",
  ];
  const child = spawn(ffmpeg, args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const completion = new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("close", (code) => code === 0
      ? resolvePromise()
      : rejectPromise(new Error(`ffmpeg decode failed (${code}): ${stderr}`)));
  });
  const frameBytes = spec.width * spec.height * 3;
  const frame = Buffer.allocUnsafe(frameBytes);
  const probes = [];
  let frameOffset = 0;
  try {
    for await (const chunk of child.stdout) {
      let chunkOffset = 0;
      while (chunkOffset < chunk.length) {
        const count = Math.min(frameBytes - frameOffset, chunk.length - chunkOffset);
        chunk.copy(frame, frameOffset, chunkOffset, chunkOffset + count);
        frameOffset += count;
        chunkOffset += count;
        if (frameOffset === frameBytes) {
          probes.push({
            embeddedFrameId: decodeMarker(markerFromCanonicalFrame(frame, spec.width)),
            imageSignature: imageSignature(frame, spec.width, spec.height),
          });
          frameOffset = 0;
        }
      }
    }
    await completion;
  } catch (error) {
    child.kill();
    await completion.catch(() => {});
    throw error;
  }
  if (frameOffset !== 0 || probes.length !== spec.frames) {
    throw new Error(`${spec.basename}: canonical decode count ${probes.length}, trailing bytes ${frameOffset}`);
  }
  return probes;
}

async function writeGolden(spec, path, goldenPath) {
  const result = probe(path);
  const stream = result.streams[0];
  const codedWidth = Number(stream.coded_width || stream.width);
  const codedHeight = Number(stream.coded_height || stream.height);
  const visibleWidth = Number(stream.width);
  const visibleHeight = Number(stream.height);
  if (visibleWidth !== spec.width || visibleHeight !== spec.height || codedWidth < visibleWidth || codedHeight < visibleHeight) {
    throw new Error(`${spec.basename}: coded/visible size ${codedWidth}x${codedHeight}/${visibleWidth}x${visibleHeight}`);
  }
  if (result.frames.length !== spec.frames) {
    throw new Error(`${spec.basename}: expected ${spec.frames} frames, found ${result.frames.length}`);
  }
  const probes = await decodeProbes(path, spec);
  const packetsByPts = new Map();
  result.packets.forEach((packet, sampleOrdinal) => {
    const values = packetsByPts.get(packet.pts) ?? [];
    values.push({ sampleOrdinal, sync: String(packet.flags || "").includes("K") });
    packetsByPts.set(packet.pts, values);
  });
  const packetCursors = new Map();
  const indexed = result.frames.map((frame, decodeIndex) => {
    const cursor = packetCursors.get(frame.pts) ?? 0;
    const packet = packetsByPts.get(frame.pts)?.[cursor];
    if (!packet) throw new Error(`${spec.basename}: frame PTS ${frame.pts} has no packet`);
    packetCursors.set(frame.pts, cursor + 1);
    return {
      ptsUs: rescaleToUs(frame.pts, stream.time_base),
      sampleOrdinal: packet.sampleOrdinal,
      sync: packet.sync || frame.key_frame === 1,
      decodeIndex,
    };
  });
  indexed.sort((left, right) => left.ptsUs - right.ptsUs || left.sampleOrdinal - right.sampleOrdinal);
  const duplicateCounts = new Map();
  const frames = indexed.map((entry, displayFrameIndex) => {
    const duplicateOrdinal = duplicateCounts.get(entry.ptsUs) ?? 0;
    duplicateCounts.set(entry.ptsUs, duplicateOrdinal + 1);
    const probe = probes[entry.decodeIndex];
    const expectedId = spec.idBase + entry.decodeIndex;
    if (probe.embeddedFrameId !== expectedId) {
      throw new Error(`${spec.basename}: embedded ID ${probe.embeddedFrameId} != ${expectedId}`);
    }
    return {
      displayFrameIndex,
      ptsUs: entry.ptsUs,
      duplicateOrdinal,
      sampleOrdinal: entry.sampleOrdinal,
      embeddedFrameId: probe.embeddedFrameId,
      sync: entry.sync,
      imageSignature: probe.imageSignature,
    };
  });
  const golden = {
    schemaVersion: 1,
    fixture: `${spec.basename}.mp4`,
    sourceSha256: sha256File(path),
    codec: stream.codec_name,
    profile: stream.profile,
    codedWidth,
    codedHeight,
    crop: { left: 0, top: 0, right: visibleWidth - 1, bottom: visibleHeight - 1 },
    rotationDegrees: 0,
    pixelAspectRatio: { numerator: 1, denominator: 1 },
    frameCount: frames.length,
    frames,
  };
  writeFileSync(goldenPath, `${JSON.stringify(golden)}\n`);
  return golden;
}

function fixtureSpecForManifest(spec) {
  return {
    basename: spec.basename,
    visibleWidth: spec.width,
    visibleHeight: spec.height,
    canonicalWidth: spec.width,
    canonicalHeight: spec.height,
    frameCount: spec.frames,
    fps,
    codec: spec.codec,
    profile: spec.profile,
    encoder: spec.encoder,
    gop: spec.gop,
    bFrames: spec.bFrames,
    variableFrameRate: spec.vfr === true,
    embeddedFrameIdBase: spec.idBase,
  };
}

function verifyHost() {
  const version = firstLine(ffmpeg, ["-version"]);
  if (!version.includes("n8.1.2-21-gce3c09c101")) throw new Error(`unexpected FFmpeg: ${version}`);
  const nvencHost = String(run("nvidia-smi", ["--query-gpu=name,driver_version", "--format=csv,noheader"])).trim();
  if (!nvencHost.includes("RTX 4080 SUPER")) throw new Error(`representative fixtures require the frozen RTX 4080 SUPER host, found: ${nvencHost}`);
  return {
    ffmpeg: version,
    ffprobe: firstLine(ffprobe, ["-version"]),
    ffmpegExecutableSha256: sha256File(ffmpeg),
    ffprobeExecutableSha256: sha256File(ffprobe),
    distributionArchive: archive,
    nvencHost,
  };
}

function replaceOutput(stagingDir, force) {
  if (statExists(outputDir)) {
    if (!force) throw new Error(`${relative(root, outputDir)} already exists; verify it or pass --force to replace it`);
    const safeRoot = `${resolve(generatedRoot)}\\`;
    if (!`${resolve(outputDir)}\\`.startsWith(safeRoot)) throw new Error("refusing to replace output outside android/.generated/testdata");
    rmSync(outputDir, { recursive: true, force: true });
  }
  renameSync(stagingDir, outputDir);
}

function statExists(path) {
  try {
    statSync(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function main() {
  const force = process.argv.includes("--force");
  const toolchain = verifyHost();
  mkdirSync(generatedRoot, { recursive: true });
  const stagingDir = join(generatedRoot, `.representative-resolution-${process.pid}`);
  if (statExists(stagingDir)) rmSync(stagingDir, { recursive: true, force: true });
  mkdirSync(stagingDir, { recursive: true });
  const records = [];
  try {
    for (const spec of fixtures) {
      console.log(`generating ${spec.basename} (${spec.width}x${spec.height}, ${spec.frames} frames)`);
      const path = join(stagingDir, `${spec.basename}.mp4`);
      const goldenPath = join(stagingDir, `${spec.basename}.json`);
      const args = await encode(spec, path);
      const golden = await writeGolden(spec, path, goldenPath);
      records.push({
        ...fixtureSpecForManifest(spec),
        codedWidth: golden.codedWidth,
        codedHeight: golden.codedHeight,
        crop: golden.crop,
        fixture: `${spec.basename}.mp4`,
        golden: `${spec.basename}.json`,
        sourceSha256: golden.sourceSha256,
        sourceBytes: statSync(path).size,
        goldenSha256: sha256File(goldenPath),
        goldenBytes: statSync(goldenPath).size,
        command: redactArgs(args, path),
      });
    }
    const generatorSha256 = sha256File(fileURLToPath(import.meta.url));
    const artifactSetSha256 = sha256Bytes(Buffer.from(JSON.stringify(records.map((record) => ({
      fixture: record.fixture,
      sourceSha256: record.sourceSha256,
      sourceBytes: record.sourceBytes,
      golden: record.golden,
      goldenSha256: record.goldenSha256,
      goldenBytes: record.goldenBytes,
    })))));
    const manifest = {
      schemaVersion: 1,
      status: "LOCKED",
      syntheticOnly: true,
      generatedAssetsTracked: false,
      generator: "android/tools/generate-representative-resolution-fixtures.mjs",
      generatorSha256,
      outputDirectory: "android/.generated/testdata/representative-resolution",
      marker: { ...marker, payload: "16-bit frame ID + CRC-8/0x07 + fixed finder pattern" },
      colorPolicy: {
        standard: "BT.709",
        range: "limited",
        transfer: "BT.709",
        primaries: "BT.709",
        metadataRequired: true,
      },
      longHoldPolicy: {
        mode: "segmented",
        reason: "360 frames at the product 50 ms repeat interval cannot sustain a single 60-second +1/+5 hold; measured hold windows must be segmented and boundary transitions excluded from interval metrics.",
      },
      toolchain,
      artifactSetSha256,
      cache: {
        key: `ccr-representative-resolution-v1-${artifactSetSha256}`,
        restoreKeysAllowed: false,
        verifyAfterRestore: "node android/tools/verify-representative-resolution-fixtures.mjs",
      },
      fixtures: records,
    };
    writeFileSync(join(stagingDir, "manifest.generated.json"), `${JSON.stringify(manifest, null, 2)}\n`);
    replaceOutput(stagingDir, force);
    mkdirSync(dirname(lockPath), { recursive: true });
    writeFileSync(lockPath, `${JSON.stringify(manifest, null, 2)}\n`);
    console.log(`generated ${records.length} representative-resolution fixtures`);
    console.log(`cache key: ${manifest.cache.key}`);
  } catch (error) {
    rmSync(stagingDir, { recursive: true, force: true });
    throw error;
  }
}

await main();
