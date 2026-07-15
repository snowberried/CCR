import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const toolDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(toolDir, "../..");
const outputDir = join(root, "android/testdata/frame-accuracy");
const ffmpeg = join(root, "tools/ffmpeg/bin/ffmpeg.exe");
const ffprobe = join(root, "tools/ffmpeg/bin/ffprobe.exe");
const width = 256;
const height = 144;
const fps = 12;
const marker = { x: 8, y: 8, cells: 8, cellSize: 12 };

const fixtures = [
  { fixture: "h264-ip", frames: 12, seed: 1, encoder: "openh264", gop: 12 },
  { fixture: "h264-bframes", frames: 20, seed: 2, encoder: "nvenc", gop: 12, bFrames: 2 },
  { fixture: "vfr", frames: 12, seed: 3, encoder: "openh264", gop: 12, vfr: true },
  { fixture: "long-gop", frames: 36, seed: 4, encoder: "openh264", gop: 60 },
  { fixture: "nonzero-pts", frames: 12, seed: 5, encoder: "openh264", gop: 12, ptsOffsetSeconds: 2 },
  { fixture: "one-frame", frames: 1, seed: 6, encoder: "openh264", gop: 12 },
  { fixture: "two-frame", frames: 2, seed: 7, encoder: "openh264", gop: 12 },
  { fixture: "short-last-gop", frames: 17, seed: 8, encoder: "openh264", gop: 12 },
  { fixture: "rotation-90", frames: 8, seed: 9, encoder: "openh264", gop: 8, rotation: 90 },
  { fixture: "rotation-180", frames: 8, seed: 10, encoder: "openh264", gop: 8, rotation: 180 },
  { fixture: "rotation-270", frames: 8, seed: 11, encoder: "openh264", gop: 8, rotation: 270 },
  { fixture: "hevc-main8", frames: 12, seed: 12, encoder: "kvazaar", gop: 12 },
  { fixture: "burst", frames: 48, seed: 13, encoder: "openh264", gop: 24 },
  { fixture: "switch-a", frames: 12, seed: 14, encoder: "openh264", gop: 12 },
  { fixture: "switch-b", frames: 12, seed: 15, encoder: "openh264", gop: 12 },
  { fixture: "par-8-9", frames: 8, seed: 16, encoder: "openh264", gop: 8, sar: [8, 9] },
];

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    cwd: root,
    encoding: options.binary ? null : "utf8",
    input: options.input,
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : result.stderr;
    throw new Error(`${relative(root, executable)} failed (${result.status}): ${stderr}`);
  }
  return result.stdout;
}

function crc8(value) {
  let crc = 0;
  for (const byte of [(value >>> 8) & 0xff, value & 0xff]) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
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

function embeddedId(spec, index) {
  return spec.seed * 100 + index;
}

function makeFrame(spec, index) {
  const frame = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 3;
      frame[offset] = (32 + spec.seed * 9 + index * 13 + x) % 208 + 24;
      frame[offset + 1] = (48 + spec.seed * 7 + index * 17 + y * 2) % 192 + 32;
      frame[offset + 2] = (64 + spec.seed * 5 + index * 19 + Math.floor(x / 8) * 7) % 176 + 40;
    }
  }
  const bits = markerBits(embeddedId(spec, index));
  for (let row = 0; row < marker.cells; row += 1) {
    for (let column = 0; column < marker.cells; column += 1) {
      const value = bits[row * marker.cells + column] ? 240 : 16;
      for (let dy = 0; dy < marker.cellSize; dy += 1) {
        for (let dx = 0; dx < marker.cellSize; dx += 1) {
          const x = marker.x + column * marker.cellSize + dx;
          const y = marker.y + row * marker.cellSize + dy;
          const offset = (y * width + x) * 3;
          frame[offset] = value;
          frame[offset + 1] = value;
          frame[offset + 2] = value;
        }
      }
    }
  }
  return frame;
}

