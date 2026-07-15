import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const fixtureDir = resolve(toolDir, "../testdata/frame-accuracy");
const required = [
  "h264-ip", "h264-bframes", "vfr", "long-gop", "nonzero-pts", "one-frame", "two-frame",
  "short-last-gop", "rotation-90", "rotation-180", "rotation-270", "hevc-main8", "burst",
  "switch-a", "switch-b", "par-8-9",
];

function fail(message) {
  throw new Error(`frame-accuracy verification failed: ${message}`);
}

for (const name of required) {
  const mp4Path = join(fixtureDir, `${name}.mp4`);
  const jsonPath = join(fixtureDir, `${name}.json`);
  const golden = JSON.parse(readFileSync(jsonPath, "utf8"));
  const sha = createHash("sha256").update(readFileSync(mp4Path)).digest("hex");
  if (golden.schemaVersion !== 1) fail(`${name}: schemaVersion`);
  if (golden.fixture !== `${name}.mp4`) fail(`${name}: fixture name`);
  if (golden.sourceSha256 !== sha) fail(`${name}: sourceSha256`);
  if (!["h264", "hevc"].includes(golden.codec)) fail(`${name}: codec`);
  if (!Number.isInteger(golden.codedWidth) || !Number.isInteger(golden.codedHeight)) fail(`${name}: coded size`);
  const { left, top, right, bottom } = golden.crop ?? {};
  if (![left, top, right, bottom].every(Number.isInteger) || right < left || bottom < top) fail(`${name}: inclusive crop`);
  if (![0, 90, 180, 270].includes(golden.rotationDegrees)) fail(`${name}: rotation`);
  if (golden.pixelAspectRatio?.numerator <= 0 || golden.pixelAspectRatio?.denominator <= 0) fail(`${name}: PAR`);
  if (golden.frameCount !== golden.frames?.length || golden.frameCount < 1) fail(`${name}: frameCount`);
  const keys = new Set();
  golden.frames.forEach((frame, index) => {
    if (frame.displayFrameIndex !== index) fail(`${name}: displayFrameIndex ${index}`);
    if (!Number.isSafeInteger(frame.ptsUs) || !Number.isInteger(frame.duplicateOrdinal)) fail(`${name}: frame key ${index}`);
    if (!Number.isInteger(frame.sampleOrdinal) || !Number.isInteger(frame.embeddedFrameId)) fail(`${name}: identity ${index}`);
    if (typeof frame.sync !== "boolean") fail(`${name}: sync ${index}`);
    if (!Array.isArray(frame.imageSignature) || frame.imageSignature.length !== 16 * 16 * 3) fail(`${name}: signature ${index}`);
    if (frame.imageSignature.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) fail(`${name}: signature value ${index}`);
    const key = `${frame.ptsUs}:${frame.duplicateOrdinal}`;
    if (keys.has(key)) fail(`${name}: duplicate FrameKey ${key}`);
    keys.add(key);
  });
}

const mp4Names = readdirSync(fixtureDir).filter((name) => name.endsWith(".mp4")).sort();
const expectedNames = required.map((name) => `${name}.mp4`).sort();
if (JSON.stringify(mp4Names) !== JSON.stringify(expectedNames)) fail("unexpected or missing MP4 fixture");
const provenance = JSON.parse(readFileSync(join(fixtureDir, "provenance.json"), "utf8"));
if (provenance.schemaVersion !== 1 || provenance.syntheticOnly !== true) fail("provenance contract");
if (!String(provenance.ffmpeg).includes("n8.1.2-21-gce3c09c101")) fail("FFmpeg version pin");
if (!String(provenance.nvencHost).includes("RTX 4080 SUPER")) fail("NVENC provenance");
const reportFormat = JSON.parse(readFileSync(join(fixtureDir, "s24-report-format.json"), "utf8"));
if (reportFormat.schemaVersion !== 2 || !String(reportFormat.status).startsWith("Pending")) fail("pending report format");
for (const field of [
  "publishedSwaps", "staleBeforeSwap", "swapFailures", "surfaceInvalid",
  "publicationInvariantViolations", "outputFormatChanges", "configuredOutputMetadata",
  "decodedOutputFormatHistory", "fullFrameReadbacks",
]) {
  if (!(field in reportFormat.decoder)) fail(`pending report decoder field ${field}`);
}
console.log(`verified ${required.length} synthetic frame-accuracy fixtures`);
