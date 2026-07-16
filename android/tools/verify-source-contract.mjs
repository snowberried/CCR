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
const gitAttributes = readFileSync(resolve(repoRoot, ".gitattributes"), "utf8");
const runtimeInputs = JSON.parse(
  readFileSync(resolve(androidRoot, "validation/runtime-inputs-v2.json"), "utf8"),
);
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
const representativeLockText = readFileSync(
  resolve(androidRoot, "testdata/representative-resolution/manifest.lock.json"),
  "utf8",
);
const representativeLock = JSON.parse(representativeLockText);
const representativeReadme = readFileSync(
  resolve(androidRoot, "testdata/representative-resolution/README.md"),
  "utf8",
);
const resumableScriptNames = [
  "run-s24-idle.ps1",
  "run-s24-codec-switch.ps1",
  "run-s24-lifecycle.ps1",
  "run-s24-battery.ps1",
];
const resumableScripts = new Map(
  resumableScriptNames.map((name) => [
    name,
    readFileSync(resolve(androidRoot, "scripts", name), "utf8"),
  ]),
);
const s24Common = readFileSync(
  resolve(androidRoot, "scripts/s24-validation-common.ps1"),
  "utf8",
);
const s24Gate = readFileSync(resolve(androidRoot, "scripts/run-s24-gate.ps1"), "utf8");
const s24Representative = readFileSync(
  resolve(androidRoot, "scripts/run-s24-representative-validation.ps1"),
  "utf8",
);
const s24NavigationPerf = readFileSync(
  resolve(androidRoot, "scripts/run-s24-navigation-perf.ps1"),
  "utf8",
);
const s24Pinned = readFileSync(resolve(androidRoot, "scripts/s24-pinned-artifacts.ps1"), "utf8");
const s24PinnedTests = readFileSync(
  resolve(androidRoot, "scripts/test-s24-pinned-artifacts.ps1"),
  "utf8",
);
const s24FrameAccuracyTest = readFileSync(
  resolve(androidRoot, "app/src/androidTest/java/com/snowberried/ctcinereviewer/gate/S24FrameAccuracyTest.kt"),
  "utf8",
);
const validationHarnessV2 = readFileSync(
  resolve(
    androidRoot,
    "app/src/androidTest/java/com/snowberried/ctcinereviewer/validation/ValidationHarnessV2.kt",
  ),
  "utf8",
);
const benchmarkActivity = readFileSync(
  resolve(
    androidRoot,
    "app/src/benchmark/java/com/snowberried/ctcinereviewer/benchmark/BenchmarkActivity.kt",
  ),
  "utf8",
);
const macrobenchmark = readFileSync(
  resolve(
    androidRoot,
    "macrobenchmark/src/main/java/com/snowberried/ctcinereviewer/macrobenchmark/CcrProductMacrobenchmark.kt",
  ),
  "utf8",
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
requireContract(/versionCode\s*=\s*5\b/.test(build), "versionCode is not 5");
requireContract(/versionName\s*=\s*"0\.2\.0-alpha\.4"/.test(build), "versionName is not 0.2.0-alpha.4");
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
  workflow.includes("name: ccr-android-0.2.0-alpha.4-internal"),
  "Android CI artifact identity is stale",
);
requireContract(
  workflow.includes("name: ccr-android-0.2.0-alpha.4-test-tools"),
  "Android CI test-tool artifact identity is stale",
);
requireContract(
  workflow.includes("verify-representative-resolution-fixtures.mjs --manifest-only"),
  "representative-resolution manifest verifier is missing from CI",
);
requireContract(workflow.includes("verify-runtime-inputs.mjs"), "runtime-input verifier is missing from CI");
requireContract(
  workflow.includes("test-s24-pinned-artifacts.ps1"),
  "pinned S24 negative tests are missing from CI",
);
requireContract(
  workflow.includes("CCR_ANDROID_COMMIT_SHA: 189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e"),
  "Android CI does not separate the runtime source SHA from the harness SHA",
);
for (const line of [
  "/android/tools/generate-representative-resolution-fixtures.mjs text eol=lf",
  "/android/validation/device-baselines/sm-s928n-android16-2026-07-15/s24-frame-accuracy-report.sanitized.json text eol=lf",
]) {
  requireContract(gitAttributes.split(/\r?\n/).includes(line), `missing narrow LF lock: ${line}`);
}
requireContract(runtimeInputs.schemaVersion === 1, "runtime-input manifest schema");
requireContract(
  runtimeInputs.runtimeSourceSha === "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e",
  "runtime-input manifest source SHA",
);
requireContract(
  runtimeInputs.runtimeInputsTreeSha256 ===
    "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941",
  "runtime-input manifest tree SHA",
);
requireContract(runtimeInputs.files?.length === 32, "runtime-input manifest file count");
requireContract(
  build.includes('add("benchmarkImplementation", "androidx.metrics:metrics-performance:1.0.0")'),
  "JankStats is not isolated to the benchmark variant",
);
requireContract(
  !/^\s*implementation\("androidx\.metrics:metrics-performance:/m.test(build),
  "JankStats leaked into the product implementation configuration",
);

for (const [name, source] of resumableScripts) {
  for (const marker of [
    "MaxMinutes",
    "$Resume",
    "Get-CcrCheckpoint",
    "Save-CcrCheckpoint",
    "Clear-CcrRunArtifacts",
    "Complete-CcrCleanup",
    "Get-CcrBatteryStateSafe",
    "chargingAtStart",
    "containsRealMediaMetadata = $false",
  ]) {
    requireContract(source.includes(marker), `${name} missing resumable safety marker ${marker}`);
  }
}
const s24ExactV2Evidence = `${s24FrameAccuracyTest}\n${validationHarnessV2}`;
for (const marker of [
  "am force-stop",
  "uninstall $packageName",
  "stay_on_while_plugged_in",
  "screen_brightness_mode",
  "screen_off_timeout",
  "accelerometer_rotation",
  "user_rotation",
  "S24_CLEAN_WORKTREE_REQUIRED",
  "Invoke-CcrTimedProcess",
  "CleanupFailures",
  "S24_MAX_MINUTES_REACHED_DURING_BUILD",
]) {
  requireContract(s24Common.includes(marker), `S24 common cleanup missing ${marker}`);
}
for (const [name, source] of [
  ["run-s24-gate.ps1", s24Gate],
  ["run-s24-representative-validation.ps1", s24Representative],
  ["run-s24-navigation-perf.ps1", s24NavigationPerf],
]) {
  for (const marker of ["ArtifactManifest", "OutputDirectory", "PreflightOnly", "Invoke-CcrPinnedPreflight"]) {
    requireContract(source.includes(marker), `${name} missing pinned execution marker ${marker}`);
  }
  for (const forbidden of [/gradlew/i, /assemble/i, /connectedAndroidTest/i, /build[\\/]outputs/i]) {
    requireContract(!forbidden.test(source), `${name} contains build-time execution path ${forbidden}`);
  }
}
for (const marker of [
  "5a7febeb74b2abe9ed8cc5651d145044f16c55203e2beb875ce901f35fdcaf80",
  "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941",
  "PINNED_MANIFEST_HARNESS_SOURCE_MISMATCH",
  "PINNED_ARTIFACT_SHA_MISMATCH",
  "PINNED_INSTALLED_APK_IDENTITY_MISMATCH",
  "PINNED_REPORT_RUN_ID_MISMATCH",
  "PINNED_BENCHMARK_COUNTER_MISSING",
  "Save-CcrPinnedDeviceSettings",
  "Restore-CcrPinnedDeviceSettings",
]) {
  requireContract(s24Pinned.includes(marker), `pinned S24 common contract missing ${marker}`);
}
requireContract(
  s24PinnedTests.includes("S24 pinned artifact host tests passed") &&
    s24PinnedTests.includes("device mutation was attempted"),
  "pinned S24 negative-test contract is incomplete",
);
for (const marker of [
  'put("appVersionName"',
  'put("appVersionCode"',
  'put("appCommitSha"',
  'put("testApkSha256"',
  'put("syntheticOnly", true)',
  'put("containsRealMediaMetadata", false)',
  '"${golden.fixture}: signature length"',
]) {
  requireContract(s24ExactV2Evidence.includes(marker), `S24 exact report contract missing ${marker}`);
}
for (const marker of [
  "runId",
  "runtimeSourceSha",
  "harnessSourceSha",
  "runtimeInputsTreeSha256",
  "artifactSetRevision",
  "startedAtElapsedRealtimeNs",
  "finishedAtElapsedRealtimeNs",
  "duplicate instrumentation runId",
]) {
  requireContract(validationHarnessV2.includes(marker), `validation harness v2 missing ${marker}`);
}
for (const marker of [
  "ccr.outstanding_foreground_target_depth_max",
  "ccr.release_after_accepted_target_count",
  "ccr.hold_prefetch_started",
  "ccr.counter_complete",
  "ccr.run_identity",
]) {
  requireContract(benchmarkActivity.includes(marker), `benchmark harness v2 missing ${marker}`);
}
for (const marker of [
  "ccr-benchmark-harness-v2",
  "source-equivalent pinned benchmark measurement build",
  "CcrCounterMetric",
  "expectedTraceCount",
  "ccrBenchmarkHarnessV2",
]) {
  requireContract(macrobenchmark.includes(marker), `macrobenchmark harness v2 missing ${marker}`);
}
requireContract(
  resumableScripts.get("run-s24-codec-switch.ps1").includes("CHUNKED_SAFE_CHECKPOINTS"),
  "codec switch checkpoint continuity caveat is missing",
);
requireContract(
  resumableScripts.get("run-s24-lifecycle.ps1").includes("INCONCLUSIVE_NO_PER_CYCLE_RESOURCE_SAMPLES"),
  "lifecycle resource plateau caveat is missing",
);
const batteryScript = resumableScripts.get("run-s24-battery.ps1");
requireContract(
  batteryScript.includes("if ($context.BatteryAtStart.pluggedOrCharging)") &&
    batteryScript.includes('status = "NOT_EVALUABLE"') &&
    batteryScript.includes('reason = "USB_OR_CHARGING_AT_START"'),
  "battery wrapper must stop immediately when USB or charging is active",
);
for (const name of ["run-s24-idle.ps1", "run-s24-battery.ps1"]) {
  requireContract(
    resumableScripts.get(name).includes('resumeGranularity -NotePropertyValue "whole-instrumentation-restart"'),
    `${name} must declare whole-instrumentation resume granularity`,
  );
}

requireContract(representativeLock.status === "LOCKED", "representative fixture lock is not immutable");
requireContract(representativeLock.syntheticOnly === true, "representative fixtures are not synthetic-only");
requireContract(
  representativeLock.generatedAssetsTracked === false,
  "representative generated assets must not be tracked",
);
requireContract(representativeLock.fixtures?.length === 7, "representative fixture count is not 7");
requireContract(
  representativeLock.fixtures.every(
    (fixture) => fixture.frameCount >= 300 && /^[a-f0-9]{64}$/.test(fixture.sourceSha256),
  ),
  "representative fixture frame count or SHA contract",
);
requireContract(
  /^ccr-representative-resolution-v1-[a-f0-9]{64}$/.test(representativeLock.cache?.key ?? ""),
  "representative fixture exact cache key",
);
requireContract(
  gitignore.split(/\r?\n/).includes("android/.generated/"),
  "representative generated cache ignore is missing",
);
const representativeEvidenceText = `${representativeLockText}\n${representativeReadme}`;
for (const [pattern, label] of [
  [/[A-Za-z]:\\/, "Windows absolute path"],
  [/\/(?:Users|home)\//, "user-home absolute path"],
  [/(?:patient|accession|contentUri|fileName|deviceSerial)/i, "source identifier field"],
]) {
  requireContract(!pattern.test(representativeEvidenceText), `representative fixture contract contains ${label}`);
}

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

console.log("verified Android 0.2.0-alpha.4 identity, frozen evidence privacy, CI, local sample, and signing contracts");