function encoderArgs(spec) {
  if (spec.encoder === "nvenc") {
    return ["-c:v", "h264_nvenc", "-preset", "p7", "-tune", "hq", "-rc", "constqp", "-qp", "18", "-profile:v", "main", "-g", String(spec.gop), "-bf", String(spec.bFrames), "-pix_fmt", "yuv420p"];
  }
  if (spec.encoder === "kvazaar") {
    return ["-c:v", "libkvazaar", "-qp", "18", "-g", String(spec.gop), "-pix_fmt", "yuv420p"];
  }
  return ["-c:v", "libopenh264", "-profile:v", "66", "-g", String(spec.gop), "-bf", "0", "-b:v", "1200k", "-pix_fmt", "yuv420p"];
}

function encode(spec) {
  const finalPath = join(outputDir, `${spec.fixture}.mp4`);
  const encodedPath = spec.rotation ? join(outputDir, `${spec.fixture}.base.mp4`) : finalPath;
  const filters = [];
  if (spec.vfr) filters.push("setpts=(N+floor(N/3))/(12*TB)");
  if (spec.ptsOffsetSeconds) filters.push(`setpts=PTS+${spec.ptsOffsetSeconds}/TB`);
  if (spec.sar) filters.push(`setsar=${spec.sar[0]}/${spec.sar[1]}`);
  const args = [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", `${width}x${height}`, "-r", String(fps), "-i", "pipe:0",
    "-an",
    ...(filters.length ? ["-vf", filters.join(",")] : []),
    ...(spec.vfr ? ["-fps_mode", "vfr"] : []),
    ...encoderArgs(spec),
    "-video_track_timescale", "12000", "-movflags", "+faststart", encodedPath,
  ];
  const input = Buffer.concat(Array.from({ length: spec.frames }, (_, index) => makeFrame(spec, index)));
  run(ffmpeg, args, { input });
  const commands = [{ purpose: "encode", args: redactCommand(args, encodedPath) }];
  if (spec.rotation) {
    const rotationArgs = ["-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0", String(spec.rotation), "-i", encodedPath, "-map", "0:v:0", "-c", "copy", finalPath];
    run(ffmpeg, rotationArgs);
    rmSync(encodedPath);
    commands.push({ purpose: "rotation metadata remux", args: redactCommand(rotationArgs, encodedPath, finalPath) });
  }
  return commands;
}

function redactCommand(args, ...paths) {
  const replacements = new Map(paths.map((path, index) => [path, index === paths.length - 1 ? "<fixture.mp4>" : "<temporary.mp4>"]));
  return args.map((arg) => replacements.get(arg) ?? arg).map((arg) => arg === "pipe:0" ? "pipe:<synthetic-rgb>" : arg);
}

function normalizeRotation(value) {
  return ((Number(value || 0) % 360) + 360) % 360;
}

function parseRatio(value) {
  if (!value || value === "N/A") return [1, 1];
  const [numerator, denominator] = value.split(":").map(Number);
  return numerator > 0 && denominator > 0 ? [numerator, denominator] : [1, 1];
}

function rescaleToUs(rawPts, timeBase) {
  const [numerator, denominator] = timeBase.split("/").map(BigInt);
  return Number(BigInt(rawPts) * numerator * 1_000_000n / denominator);
}

