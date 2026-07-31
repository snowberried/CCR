import { createHash } from "node:crypto";

const MASK = 0x7fff_ffffn;

const RUNTIME_SOURCE_SHA = "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e";
const RUNTIME_INPUTS_TREE_SHA256 = "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941";
const FIXED_DEBUG_APK_SHA256 = "5a7febeb74b2abe9ed8cc5651d145044f16c55203e2beb875ce901f35fdcaf80";

export const ALPHA4_BASELINE_CATEGORIES = [
  "cache-or-history-hit",
  "ahead-of-cursor",
  "same-gop",
  "adjacent-gop",
  "far-random",
];

export const ALPHA4_BASELINE_DIRECTIONS = ["stationary", "forward", "reverse"];

const MIN_AHEAD_DISTANCE = 16;
const MAX_AHEAD_DISTANCE = 32;
const MAX_SAME_GOP_REVERSE_DISTANCE = 15;

class Lcg {
  constructor(seed) {
    this.state = BigInt(seed) & MASK;
  }

  nextInt(bound) {
    if (!Number.isInteger(bound) || bound <= 0) throw new Error("invalid random bound");
    this.state = (this.state * 1_103_515_245n + 12_345n) & MASK;
    return Number(this.state % BigInt(bound));
  }
}

export function createAlpha4SeekPlan(frameCount, syncFrameIndices, seed) {
  if (!Number.isInteger(frameCount) || frameCount < 300) throw new Error("frameCount must be >= 300");
  const sync = [...new Set(syncFrameIndices)].sort((left, right) => left - right);
  if (sync.length < 2 || sync[0] !== 0 || sync.some((index) => !Number.isInteger(index) || index < 0 || index >= frameCount)) {
    throw new Error("invalid sync frame indices");
  }
  const random = new Lcg(seed);
  const targets = [];
  const used = new Set();
  const add = (category, setupFrameIndex, targetFrameIndex) => targets.push({
    ordinal: -1,
    category,
    setupFrameIndex,
    targetFrameIndex,
    direction: targetFrameIndex > setupFrameIndex
      ? "forward"
      : targetFrameIndex < setupFrameIndex ? "reverse" : "stationary",
  });
  const adjacentPairs = buildAdjacentPairs(frameCount, sync);
  const adjacentProtected = new Set(adjacentPairs.flatMap(([setup, target]) => [setup, target]));

  const cacheTargets = [0, Math.floor(frameCount / 2), frameCount - 1];
  while (cacheTargets.length < 10) {
    const candidate = random.nextInt(frameCount);
    if (!used.has(candidate) && !cacheTargets.includes(candidate) && !adjacentProtected.has(candidate)) {
      cacheTargets.push(candidate);
    }
  }
  for (const target of cacheTargets) {
    if (used.has(target)) throw new Error("duplicate cache target");
    used.add(target);
    add(ALPHA4_BASELINE_CATEGORIES[0], target, target);
  }

  while (targets.filter(({ category }) => category === ALPHA4_BASELINE_CATEGORIES[1]).length < 10) {
    const gop = random.nextInt(sync.length);
    const start = sync[gop];
    const end = sync[gop + 1] ?? frameCount;
    if (end - start < MIN_AHEAD_DISTANCE + 1) continue;
    const setup = start + random.nextInt(end - start - MIN_AHEAD_DISTANCE);
    const maximumDistance = Math.min(MAX_AHEAD_DISTANCE, end - 1 - setup);
    const target = setup + MIN_AHEAD_DISTANCE + random.nextInt(maximumDistance - MIN_AHEAD_DISTANCE + 1);
    if (!used.has(setup) && !used.has(target) &&
        !adjacentProtected.has(setup) && !adjacentProtected.has(target)) {
      used.add(setup);
      used.add(target);
      add(ALPHA4_BASELINE_CATEGORIES[1], setup, target);
    }
  }

  while (targets.filter(({ category }) => category === ALPHA4_BASELINE_CATEGORIES[2]).length < 10) {
    const gop = random.nextInt(sync.length);
    const start = sync[gop];
    const end = sync[gop + 1] ?? frameCount;
    if (end - start < 2) continue;
    const target = start + random.nextInt(end - start - 1);
    const maximumDistance = Math.min(MAX_SAME_GOP_REVERSE_DISTANCE, end - 1 - target);
    const setup = target + 1 + random.nextInt(maximumDistance);
    if (!used.has(setup) && !used.has(target) &&
        !adjacentProtected.has(setup) && !adjacentProtected.has(target)) {
      used.add(setup);
      used.add(target);
      add(ALPHA4_BASELINE_CATEGORIES[2], setup, target);
    }
  }

  for (const [setup, target] of adjacentPairs.slice(0, 10)) {
    if (used.has(setup) || used.has(target)) throw new Error("adjacent target was not reserved");
    used.add(setup);
    used.add(target);
    add(ALPHA4_BASELINE_CATEGORIES[3], setup, target);
  }

  while (targets.filter(({ category }) => category === ALPHA4_BASELINE_CATEGORIES[4]).length < 10) {
    const target = random.nextInt(frameCount);
    const half = Math.floor(frameCount / 2);
    const setup = target < half ? target + half : target - half;
    if (!used.has(setup) && !used.has(target) && setup !== target) {
      used.add(setup);
      used.add(target);
      add(ALPHA4_BASELINE_CATEGORIES[4], setup, target);
    }
  }
  if (targets.length !== 50) throw new Error("target count mismatch");
  if (new Set(targets.map(({ targetFrameIndex }) => targetFrameIndex)).size !== 50) throw new Error("target uniqueness mismatch");
  const globallyReservedSlots = targets.flatMap(({ setupFrameIndex, targetFrameIndex }) =>
    [...new Set([setupFrameIndex, targetFrameIndex])]);
  if (new Set(globallyReservedSlots).size !== globallyReservedSlots.length) {
    throw new Error("setup/target global uniqueness mismatch");
  }
  return targets.map((target, ordinal) => ({ ...target, ordinal })).map((target) => {
    if (classifyAlpha4SeekTarget(target, frameCount, sync) !== target.category) {
      throw new Error("seek category is not mutually exclusive");
    }
    return target;
  });
}

