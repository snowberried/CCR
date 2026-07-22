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
const runtimeInputsAlpha5 = JSON.parse(
  readFileSync(resolve(androidRoot, "validation/runtime-inputs-alpha5-v1.json"), "utf8"),
);
const runtimeInputsAlpha6 = JSON.parse(
  readFileSync(resolve(androidRoot, "validation/runtime-inputs-alpha6-v1.json"), "utf8"),
);
const verifyRuntimeInputsAlpha5 = readFileSync(
  resolve(androidRoot, "tools/verify-runtime-inputs-alpha5.mjs"),
  "utf8",
);
const verifyRuntimeInputsAlpha6 = readFileSync(
  resolve(androidRoot, "tools/verify-runtime-inputs-alpha6.mjs"),
  "utf8",
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
const alpha5RunnerNames = [
  "run-s24-alpha5-instrumentation.ps1",
  "run-s24-alpha5-navigation-perf.ps1",
  "run-s24-alpha5-random.ps1",
  "run-s24-alpha5-validation.ps1",
];
const alpha5Runners = new Map(
  alpha5RunnerNames.map((name) => [
    name,
    readFileSync(resolve(androidRoot, "scripts", name), "utf8"),
  ]),
);
const s24Alpha5Pinned = readFileSync(
  resolve(androidRoot, "scripts/s24-alpha5-pinned-artifacts.ps1"),
  "utf8",
);
const s24Alpha5PinnedTests = readFileSync(
  resolve(androidRoot, "scripts/test-s24-alpha5-pinned-artifacts.ps1"),
  "utf8",
);
const alpha6ScriptNames = [
  "run-s24-alpha6-stage1.ps1",
  "run-s24-alpha6-random.ps1",
];
const alpha6Scripts = new Map(
  alpha6ScriptNames.map((name) => [
    name,
    readFileSync(resolve(androidRoot, "scripts", name), "utf8"),
  ]),
);
const alpha6Stage1Runner = alpha6Scripts.get("run-s24-alpha6-stage1.ps1");
const alpha6RandomRunner = alpha6Scripts.get("run-s24-alpha6-random.ps1");
const s24Alpha6Pinned = readFileSync(
  resolve(androidRoot, "scripts/s24-alpha6-pinned-artifacts.ps1"),
  "utf8",
);
const s24Alpha6PinnedTests = readFileSync(
  resolve(androidRoot, "scripts/test-s24-alpha6-pinned-artifacts.ps1"),
  "utf8",
);
const alpha6TailContract = readFileSync(
  resolve(androidRoot, "scripts/alpha6-tail-contract.ps1"),
  "utf8",
);
const alpha6TailTests = readFileSync(
  resolve(androidRoot, "scripts/test-alpha6-tail-contract.ps1"),
  "utf8",
);
const alpha6Stage1Tests = readFileSync(
  resolve(androidRoot, "scripts/test-run-s24-alpha6-stage1.ps1"),
  "utf8",
);
const alpha6RandomTests = readFileSync(
  resolve(androidRoot, "scripts/test-run-s24-alpha6-random.ps1"),
  "utf8",
);
const alpha6RandomEvidence = [
  "Alpha5RandomSeekExactnessTest.kt",
  "Alpha5RandomSeekPerformanceTest.kt",
].map((name) => readFileSync(
  resolve(androidRoot, "app/src/androidTest/java/com/snowberried/ctcinereviewer/gate", name),
  "utf8",
)).join("\n");
const verifyApkPrivacy = readFileSync(
  resolve(androidRoot, "scripts/verify-apk-privacy.ps1"),
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
requireContract(/versionCode\s*=\s*7\b/.test(build), "versionCode is not 7");
requireContract(/versionName\s*=\s*"0\.2\.0-alpha\.6"/.test(build), "versionName is not 0.2.0-alpha.6");
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
requireContract(workflow.includes("fetch-depth: 0"), "Android CI does not fetch frozen runtime history");
requireContract(
  workflow.includes("name: ccr-android-0.2.0-alpha.6-internal"),
  "Android CI artifact identity is stale",
);
requireContract(
  workflow.includes("name: ccr-android-0.2.0-alpha.6-test-tools"),
  "Android CI test-tool artifact identity is stale",
);
requireContract(
  workflow.includes("verify-representative-resolution-fixtures.mjs --manifest-only"),
  "representative-resolution manifest verifier is missing from CI",
);
requireContract(workflow.includes("verify-runtime-inputs.mjs"), "runtime-input verifier is missing from CI");
requireContract(
  workflow.includes("verify-runtime-inputs-alpha5.mjs"),
  "Alpha 5 runtime-input verifier is missing from CI",
);
requireContract(
  workflow.includes("verify-runtime-inputs-alpha6.mjs"),
  "Alpha 6 runtime-input verifier is missing from CI",
);
requireContract(
  workflow.includes("test-s24-pinned-artifacts.ps1"),
  "pinned S24 negative tests are missing from CI",
);
requireContract(
  workflow.includes("test-s24-alpha5-pinned-artifacts.ps1"),
  "Alpha 5 pinned S24 negative tests are missing from CI",
);
requireContract(
  workflow.includes(`CCR_ANDROID_COMMIT_SHA: ${runtimeInputsAlpha6.runtimeSourceSha}`),
  "Android CI does not separate the runtime source SHA from the harness SHA",
);
for (const scriptName of [
  "test-s24-alpha6-pinned-artifacts.ps1",
  "test-alpha6-tail-contract.ps1",
  "test-run-s24-alpha6-stage1.ps1",
  "test-run-s24-alpha6-random.ps1",
]) {
  requireContract(workflow.includes(scriptName), `Alpha 6 CI host test is missing: ${scriptName}`);
}
requireContract(
  (workflow.match(/if: github\.ref == 'refs\/heads\/main'/g) ?? []).length === 2,
  "binary CI artifacts are not restricted to main",
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
requireContract(runtimeInputsAlpha5.schemaVersion === 1, "Alpha 5 runtime-input manifest schema");
requireContract(
  /^[a-f0-9]{40}$/.test(runtimeInputsAlpha5.runtimeSourceSha),
  "Alpha 5 runtime-input manifest source SHA",
);
requireContract(
  /^[a-f0-9]{64}$/.test(runtimeInputsAlpha5.runtimeInputsTreeSha256),
  "Alpha 5 runtime-input manifest tree SHA",
);
requireContract(runtimeInputsAlpha5.files?.length >= 32, "Alpha 5 runtime-input manifest file count");
requireContract(runtimeInputsAlpha6.schemaVersion === 1, "Alpha 6 runtime-input manifest schema");
requireContract(
  runtimeInputsAlpha6.runtimeSourceSha === "c9a7147d39d2d370916f325a108876c0947ddcb8",
  "Alpha 6 runtime-input manifest source SHA",
);
requireContract(
  runtimeInputsAlpha6.runtimeInputsTreeSha256 ===
    "0eb249abadab7d89ba42a40772eb9a8610c193c87279c8633bb6275ac828fc0d",
  "Alpha 6 runtime-input manifest tree SHA",
);
requireContract(runtimeInputsAlpha6.files?.length === 40, "Alpha 6 runtime-input manifest file count");
requireContract(
  verifyRuntimeInputsAlpha5.includes('snapshot(runtimeSourceSha)') &&
    !verifyRuntimeInputsAlpha5.includes('snapshot("HEAD")'),
  "Alpha 5 verifier no longer verifies its historical snapshot independently",
);
requireContract(
  verifyRuntimeInputsAlpha6.includes('snapshot(runtimeSourceSha)') &&
    verifyRuntimeInputsAlpha6.includes('snapshot("HEAD")') &&
    verifyRuntimeInputsAlpha6.includes("assertNoRuntimeWorkingTreeChanges"),
  "Alpha 6 verifier does not freeze historical, HEAD, and worktree runtime inputs",
);
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
for (const [name, source] of alpha5Runners) {
  for (const marker of [
    "ArtifactManifest",
    "ArtifactManifestSha256",
    "MaxMinutes",
    "Resume",
    "PreflightOnly",
  ]) {
    requireContract(source.includes(marker), `${name} missing Alpha 5 safety marker ${marker}`);
  }
  for (const forbidden of [/gradlew/i, /assemble/i, /connectedAndroidTest/i, /build[\\/]outputs/i]) {
    requireContract(!forbidden.test(source), `${name} contains build-time execution path ${forbidden}`);
  }
}
for (const marker of [
  "$script:CcrPinnedArtifactSetRevision = 3",
  `$script:CcrPinnedRuntimeSourceSha = "${runtimeInputsAlpha5.runtimeSourceSha}"`,
  `$script:CcrPinnedRuntimeInputsTreeSha256 = "${runtimeInputsAlpha5.runtimeInputsTreeSha256}"`,
  '$script:CcrPinnedVersionName = "0.2.0-alpha.5"',
  "$script:CcrPinnedVersionCode = 6",
  "Assert-CcrAlpha5ManifestSha256",
  "Invoke-CcrAlpha5PinnedPreflight",
  "ALPHA5_PREFLIGHT_MANIFEST_SHA_MISMATCH",
]) {
  requireContract(s24Alpha5Pinned.includes(marker), `Alpha 5 pinned contract missing ${marker}`);
}
requireContract(
  s24Alpha5Pinned.indexOf("Assert-CcrAlpha5ManifestSha256 $ArtifactManifest") <
    s24Alpha5Pinned.indexOf("$script:CcrAlpha5BasePinnedPreflight @parameters"),
  "Alpha 5 manifest hash is not checked before pinned preflight/ADB",
);
requireContract(
  s24Alpha5PinnedTests.includes("Alpha5 pinned-artifact script tests passed") &&
    s24Alpha5PinnedTests.includes("ALPHA5_TEST_MANIFEST_SHA_FAILURE_TOUCHED_ADB") &&
    s24Alpha5PinnedTests.includes("ALPHA5_TEST_BUILD_COMMAND_FORBIDDEN"),
  "Alpha 5 pinned negative-test contract is incomplete",
);
for (const [name, source] of alpha6Scripts) {
  for (const marker of [
    "ArtifactManifest",
    "ArtifactManifestSha256",
    "RuntimeSourceSha",
    "HarnessSourceSha",
    "RuntimeInputsTreeSha256",
    "ExpectedDebugAppSha256",
    "OutputDirectory",
    "MaxMinutes",
    "Resume",
    "PreflightOnly",
    "Invoke-CcrAlpha6PinnedHostPreflight",
    "Assert-CcrAlpha6ArtifactSetUnchanged",
    "buildCommandCount = 0L",
  ]) {
    requireContract(source.includes(marker), `${name} missing Alpha 6 safety marker ${marker}`);
  }
  for (const forbidden of [/connectedAndroidTest/i, /build[\\/]outputs/i]) {
    requireContract(!forbidden.test(source), `${name} contains build-time execution path ${forbidden}`);
  }
}
for (const marker of [
  "$script:CcrPinnedArtifactSetRevision = 4",
  '$script:CcrPinnedVersionName = "0.2.0-alpha.6"',
  "$script:CcrPinnedVersionCode = 7",
  "Invoke-CcrAlpha6PinnedHostPreflight",
  "Assert-CcrAlpha6ArtifactSetUnchanged",
  "Assert-CcrAlpha6ValidationScriptsBuildFree",
  "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO",
  "New-CcrAlpha6TimedAdbInvoker",
  "Initialize-CcrAlpha6PinnedDeviceSettings",
  "$process.WaitForExit(2000)",
  "ResumeRestoreBaseline",
  "resume_device_settings_changed",
]) {
  requireContract(s24Alpha6Pinned.includes(marker), `Alpha 6 pinned contract missing ${marker}`);
}
requireContract(
  !/\$script:CcrPinned(?:RuntimeSourceSha|RuntimeInputsTreeSha256|DebugAppSha256)\s*=\s*"[0-9a-f]{40,64}"/.test(
    s24Alpha6Pinned,
  ),
  "Alpha 6 pinned helper contains a tracked final artifact placeholder",
);
requireContract(
  s24Alpha6PinnedTests.includes("Alpha 6 pinned-artifact v4 host tests passed") &&
    s24Alpha6PinnedTests.includes("device-validation-pending-build-count-zero"),
  "Alpha 6 pinned negative-test contract is incomplete",
);
requireContract(
  alpha6TailTests.includes("Alpha 6 tail contract tests passed") &&
    alpha6TailContract.includes("associatedLongGapCount") &&
    alpha6TailContract.includes("p995Ns") &&
    alpha6TailContract.includes("longestConsecutivePublicationGapNs") &&
    alpha6TailTests.includes("boundary-gap-hard-fail"),
  "Alpha 6 tail hard-gate contract is incomplete",
);
requireContract(
  alpha6Stage1Tests.includes("Alpha 6 Stage 1 host-only tests passed") &&
    alpha6RandomTests.includes("Alpha6 random runner host tests passed"),
  "Alpha 6 runner host-negative tests are incomplete",
);
for (const marker of [
  "measuredWindowBuildAssociatedLongGapCount",
  "ALPHA6_STAGE1_REVERSE_MECHANISM_NOT_EXERCISED",
  "$absoluteMinimumFps",
  "publicationGapMaxUs",
  "ALPHA6_STAGE1_RESUME_COMPLETED_CHECKPOINT_MISSING",
  "Initialize-CcrAlpha6PinnedDeviceSettings",
  "New-CcrAlpha6TimedAdbInvoker",
  "ALPHA6_STAGE1_RESUME_SUMMARY_CONTRACT_MISMATCH",
  "ALPHA6_STAGE1_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH",
  'checkpoint-alpha6-stage1-device-settings-$hostPreflightRunId.json',
  '"h264-bframes.mp4", "long-gop.mp4", "hevc-main8.mp4", "vfr.mp4"',
]) {
  requireContract(alpha6Stage1Runner.includes(marker), `Alpha 6 Stage 1 contract missing ${marker}`);
}
for (const marker of [
  "ALPHA6_RANDOM_STAGE2_NOT_IMPLEMENTED",
  "ALPHA6_RANDOM_TARGET_SET_IDENTITY_MISMATCH",
  "ALPHA6_RANDOM_TARGET_ORDINAL_SET_MISMATCH",
  "ALPHA6_RANDOM_MAX_REGRESSION",
  "Initialize-CcrAlpha6PinnedDeviceSettings",
  "New-CcrAlpha6TimedAdbInvoker",
  "Assert-CcrAlpha6RandomCompletedSummary",
  "Assert-CcrAlpha6RandomPreflightSummary",
  'checkpoint-alpha6-random-device-settings-$hostPreflightRunId.json',
]) {
  requireContract(alpha6RandomRunner.includes(marker), `Alpha 6 random contract missing ${marker}`);
}
requireContract(
  s24FrameAccuracyTest.includes(
    'listOf("h264-bframes", "long-gop", "vfr", "hevc-main8")',
  ),
  "Alpha 6 reverse exactness fixture set does not include HEVC Main8",
);
requireContract(
  macrobenchmark.includes('"ccr.publication_gap_max_us" to "ccrPublicationGapMaxUs"') &&
    macrobenchmark.includes('required("gapMaxUs")'),
  "Alpha 6 macrobenchmark boundary-gap evidence is not wired",
);
for (const marker of [
  '"requestedCategory"',
  '"attemptedPlan"',
  '"selectedPlan"',
  '"fallbackReason"',
  '"decoderCursorFrame"',
  '"previousSyncFrame"',
  '"estimatedOutputCount"',
  '"actualOutputCount"',
  '"auxiliaryUsed"',
]) {
  requireContract(alpha6RandomEvidence.includes(marker), `Alpha 6 random report missing ${marker}`);
}
for (const marker of [
  runtimeInputsAlpha6.runtimeSourceSha,
  runtimeInputsAlpha6.runtimeInputsTreeSha256,
  "EXPECTED_ARTIFACT_SET_REVISION = 4",
]) {
  requireContract(validationHarnessV2.includes(marker), `Alpha 6 validation harness identity missing ${marker}`);
}
for (const source of [benchmarkActivity, macrobenchmark]) {
  requireContract(source.includes(runtimeInputsAlpha6.runtimeSourceSha), "Alpha 6 benchmark runtime SHA mismatch");
  requireContract(source.includes(runtimeInputsAlpha6.runtimeInputsTreeSha256), "Alpha 6 benchmark runtime tree mismatch");
  requireContract(source.includes("ARTIFACT_SET_REVISION = 4"), "Alpha 6 benchmark artifact revision mismatch");
}
for (const marker of [
  '$ExpectedApplicationId = "com.snowberried.ctcinereviewer.internal"',
  '$ExpectedVersionName = "0.2.0-alpha.6"',
  "$ExpectedVersionCode = 7",
  "android.permission.INTERNET",
  "android.permission.READ_MEDIA_VIDEO",
  "android.permission.MANAGE_EXTERNAL_STORAGE",
]) {
  requireContract(verifyApkPrivacy.includes(marker), `APK privacy verifier missing ${marker}`);
}
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

console.log("verified Android 0.2.0-alpha.6 identity, Alpha 4/5/6 runtime freezes, v4 host gates, evidence privacy, CI, local sample, and signing contracts");
