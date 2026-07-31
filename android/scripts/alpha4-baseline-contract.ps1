$ErrorActionPreference = "Stop"

function Test-CcrAlpha4BaselineProperty {
  param([object]$Value, [string]$Name)
  return $null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CcrAlpha4BaselineRequiredProperty {
  param([object]$Value, [string]$Name)
  if (-not (Test-CcrAlpha4BaselineProperty $Value $Name)) {
    throw "ALPHA4_RANDOM_BASELINE_PROPERTY_MISSING:$Name"
  }
  return $Value.PSObject.Properties[$Name].Value
}

function Test-CcrAlpha4PrivateMediaReference {
  param([Parameter(Mandatory = $true)][string]$Serialized)
  return $Serialized -match '(?i)\b(fileName|displayName|originalName|videoUri|mediaUri|contentUri|documentUri|absolutePath|mediaPath|fixturePath|inputPath|inputUri|sourcePath|sourceFile|sourceSha256|sourceHash|mediaSourceHash|privateFixtureName)\b' -or
    $Serialized -match '(?i)[A-Za-z]:\\|/(storage|sdcard|Users|home|data/(?:media|user))/|content://|file://|\.(?:mp4|m4v|mov|avi|mkv|hevc|h264)(?:["?]|$)'
}

function New-CcrAlpha4DeadlineUtc {
  param([Parameter(Mandatory = $true)][ValidateRange(1, 240)][int]$MaxMinutes)
  return [DateTimeOffset]::UtcNow.AddMinutes($MaxMinutes)
}

function Get-CcrAlpha4RemainingSeconds {
  param(
    [Parameter(Mandatory = $true)][DateTimeOffset]$DeadlineUtc,
    [Parameter(Mandatory = $true)][string]$Stage
  )
  $remaining = [long][Math]::Floor(($DeadlineUtc - [DateTimeOffset]::UtcNow).TotalSeconds)
  if ($remaining -le 0) { throw "ALPHA4_BASELINE_MAX_MINUTES_EXCEEDED:$Stage" }
  return [Math]::Min($remaining, [int]::MaxValue)
}

function Assert-CcrAlpha4Deadline {
  param(
    [Parameter(Mandatory = $true)][DateTimeOffset]$DeadlineUtc,
    [Parameter(Mandatory = $true)][string]$Stage
  )
  Get-CcrAlpha4RemainingSeconds -DeadlineUtc $DeadlineUtc -Stage $Stage | Out-Null
}

function Assert-CcrAlpha4RandomSessionCheckpointIdentity {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][int]$ExpectedMaxMinutes,
    [Parameter(Mandatory = $true)][string]$ExpectedTestClass,
    [Parameter(Mandatory = $true)][string]$ExpectedReportName
  )
  if ([int]$Checkpoint.schemaVersion -ne 1 -or
      [string]$Checkpoint.kind -cne "s24-alpha4-random-session-checkpoint" -or
      [string]$Checkpoint.status -cne "PASS" -or
      [string]$Checkpoint.completedStage -cne "session-settings-captured" -or
      [string]$Checkpoint.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [int]$Checkpoint.artifactSetRevision -ne $script:CcrPinnedArtifactSetRevision -or
      [string]$Checkpoint.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Checkpoint.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Checkpoint.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Checkpoint.debugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Checkpoint.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Checkpoint.device.serial -cne $Context.Serial -or
      [string]$Checkpoint.device.fingerprint -cne $Context.Fingerprint -or
      [int]$Checkpoint.parameters.maxMinutes -ne $ExpectedMaxMinutes -or
      [string]$Checkpoint.parameters.testClass -cne $ExpectedTestClass -or
      [string]$Checkpoint.parameters.reportName -cne $ExpectedReportName -or
      [string]$Checkpoint.parameters.resumeGranularity -cne
        "whole-instrumentation-restart; complete-pass-evidence-only-reuse") {
    throw "ALPHA4_RANDOM_RESUME_SESSION_IDENTITY_MISMATCH"
  }
  foreach ($field in @("stayAwake", "brightnessMode", "brightness", "screenTimeout", "accelerometerRotation", "userRotation")) {
    if ($null -eq $Checkpoint.savedSettings.PSObject.Properties[$field]) {
      throw "ALPHA4_RANDOM_RESUME_SAVED_SETTING_MISSING:$field"
    }
  }
  return $Checkpoint
}

function Invoke-CcrAlpha4TimedInstrumentation {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][ValidateSet("debugTest", "macrobenchmarkTest")][string]$TestRole,
    [Parameter(Mandatory = $true)][string]$ClassName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][DateTimeOffset]$DeadlineUtc,
    [int]$ExpectedTestCount = 1,
    [hashtable]$AdditionalArguments = @{}
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  if ($ExpectedTestCount -lt 1) { throw "ALPHA4_BASELINE_EXPECTED_TEST_COUNT_INVALID" }
  $test = Get-CcrPinnedArtifact $Context $TestRole
  $appRole = if ($TestRole -ceq "debugTest") { "debugApp" } else { "benchmarkApp" }
  $app = Get-CcrPinnedArtifact $Context $appRole
  $required = [ordered]@{
    class = $ClassName
    runId = $RunId
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    expectedAppSha256 = [string]$app.sha256
    expectedTestApkSha256 = [string]$test.sha256
  }
  foreach ($key in $AdditionalArguments.Keys) {
    if ($required.Contains($key)) { throw "ALPHA4_BASELINE_INSTRUMENTATION_ARGUMENT_OVERRIDE:$key" }
    $required[$key] = [string]$AdditionalArguments[$key]
  }
  $remainingSeconds = Get-CcrAlpha4RemainingSeconds -DeadlineUtc $DeadlineUtc -Stage "instrumentation-start/$TestRole"
  $args = @(
    "-s", $Context.Serial, "shell", "timeout", "${remainingSeconds}s", "am", "instrument", "-w", "-r"
  )
  foreach ($key in @($required.Keys | Sort-Object)) { $args += @("-e", [string]$key, [string]$required[$key]) }
  $args += "$($test.packageName)/$($test.runner)"
  $minimumStartedAt = Get-CcrPinnedDeviceElapsedRealtimeNs $Context
  $result = Invoke-CcrPinnedAdb $Context $args
  if ($result.exitCode -eq 124) { throw "ALPHA4_BASELINE_INSTRUMENTATION_TIMEOUT:$TestRole" }
  if ($result.exitCode -ne 0 -or
      $result.output -notmatch "OK \($ExpectedTestCount tests?\)" -or
      $result.output -match '(?m)^FAILURES!!!\s*$|INSTRUMENTATION_(?:FAILED|ABORTED):') {
    throw "ALPHA4_BASELINE_INSTRUMENTATION_FAILED:$TestRole"
  }
  Assert-CcrAlpha4Deadline -DeadlineUtc $DeadlineUtc -Stage "instrumentation-finish/$TestRole"
  return [PSCustomObject]@{
    RunId = $RunId
    MinimumStartedAtElapsedRealtimeNs = $minimumStartedAt
    Output = $result.output
  }
}