function classifyAlpha4SeekTarget(target, frameCount, sync) {
  const distance = Math.abs(target.targetFrameIndex - target.setupFrameIndex);
  const setupSyncOrdinal = sync.findLastIndex((index) => index <= target.setupFrameIndex);
  const targetSyncOrdinal = sync.findLastIndex((index) => index <= target.targetFrameIndex);
  const matches = [
    [ALPHA4_BASELINE_CATEGORIES[0], target.direction === "stationary" && distance === 0],
    [ALPHA4_BASELINE_CATEGORIES[1], target.direction === "forward" &&
      distance >= MIN_AHEAD_DISTANCE && distance <= MAX_AHEAD_DISTANCE && setupSyncOrdinal === targetSyncOrdinal],
    [ALPHA4_BASELINE_CATEGORIES[2], target.direction === "reverse" &&
      distance >= 1 && distance <= MAX_SAME_GOP_REVERSE_DISTANCE && setupSyncOrdinal === targetSyncOrdinal],
    [ALPHA4_BASELINE_CATEGORIES[3], target.direction === "forward" &&
      targetSyncOrdinal - setupSyncOrdinal === 1 && distance < Math.floor(frameCount / 2)],
    [ALPHA4_BASELINE_CATEGORIES[4], target.direction !== "stationary" && distance === Math.floor(frameCount / 2)],
  ].filter(([, matchesCategory]) => matchesCategory);
  return matches.length === 1 ? matches[0][0] : null;
}