function probe(path) {
  const entries = "stream=codec_name,profile,width,height,coded_width,coded_height,time_base,sample_aspect_ratio:stream_side_data=rotation:packet=pts,flags:frame=pts,key_frame";
  const result = JSON.parse(run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_streams", "-show_packets", "-show_frames", "-show_entries", entries, "-of", "json", path]));
  const combined = result.packets_and_frames ?? [];
  result.packets = result.packets ?? combined.filter((entry) => entry.type === "packet");
  result.frames = result.frames ?? combined.filter((entry) => entry.type === "frame");
  return result;
}

function canonicalGeometry(stream, rotation) {
  const codedWidth = Number(stream.coded_width || stream.width);
  const codedHeight = Number(stream.coded_height || stream.height);
  const [parWidth, parHeight] = parseRatio(stream.sample_aspect_ratio);
  const squareWidth = Math.max(1, Math.floor((codedWidth * parWidth + parHeight / 2) / parHeight));
  return {
    codedWidth,
    codedHeight,
    crop: { left: 0, top: 0, right: codedWidth - 1, bottom: codedHeight - 1 },
    parWidth,
    parHeight,
    preWidth: squareWidth,
    preHeight: codedHeight,
    width: rotation === 90 || rotation === 270 ? codedHeight : squareWidth,
    height: rotation === 90 || rotation === 270 ? squareWidth : codedHeight,
  };
}

function decodeCanonical(path, geometry, rotation) {
  const filters = [`crop=${geometry.codedWidth}:${geometry.codedHeight}:0:0`];
  if (geometry.preWidth !== geometry.codedWidth) filters.push(`scale=${geometry.preWidth}:${geometry.preHeight}:flags=bilinear`);
  if (rotation === 90) filters.push("transpose=clock");
  if (rotation === 180) filters.push("hflip", "vflip");
  if (rotation === 270) filters.push("transpose=cclock");
  return run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-noautorotate", "-i", path, "-map", "0:v:0", "-an", "-vf", filters.join(","), "-fps_mode", "passthrough", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], { binary: true });
}

function imageSignature(frame, frameWidth, frameHeight) {
  const signature = [];
  for (let blockY = 0; blockY < 16; blockY += 1) {
    const y0 = Math.floor(blockY * frameHeight / 16);
    const y1 = Math.floor((blockY + 1) * frameHeight / 16);
    for (let blockX = 0; blockX < 16; blockX += 1) {
      const x0 = Math.floor(blockX * frameWidth / 16);
      const x1 = Math.floor((blockX + 1) * frameWidth / 16);
      const sums = [0, 0, 0];
      let count = 0;
      for (let y = y0; y < y1; y += 1) {
        for (let x = x0; x < x1; x += 1) {
          const offset = (y * frameWidth + x) * 3;
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

function canonicalPoint(sourceX, sourceY, geometry, rotation) {
  const x = (sourceX + 0.5) * geometry.preWidth / geometry.codedWidth - 0.5;
  const y = sourceY;
  if (rotation === 90) return [geometry.preHeight - 1 - y, x];
  if (rotation === 180) return [geometry.preWidth - 1 - x, geometry.preHeight - 1 - y];
  if (rotation === 270) return [y, geometry.preWidth - 1 - x];
  return [x, y];
}

function decodeMarker(frame, geometry, rotation) {
  const bits = [];
  for (let row = 0; row < marker.cells; row += 1) {
    for (let column = 0; column < marker.cells; column += 1) {
      let luminance = 0;
      let count = 0;
      for (const fractionY of [0.3, 0.5, 0.7]) {
        for (const fractionX of [0.3, 0.5, 0.7]) {
          const sourceX = marker.x + (column + fractionX) * marker.cellSize;
          const sourceY = marker.y + (row + fractionY) * marker.cellSize;
          const [canonicalX, canonicalY] = canonicalPoint(sourceX, sourceY, geometry, rotation);
          const x = Math.max(0, Math.min(geometry.width - 1, Math.round(canonicalX)));
          const y = Math.max(0, Math.min(geometry.height - 1, Math.round(canonicalY)));
          const offset = (y * geometry.width + x) * 3;
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
  for (let row = 1; row < 7; row += 1) for (let column = 1; column < 7; column += 1) payload.push(bits[row * 8 + column]);
  const id = payload.slice(0, 16).reduce((value, bit) => value * 2 + bit, 0);
  const embeddedCrc = payload.slice(16, 24).reduce((value, bit) => value * 2 + bit, 0);
  if (crc8(id) !== embeddedCrc) throw new Error(`embedded CRC mismatch for ${id}`);
  return id;
}

function writeGolden(spec, commands) {
  const path = join(outputDir, `${spec.fixture}.mp4`);
  const result = probe(path);
  const stream = result.streams[0];
  const rotation = normalizeRotation(stream.side_data_list?.find((entry) => entry.rotation !== undefined)?.rotation ?? spec.rotation);
  const geometry = canonicalGeometry(stream, rotation);
  const decoded = decodeCanonical(path, geometry, rotation);
  const frameBytes = geometry.width * geometry.height * 3;
  if (decoded.length % frameBytes !== 0) throw new Error(`${spec.fixture}: invalid decoded byte length`);
  const decodedCount = decoded.length / frameBytes;
  if (decodedCount !== spec.frames) throw new Error(`${spec.fixture}: expected ${spec.frames} decoded frames, found ${decodedCount}`);

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
    if (!packet) throw new Error(`${spec.fixture}: frame PTS ${frame.pts} has no packet`);
    packetCursors.set(frame.pts, cursor + 1);
    return { rawPts: frame.pts, ptsUs: rescaleToUs(frame.pts, stream.time_base), sampleOrdinal: packet.sampleOrdinal, sync: packet.sync || frame.key_frame === 1, decodeIndex };
  });
  indexed.sort((left, right) => left.ptsUs - right.ptsUs || left.sampleOrdinal - right.sampleOrdinal);
  const duplicateCounts = new Map();
  const frames = indexed.map((entry, displayFrameIndex) => {
    const duplicateOrdinal = duplicateCounts.get(entry.ptsUs) ?? 0;
    duplicateCounts.set(entry.ptsUs, duplicateOrdinal + 1);
    const raw = decoded.subarray(entry.decodeIndex * frameBytes, (entry.decodeIndex + 1) * frameBytes);
    const actualId = decodeMarker(raw, geometry, rotation);
    const expectedId = embeddedId(spec, entry.decodeIndex);
    if (actualId !== expectedId) throw new Error(`${spec.fixture}: embedded ID ${actualId} != ${expectedId}`);
    return {
      displayFrameIndex,
      ptsUs: entry.ptsUs,
      duplicateOrdinal,
      sampleOrdinal: entry.sampleOrdinal,
      embeddedFrameId: actualId,
      sync: entry.sync,
      imageSignature: imageSignature(raw, geometry.width, geometry.height),
    };
  });
  const sourceSha256 = createHash("sha256").update(readFileSync(path)).digest("hex");
  const golden = {
    schemaVersion: 1,
    fixture: `${spec.fixture}.mp4`,
    sourceSha256,
    codec: stream.codec_name,
    profile: stream.profile,
    codedWidth: geometry.codedWidth,
    codedHeight: geometry.codedHeight,
    crop: geometry.crop,
    rotationDegrees: rotation,
    pixelAspectRatio: { numerator: geometry.parWidth, denominator: geometry.parHeight },
    frameCount: frames.length,
    frames,
  };
  writeFileSync(join(outputDir, `${spec.fixture}.json`), `${JSON.stringify(golden)}\n`);
  return { fixture: golden.fixture, golden: `${spec.fixture}.json`, sourceSha256, commands };
}

function firstLine(executable, args) {
  return String(run(executable, args)).split(/\r?\n/, 1)[0];
}

mkdirSync(outputDir, { recursive: true });
if (process.argv.includes("--compact-existing")) {
  for (const spec of fixtures) {
    const path = join(outputDir, `${spec.fixture}.json`);
    writeFileSync(path, `${JSON.stringify(JSON.parse(readFileSync(path, "utf8")))}\n`);
  }
  console.log(`compacted ${fixtures.length} existing golden JSON files without re-encoding`);
  process.exit(0);
}
for (const file of fixtures.flatMap((spec) => [`${spec.fixture}.mp4`, `${spec.fixture}.json`, `${spec.fixture}.base.mp4`])) rmSync(join(outputDir, file), { force: true });
const records = [];
for (const spec of fixtures) records.push(writeGolden(spec, encode(spec)));
const gpu = run("nvidia-smi", ["--query-gpu=name,driver_version", "--format=csv,noheader"]).trim();
const provenance = {
  schemaVersion: 1,
  syntheticOnly: true,
  generator: "android/tools/generate-frame-accuracy-fixtures.mjs",
  ffmpeg: firstLine(ffmpeg, ["-version"]),
  ffprobe: firstLine(ffprobe, ["-version"]),
  nvencHost: gpu,
  marker: { ...marker, payload: "16-bit frame ID + CRC-8/0x07 + fixed finder pattern" },
  fixtures: records,
};
writeFileSync(join(outputDir, "provenance.json"), `${JSON.stringify(provenance, null, 2)}\n`);
writeFileSync(join(outputDir, "README.md"), "# Frame Accuracy Fixtures\n\n비식별 합성 RGB 패턴만 포함한다. 실제 사용자 영상과 파일명은 포함하지 않는다. MP4는 고정 파일이며 CI에서 재인코딩하지 않는다.\n");
console.log(`generated ${records.length} fixtures in ${relative(root, outputDir)}`);