function Assert-CcrAlpha4ReverseBaselineEvidence {
  param([Parameter(Mandatory = $true)][object]$Evidence)
  $requiredFields = @(
    "publicationGapMaxUs", "foregroundDecoded", "issuedRequestCount", "coalescedRequestCount",
    "prefetchHitCount", "cacheEvictionCount", "seekCount", "flushCount", "sequentialEntryCount",
    "sequentialFallbackCount", "sequentialOutputCount", "swapFailureCount", "codecComponent",
    "hardwareAccelerated", "canonicalFrameBytes", "cacheBudgetBytes", "cacheBytes", "cacheEntryCount",
    "peakCacheEntryCount", "cacheRejectionCount", "cacheThrashCount", "liveTextureCount",
    "peakLiveTextureCount", "textureDoubleReleaseCount", "staleDiscardCount", "staleBeforeSwapCount",
    "surfaceInvalidCount", "publicationInvariantViolationCount", "decoderRecreateCount", "javaUsedBytes",
    "nativeAllocatedBytes", "totalPssBytes", "gpuMetricAvailability"
  )
  foreach ($iteration in @($Evidence.iterations)) {
    foreach ($field in $requiredFields) {
      if (-not (Test-CcrAlpha4BaselineProperty $iteration $field)) {
        throw "ALPHA4_REVERSE_BASELINE_COUNTER_MISSING:$field"
      }
    }
    foreach ($field in @(
      "publicationGapMaxUs", "foregroundDecoded", "issuedRequestCount", "coalescedRequestCount",
      "prefetchHitCount", "cacheEvictionCount", "seekCount", "flushCount", "sequentialEntryCount",
      "sequentialFallbackCount", "sequentialOutputCount", "swapFailureCount", "canonicalFrameBytes",
      "cacheBudgetBytes", "cacheBytes", "cacheEntryCount", "peakCacheEntryCount", "cacheRejectionCount",
      "cacheThrashCount", "liveTextureCount", "peakLiveTextureCount", "textureDoubleReleaseCount",
      "staleDiscardCount", "staleBeforeSwapCount", "surfaceInvalidCount", "publicationInvariantViolationCount",
      "decoderRecreateCount", "javaUsedBytes", "nativeAllocatedBytes", "totalPssBytes"
    )) {
      if ([long]$iteration.$field -lt 0) { throw "ALPHA4_REVERSE_BASELINE_COUNTER_NEGATIVE:$field" }
    }
    if ([long]$iteration.foregroundDecoded -le 0 -or
        [long]$iteration.issuedRequestCount -le 0 -or
        [long]$iteration.seekCount -le 0 -or
        [long]$iteration.flushCount -le 0) {
      throw "ALPHA4_REVERSE_BASELINE_PATH_NOT_EXERCISED:$($iteration.runIteration)"
    }
    if ([long]$iteration.activeMs -lt 10000 -and [long]$iteration.published -lt 100) {
      throw "ALPHA4_REVERSE_BASELINE_DURATION_TOO_SHORT:$($iteration.runIteration)"
    }
    if ([long]$iteration.swapFailureCount -ne 0) {
      throw "ALPHA4_REVERSE_BASELINE_SWAP_FAILURE:$($iteration.runIteration)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$iteration.codecComponent) -or
        [string]$iteration.codecComponent -ceq "UNKNOWN" -or $iteration.hardwareAccelerated -ne $true) {
      throw "ALPHA4_REVERSE_BASELINE_DECODER_IDENTITY_INVALID:$($iteration.runIteration)"
    }
    if ([long]$iteration.canonicalFrameBytes -le 0 -or [long]$iteration.cacheBudgetBytes -le 0 -or
        [long]$iteration.cacheBytes -gt [long]$iteration.cacheBudgetBytes -or
        [long]$iteration.peakCacheEntryCount -lt [long]$iteration.cacheEntryCount -or
        [long]$iteration.peakLiveTextureCount -lt [long]$iteration.liveTextureCount) {
      throw "ALPHA4_REVERSE_BASELINE_RESOURCE_COUNTER_INVALID:$($iteration.runIteration)"
    }
    foreach ($field in @(
      "textureDoubleReleaseCount", "staleBeforeSwapCount", "surfaceInvalidCount",
      "publicationInvariantViolationCount"
    )) {
      if ([long]$iteration.$field -ne 0) { throw "ALPHA4_REVERSE_BASELINE_SAFETY_COUNTER_NONZERO:$field" }
    }
    if ([string]$iteration.gpuMetricAvailability -cne "UNKNOWN") {
      throw "ALPHA4_REVERSE_BASELINE_GPU_AVAILABILITY_MISMATCH"
    }
  }
  return $Evidence
}