function buildAdjacentPairs(frameCount, sync) {
  const pairs = [];
  for (let offset = 0; pairs.length < 10; offset += 1) {
    let addedAtOffset = false;
    for (let relativeIndex = 0; relativeIndex < sync.length - 1 && pairs.length < 10; relativeIndex += 1) {
      const boundary = sync[relativeIndex + 1];
      const previousBoundary = sync[relativeIndex];
      const nextBoundary = sync[relativeIndex + 2] ?? frameCount;
      const setup = boundary - 1 - offset;
      const target = boundary + offset;
      if (setup >= previousBoundary && target < nextBoundary) {
        pairs.push([setup, target]);
        addedAtOffset = true;
      }
    }
    if (!addedAtOffset) throw new Error("not enough adjacent-GOP targets");
  }
  return pairs;
}

export function createAlpha4BurstTargets(frameCount, seed) {
  const random = new Lcg(BigInt(seed) ^ 0x5eed5eedn);
  const targets = [];
  while (targets.length < 10) {
    const candidate = random.nextInt(frameCount);
    if (!targets.includes(candidate)) targets.push(candidate);
  }
  return targets;
}

export function alpha4SeekPlanIdentity(frameCount, syncFrameIndices, seed, targets) {
  const canonical = [
    "alpha4-random-seek-baseline-v1",
    String(frameCount),
    [...new Set(syncFrameIndices)].sort((left, right) => left - right).join(","),
    String(seed),
    ...targets.map((target) =>
      `${target.ordinal}|${target.category}|${target.setupFrameIndex}|${target.targetFrameIndex}|${target.direction}`),
    "",
  ].join("\n");
  return createHash("sha256").update(canonical, "ascii").digest("hex");
}

