import assert from "node:assert/strict";
import test from "node:test";
import {
  ALPHA4_BASELINE_CATEGORIES,
  ALPHA4_BASELINE_DIRECTIONS,
  alpha4SeekPlanIdentity,
  createAlpha4BurstTargets,
  createAlpha4SeekPlan,
  validateAlpha4BaselineReport,
} from "./alpha4-baseline-contract.mjs";

const sync = [0, 48, 96, 144, 192, 240, 288, 336];
const EXPECTED_ARTIFACTS = {
  expectedHarnessSourceSha: "c".repeat(40),
  expectedTestApkSha256: "b".repeat(64),
};

test("deterministic planner produces required categories and boundaries", () => {
  const first = createAlpha4SeekPlan(360, sync, 0x41a40001);
  assert.deepEqual(first, createAlpha4SeekPlan(360, sync, 0x41a40001));
  assert.equal(first.length, 50);
  for (const category of ALPHA4_BASELINE_CATEGORIES) {
    assert.equal(first.filter((target) => target.category === category).length, 10);
  }
  const indices = new Set(first.map((target) => target.targetFrameIndex));
  assert.ok([0, 180, 359].every((index) => indices.has(index)));
  assert.ok(first.some((target) => target.category === "adjacent-gop" && sync.includes(target.targetFrameIndex)));
  assert.ok(first.filter((target) => target.category === "ahead-of-cursor").every((target) =>
    target.direction === "forward" && target.targetFrameIndex - target.setupFrameIndex >= 16));
  assert.ok(first.filter((target) => target.category === "same-gop").every((target) =>
    target.direction === "reverse" && target.setupFrameIndex - target.targetFrameIndex <= 15));
  assert.ok(first.filter((target) => target.category === "cache-or-history-hit").every((target) => target.setupFrameIndex === target.targetFrameIndex));
  assert.ok(first.every((target) => ALPHA4_BASELINE_DIRECTIONS.includes(target.direction)));
  assert.equal(new Set(first.map(({ targetFrameIndex }) => targetFrameIndex)).size, 50);
  const uniqueCacheSlots = first.flatMap((target) => target.category === "cache-or-history-hit"
    ? [target.targetFrameIndex]
    : [target.setupFrameIndex, target.targetFrameIndex]);
  assert.equal(new Set(uniqueCacheSlots).size, uniqueCacheSlots.length);
});

test("long-GOP plan remains deterministic and bounded", () => {
  const plan = createAlpha4SeekPlan(360, [0, 240], 0x41a40003);
  assert.equal(plan.length, 50);
  assert.ok(plan.every(({ setupFrameIndex, targetFrameIndex }) =>
    setupFrameIndex >= 0 && setupFrameIndex < 360 && targetFrameIndex >= 0 && targetFrameIndex < 360));
  assert.equal(plan.filter(({ category }) => category === "adjacent-gop").length, 10);
});

test("plan identity and burst targets are deterministic", () => {
  const plan = createAlpha4SeekPlan(360, sync, 0x41a40001);
  assert.equal(
    alpha4SeekPlanIdentity(360, sync, 0x41a40001, plan),
    "e27c3831f54e977f8cbe66221fd8cbf636b255cbfbd06cbd31119ea2d5ec6da6",
  );
  assert.deepEqual(createAlpha4BurstTargets(360, 0x41a40001), createAlpha4BurstTargets(360, 0x41a40001));
  assert.equal(new Set(createAlpha4BurstTargets(360, 0x41a40001)).size, 10);
});

function syncEvidence(index, syncIndices) {
  const ordinal = syncIndices.findLastIndex((value) => value <= index);
  return { frameIndex: syncIndices[Math.max(0, ordinal)], ordinal: Math.max(0, ordinal) };
}

