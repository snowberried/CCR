import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(toolDir, "../..");
const fixtureDir = join(root, "android/.generated/testdata/representative-resolution");
const lockPath = join(root, "android/testdata/representative-resolution/manifest.lock.json");
const manifestOnly = process.argv.includes("--manifest-only");
const expected = [
  ["720p-h264-bframes", 1280, 720, "h264", "h264_nvenc", true],
  ["1080p-h264-bframes", 1920, 1080, "h264", "h264_nvenc", true],
  ["1080p-h264-long-gop", 1920, 1080, "h264", "h264_nvenc", false],
  ["1080p-hevc-main8", 1920, 1080, "hevc", "hevc_nvenc", false],
  ["1080p-vfr", 1920, 1080, "h264", "h264_nvenc", false],
  ["1080p-switch-a", 1920, 1080, "h264", "h264_nvenc", false],
  ["1080p-switch-b", 1920, 1080, "hevc", "hevc_nvenc", false],
];

function fail(message) {
  throw new Error(`representative-resolution verification failed: ${message}`);
}

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function artifactIdentity(record) {
  return {
    fixture: record.fixture,
    sourceSha256: record.sourceSha256,
    sourceBytes: record.sourceBytes,
    golden: record.golden,
    goldenSha256: record.goldenSha256,
    goldenBytes: record.goldenBytes,
  };
}