export function validateAlpha4BaselineReport(report, expectedArtifacts) {
  const fail = (message) => { throw new Error(`alpha4 baseline report invalid: ${message}`); };
  const integer = (value, minimum = 0) => Number.isSafeInteger(value) && value >= minimum;
  const hex = (value, length) => new RegExp(`^[0-9a-f]{${length}}$`).test(value ?? "");
  const exactKeys = (value, allowed, scope) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${scope} shape`);
    const actual = Object.keys(value).sort();
    const expected = [...allowed].sort();
    if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
      fail(`${scope} keys`);
    }
  };
  const serialized = JSON.stringify(report);
  const keys = [];
  const visit = (value) => {
    if (!value || typeof value !== "object") return;
    for (const [key, child] of Object.entries(value)) {
      keys.push(key);
      visit(child);
    }
  };
  visit(report);
  if (keys.some((key) => /^(?:fileName|filePath|videoUri|contentUri|absolutePath|assetPath|sourcePath|sourceSha256|sourceHash|privateFixtureName|fixtureName|mediaName)$/i.test(key)) ||
      /(?:content|file|https?|ftp):\/\/|[A-Za-z]:\\|\/(?:storage|sdcard|data\/user|Users|home)\/|\.(?:mp4|mov|mkv|avi)\b/i.test(serialized)) {
    fail("media identifier");
  }
  const expectedHarnessSourceSha = expectedArtifacts?.expectedHarnessSourceSha?.toLowerCase();
  const expectedTestApkSha256 = expectedArtifacts?.expectedTestApkSha256?.toLowerCase();
  if (!hex(expectedHarnessSourceSha, 40) || !hex(expectedTestApkSha256, 64)) {
    fail("expected harness/test artifact identity");
  }
  exactKeys(report, [
    "schemaVersion", "kind", "status", "baselineCompleteness", "renderMode", "pixelExactnessEvidence",
    "applicationId", "appVersionName",
    "appVersionCode", "appCommitSha", "syntheticOnly", "containsRealMediaMetadata",
    "mediaFileNameIncluded", "mediaUriIncluded", "mediaPathIncluded", "mediaSourceHashIncluded",
    "metricAvailability", "gpuMetrics", "memoryMeasurement", "memory", "fixtures", "fixtureCount", "targetCount",
    "mismatchCount", "writeOpenCount", "runId", "startedAtElapsedRealtimeNs",
    "finishedAtElapsedRealtimeNs", "runtimeSourceSha", "harnessSourceSha",
    "runtimeInputsTreeSha256", "artifactSetRevision", "testCount",
    "instrumentationExpectedTestCount", "appSha256", "testApkSha256",
  ], "report");
  if (report?.schemaVersion !== 1 ||
      report?.kind !== "alpha4-random-source-equivalent-timing-baseline") fail("identity");
  if (report.status !== "PASS" || report.baselineCompleteness !== "PENDING_TRACE_MERGE") fail("status/completeness");
  if (report.renderMode !== "PILOT_SOURCE_EQUIVALENT" ||
      report.pixelExactnessEvidence !== "SEPARATE_FROZEN_GATES") fail("render mode/exactness scope");
  if (report.applicationId !== "com.snowberried.ctcinereviewer.internal" ||
      report.appVersionName !== "0.2.0-alpha.4" || report.appVersionCode !== 5) fail("package identity");
  if (report.appCommitSha !== RUNTIME_SOURCE_SHA || report.runtimeSourceSha !== RUNTIME_SOURCE_SHA ||
      report.runtimeInputsTreeSha256 !== RUNTIME_INPUTS_TREE_SHA256 || report.artifactSetRevision !== 2 ||
      report.appSha256 !== FIXED_DEBUG_APK_SHA256 || report.testApkSha256 !== expectedTestApkSha256 ||
      report.harnessSourceSha !== expectedHarnessSourceSha) fail("pinned artifact identity");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/.test(report.runId ?? "") ||
      report.testCount !== 1 || report.instrumentationExpectedTestCount !== 1 ||
      !integer(report.startedAtElapsedRealtimeNs) ||
      !integer(report.finishedAtElapsedRealtimeNs) ||
      report.finishedAtElapsedRealtimeNs < report.startedAtElapsedRealtimeNs) fail("run identity");
  if (report.syntheticOnly !== true || report.containsRealMediaMetadata !== false) fail("privacy markers");
  for (const name of ["mediaFileNameIncluded", "mediaUriIncluded", "mediaPathIncluded", "mediaSourceHashIncluded"]) {
    if (report[name] !== false) fail(name);
  }
  exactKeys(report.metricAvailability, [
    "acceptedToFirstDecoderOutput", "acceptedToTargetOutput", "gpu", "releaseOvershoot",
  ], "metric availability");
  if (report.metricAvailability?.acceptedToFirstDecoderOutput !== "PENDING_TRACE_MERGE" ||
      report.metricAvailability?.acceptedToTargetOutput !== "PENDING_TRACE_MERGE" ||
      report.metricAvailability?.gpu !== "UNKNOWN" ||
      report.metricAvailability?.releaseOvershoot !== "UNKNOWN" || report.gpuMetrics !== null) fail("metric availability");
  if (report.mismatchCount !== 0 || report.writeOpenCount !== 0) fail("global exactness/write-open");
  if (report.memoryMeasurement !== "POST_ACTIVITY_CLEANUP_SNAPSHOT") fail("root memory measurement scope");
  exactKeys(report.memory, ["javaUsedBytes", "nativeAllocatedBytes", "totalPssBytes"], "memory");
  if (!integer(report.memory?.javaUsedBytes) || !integer(report.memory?.nativeAllocatedBytes) ||
      !integer(report.memory?.totalPssBytes)) fail("memory");
  if (!Array.isArray(report.fixtures) || report.fixtures.length !== 5 || report.fixtureCount !== 5 || report.targetCount !== 250) fail("fixture totals");
  if (new Set(report.fixtures.map(({ fixtureId }) => fixtureId)).size !== 5) fail("duplicate fixture id");
  for (const fixture of report.fixtures) {
    exactKeys(fixture, [
      "fixtureId", "frameCount", "codecComponent", "hardwareAccelerated", "targetCount",
      "deterministicSeed", "syncFrameIndices", "syncSamples", "targetSetIdentity", "categoryCounts",
      "containsFirstMiddleLast", "containsGopBoundary", "targets", "burst", "cacheBudgetBytes",
      "cacheBytes", "cacheEntryCount", "peakCacheEntryCount", "cacheEvictionCount",
      "cacheRejectionCount", "cacheThrashCount", "liveTextureCount", "peakLiveTextureCount",
      "textureDoubleReleaseCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount",
      "publicationInvariantViolationCount", "fullFrameReadbackCount",
      "inSessionMemory",
    ], "fixture");
    if (!/^fixture-0[1-5]$/.test(fixture.fixtureId) || fixture.targetCount !== 50 || !Array.isArray(fixture.targets) || fixture.targets.length !== 50) fail("fixture identity/count");
    exactKeys(
      fixture.inSessionMemory,
      ["javaUsedBytes", "nativeAllocatedBytes", "totalPssBytes"],
      "in-session memory",
    );
    if (!integer(fixture.inSessionMemory.javaUsedBytes) ||
        !integer(fixture.inSessionMemory.nativeAllocatedBytes) ||
        !integer(fixture.inSessionMemory.totalPssBytes)) fail("in-session memory");
    if (!integer(fixture.frameCount, 300) || !integer(fixture.deterministicSeed) ||
        !Array.isArray(fixture.syncFrameIndices) || fixture.syncFrameIndices.length < 2 ||
        fixture.syncFrameIndices[0] !== 0 || !fixture.syncFrameIndices.every((value) => integer(value) && value < fixture.frameCount) ||
        !fixture.syncFrameIndices.every((value, index, values) => index === 0 || value > values[index - 1]) ||
        typeof fixture.codecComponent !== "string" || fixture.codecComponent.length === 0 ||
        fixture.hardwareAccelerated !== true) fail("fixture metadata");
    if (!Array.isArray(fixture.syncSamples) || fixture.syncSamples.length !== fixture.syncFrameIndices.length) {
      fail("sync sample evidence");
    }
    fixture.syncSamples.forEach((sample, index) => {
      exactKeys(sample, ["displayFrameIndex", "sampleOrdinal"], "sync sample");
      if (!integer(sample.displayFrameIndex) || sample.displayFrameIndex >= fixture.frameCount ||
          !integer(sample.sampleOrdinal) || sample.sampleOrdinal >= fixture.frameCount || (index > 0 &&
            sample.sampleOrdinal <= fixture.syncSamples[index - 1].sampleOrdinal)) {
        fail("sync sample evidence");
      }
    });
    if (fixture.syncSamples[0].displayFrameIndex !== 0 || fixture.syncSamples[0].sampleOrdinal !== 0 ||
        new Set(fixture.syncSamples.map(({ displayFrameIndex }) => displayFrameIndex)).size !== fixture.syncSamples.length) {
      fail("sync sample origin/uniqueness");
    }
    const reportedSyncIndices = fixture.syncSamples.map(({ displayFrameIndex }) => displayFrameIndex)
      .sort((left, right) => left - right);
    if (reportedSyncIndices.some((value, index) => value !== fixture.syncFrameIndices[index])) {
      fail("sync sample/display index mismatch");
    }
    const previousSync = (sampleOrdinal) => {
      const ordinal = fixture.syncSamples.findLastIndex((sample) => sample.sampleOrdinal <= sampleOrdinal);
      if (ordinal < 0) fail("previous-sync unavailable");
      return { ordinal, displayFrameIndex: fixture.syncSamples[ordinal].displayFrameIndex };
    };
    const expectedPlan = createAlpha4SeekPlan(fixture.frameCount, fixture.syncFrameIndices, fixture.deterministicSeed);
    if (fixture.targetSetIdentity !== alpha4SeekPlanIdentity(
      fixture.frameCount,
      fixture.syncFrameIndices,
      fixture.deterministicSeed,
      expectedPlan,
    )) fail("target-set identity");
    for (const category of ALPHA4_BASELINE_CATEGORIES) {
      if (fixture.categoryCounts?.[category] !== 10) fail(`category count ${category}`);
    }
    exactKeys(fixture.categoryCounts, ALPHA4_BASELINE_CATEGORIES, "category counts");
    if (fixture.containsFirstMiddleLast !== true || fixture.containsGopBoundary !== true) fail("required boundaries");
    fixture.targets.forEach((target, index) => {
      exactKeys(target, [
        "ordinal", "category", "direction", "setupFrameIndex", "targetFrameIndex",
        "setupSampleOrdinal", "targetSampleOrdinal", "targetPtsUs", "fileGeneration",
        "requestGeneration", "acceptedElapsedRealtimeNs", "publishedElapsedRealtimeNs",
        "setupPreviousSyncFrameIndex", "targetPreviousSyncFrameIndex", "setupSyncOrdinal",
        "targetSyncOrdinal", "acceptedToFirstDecoderOutputUs", "acceptedToTargetOutputUs",
        "acceptedToPublicationUs", "acceptedDisplayedFrameIndex", "publishedDisplayedFrameIndex",
        "acceptedDisplayedMeasurement", "acceptedRawFrameLag", "publishedRawFrameLag",
        "decodedOutputCount", "seekCount", "flushCount", "cacheOrHistoryHit",
        "staleDiscardCount", "nonTargetPublishedCount",
      ], "target");
      const expected = expectedPlan[index];
      if (target.ordinal !== expected.ordinal || target.category !== expected.category ||
          target.direction !== expected.direction || target.setupFrameIndex !== expected.setupFrameIndex ||
          target.targetFrameIndex !== expected.targetFrameIndex) fail("target plan drift");
      if (!integer(target.targetPtsUs) || !integer(target.setupPreviousSyncFrameIndex) ||
          !integer(target.targetPreviousSyncFrameIndex) || !integer(target.setupSyncOrdinal) ||
          !integer(target.targetSyncOrdinal) || !integer(target.setupSampleOrdinal) ||
          target.setupSampleOrdinal >= fixture.frameCount || !integer(target.targetSampleOrdinal) ||
          target.targetSampleOrdinal >= fixture.frameCount || !integer(target.fileGeneration, 1) ||
          !integer(target.requestGeneration, 1) || !integer(target.acceptedElapsedRealtimeNs) ||
          !integer(target.publishedElapsedRealtimeNs) ||
          target.publishedElapsedRealtimeNs < target.acceptedElapsedRealtimeNs ||
          target.acceptedToFirstDecoderOutputUs !== null ||
          target.acceptedToTargetOutputUs !== null || !integer(target.acceptedToPublicationUs) ||
          target.acceptedToPublicationUs !== Math.floor(
            (target.publishedElapsedRealtimeNs - target.acceptedElapsedRealtimeNs) / 1_000,
          ) ||
          target.acceptedDisplayedFrameIndex !== expected.setupFrameIndex ||
          target.publishedDisplayedFrameIndex !== expected.targetFrameIndex ||
          target.acceptedDisplayedMeasurement !== "SETUP_PUBLICATION" ||
          target.acceptedRawFrameLag !== Math.abs(expected.targetFrameIndex - target.acceptedDisplayedFrameIndex) ||
          target.publishedRawFrameLag !== Math.abs(expected.targetFrameIndex - target.publishedDisplayedFrameIndex) ||
          !integer(target.decodedOutputCount) ||
          !integer(target.seekCount) || !integer(target.flushCount) ||
          !integer(target.staleDiscardCount) || target.nonTargetPublishedCount !== 0) fail("target evidence");
      const actualDirection = target.targetFrameIndex > target.acceptedDisplayedFrameIndex
        ? "forward"
        : target.targetFrameIndex < target.acceptedDisplayedFrameIndex ? "reverse" : "stationary";
      if (actualDirection !== target.direction) fail("actual direction evidence");
      const setupPreviousSync = previousSync(target.setupSampleOrdinal);
      const targetPreviousSync = previousSync(target.targetSampleOrdinal);
      if (target.setupPreviousSyncFrameIndex !== setupPreviousSync.displayFrameIndex ||
          target.setupSyncOrdinal !== setupPreviousSync.ordinal ||
          target.targetPreviousSyncFrameIndex !== targetPreviousSync.displayFrameIndex ||
          target.targetSyncOrdinal !== targetPreviousSync.ordinal) fail("previous-sync exact evidence");
      const expectedHit = expected.category === ALPHA4_BASELINE_CATEGORIES[0];
      if (target.cacheOrHistoryHit !== expectedHit) fail("category cache contamination");
      const distance = Math.abs(target.targetFrameIndex - target.setupFrameIndex);
      const categoryPredicates = {
        [ALPHA4_BASELINE_CATEGORIES[0]]: target.direction === "stationary" && distance === 0,
        [ALPHA4_BASELINE_CATEGORIES[1]]: target.direction === "forward" &&
          distance >= MIN_AHEAD_DISTANCE && distance <= MAX_AHEAD_DISTANCE &&
          target.setupSyncOrdinal === target.targetSyncOrdinal,
        [ALPHA4_BASELINE_CATEGORIES[2]]: target.direction === "reverse" &&
          distance >= 1 && distance <= MAX_SAME_GOP_REVERSE_DISTANCE &&
          target.setupSyncOrdinal === target.targetSyncOrdinal,
        [ALPHA4_BASELINE_CATEGORIES[3]]: target.direction === "forward" &&
          target.targetSyncOrdinal - target.setupSyncOrdinal === 1 && distance < Math.floor(fixture.frameCount / 2),
        [ALPHA4_BASELINE_CATEGORIES[4]]: target.direction !== "stationary" &&
          distance === Math.floor(fixture.frameCount / 2),
      };
      const matchingCategories = Object.entries(categoryPredicates)
        .filter(([, matchesCategory]) => matchesCategory)
        .map(([category]) => category);
      if (matchingCategories.length !== 1 || matchingCategories[0] !== target.category) {
        fail("mutually-exclusive category predicate");
      }
    });
    const measuredFileGeneration = fixture.targets[0].fileGeneration;
    if (fixture.targets.some(({ fileGeneration }) => fileGeneration !== measuredFileGeneration) ||
        !fixture.targets.every((target, index, targets) =>
          index === 0 || target.requestGeneration > targets[index - 1].requestGeneration)) {
      fail("measured generation continuity");
    }
    const measuredSlots = fixture.targets.flatMap((target) => target.setupFrameIndex === target.targetFrameIndex
      ? [[target.setupFrameIndex, target.setupSampleOrdinal]]
      : [
          [target.setupFrameIndex, target.setupSampleOrdinal],
          [target.targetFrameIndex, target.targetSampleOrdinal],
        ]);
    if (new Set(measuredSlots.map(([frameIndex]) => frameIndex)).size !== measuredSlots.length ||
        new Set(measuredSlots.map(([, sampleOrdinal]) => sampleOrdinal)).size !== measuredSlots.length) {
      fail("setup/target evidence contamination");
    }
    const syncSampleByFrame = new Map(fixture.syncSamples.map((sample) =>
      [sample.displayFrameIndex, sample.sampleOrdinal]));
    if (measuredSlots.some(([frameIndex, sampleOrdinal]) =>
      syncSampleByFrame.has(frameIndex) && syncSampleByFrame.get(frameIndex) !== sampleOrdinal)) {
      fail("sync target sample mismatch");
    }
    const expectedBurst = createAlpha4BurstTargets(fixture.frameCount, fixture.deterministicSeed);
    exactKeys(fixture.burst, [
      "requestCount", "acceptedRequestCount", "acceptedRequestGenerations", "finalTargetFrameIndex",
      "fileGeneration", "requestGeneration", "acceptedElapsedRealtimeNs",
      "assessmentWindowStartElapsedRealtimeNs", "publishedElapsedRealtimeNs",
      "acceptedToPublicationUs", "nonTargetPublishedCount",
      "nonFinalPublishedAfterFinalAcceptanceCount", "publicationAssessment",
      "discardedStaleAssessment", "staleDiscardCount",
    ], "burst");
    if (fixture.burst?.requestCount !== 10 || fixture.burst?.acceptedRequestCount !== 10 ||
        !Array.isArray(fixture.burst?.acceptedRequestGenerations) ||
        fixture.burst.acceptedRequestGenerations.length !== 10 ||
        !fixture.burst.acceptedRequestGenerations.every((generation, index, generations) =>
          integer(generation, 1) && (index === 0 || generation > generations[index - 1])) ||
        fixture.burst.requestGeneration !== fixture.burst.acceptedRequestGenerations.at(-1) ||
        fixture.burst?.finalTargetFrameIndex !== expectedBurst.at(-1) ||
        fixture.burst?.fileGeneration !== measuredFileGeneration ||
        !integer(fixture.burst?.requestGeneration, 1) ||
        fixture.burst.requestGeneration <= fixture.targets.at(-1).requestGeneration ||
        !integer(fixture.burst?.acceptedElapsedRealtimeNs) || !integer(fixture.burst?.publishedElapsedRealtimeNs) ||
        fixture.burst.assessmentWindowStartElapsedRealtimeNs !== fixture.burst.acceptedElapsedRealtimeNs ||
        fixture.burst.publishedElapsedRealtimeNs < fixture.burst.acceptedElapsedRealtimeNs ||
        !integer(fixture.burst?.acceptedToPublicationUs) || fixture.burst?.nonTargetPublishedCount !== 0 ||
        fixture.burst?.nonFinalPublishedAfterFinalAcceptanceCount !== 0 ||
        fixture.burst?.publicationAssessment !== "EVENT_TIMESTAMP_AT_OR_AFTER_FINAL_ACCEPTANCE" ||
        fixture.burst?.discardedStaleAssessment !== "FINAL_GENERATION_ONLY_NO_CALLBACK_TIMESTAMP" ||
        fixture.burst.acceptedToPublicationUs !== Math.floor(
          (fixture.burst.publishedElapsedRealtimeNs - fixture.burst.acceptedElapsedRealtimeNs) / 1_000,
        ) ||
        !integer(fixture.burst?.staleDiscardCount)) fail("burst last-request-wins");
    if (!integer(fixture.cacheBudgetBytes, 1) || !integer(fixture.cacheBytes) || fixture.cacheBytes > fixture.cacheBudgetBytes ||
        !integer(fixture.cacheEntryCount) || !integer(fixture.peakCacheEntryCount) ||
        fixture.cacheEntryCount > fixture.peakCacheEntryCount ||
        !integer(fixture.cacheEvictionCount) || !integer(fixture.cacheRejectionCount) ||
        !integer(fixture.cacheThrashCount) || !integer(fixture.liveTextureCount) ||
        !integer(fixture.peakLiveTextureCount) || fixture.liveTextureCount > fixture.peakLiveTextureCount ||
        fixture.textureDoubleReleaseCount !== 0 ||
        fixture.staleBeforeSwapCount !== 0 || fixture.swapFailureCount !== 0 ||
        fixture.surfaceInvalidCount !== 0 || fixture.publicationInvariantViolationCount !== 0 ||
        fixture.fullFrameReadbackCount !== 0) fail("cache/texture/publication invariant");
  }
  return true;
}