function validFixture(index) {
  const seed = 0x41a40001 + index;
  const plan = createAlpha4SeekPlan(360, sync, seed);
  return {
    fixtureId: `fixture-0${index + 1}`,
    frameCount: 360,
    codecComponent: index === 4 ? "c2.qti.hevc.decoder" : "c2.qti.avc.decoder",
    hardwareAccelerated: true,
    targetCount: 50,
    deterministicSeed: seed,
    syncFrameIndices: sync,
    syncSamples: sync.map((displayFrameIndex) => ({ displayFrameIndex, sampleOrdinal: displayFrameIndex })),
    targetSetIdentity: alpha4SeekPlanIdentity(360, sync, seed, plan),
    categoryCounts: Object.fromEntries(ALPHA4_BASELINE_CATEGORIES.map((category) => [category, 10])),
    containsFirstMiddleLast: true,
    containsGopBoundary: true,
    targets: plan.map((target) => {
      const setupSync = syncEvidence(target.setupFrameIndex, sync);
      const targetSync = syncEvidence(target.targetFrameIndex, sync);
      return {
        ...target,
        setupSampleOrdinal: target.setupFrameIndex,
        targetSampleOrdinal: target.targetFrameIndex,
        targetPtsUs: target.targetFrameIndex * 41_667,
        fileGeneration: index + 1,
        requestGeneration: target.ordinal + 1,
        acceptedElapsedRealtimeNs: 1_000_000 + target.ordinal * 10_000,
        publishedElapsedRealtimeNs: 2_000_000 + target.ordinal * 10_000,
        setupPreviousSyncFrameIndex: setupSync.frameIndex,
        targetPreviousSyncFrameIndex: targetSync.frameIndex,
        setupSyncOrdinal: setupSync.ordinal,
        targetSyncOrdinal: targetSync.ordinal,
        acceptedToFirstDecoderOutputUs: null,
        acceptedToTargetOutputUs: null,
        acceptedToPublicationUs: 1_000,
        acceptedDisplayedFrameIndex: target.setupFrameIndex,
        publishedDisplayedFrameIndex: target.targetFrameIndex,
        acceptedDisplayedMeasurement: "SETUP_PUBLICATION",
        acceptedRawFrameLag: Math.abs(target.targetFrameIndex - target.setupFrameIndex),
        publishedRawFrameLag: 0,
        decodedOutputCount: target.category === "cache-or-history-hit" ? 0 : 5,
        seekCount: target.category === "cache-or-history-hit" ? 0 : 1,
        flushCount: target.category === "cache-or-history-hit" ? 0 : 1,
        cacheOrHistoryHit: target.category === "cache-or-history-hit",
        staleDiscardCount: 0,
        nonTargetPublishedCount: 0,
      };
    }),
    burst: {
      requestCount: 10,
      acceptedRequestCount: 10,
      acceptedRequestGenerations: Array.from({ length: 10 }, (_, generation) => 51 + generation),
      finalTargetFrameIndex: createAlpha4BurstTargets(360, seed).at(-1),
      fileGeneration: index + 1,
      requestGeneration: 60,
      acceptedElapsedRealtimeNs: 2_000_000,
      assessmentWindowStartElapsedRealtimeNs: 2_000_000,
      publishedElapsedRealtimeNs: 4_000_000,
      acceptedToPublicationUs: 2_000,
      nonTargetPublishedCount: 0,
      nonFinalPublishedAfterFinalAcceptanceCount: 0,
      publicationAssessment: "EVENT_TIMESTAMP_AT_OR_AFTER_FINAL_ACCEPTANCE",
      discardedStaleAssessment: "FINAL_GENERATION_ONLY_NO_CALLBACK_TIMESTAMP",
      staleDiscardCount: 9,
    },
    cacheBudgetBytes: 64 * 1024 * 1024,
    cacheBytes: 32 * 1024 * 1024,
    cacheEntryCount: 4,
    peakCacheEntryCount: 8,
    cacheEvictionCount: 2,
    cacheRejectionCount: 0,
    cacheThrashCount: 0,
    liveTextureCount: 4,
    peakLiveTextureCount: 8,
    textureDoubleReleaseCount: 0,
    staleBeforeSwapCount: 0,
    swapFailureCount: 0,
    surfaceInvalidCount: 0,
    publicationInvariantViolationCount: 0,
    fullFrameReadbackCount: 0,
    inSessionMemory: {
      javaUsedBytes: 40,
      nativeAllocatedBytes: 50,
      totalPssBytes: 60,
    },
  };
}

function validReport() {
  return {
    schemaVersion: 1,
    kind: "alpha4-random-source-equivalent-timing-baseline",
    status: "PASS",
    baselineCompleteness: "PENDING_TRACE_MERGE",
    renderMode: "PILOT_SOURCE_EQUIVALENT",
    pixelExactnessEvidence: "SEPARATE_FROZEN_GATES",
    applicationId: "com.snowberried.ctcinereviewer.internal",
    appVersionName: "0.2.0-alpha.4",
    appVersionCode: 5,
    appCommitSha: "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e",
    runId: "alpha4-test-run",
    startedAtElapsedRealtimeNs: 1_000,
    finishedAtElapsedRealtimeNs: 2_000,
    runtimeSourceSha: "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e",
    harnessSourceSha: "c".repeat(40),
    runtimeInputsTreeSha256: "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941",
    artifactSetRevision: 2,
    testCount: 1,
    instrumentationExpectedTestCount: 1,
    appSha256: "5a7febeb74b2abe9ed8cc5651d145044f16c55203e2beb875ce901f35fdcaf80",
    testApkSha256: "b".repeat(64),
    syntheticOnly: true,
    containsRealMediaMetadata: false,
    mediaFileNameIncluded: false,
    mediaUriIncluded: false,
    mediaPathIncluded: false,
    mediaSourceHashIncluded: false,
    metricAvailability: {
      acceptedToFirstDecoderOutput: "PENDING_TRACE_MERGE",
      acceptedToTargetOutput: "PENDING_TRACE_MERGE",
      gpu: "UNKNOWN",
      releaseOvershoot: "UNKNOWN",
    },
    gpuMetrics: null,
    memoryMeasurement: "POST_ACTIVITY_CLEANUP_SNAPSHOT",
    memory: {
      javaUsedBytes: 10,
      nativeAllocatedBytes: 20,
      totalPssBytes: 30,
    },
    fixtureCount: 5,
    targetCount: 250,
    mismatchCount: 0,
    writeOpenCount: 0,
    fixtures: Array.from({ length: 5 }, (_, index) => validFixture(index)),
  };
}