const lockText = readFileSync(lockPath, "utf8");
if (/[A-Za-z]:\\|\/(?:Users|home)\//.test(lockText)) fail("manifest contains an absolute user path");
if (/\"(?:patientName|patientId|accessionNumber|contentUri|fileName)\"\s*:/i.test(lockText)) fail("manifest contains an identifier field");
const lock = JSON.parse(lockText);
if (lock.schemaVersion !== 1 || lock.status !== "LOCKED" || lock.syntheticOnly !== true) fail("manifest lock status");
if (lock.generatedAssetsTracked !== false) fail("generated asset tracking contract");
if (lock.outputDirectory !== "android/.generated/testdata/representative-resolution") fail("output directory");
if (lock.generatorSha256 !== sha256File(join(root, lock.generator))) fail("generator identity");
if (lock.longHoldPolicy?.mode !== "segmented") fail("segmented long-hold provenance");
if (lock.cache?.restoreKeysAllowed !== false || !String(lock.cache?.key).startsWith("ccr-representative-resolution-v1-")) fail("cache contract");
if (!String(lock.toolchain?.ffmpeg).includes("n8.1.2-21-gce3c09c101")) fail("FFmpeg pin");
if (!String(lock.toolchain?.nvencHost).includes("RTX 4080 SUPER")) fail("NVENC host pin");
if (lock.fixtures?.length !== expected.length) fail("fixture manifest count");

const records = expected.map(([basename, width, height, codec, encoder], fixtureIndex) => {
  const record = lock.fixtures.find((entry) => entry.basename === basename);
  if (!record) fail(`${basename}: lock record`);
  if (record.visibleWidth !== width || record.visibleHeight !== height || record.frameCount !== 360 || record.fps !== 12) fail(`${basename}: fixed spec`);
  if (record.canonicalWidth !== width || record.canonicalHeight !== height) fail(`${basename}: canonical size`);
  if (!Number.isInteger(record.codedWidth) || !Number.isInteger(record.codedHeight) || record.codedWidth < width || record.codedHeight < height) fail(`${basename}: coded size`);
  if (JSON.stringify(record.crop) !== JSON.stringify({ left: 0, top: 0, right: width - 1, bottom: height - 1 })) fail(`${basename}: inclusive crop lock`);
  if (record.codec !== codec || record.profile !== "Main" || record.encoder !== encoder) fail(`${basename}: codec contract`);
  if (record.embeddedFrameIdBase !== 10000 + fixtureIndex * 1000) fail(`${basename}: embedded ID base`);
  if (!/^[a-f0-9]{64}$/.test(record.sourceSha256) || !/^[a-f0-9]{64}$/.test(record.goldenSha256)) fail(`${basename}: SHA format`);
  if (!Number.isSafeInteger(record.sourceBytes) || record.sourceBytes <= 0 || !Number.isSafeInteger(record.goldenBytes) || record.goldenBytes <= 0) fail(`${basename}: byte size`);
  if (!Array.isArray(record.command) || !record.command.includes(encoder) || record.command.some((value) => /[A-Za-z]:\\/.test(value))) fail(`${basename}: sanitized encoder command`);
  return record;
});

const artifactRecords = records.map(artifactIdentity);
const artifactSetSha256 = createHash("sha256").update(JSON.stringify(artifactRecords)).digest("hex");
if (artifactSetSha256 !== lock.artifactSetSha256) fail("artifact set SHA");
if (lock.cache.key !== `ccr-representative-resolution-v1-${artifactSetSha256}`) fail("cache key identity");

if (manifestOnly) {
  console.log(`verified representative-resolution manifest lock (${lock.cache.key})`);
  process.exit(0);
}

const generatedManifest = JSON.parse(readFileSync(join(fixtureDir, "manifest.generated.json"), "utf8"));
if (JSON.stringify(generatedManifest) !== JSON.stringify(lock)) fail("generated manifest differs from tracked lock");
const expectedFiles = new Set(["manifest.generated.json"]);

expected.forEach(([basename, width, height, codec, , expectReorder]) => {
  const record = records.find((entry) => entry.basename === basename);
  const mp4Path = join(fixtureDir, record.fixture);
  const jsonPath = join(fixtureDir, record.golden);
  expectedFiles.add(record.fixture);
  expectedFiles.add(record.golden);
  if (statSync(mp4Path).size !== record.sourceBytes || sha256File(mp4Path) !== record.sourceSha256) fail(`${basename}: MP4 identity`);
  if (statSync(jsonPath).size !== record.goldenBytes || sha256File(jsonPath) !== record.goldenSha256) fail(`${basename}: golden identity`);
  const golden = JSON.parse(readFileSync(jsonPath, "utf8"));
  if (golden.schemaVersion !== 1 || golden.fixture !== record.fixture || golden.sourceSha256 !== record.sourceSha256) fail(`${basename}: golden header`);
  if (golden.codec !== codec || golden.profile !== "Main") fail(`${basename}: probed codec/profile`);
  if (golden.codedWidth !== record.codedWidth || golden.codedHeight !== record.codedHeight) fail(`${basename}: golden coded size`);
  if (JSON.stringify(golden.crop) !== JSON.stringify(record.crop)) fail(`${basename}: inclusive crop golden`);
  if (golden.rotationDegrees !== 0 || golden.pixelAspectRatio?.numerator !== 1 || golden.pixelAspectRatio?.denominator !== 1) fail(`${basename}: rotation/PAR`);
  if (golden.frameCount !== 360 || golden.frames?.length !== 360) fail(`${basename}: frame count`);
  const keys = new Set();
  const ids = new Set();
  const duplicateCounts = new Map();
  golden.frames.forEach((frame, index) => {
    if (frame.displayFrameIndex !== index) fail(`${basename}: display index ${index}`);
    if (!Number.isSafeInteger(frame.ptsUs) || !Number.isInteger(frame.sampleOrdinal)) fail(`${basename}: PTS/sample ${index}`);
    const duplicateOrdinal = duplicateCounts.get(frame.ptsUs) ?? 0;
    if (frame.duplicateOrdinal !== duplicateOrdinal) fail(`${basename}: duplicate ordinal ${index}`);
    duplicateCounts.set(frame.ptsUs, duplicateOrdinal + 1);
    const key = `${frame.ptsUs}:${frame.duplicateOrdinal}`;
    if (keys.has(key)) fail(`${basename}: duplicate FrameKey ${key}`);
    keys.add(key);
    if (!Number.isInteger(frame.embeddedFrameId) || ids.has(frame.embeddedFrameId)) fail(`${basename}: embedded ID ${index}`);
    ids.add(frame.embeddedFrameId);
    if (typeof frame.sync !== "boolean") fail(`${basename}: sync ${index}`);
    if (!Array.isArray(frame.imageSignature) || frame.imageSignature.length !== 768) fail(`${basename}: signature ${index}`);
    if (frame.imageSignature.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) fail(`${basename}: signature value ${index}`);
  });
  if (!golden.frames.some((frame) => frame.sync)) fail(`${basename}: no sync sample`);
  const reordered = golden.frames.some((frame, index, frames) => index > 0 && frame.sampleOrdinal < frames[index - 1].sampleOrdinal);
  if (expectReorder && !reordered) fail(`${basename}: no B-frame reorder boundary`);
  if (basename === "1080p-h264-long-gop") {
    const syncIndices = golden.frames.filter((frame) => frame.sync).map((frame) => frame.displayFrameIndex);
    if (syncIndices.length > 2 || (syncIndices[1] !== undefined && syncIndices[1] < 200)) fail(`${basename}: GOP is not long`);
  }
  if (basename === "1080p-vfr") {
    const deltas = golden.frames.slice(1).map((frame, index) => frame.ptsUs - golden.frames[index].ptsUs);
    const cadence = deltas.map((delta, index) => {
      if (delta === 83_333 || delta === 83_334) return 12;
      if (delta === 166_666 || delta === 166_667) return 6;
      fail(`${basename}: unexpected cadence delta ${delta} at interval ${index}`);
    });
    const transitions = cadence.slice(1)
      .map((value, index) => value === cadence[index] ? null : index + 1)
      .filter((value) => value !== null);
    if (JSON.stringify(transitions) !== JSON.stringify([120, 240])) {
      fail(`${basename}: expected two cadence transitions after intervals 120 and 240`);
    }
  }
});

const actualFiles = readdirSync(fixtureDir).sort();
const allowedFiles = [...expectedFiles].sort();
if (JSON.stringify(actualFiles) !== JSON.stringify(allowedFiles)) fail("unexpected or missing generated file");

console.log(`verified ${expected.length} representative-resolution fixtures (${lock.cache.key})`);