function Assert-CcrAlpha4RandomBaselineReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][string]$ExpectedRuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$ExpectedRuntimeInputsTreeSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedHarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugTestSha256
  )
  if ([int](Get-CcrAlpha4BaselineRequiredProperty $Report "schemaVersion") -ne 1 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "kind") -cne "alpha4-random-source-equivalent-timing-baseline" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "status") -cne "PASS") {
    throw "ALPHA4_RANDOM_BASELINE_IDENTITY_MISMATCH"
  }
  if ([string](Get-CcrAlpha4BaselineRequiredProperty $Report "baselineCompleteness") -cne "PENDING_TRACE_MERGE" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "renderMode") -cne "PILOT_SOURCE_EQUIVALENT" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "pixelExactnessEvidence") -cne "SEPARATE_FROZEN_GATES" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "memoryMeasurement") -cne "POST_ACTIVITY_CLEANUP_SNAPSHOT" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "applicationId") -cne "com.snowberried.ctcinereviewer.internal" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "appVersionName") -cne "0.2.0-alpha.4" -or
      [long](Get-CcrAlpha4BaselineRequiredProperty $Report "appVersionCode") -ne 5 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "appCommitSha") -cne $ExpectedRuntimeSourceSha -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "runtimeSourceSha") -cne $ExpectedRuntimeSourceSha -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "runtimeInputsTreeSha256") -cne $ExpectedRuntimeInputsTreeSha256 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "harnessSourceSha") -cne $ExpectedHarnessSourceSha -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "artifactSetRevision") -ne 2 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "appSha256") -cne $ExpectedDebugAppSha256 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "testApkSha256") -cne $ExpectedDebugTestSha256) {
    throw "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"
  }
  if ([string](Get-CcrAlpha4BaselineRequiredProperty $Report "runId") -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$' -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "testCount") -ne 1 -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "instrumentationExpectedTestCount") -ne 1 -or
      [long](Get-CcrAlpha4BaselineRequiredProperty $Report "startedAtElapsedRealtimeNs") -lt 0 -or
      [long](Get-CcrAlpha4BaselineRequiredProperty $Report "finishedAtElapsedRealtimeNs") -lt [long]$Report.startedAtElapsedRealtimeNs) {
    throw "ALPHA4_RANDOM_BASELINE_RUN_IDENTITY_MISMATCH"
  }
  if ((Get-CcrAlpha4BaselineRequiredProperty $Report "syntheticOnly") -ne $true -or
      (Get-CcrAlpha4BaselineRequiredProperty $Report "containsRealMediaMetadata") -ne $false) {
    throw "ALPHA4_RANDOM_BASELINE_PRIVACY_MISMATCH"
  }
  foreach ($field in @("mediaFileNameIncluded", "mediaUriIncluded", "mediaPathIncluded", "mediaSourceHashIncluded")) {
    if ((Get-CcrAlpha4BaselineRequiredProperty $Report $field) -ne $false) {
      throw "ALPHA4_RANDOM_BASELINE_PRIVACY_MARKER_MISMATCH:$field"
    }
  }
  $serialized = $Report | ConvertTo-Json -Depth 20 -Compress
  if (Test-CcrAlpha4PrivateMediaReference $serialized) {
    throw "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"
  }

  $availability = Get-CcrAlpha4BaselineRequiredProperty $Report "metricAvailability"
  foreach ($field in @("acceptedToFirstDecoderOutput", "acceptedToTargetOutput")) {
    if ([string](Get-CcrAlpha4BaselineRequiredProperty $availability $field) -cne "PENDING_TRACE_MERGE") {
      throw "ALPHA4_RANDOM_BASELINE_PENDING_METRIC_MISMATCH:$field"
    }
  }
  foreach ($field in @("gpu", "releaseOvershoot")) {
    if ([string](Get-CcrAlpha4BaselineRequiredProperty $availability $field) -cne "UNKNOWN") {
      throw "ALPHA4_RANDOM_BASELINE_UNKNOWN_METRIC_MISMATCH:$field"
    }
  }
  if ($null -ne (Get-CcrAlpha4BaselineRequiredProperty $Report "gpuMetrics")) {
    throw "ALPHA4_RANDOM_BASELINE_GPU_METRICS_MUST_BE_NULL"
  }
  if ([int](Get-CcrAlpha4BaselineRequiredProperty $Report "fixtureCount") -ne 5 -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "targetCount") -ne 250 -or
      [long](Get-CcrAlpha4BaselineRequiredProperty $Report "mismatchCount") -ne 0 -or
      [long](Get-CcrAlpha4BaselineRequiredProperty $Report "writeOpenCount") -ne 0) {
    throw "ALPHA4_RANDOM_BASELINE_TOTALS_MISMATCH"
  }

  $memory = Get-CcrAlpha4BaselineRequiredProperty $Report "memory"
  foreach ($field in @("javaUsedBytes", "nativeAllocatedBytes", "totalPssBytes")) {
    if ([long](Get-CcrAlpha4BaselineRequiredProperty $memory $field) -lt 0) {
      throw "ALPHA4_RANDOM_BASELINE_MEMORY_INVALID:$field"
    }
  }

  $fixtures = @((Get-CcrAlpha4BaselineRequiredProperty $Report "fixtures"))
  $fixtureIds = @($fixtures | ForEach-Object { [string](Get-CcrAlpha4BaselineRequiredProperty $_ "fixtureId") } | Sort-Object)
  if ($fixtures.Count -ne 5 -or ($fixtureIds -join ",") -cne "fixture-01,fixture-02,fixture-03,fixture-04,fixture-05") {
    throw "ALPHA4_RANDOM_BASELINE_FIXTURE_IDENTITY_MISMATCH"
  }
  $categories = @("cache-or-history-hit", "ahead-of-cursor", "same-gop", "adjacent-gop", "far-random")
  foreach ($fixture in $fixtures) {
    $fixtureId = [string]$fixture.fixtureId
    $frameCount = [int](Get-CcrAlpha4BaselineRequiredProperty $fixture "frameCount")
    $targets = @((Get-CcrAlpha4BaselineRequiredProperty $fixture "targets"))
    $syncFrameIndices = @((Get-CcrAlpha4BaselineRequiredProperty $fixture "syncFrameIndices"))
    $syncSamples = @((Get-CcrAlpha4BaselineRequiredProperty $fixture "syncSamples"))
    $inSessionMemory = Get-CcrAlpha4BaselineRequiredProperty $fixture "inSessionMemory"
    if ($frameCount -lt 300 -or
        $syncFrameIndices.Count -lt 2 -or [int]$syncFrameIndices[0] -ne 0 -or
        @($syncFrameIndices | Where-Object { [int]$_ -lt 0 -or [int]$_ -ge $frameCount }).Count -ne 0 -or
        $syncSamples.Count -ne $syncFrameIndices.Count -or
        [string]::IsNullOrWhiteSpace([string](Get-CcrAlpha4BaselineRequiredProperty $fixture "codecComponent")) -or
        (Get-CcrAlpha4BaselineRequiredProperty $fixture "hardwareAccelerated") -ne $true -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "fullFrameReadbackCount") -ne 0 -or
        [int](Get-CcrAlpha4BaselineRequiredProperty $fixture "targetCount") -ne 50 -or
        $targets.Count -ne 50 -or
        (Get-CcrAlpha4BaselineRequiredProperty $fixture "containsFirstMiddleLast") -ne $true -or
        (Get-CcrAlpha4BaselineRequiredProperty $fixture "containsGopBoundary") -ne $true -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "deterministicSeed") -le 0 -or
        [string](Get-CcrAlpha4BaselineRequiredProperty $fixture "targetSetIdentity") -notmatch '^[0-9a-f]{64}$') {
      throw "ALPHA4_RANDOM_BASELINE_FIXTURE_CONTRACT_MISMATCH:$fixtureId"
    }
    if ([long](Get-CcrAlpha4BaselineRequiredProperty $inSessionMemory "javaUsedBytes") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $inSessionMemory "nativeAllocatedBytes") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $inSessionMemory "totalPssBytes") -le 0) {
      throw "ALPHA4_RANDOM_BASELINE_IN_SESSION_MEMORY_INVALID:$fixtureId"
    }
    for ($syncIndex = 0; $syncIndex -lt $syncSamples.Count; $syncIndex += 1) {
      $syncSample = $syncSamples[$syncIndex]
      $displayFrameIndex = [int](Get-CcrAlpha4BaselineRequiredProperty $syncSample "displayFrameIndex")
      $sampleOrdinal = [int](Get-CcrAlpha4BaselineRequiredProperty $syncSample "sampleOrdinal")
      if ($displayFrameIndex -lt 0 -or $displayFrameIndex -ge $frameCount -or
          $sampleOrdinal -lt 0 -or $sampleOrdinal -ge $frameCount -or
          $displayFrameIndex -ne [int]$syncFrameIndices[$syncIndex] -or
          ($syncIndex -eq 0 -and ($displayFrameIndex -ne 0 -or $sampleOrdinal -ne 0)) -or
          ($syncIndex -gt 0 -and
            ($displayFrameIndex -le [int]$syncSamples[$syncIndex - 1].displayFrameIndex -or
             $sampleOrdinal -le [int]$syncSamples[$syncIndex - 1].sampleOrdinal))) {
        throw "ALPHA4_RANDOM_BASELINE_SYNC_SAMPLE_MISMATCH:$fixtureId/$syncIndex"
      }
    }
    $categoryCounts = Get-CcrAlpha4BaselineRequiredProperty $fixture "categoryCounts"
    foreach ($category in $categories) {
      if ([int](Get-CcrAlpha4BaselineRequiredProperty $categoryCounts $category) -ne 10 -or
          @($targets | Where-Object { [string]$_.category -ceq $category }).Count -ne 10) {
        throw "ALPHA4_RANDOM_BASELINE_CATEGORY_COUNT_MISMATCH:$fixtureId/$category"
      }
    }
    $ordinals = @($targets | ForEach-Object { [int](Get-CcrAlpha4BaselineRequiredProperty $_ "ordinal") } | Sort-Object)
    if (($ordinals -join ",") -cne ((0..49) -join ",")) {
      throw "ALPHA4_RANDOM_BASELINE_TARGET_ORDINAL_MISMATCH:$fixtureId"
    }
    $measuredFrameIndices = [System.Collections.Generic.HashSet[int]]::new()
    $measuredSampleOrdinals = [System.Collections.Generic.HashSet[int]]::new()
    $measuredFileGeneration = [long](Get-CcrAlpha4BaselineRequiredProperty $targets[0] "fileGeneration")
    $previousRequestGeneration = 0L
    foreach ($target in $targets) {
      $ordinal = [int]$target.ordinal
      $direction = [string](Get-CcrAlpha4BaselineRequiredProperty $target "direction")
      $setupFrameIndex = [int](Get-CcrAlpha4BaselineRequiredProperty $target "setupFrameIndex")
      $targetFrameIndex = [int](Get-CcrAlpha4BaselineRequiredProperty $target "targetFrameIndex")
      $setupSampleOrdinal = [int](Get-CcrAlpha4BaselineRequiredProperty $target "setupSampleOrdinal")
      $targetSampleOrdinal = [int](Get-CcrAlpha4BaselineRequiredProperty $target "targetSampleOrdinal")
      $acceptedDisplayedFrameIndex = [int](Get-CcrAlpha4BaselineRequiredProperty $target "acceptedDisplayedFrameIndex")
      $publishedDisplayedFrameIndex = [int](Get-CcrAlpha4BaselineRequiredProperty $target "publishedDisplayedFrameIndex")
      if ([string]$target.category -cnotin $categories -or $direction -cnotin @("stationary", "forward", "reverse") -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "setupFrameIndex") -lt 0 -or
          [int]$target.setupFrameIndex -ge $frameCount -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "targetFrameIndex") -lt 0 -or
          [int]$target.targetFrameIndex -ge $frameCount -or
          $setupSampleOrdinal -lt 0 -or $setupSampleOrdinal -ge $frameCount -or
          $targetSampleOrdinal -lt 0 -or $targetSampleOrdinal -ge $frameCount -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "targetPtsUs") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "fileGeneration") -lt 1 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "requestGeneration") -lt 1 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "acceptedElapsedRealtimeNs") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "publishedElapsedRealtimeNs") -lt [long]$target.acceptedElapsedRealtimeNs -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "setupPreviousSyncFrameIndex") -lt 0 -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "targetPreviousSyncFrameIndex") -lt 0 -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "setupSyncOrdinal") -lt 0 -or
          [int](Get-CcrAlpha4BaselineRequiredProperty $target "targetSyncOrdinal") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "acceptedToPublicationUs") -lt 0 -or
          [long]$target.acceptedToPublicationUs -ne [long][Math]::Floor(
            ([long]$target.publishedElapsedRealtimeNs - [long]$target.acceptedElapsedRealtimeNs) / 1000.0
          ) -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "decodedOutputCount") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "seekCount") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "flushCount") -lt 0 -or
          $acceptedDisplayedFrameIndex -ne $setupFrameIndex -or
          $publishedDisplayedFrameIndex -ne $targetFrameIndex -or
          [string](Get-CcrAlpha4BaselineRequiredProperty $target "acceptedDisplayedMeasurement") -cne "SETUP_PUBLICATION" -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "acceptedRawFrameLag") -ne [Math]::Abs($targetFrameIndex - $acceptedDisplayedFrameIndex) -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "publishedRawFrameLag") -ne [Math]::Abs($targetFrameIndex - $publishedDisplayedFrameIndex) -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "staleDiscardCount") -lt 0 -or
          [long](Get-CcrAlpha4BaselineRequiredProperty $target "nonTargetPublishedCount") -ne 0) {
        throw "ALPHA4_RANDOM_BASELINE_TARGET_CONTRACT_MISMATCH:$fixtureId/$ordinal"
      }
      $actualDirection = if ($targetFrameIndex -gt $acceptedDisplayedFrameIndex) {
        "forward"
      } elseif ($targetFrameIndex -lt $acceptedDisplayedFrameIndex) {
        "reverse"
      } else {
        "stationary"
      }
      if ($direction -cne $actualDirection) {
        throw "ALPHA4_RANDOM_BASELINE_DIRECTION_MISMATCH:$fixtureId/$ordinal"
      }
      if ([long]$target.fileGeneration -ne $measuredFileGeneration -or
          [long]$target.requestGeneration -le $previousRequestGeneration) {
        throw "ALPHA4_RANDOM_BASELINE_TARGET_GENERATION_MISMATCH:$fixtureId/$ordinal"
      }
      $previousRequestGeneration = [long]$target.requestGeneration
      $setupPreviousSyncOrdinal = -1
      $targetPreviousSyncOrdinal = -1
      for ($syncIndex = 0; $syncIndex -lt $syncSamples.Count; $syncIndex += 1) {
        if ([int]$syncSamples[$syncIndex].sampleOrdinal -le $setupSampleOrdinal) { $setupPreviousSyncOrdinal = $syncIndex }
        if ([int]$syncSamples[$syncIndex].sampleOrdinal -le $targetSampleOrdinal) { $targetPreviousSyncOrdinal = $syncIndex }
      }
      if ($setupPreviousSyncOrdinal -lt 0 -or $targetPreviousSyncOrdinal -lt 0 -or
          [int]$target.setupSyncOrdinal -ne $setupPreviousSyncOrdinal -or
          [int]$target.targetSyncOrdinal -ne $targetPreviousSyncOrdinal -or
          [int]$target.setupPreviousSyncFrameIndex -ne [int]$syncSamples[$setupPreviousSyncOrdinal].displayFrameIndex -or
          [int]$target.targetPreviousSyncFrameIndex -ne [int]$syncSamples[$targetPreviousSyncOrdinal].displayFrameIndex) {
        throw "ALPHA4_RANDOM_BASELINE_PREVIOUS_SYNC_MISMATCH:$fixtureId/$ordinal"
      }
      foreach ($slot in @(
        @($setupFrameIndex, $setupSampleOrdinal),
        @($targetFrameIndex, $targetSampleOrdinal)
      )) {
        if ($setupFrameIndex -eq $targetFrameIndex -and [int]$slot[0] -eq $targetFrameIndex -and
            $measuredFrameIndices.Contains($targetFrameIndex)) { continue }
        if (-not $measuredFrameIndices.Add([int]$slot[0]) -or -not $measuredSampleOrdinals.Add([int]$slot[1])) {
          throw "ALPHA4_RANDOM_BASELINE_MEASURED_SLOT_CONTAMINATION:$fixtureId/$ordinal"
        }
        for ($syncIndex = 0; $syncIndex -lt $syncSamples.Count; $syncIndex += 1) {
          if ([int]$syncSamples[$syncIndex].displayFrameIndex -eq [int]$slot[0] -and
              [int]$syncSamples[$syncIndex].sampleOrdinal -ne [int]$slot[1]) {
            throw "ALPHA4_RANDOM_BASELINE_SYNC_TARGET_SAMPLE_MISMATCH:$fixtureId/$ordinal"
          }
        }
      }
      if ($null -ne (Get-CcrAlpha4BaselineRequiredProperty $target "acceptedToFirstDecoderOutputUs") -or
          $null -ne (Get-CcrAlpha4BaselineRequiredProperty $target "acceptedToTargetOutputUs")) {
        throw "ALPHA4_RANDOM_BASELINE_UNAVAILABLE_METRIC_NOT_NULL:$fixtureId/$ordinal"
      }
      if ([string]$target.category -ceq "cache-or-history-hit" -and
          (Get-CcrAlpha4BaselineRequiredProperty $target "cacheOrHistoryHit") -ne $true) {
        throw "ALPHA4_RANDOM_BASELINE_EXPECTED_CACHE_HIT_MISSING:$fixtureId/$ordinal"
      }
      if ([string]$target.category -cne "cache-or-history-hit" -and
          (Get-CcrAlpha4BaselineRequiredProperty $target "cacheOrHistoryHit") -ne $false) {
        throw "ALPHA4_RANDOM_BASELINE_CACHE_CONTAMINATION:$fixtureId/$ordinal"
      }
      $distance = [Math]::Abs($targetFrameIndex - $setupFrameIndex)
      $matchingCategories = [System.Collections.Generic.List[string]]::new()
      if ($direction -ceq "stationary" -and $distance -eq 0) { $matchingCategories.Add("cache-or-history-hit") | Out-Null }
      if ($direction -ceq "forward" -and $distance -ge 16 -and $distance -le 32 -and
          [int]$target.setupSyncOrdinal -eq [int]$target.targetSyncOrdinal) { $matchingCategories.Add("ahead-of-cursor") | Out-Null }
      if ($direction -ceq "reverse" -and $distance -ge 1 -and $distance -le 15 -and
          [int]$target.setupSyncOrdinal -eq [int]$target.targetSyncOrdinal) { $matchingCategories.Add("same-gop") | Out-Null }
      if ($direction -ceq "forward" -and [int]$target.targetSyncOrdinal - [int]$target.setupSyncOrdinal -eq 1 -and
          $distance -lt [Math]::Floor($frameCount / 2.0)) { $matchingCategories.Add("adjacent-gop") | Out-Null }
      if ($direction -cne "stationary" -and $distance -eq [Math]::Floor($frameCount / 2.0)) {
        $matchingCategories.Add("far-random") | Out-Null
      }
      if ($matchingCategories.Count -ne 1 -or $matchingCategories[0] -cne [string]$target.category) {
        throw "ALPHA4_RANDOM_BASELINE_CATEGORY_PREDICATE_MISMATCH:$fixtureId/$ordinal"
      }
    }

    $burst = Get-CcrAlpha4BaselineRequiredProperty $fixture "burst"
    if ([int](Get-CcrAlpha4BaselineRequiredProperty $burst "requestCount") -ne 10 -or
        [int](Get-CcrAlpha4BaselineRequiredProperty $burst "acceptedRequestCount") -ne 10 -or
        @((Get-CcrAlpha4BaselineRequiredProperty $burst "acceptedRequestGenerations")).Count -ne 10 -or
        [int](Get-CcrAlpha4BaselineRequiredProperty $burst "finalTargetFrameIndex") -lt 0 -or
        [int]$burst.finalTargetFrameIndex -ge $frameCount -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "fileGeneration") -lt 1 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "requestGeneration") -lt 1 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "acceptedElapsedRealtimeNs") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "assessmentWindowStartElapsedRealtimeNs") -ne [long]$burst.acceptedElapsedRealtimeNs -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "publishedElapsedRealtimeNs") -lt [long]$burst.acceptedElapsedRealtimeNs -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "acceptedToPublicationUs") -lt 0 -or
        [long]$burst.acceptedToPublicationUs -ne [long][Math]::Floor(
          ([long]$burst.publishedElapsedRealtimeNs - [long]$burst.acceptedElapsedRealtimeNs) / 1000.0
        ) -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "nonTargetPublishedCount") -ne 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "nonFinalPublishedAfterFinalAcceptanceCount") -ne 0 -or
        [string](Get-CcrAlpha4BaselineRequiredProperty $burst "publicationAssessment") -cne "EVENT_TIMESTAMP_AT_OR_AFTER_FINAL_ACCEPTANCE" -or
        [string](Get-CcrAlpha4BaselineRequiredProperty $burst "discardedStaleAssessment") -cne "FINAL_GENERATION_ONLY_NO_CALLBACK_TIMESTAMP" -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $burst "staleDiscardCount") -lt 0) {
      throw "ALPHA4_RANDOM_BASELINE_BURST_CONTRACT_MISMATCH:$fixtureId"
    }
    $acceptedRequestGenerations = @((Get-CcrAlpha4BaselineRequiredProperty $burst "acceptedRequestGenerations"))
    for ($generationIndex = 0; $generationIndex -lt $acceptedRequestGenerations.Count; $generationIndex += 1) {
      if ([long]$acceptedRequestGenerations[$generationIndex] -lt 1 -or
          ($generationIndex -gt 0 -and [long]$acceptedRequestGenerations[$generationIndex] -le [long]$acceptedRequestGenerations[$generationIndex - 1])) {
        throw "ALPHA4_RANDOM_BASELINE_BURST_GENERATION_MISMATCH:$fixtureId"
      }
    }
    if ([long]$burst.requestGeneration -ne [long]$acceptedRequestGenerations[-1]) {
      throw "ALPHA4_RANDOM_BASELINE_BURST_FINAL_GENERATION_MISMATCH:$fixtureId"
    }
    if ([long]$burst.fileGeneration -ne $measuredFileGeneration) {
      throw "ALPHA4_RANDOM_BASELINE_BURST_FILE_GENERATION_MISMATCH:$fixtureId"
    }
    if ([long]$burst.requestGeneration -le $previousRequestGeneration) {
      throw "ALPHA4_RANDOM_BASELINE_BURST_FINAL_GENERATION_MISMATCH:$fixtureId"
    }
    foreach ($field in @("textureDoubleReleaseCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount", "publicationInvariantViolationCount")) {
      if ([long](Get-CcrAlpha4BaselineRequiredProperty $fixture $field) -ne 0) {
        throw "ALPHA4_RANDOM_BASELINE_SAFETY_COUNTER_NONZERO:$fixtureId/$field"
      }
    }
    $cacheBudget = [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheBudgetBytes")
    $cacheBytes = [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheBytes")
    if ($cacheBudget -le 0 -or $cacheBytes -lt 0 -or $cacheBytes -gt $cacheBudget -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheEntryCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "peakCacheEntryCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheEvictionCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheRejectionCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "cacheThrashCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "liveTextureCount") -lt 0 -or
        [long](Get-CcrAlpha4BaselineRequiredProperty $fixture "peakLiveTextureCount") -lt [long]$fixture.liveTextureCount) {
      throw "ALPHA4_RANDOM_BASELINE_RESOURCE_COUNTER_INVALID:$fixtureId"
    }
  }
  return $Report
}