test("report schema accepts sanitized synthetic evidence", () => {
  assert.equal(validateAlpha4BaselineReport(validReport(), EXPECTED_ARTIFACTS), true);
});

test("report schema requires exact harness and test APK identity inputs", () => {
  assert.throws(() => validateAlpha4BaselineReport(validReport()), /expected harness\/test artifact identity/);
  assert.throws(
    () => validateAlpha4BaselineReport(validReport(), {
      ...EXPECTED_ARTIFACTS,
      expectedTestApkSha256: "0".repeat(64),
    }),
    /pinned artifact identity/,
  );
  assert.throws(
    () => validateAlpha4BaselineReport(validReport(), {
      ...EXPECTED_ARTIFACTS,
      expectedHarnessSourceSha: "0".repeat(40),
    }),
    /pinned artifact identity/,
  );
});

test("report schema rejects identity, invariant, burst, and plan drift", () => {
  const missingInvariant = validReport();
  delete missingInvariant.mismatchCount;
  assert.throws(() => validateAlpha4BaselineReport(missingInvariant, EXPECTED_ARTIFACTS), /report keys/);
  const wrongArtifact = validReport();
  wrongArtifact.appSha256 = "0".repeat(64);
  assert.throws(() => validateAlpha4BaselineReport(wrongArtifact, EXPECTED_ARTIFACTS), /artifact identity/);
  const cacheContamination = validReport();
  cacheContamination.fixtures[0].targets.find(({ category }) => category === "far-random").cacheOrHistoryHit = true;
  assert.throws(() => validateAlpha4BaselineReport(cacheContamination, EXPECTED_ARTIFACTS), /cache contamination/);
  const invalidBurst = validReport();
  invalidBurst.fixtures[0].burst.nonTargetPublishedCount = 1;
  assert.throws(() => validateAlpha4BaselineReport(invalidBurst, EXPECTED_ARTIFACTS), /last-request-wins/);
  const staleSwap = validReport();
  staleSwap.fixtures[0].staleBeforeSwapCount = 1;
  assert.throws(() => validateAlpha4BaselineReport(staleSwap, EXPECTED_ARTIFACTS), /publication invariant/);
  const planDrift = validReport();
  planDrift.fixtures[0].targets[0].targetFrameIndex += 1;
  assert.throws(() => validateAlpha4BaselineReport(planDrift, EXPECTED_ARTIFACTS), /plan drift/);
});

test("report schema rejects media identity and fabricated GPU data", () => {
  const identityLeak = validReport();
  identityLeak.fixtures[0].fileName = "private.mp4";
  assert.throws(() => validateAlpha4BaselineReport(identityLeak, EXPECTED_ARTIFACTS), /media identifier/);
  const uriLeak = validReport();
  uriLeak.fixtures[0].videoUri = "content://private/video";
  assert.throws(() => validateAlpha4BaselineReport(uriLeak, EXPECTED_ARTIFACTS), /media identifier/);
  const pathLeak = validReport();
  pathLeak.fixtures[0].absolutePath = "C:\\private\\video.bin";
  assert.throws(() => validateAlpha4BaselineReport(pathLeak, EXPECTED_ARTIFACTS), /media identifier/);
  const fabricatedGpu = validReport();
  fabricatedGpu.gpuMetrics = { busyPercent: 12 };
  assert.throws(() => validateAlpha4BaselineReport(fabricatedGpu, EXPECTED_ARTIFACTS), /metric availability/);
});

