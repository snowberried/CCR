import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const androidRoot = resolve(toolDir, "..");
const repoRoot = resolve(androidRoot, "..");
const manifest = readFileSync(resolve(androidRoot, "app/src/main/AndroidManifest.xml"), "utf8");
const build = readFileSync(resolve(androidRoot, "app/build.gradle.kts"), "utf8");
const session = readFileSync(
  resolve(androidRoot, "app/src/main/java/com/snowberried/ctcinereviewer/media/ExactFrameSession.kt"),
  "utf8",
);
const provider = readFileSync(
  resolve(androidRoot, "app/src/debug/java/com/snowberried/ctcinereviewer/gate/ReadOnlyFixtureProvider.kt"),
  "utf8",
);
const signingExample = readFileSync(resolve(androidRoot, "signing.properties.example"), "utf8");
const gitignore = readFileSync(resolve(repoRoot, ".gitignore"), "utf8");
const workflow = readFileSync(resolve(repoRoot, ".github/workflows/android-ci.yml"), "utf8");
const baselineDir = resolve(
  androidRoot,
  "validation/device-baselines/sm-s928n-android16-2026-07-15",
);
const baselineReportBytes = readFileSync(resolve(baselineDir, "s24-frame-accuracy-report.sanitized.json"));
const baselineReportText = baselineReportBytes.toString("utf8");
const baselineReport = JSON.parse(baselineReportText);
const baselineReadme = readFileSync(resolve(baselineDir, "README.md"), "utf8");
const baselineChecksums = readFileSync(resolve(baselineDir, "checksums.sha256"), "utf8");
const localSampleReadme = readFileSync(resolve(repoRoot, "local-samples/README.md"), "utf8");
const localSampleExample = JSON.parse(
  readFileSync(resolve(repoRoot, "local-samples/manifest.example.json"), "utf8"),
);

function requireContract(condition, message) {
  if (!condition) throw new Error(`Android source contract failed: ${message}`);
}

for (const permission of ["INTERNET", "READ_MEDIA_VIDEO", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE"]) {
  requireContract(!manifest.includes(permission), `forbidden manifest permission ${permission}`);
}
for (const dependency of ["firebase", "analytics", "okhttp", "retrofit", "ktor-client", "sentry"]) {
  requireContract(!build.toLowerCase().includes(dependency), `external transmission dependency ${dependency}`);
}
requireContract(session.includes('openFileDescriptor(uri, "r")'), "source URI is not opened explicitly read-only");
requireContract(!/openFileDescriptor\([^\n]+,\s*"(?:w|rw|rwt|wa)"/.test(session), "write-capable source open mode");
requireContract(provider.includes("ParcelFileDescriptor.MODE_READ_ONLY"), "fixture provider is not read-only");
requireContract(provider.includes('if (mode != "r")'), "fixture provider does not reject write modes");
requireContract(/versionCode\s*=\s*3\b/.test(build), "versionCode is not 3");
requireContract(/versionName\s*=\s*"0\.2\.0-alpha\.2"/.test(build), "versionName is not 0.2.0-alpha.2");
requireContract(build.includes('applicationIdSuffix = ".internal"'), "internal application ID suffix is missing");
requireContract(
  build.includes('androidx.compose.material3.adaptive:adaptive:1.2.0'),
  "approved adaptive Compose dependency is missing",
);
requireContract(build.includes('create("internalRelease")'), "internalRelease signing config is missing");
for (const name of [
  "CCR_ANDROID_INTERNAL_KEYSTORE_PATH",
  "CCR_ANDROID_INTERNAL_KEYSTORE_PASSWORD",
  "CCR_ANDROID_INTERNAL_KEY_ALIAS",
  "CCR_ANDROID_INTERNAL_KEY_PASSWORD",
]) {
  requireContract(build.includes(name), `internal signing environment boundary ${name}`);
}
requireContract(!build.includes("CCR_ANDROID_KEYSTORE_"), "legacy generic signing environment boundary remains");
requireContract(signingExample.includes("internalStoreFile="), "internal signing example is missing");
requireContract(gitignore.split(/\r?\n/).includes("*.jks"), "recursive JKS ignore is missing");
requireContract(gitignore.split(/\r?\n/).includes("*.keystore"), "recursive keystore ignore is missing");
requireContract(gitignore.split(/\r?\n/).includes("signing.properties"), "recursive signing properties ignore is missing");
requireContract(workflow.includes('      - "codex/android-*"'), "Android CI codex/android-* push filter is missing");
requireContract(
  workflow.includes("name: ccr-android-0.2.0-alpha.1-internal"),
  "Android CI artifact identity is stale",
);

requireContract(baselineReport.status === "PASS", "frozen Gate 3 report is not PASS");
requireContract(
  baselineReport.baseline?.commit === "61e85dcec314b1ec94faf554262db8586abdef51",
  "frozen Gate 3 report points to the wrong commit",
);
const baselineEvidenceText = `${baselineReportText}\n${baselineReadme}\n${baselineChecksums}`;
for (const [pattern, label] of [
  [/[A-Za-z]:\\/, "Windows absolute path"],
  [/\/(?:Users|home)\//, "user-home absolute path"],
  [/"(?:serial|deviceSerial|patientName|patientId|accessionNumber)"\s*:/i, "identifier field"],
]) {
  requireContract(!pattern.test(baselineEvidenceText), `frozen Gate 3 evidence contains ${label}`);
}
const baselineReportSha = createHash("sha256").update(baselineReportBytes).digest("hex");
requireContract(
  baselineChecksums.split(/\r?\n/).includes(
    `${baselineReportSha}  s24-frame-accuracy-report.sanitized.json`,
  ),
  "frozen Gate 3 report checksum does not match",
);

for (const ignoreLine of [
  "local-samples/*",
  "!local-samples/README.md",
  "!local-samples/manifest.example.json",
]) {
  requireContract(gitignore.split(/\r?\n/).includes(ignoreLine), `local sample ignore contract ${ignoreLine}`);
}
requireContract(localSampleReadme.includes("실제 영상"), "local sample privacy guidance is missing");
for (const field of [
  "localFixtureId",
  "codec",
  "profile",
  "resolution",
  "rotationDegrees",
  "variableFrameRate",
  "expectedFrameCount",
  "referenceFrames",
]) {
  requireContract(Object.hasOwn(localSampleExample, field), `local sample manifest field ${field}`);
}
for (const forbiddenField of ["sha256", "fileName", "path", "contentUri"]) {
  requireContract(
    !Object.hasOwn(localSampleExample, forbiddenField),
    `tracked local sample example contains forbidden field ${forbiddenField}`,
  );
}
requireContract(
  localSampleExample.referenceFrames.every(
    (frame) => Number.isInteger(frame.displayFrameIndex) && Number.isInteger(frame.ptsUs),
  ),
  "local sample reference frame index/PTS contract",
);

console.log("verified Android 0.2.0-alpha.2 identity, frozen evidence privacy, CI, local sample, and signing contracts");