function Get-CcrAlpha4TraceStageTiming {
  param(
    [Parameter(Mandatory = $true)][string]$TracePath,
    [Parameter(Mandatory = $true)][object]$Report
  )
  if (-not (Test-Path -LiteralPath $TracePath -PathType Leaf) -or (Get-Item -LiteralPath $TracePath).Length -le 0) {
    throw "ALPHA4_RANDOM_BASELINE_TRACE_MISSING_OR_EMPTY"
  }
  $pattern = [regex]::new(
    '(?<ts>[0-9]+\.[0-9]+):\s+tracing_mark_write:\s+B\|[0-9]+\|(?<stage>CCR\.(?:request\.accept|output\.first|output\.target|publish)) f=(?<f>[0-9]+) r=(?<r>[0-9]+) i=(?<i>-?[0-9]+) p=(?<p>-?[0-9]+)',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
  )
  $events = [System.Collections.Generic.List[object]]::new()
  foreach ($line in [System.IO.File]::ReadLines([System.IO.Path]::GetFullPath($TracePath))) {
    $match = $pattern.Match($line)
    if (-not $match.Success) { continue }
    $timestampSeconds = [decimal]::Parse($match.Groups["ts"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $events.Add([PSCustomObject]@{
      timestampUs = [long]($timestampSeconds * 1000000)
      stage = $match.Groups["stage"].Value
      fileGeneration = [long]$match.Groups["f"].Value
      requestGeneration = [long]$match.Groups["r"].Value
      frameIndex = [int]$match.Groups["i"].Value
      ptsUs = [long]$match.Groups["p"].Value
    }) | Out-Null
  }
  $eventsByRequest = @{}
  foreach ($event in $events) {
    $key = "$($event.fileGeneration)/$($event.requestGeneration)"
    if (-not $eventsByRequest.ContainsKey($key)) { $eventsByRequest[$key] = [System.Collections.Generic.List[object]]::new() }
    $eventsByRequest[$key].Add($event) | Out-Null
  }
  $fixtureReports = @($Report.fixtures)
  $timings = [System.Collections.Generic.List[object]]::new()
  foreach ($fixture in $fixtureReports) {
    $targets = @($fixture.targets)
    foreach ($target in $targets) {
      $key = "$($target.fileGeneration)/$($target.requestGeneration)"
      $requestEvents = @($eventsByRequest[$key])
      $accepts = @($requestEvents | Where-Object { $_.stage -ceq "CCR.request.accept" })
      $publish = @($requestEvents | Where-Object { $_.stage -ceq "CCR.publish" })
      $firstOutput = @($requestEvents | Where-Object { $_.stage -ceq "CCR.output.first" })
      $targetOutput = @($requestEvents | Where-Object { $_.stage -ceq "CCR.output.target" })
      if ($accepts.Count -ne 1 -or [int]$accepts[0].frameIndex -ne [int]$target.targetFrameIndex -or
          [long]$accepts[0].ptsUs -ne [long]$target.targetPtsUs) {
        throw "ALPHA4_RANDOM_BASELINE_TRACE_ACCEPTANCE_MISMATCH:$($fixture.fixtureId)/$($target.ordinal)"
      }
      $accept = $accepts[0]
      $acceptedUs = [long][Math]::Floor([long]$target.acceptedElapsedRealtimeNs / 1000.0)
      $publishedUs = [long][Math]::Floor([long]$target.publishedElapsedRealtimeNs / 1000.0)
      if ([long]$accept.timestampUs -lt $acceptedUs -or [long]$accept.timestampUs -gt $publishedUs -or
          $publish.Count -ne 1 -or [int]$publish[0].frameIndex -ne [int]$target.targetFrameIndex -or
          [long]$publish[0].ptsUs -ne [long]$target.targetPtsUs -or
          [long]$publish[0].timestampUs -lt $acceptedUs -or [long]$publish[0].timestampUs -gt $publishedUs) {
        throw "ALPHA4_RANDOM_BASELINE_TRACE_PUBLICATION_MISMATCH:$($fixture.fixtureId)/$($target.ordinal)"
      }
      $cacheHit = (Get-CcrAlpha4BaselineRequiredProperty $target "cacheOrHistoryHit") -eq $true
      if ($cacheHit) {
        if ($firstOutput.Count -ne 0 -or $targetOutput.Count -ne 0) {
          throw "ALPHA4_RANDOM_BASELINE_TRACE_CACHE_HIT_DECODED:$($fixture.fixtureId)/$($target.ordinal)"
        }
      } else {
        if ($firstOutput.Count -ne 1 -or $targetOutput.Count -ne 1 -or
            [long]$firstOutput[0].timestampUs -lt $acceptedUs -or
            [long]$targetOutput[0].timestampUs -lt [long]$firstOutput[0].timestampUs -or
            [long]$publish[0].timestampUs -lt [long]$targetOutput[0].timestampUs) {
          throw "ALPHA4_RANDOM_BASELINE_TRACE_DECODER_STAGE_MISMATCH:$($fixture.fixtureId)/$($target.ordinal)"
        }
      }
      $timings.Add([ordered]@{
        fixtureId = [string]$fixture.fixtureId
        ordinal = [int]$target.ordinal
        category = [string]$target.category
        targetFrameIndex = [int]$target.targetFrameIndex
        fileGeneration = [long]$target.fileGeneration
        requestGeneration = [long]$target.requestGeneration
        decoderStageStatus = if ($cacheHit) { "NOT_APPLICABLE_CACHE_HIT" } else { "MEASURED" }
        acceptedToFirstDecoderOutputUs = if ($cacheHit) { $null } else { [long]$firstOutput[0].timestampUs - $acceptedUs }
        acceptedToTargetOutputUs = if ($cacheHit) { $null } else { [long]$targetOutput[0].timestampUs - $acceptedUs }
        acceptedToPublicationUs = [long]$target.acceptedToPublicationUs
        acceptedToPublishSectionStartUs = [long]$publish[0].timestampUs - $acceptedUs
      }) | Out-Null
    }
  }
  if ($timings.Count -ne 250) { throw "ALPHA4_RANDOM_BASELINE_TRACE_TIMING_COUNT_MISMATCH:$($timings.Count)" }
  return @($timings)
}

function Merge-CcrAlpha4TraceStageTiming {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][object[]]$Timings,
    [Parameter(Mandatory = $true)][string]$TraceSha256
  )
  if ($TraceSha256 -notmatch '^[0-9a-f]{64}$' -or $Timings.Count -ne 250) {
    throw "ALPHA4_RANDOM_BASELINE_TRACE_MERGE_INPUT_INVALID"
  }
  $merged = ($Report | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
  $merged.baselineCompleteness = "COMPLETE_TRACE_MERGED"
  $merged.metricAvailability.acceptedToFirstDecoderOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
  $merged.metricAvailability.acceptedToTargetOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
  $merged | Add-Member -Force -NotePropertyName traceMergeSchemaVersion -NotePropertyValue 1
  $merged | Add-Member -Force -NotePropertyName traceSha256 -NotePropertyValue $TraceSha256
  $merged | Add-Member -Force -NotePropertyName traceTimingCount -NotePropertyValue 250
  $merged | Add-Member -Force -NotePropertyName successfulPublicationTimingSource `
    -NotePropertyValue "PublicationEvent.elapsedRealtimeNs"
  $merged | Add-Member -Force -NotePropertyName publishTraceMarkerMeaning `
    -NotePropertyValue "section-start-only; not used as successful-publication timestamp"
  $lookup = @{}
  foreach ($timing in $Timings) { $lookup["$($timing.fileGeneration)/$($timing.requestGeneration)"] = $timing }
  foreach ($fixture in @($merged.fixtures)) {
    foreach ($target in @($fixture.targets)) {
      $key = "$($target.fileGeneration)/$($target.requestGeneration)"
      if (-not $lookup.ContainsKey($key)) { throw "ALPHA4_RANDOM_BASELINE_TRACE_MERGE_TARGET_MISSING:$key" }
      $timing = $lookup[$key]
      $target.acceptedToFirstDecoderOutputUs = $timing.acceptedToFirstDecoderOutputUs
      $target.acceptedToTargetOutputUs = $timing.acceptedToTargetOutputUs
    }
  }
  return $merged
}

function Assert-CcrAlpha4MergedBaselineReport {
  param([Parameter(Mandatory = $true)][object]$Report)
  if ([string](Get-CcrAlpha4BaselineRequiredProperty $Report "baselineCompleteness") -cne "COMPLETE_TRACE_MERGED" -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "traceMergeSchemaVersion") -ne 1 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "traceSha256") -notmatch '^[0-9a-f]{64}$' -or
      [int](Get-CcrAlpha4BaselineRequiredProperty $Report "traceTimingCount") -ne 250 -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "successfulPublicationTimingSource") -cne "PublicationEvent.elapsedRealtimeNs" -or
      [string](Get-CcrAlpha4BaselineRequiredProperty $Report "publishTraceMarkerMeaning") -cne
        "section-start-only; not used as successful-publication timestamp") {
    throw "ALPHA4_RANDOM_BASELINE_TRACE_MERGE_IDENTITY_MISMATCH"
  }
  foreach ($fixture in @($Report.fixtures)) {
    foreach ($target in @($fixture.targets)) {
      $cacheHit = $target.cacheOrHistoryHit -eq $true
      if ($cacheHit -and ($null -ne $target.acceptedToFirstDecoderOutputUs -or $null -ne $target.acceptedToTargetOutputUs)) {
        throw "ALPHA4_RANDOM_BASELINE_TRACE_MERGE_CACHE_METRIC_MISMATCH"
      }
      if (-not $cacheHit -and
          ($null -eq $target.acceptedToFirstDecoderOutputUs -or [long]$target.acceptedToFirstDecoderOutputUs -lt 0 -or
           $null -eq $target.acceptedToTargetOutputUs -or [long]$target.acceptedToTargetOutputUs -lt [long]$target.acceptedToFirstDecoderOutputUs)) {
        throw "ALPHA4_RANDOM_BASELINE_TRACE_MERGE_DECODER_METRIC_MISSING"
      }
    }
  }
  return $Report
}