test("report schema fails closed on sync, lag, burst-window, and unknown evidence drift", () => {
  const wrongPreviousSync = validReport();
  wrongPreviousSync.fixtures[0].targets.find(({ targetFrameIndex }) => targetFrameIndex >= 48)
    .targetPreviousSyncFrameIndex = 0;
  assert.throws(
    () => validateAlpha4BaselineReport(wrongPreviousSync, EXPECTED_ARTIFACTS),
    /previous-sync exact evidence/,
  );

  const fabricatedLag = validReport();
  fabricatedLag.fixtures[0].targets[0].acceptedDisplayedFrameIndex += 1;
  assert.throws(() => validateAlpha4BaselineReport(fabricatedLag, EXPECTED_ARTIFACTS), /target evidence/);

  const wrongBurstWindow = validReport();
  wrongBurstWindow.fixtures[0].burst.assessmentWindowStartElapsedRealtimeNs -= 1;
  assert.throws(() => validateAlpha4BaselineReport(wrongBurstWindow, EXPECTED_ARTIFACTS), /last-request-wins/);

  const unknownEvidence = validReport();
  unknownEvidence.fixtures[0].unreviewedCounter = 0;
  assert.throws(() => validateAlpha4BaselineReport(unknownEvidence, EXPECTED_ARTIFACTS), /fixture keys/);
});

test("timing baseline rejects exactness overclaim and any full-frame readback", () => {
  const exactnessOverclaim = validReport();
  exactnessOverclaim.pixelExactnessEvidence = "IN_REPORT";
  assert.throws(
    () => validateAlpha4BaselineReport(exactnessOverclaim, EXPECTED_ARTIFACTS),
    /render mode\/exactness scope/,
  );

  const exactnessMode = validReport();
  exactnessMode.renderMode = "EXACTNESS";
  assert.throws(
    () => validateAlpha4BaselineReport(exactnessMode, EXPECTED_ARTIFACTS),
    /render mode\/exactness scope/,
  );

  const readback = validReport();
  readback.fixtures[0].fullFrameReadbackCount = 1;
  assert.throws(
    () => validateAlpha4BaselineReport(readback, EXPECTED_ARTIFACTS),
    /cache\/texture\/publication invariant/,
  );
});

test("timing baseline rejects file and request generation discontinuity", () => {
  const targetFileSwitch = validReport();
  targetFileSwitch.fixtures[0].targets[25].fileGeneration += 1;
  assert.throws(
    () => validateAlpha4BaselineReport(targetFileSwitch, EXPECTED_ARTIFACTS),
    /measured generation continuity/,
  );

  const nonIncreasingRequest = validReport();
  nonIncreasingRequest.fixtures[0].targets[25].requestGeneration =
    nonIncreasingRequest.fixtures[0].targets[24].requestGeneration;
  assert.throws(
    () => validateAlpha4BaselineReport(nonIncreasingRequest, EXPECTED_ARTIFACTS),
    /measured generation continuity/,
  );

  const burstFileSwitch = validReport();
  burstFileSwitch.fixtures[0].burst.fileGeneration += 1;
  assert.throws(
    () => validateAlpha4BaselineReport(burstFileSwitch, EXPECTED_ARTIFACTS),
    /last-request-wins/,
  );

  const burstBeforeMeasured = validReport();
  const lastMeasuredGeneration = burstBeforeMeasured.fixtures[0].targets.at(-1).requestGeneration;
  burstBeforeMeasured.fixtures[0].burst.acceptedRequestGenerations =
    Array.from({ length: 10 }, (_, index) => lastMeasuredGeneration - 9 + index);
  burstBeforeMeasured.fixtures[0].burst.requestGeneration = lastMeasuredGeneration;
  assert.throws(
    () => validateAlpha4BaselineReport(burstBeforeMeasured, EXPECTED_ARTIFACTS),
    /last-request-wins/,
  );
});

test("timing baseline rejects ambiguous or invalid memory snapshots", () => {
  const ambiguousRootMemory = validReport();
  ambiguousRootMemory.memoryMeasurement = "PEAK";
  assert.throws(
    () => validateAlpha4BaselineReport(ambiguousRootMemory, EXPECTED_ARTIFACTS),
    /root memory measurement scope/,
  );

  const missingInSessionMemory = validReport();
  delete missingInSessionMemory.fixtures[0].inSessionMemory;
  assert.throws(
    () => validateAlpha4BaselineReport(missingInSessionMemory, EXPECTED_ARTIFACTS),
    /fixture keys/,
  );

  const invalidInSessionMemory = validReport();
  invalidInSessionMemory.fixtures[0].inSessionMemory.totalPssBytes = -1;
  assert.throws(
    () => validateAlpha4BaselineReport(invalidInSessionMemory, EXPECTED_ARTIFACTS),
    /in-session memory/,
  );
});
