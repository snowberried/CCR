param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [datetime]$AbsoluteDeadlineUtc = [datetime]::MinValue,
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-alpha5-pinned-artifacts.ps1")
. (Join-Path $PSScriptRoot "alpha4-baseline-contract.ps1")
$localDeadlineUtc = New-CcrAlpha5DeadlineUtc $MaxMinutes
$deadlineUtc = if ($AbsoluteDeadlineUtc -eq [datetime]::MinValue) { $localDeadlineUtc } else {
  $candidate = $AbsoluteDeadlineUtc.ToUniversalTime()
  if ($candidate -lt $localDeadlineUtc) { $candidate } else { $localDeadlineUtc }
}
Set-CcrAlpha5ActiveDeadline $deadlineUtc
$script:CcrAlpha4FrozenRandomSummarySha256 = "5829311f14dbfeb0235fe5e511702c4ca161408ff1d260c41c6e668a9e14bab8"
$script:CcrAlpha4FrozenRandomReportSha256 = "8c9c1390bde85b4a5aebc1732acbaed78639c76d69967fa573a12891fc8feb7f"
$script:CcrAlpha4FrozenTargetSetIdentities = [ordered]@{
  "fixture-01" = "e27c3831f54e977f8cbe66221fd8cbf636b255cbfbd06cbd31119ea2d5ec6da6"
  "fixture-02" = "e32cb87230d992d8e7b596b0c45f7ecb22d39d915808eaf5c626324e12295b83"
  "fixture-03" = "2e6ca49bd7c674bb8da39a459dc008d94b3c2550e44b964f86d07024893545ee"
  "fixture-04" = "10f5e83b3a0fa02669cbb846962d5441016fef533612edb00031e6acf049dbe9"
  "fixture-05" = "79481a4a5d9defe58d2e9baf16a00943bb0519b513877c2ba4433d8b343eb0a4"
}
$context = Invoke-CcrAlpha5PinnedPreflight `
  -ArtifactManifest $ArtifactManifest -ArtifactManifestSha256 $ArtifactManifestSha256 `
  -OutputDirectory $OutputDirectory
$summaryPath = Join-Path $context.OutputDirectory "alpha5-random-summary-v1.json"

function Assert-CcrAlpha5RandomReport {
  param([object]$Report, [string]$ExpectedKind)
  if ([string]$Report.kind -cne $ExpectedKind -or [string]$Report.status -cne "PASS" -or
      [string]$Report.appVersionName -cne $script:CcrPinnedVersionName -or
      [int]$Report.appVersionCode -ne $script:CcrPinnedVersionCode -or
      [string]$Report.appCommitSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [int]$Report.fixtureCount -ne 5 -or [int]$Report.targetCount -ne 250 -or
      [long]$Report.mismatchCount -ne 0 -or [long]$Report.writeOpenCount -ne 0) {
    throw "ALPHA5_RANDOM_REPORT_CONTRACT_MISMATCH:$ExpectedKind"
  }
  foreach ($field in @(
    "syntheticOnly", "containsRealMediaMetadata", "mediaFileNameIncluded", "mediaUriIncluded",
    "mediaPathIncluded", "mediaSourceHashIncluded"
  )) { if (-not (Test-CcrPinnedProperty $Report $field)) { throw "ALPHA5_RANDOM_PRIVACY_FIELD_MISSING:$ExpectedKind/$field" } }
  if ($Report.syntheticOnly -ne $true -or $Report.containsRealMediaMetadata -ne $false -or
      $Report.mediaFileNameIncluded -ne $false -or $Report.mediaUriIncluded -ne $false -or
      $Report.mediaPathIncluded -ne $false -or $Report.mediaSourceHashIncluded -ne $false) {
    throw "ALPHA5_RANDOM_PRIVACY_MISMATCH:$ExpectedKind"
  }
  $fixtures = @($Report.fixtures)
  if ($fixtures.Count -ne 5 -or @($fixtures.fixtureId | Select-Object -Unique).Count -ne 5) {
    throw "ALPHA5_RANDOM_FIXTURE_IDENTITY_COUNT_MISMATCH:$ExpectedKind"
  }
  foreach ($fixture in $fixtures) {
    if ([int](Get-CcrPinnedRequiredProperty $fixture "targetCount") -ne 50 -or
        @((Get-CcrPinnedRequiredProperty $fixture "targets")).Count -ne 50 -or
        [string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $fixture "targetSetIdentity")) -or
        (Get-CcrPinnedRequiredProperty $fixture "containsFirstMiddleLast") -ne $true -or
        (Get-CcrPinnedRequiredProperty $fixture "containsGopBoundary") -ne $true -or
        [long](Get-CcrPinnedRequiredProperty $fixture "cacheBudgetBytes") -ne 67108864L -or
        [long](Get-CcrPinnedRequiredProperty $fixture "cacheBytes") -lt 0L -or
        [long](Get-CcrPinnedRequiredProperty $fixture "cacheBytes") -gt 67108864L -or
        [long](Get-CcrPinnedRequiredProperty $fixture "peakCacheBytes") -lt [long]$fixture.cacheBytes -or
        [long]$fixture.peakCacheBytes -gt 67108864L) {
      throw "ALPHA5_RANDOM_FIXTURE_CONTRACT_MISMATCH:$ExpectedKind/$($fixture.fixture)"
    }
    foreach ($field in @("cacheRejectionCount", "cacheThrashCount", "textureDoubleReleaseCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount", "publicationInvariantViolationCount")) {
      if ([long](Get-CcrPinnedRequiredProperty $fixture $field) -ne 0) { throw "ALPHA5_RANDOM_FIXTURE_SAFETY_MISMATCH:$ExpectedKind/$($fixture.fixtureId)/$field" }
    }
    $burst = Get-CcrPinnedRequiredProperty $fixture "burst"
    foreach ($field in @("nonTargetPublishedCount", "nonFinalPublishedAfterFinalAcceptanceCount", "staleDiscardCount")) {
      if ([long](Get-CcrPinnedRequiredProperty $burst $field) -ne 0) { throw "ALPHA5_RANDOM_BURST_MISMATCH:$ExpectedKind/$($fixture.fixtureId)/$field" }
    }
  }
}

function Get-CcrAlpha5NearestRankPercentile {
  param([long[]]$Values, [double]$Fraction)
  if ($Values.Count -eq 0) { throw "ALPHA5_RANDOM_PERCENTILE_EMPTY" }
  $sorted = @($Values | Sort-Object)
  $index = ([Math]::Ceiling($sorted.Count * $Fraction) - 1)
  return [long]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))]
}

function Assert-CcrAlpha5RandomTargetIdentityAndPerformance {
  param([object]$ExactReport, [object]$PerformanceReport)
  $exactFixtures = @($ExactReport.fixtures | Sort-Object fixtureId)
  $perfFixtures = @($PerformanceReport.fixtures | Sort-Object fixtureId)
  $latencies = [System.Collections.Generic.List[long]]::new()
  $byCategory = @{}
  foreach ($category in @("cache-or-history-hit", "ahead-of-cursor", "same-gop", "adjacent-gop", "far-random")) {
    $byCategory[$category] = [System.Collections.Generic.List[long]]::new()
  }
  for ($fixtureIndex = 0; $fixtureIndex -lt 5; $fixtureIndex += 1) {
    $exactFixture = $exactFixtures[$fixtureIndex]
    $perfFixture = $perfFixtures[$fixtureIndex]
    $fixtureId = [string](Get-CcrPinnedRequiredProperty $exactFixture "fixtureId")
    if (-not $script:CcrAlpha4FrozenTargetSetIdentities.Contains($fixtureId) -or
        [string](Get-CcrPinnedRequiredProperty $exactFixture "targetSetIdentity") -cne
          [string]$script:CcrAlpha4FrozenTargetSetIdentities[$fixtureId]) {
      throw "ALPHA5_RANDOM_ALPHA4_TARGET_SET_IDENTITY_MISMATCH:$fixtureId"
    }
    foreach ($field in @("fixtureId", "frameCount", "targetCount", "deterministicSeed", "targetSetIdentity")) {
      if ([string](Get-CcrPinnedRequiredProperty $exactFixture $field) -cne [string](Get-CcrPinnedRequiredProperty $perfFixture $field)) {
        throw "ALPHA5_RANDOM_EXACT_PERF_FIXTURE_IDENTITY_MISMATCH:$field"
      }
    }
    if (($exactFixture.categoryCounts | ConvertTo-Json -Compress) -cne ($perfFixture.categoryCounts | ConvertTo-Json -Compress)) {
      throw "ALPHA5_RANDOM_EXACT_PERF_CATEGORY_COUNT_MISMATCH:$($exactFixture.fixtureId)"
    }
    $exactTargets = @($exactFixture.targets | Sort-Object { [int]$_.ordinal })
    $perfTargets = @($perfFixture.targets | Sort-Object { [int]$_.ordinal })
    if ($exactTargets.Count -ne 50 -or $perfTargets.Count -ne 50) { throw "ALPHA5_RANDOM_TARGET_COUNT_MISMATCH:$($exactFixture.fixtureId)" }
    for ($targetIndex = 0; $targetIndex -lt 50; $targetIndex += 1) {
      foreach ($field in @(
        "ordinal", "category", "direction", "setupFrameIndex", "targetFrameIndex",
        "setupSampleOrdinal", "targetSampleOrdinal", "targetPtsUs"
      )) {
        if ([string](Get-CcrPinnedRequiredProperty $exactTargets[$targetIndex] $field) -cne [string](Get-CcrPinnedRequiredProperty $perfTargets[$targetIndex] $field)) {
          throw "ALPHA5_RANDOM_EXACT_PERF_TARGET_IDENTITY_MISMATCH:$($exactFixture.fixtureId)/$targetIndex/$field"
        }
      }
      foreach ($candidate in @($exactTargets[$targetIndex], $perfTargets[$targetIndex])) {
        if ([long](Get-CcrPinnedRequiredProperty $candidate "staleDiscardCount") -ne 0L -or
            [long](Get-CcrPinnedRequiredProperty $candidate "nonTargetPublishedCount") -ne 0L) {
          throw "ALPHA5_RANDOM_TARGET_PUBLICATION_MISMATCH:$($exactFixture.fixtureId)/$targetIndex"
        }
        if ((Get-CcrPinnedRequiredProperty $candidate "cacheOrHistoryHit") -ne $true -and
            ([string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $candidate "seekPlanKind")) -or
             [long](Get-CcrPinnedRequiredProperty $candidate "estimatedDecodeOutputCount") -lt 0L -or
             [long](Get-CcrPinnedRequiredProperty $candidate "actualDecodeOutputCount") -lt 0L)) {
          throw "ALPHA5_RANDOM_TARGET_SEEK_PLAN_MISSING:$($exactFixture.fixtureId)/$targetIndex"
        }
      }
      $latency = [long](Get-CcrPinnedRequiredProperty $perfTargets[$targetIndex] "acceptedToPublicationUs")
      if ($latency -lt 0) { throw "ALPHA5_RANDOM_NEGATIVE_LATENCY" }
      $category = [string]$perfTargets[$targetIndex].category
      if (-not $byCategory.ContainsKey($category)) { throw "ALPHA5_RANDOM_CATEGORY_UNKNOWN:$category" }
      $latencies.Add($latency); $byCategory[$category].Add($latency)
    }
  }
  if ($latencies.Count -ne 250) { throw "ALPHA5_RANDOM_LATENCY_COUNT_MISMATCH" }
  $metrics = [ordered]@{
    count = $latencies.Count
    p50Us = Get-CcrAlpha5NearestRankPercentile $latencies.ToArray() 0.50
    p95Us = Get-CcrAlpha5NearestRankPercentile $latencies.ToArray() 0.95
    maxUs = [long](($latencies | Measure-Object -Maximum).Maximum)
    categories = [ordered]@{}
  }
  foreach ($category in $byCategory.Keys | Sort-Object) {
    $values = $byCategory[$category].ToArray()
    if ($values.Count -ne 50) { throw "ALPHA5_RANDOM_CATEGORY_SAMPLE_COUNT_MISMATCH:$category" }
    $metrics.categories[$category] = [ordered]@{
      count = $values.Count; p95Us = Get-CcrAlpha5NearestRankPercentile $values 0.95
      maxUs = [long](($values | Measure-Object -Maximum).Maximum)
    }
  }
  $thresholdMisses = [System.Collections.Generic.List[string]]::new()
  if ($metrics.p95Us -gt 791002L) { $thresholdMisses.Add("OVERALL_P95") | Out-Null }
  if ($metrics.maxUs -gt 2194244L) { $thresholdMisses.Add("OVERALL_MAX") | Out-Null }
  if ([long]($metrics.categories["cache-or-history-hit"].p95Us) -gt 16000L) {
    $thresholdMisses.Add("CACHE_OR_HISTORY_P95") | Out-Null
  }
  if ([long]($metrics.categories["same-gop"].p95Us) -gt 150000L) {
    $thresholdMisses.Add("SAME_GOP_P95") | Out-Null
  }
  if ([long]($metrics.categories["far-random"].p95Us) -gt 300000L) {
    $thresholdMisses.Add("FAR_RANDOM_P95") | Out-Null
  }
  $metrics.status = if ($thresholdMisses.Count -eq 0) { "PASS" } else { "PERFORMANCE_MISS" }
  $metrics.allThresholdsPassed = $thresholdMisses.Count -eq 0
  $metrics.thresholdMisses = @($thresholdMisses)
  $metrics.alpha4BaselineP95Us = 1130004L
  $metrics.requiredP95ImprovementPercent = 30
  $metrics.maximumAllowedP95Us = 791002L
  $metrics.alpha4BaselineMaxUs = 2194244L
  $metrics.maximumAllowedMaxUs = 2194244L
  $metrics.thresholdContract = "ALPHA5_BIDIRECTIONAL_VALIDATION_V1_USER_APPROVED"
  $metrics.alpha4FrozenSummarySha256 = $script:CcrAlpha4FrozenRandomSummarySha256
  $metrics.alpha4FrozenReportSha256 = $script:CcrAlpha4FrozenRandomReportSha256
  $metrics.alpha4TargetSetIdentityCheck = "PASS"
  return $metrics
}

function Get-CcrAlpha5FileRecord {
  param([string]$Path)
  return [ordered]@{
    path = [System.IO.Path]::GetFullPath($Path)
    bytes = [long](Get-Item -LiteralPath $Path).Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
}

function Start-CcrAlpha5RandomTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$RemotePath)
  if ($RemotePath -notmatch '^/data/local/tmp/ccr-alpha5-random-[A-Za-z0-9._-]+\.atrace$') {
    throw "ALPHA5_RANDOM_TRACE_PATH_INVALID"
  }
  $categories = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace", "--list_categories")
  if ($categories.exitCode -ne 0 -or $categories.output -notmatch '(?m)^\s*view\s+-') {
    throw "ALPHA5_RANDOM_ATRACE_VIEW_UNAVAILABLE"
  }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA5_RANDOM_STALE_TRACE_CLEAR_FAILED" }
  $start = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "shell", "atrace", "--async_start", "-c", "-b", "65536",
    "-a", $script:CcrPinnedAppPackage, "view"
  )
  if ($start.exitCode -ne 0) { throw "ALPHA5_RANDOM_TRACE_START_FAILED" }
}

function Stop-CcrAlpha5RandomTrace {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath
  )
  if (Test-Path -LiteralPath $LocalPath) { throw "ALPHA5_RANDOM_LOCAL_TRACE_ALREADY_EXISTS" }
  $stop = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace --async_stop > $RemotePath")
  if ($stop.exitCode -ne 0) { throw "ALPHA5_RANDOM_TRACE_STOP_FAILED" }
  $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $RemotePath, $LocalPath)
  if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $LocalPath -PathType Leaf) -or
      (Get-Item -LiteralPath $LocalPath).Length -le 0) {
    throw "ALPHA5_RANDOM_TRACE_PULL_FAILED"
  }
  return [System.IO.Path]::GetFullPath($LocalPath)
}

function Remove-CcrAlpha5RandomRemoteTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [string]$RemotePath)
  if (-not $RemotePath) { return }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA5_RANDOM_REMOTE_TRACE_REMOVE_FAILED" }
  $verify = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "ls", "-d", $RemotePath)
  if ($verify.exitCode -eq 0) { throw "ALPHA5_RANDOM_REMOTE_TRACE_STILL_PRESENT" }
}

if ($Resume -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
  $existing = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $storedMaxMinutes = [int]$existing.maxMinutes
  Assert-CcrAlpha5PreflightDomain $existing ([bool]$PreflightOnly) "ALPHA5_RANDOM_RESUME_PREFLIGHT_DOMAIN_MISMATCH"
  if ($PreflightOnly) {
    if ([string]$existing.kind -cne "alpha5-random-preflight" -or
        [string]$existing.status -cne "PASS" -or [int]$existing.deviceMutationCount -ne 0 -or
        $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240) {
      throw "ALPHA5_RANDOM_PREFLIGHT_RESUME_IDENTITY_MISMATCH"
    }
    Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_RANDOM_PREFLIGHT_RESUME_IDENTITY_MISMATCH" | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
  if ([string]$existing.status -cnotin @("PASS", "PERFORMANCE_MISS") -or
      $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240) {
    throw "ALPHA5_RANDOM_RESUME_IDENTITY_MISMATCH"
  }
  Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_RANDOM_RESUME_IDENTITY_MISMATCH" | Out-Null
  foreach ($entry in @(
    $existing.exactnessReport, $existing.performanceInstrumentationReport, $existing.performanceReport,
    $existing.rawTrace, $existing.stageTiming
  )) {
    Assert-CcrAlpha5EvidenceFileRecord $entry $context.OutputDirectory "ALPHA5_RANDOM_RESUME_REPORT_MISMATCH" | Out-Null
  }
  $resumeExact = [System.IO.File]::ReadAllText([string]$existing.exactnessReport.path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $resumeRawPerformance = [System.IO.File]::ReadAllText([string]$existing.performanceInstrumentationReport.path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $resumePerformance = [System.IO.File]::ReadAllText([string]$existing.performanceReport.path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-CcrPinnedReport `
    -Report $resumeExact -ArtifactSet $context.ArtifactSet -RunId ([string]$existing.exactnessRunId) `
    -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha5-cost-aware-random-exactness" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
  Assert-CcrPinnedReport `
    -Report $resumeRawPerformance -ArtifactSet $context.ArtifactSet -RunId ([string]$existing.performanceRunId) `
    -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha5-cost-aware-random-performance" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
  Assert-CcrAlpha5RandomReport $resumeExact "alpha5-cost-aware-random-exactness"
  Assert-CcrAlpha5RandomReport $resumeRawPerformance "alpha5-cost-aware-random-performance"
  Assert-CcrAlpha4MergedBaselineReport $resumePerformance | Out-Null
  $resumeTimings = @(Get-CcrAlpha4TraceStageTiming -TracePath ([string]$existing.rawTrace.path) -Report $resumeRawPerformance)
  $resumeStage = [System.IO.File]::ReadAllText([string]$existing.stageTiming.path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  if ([string]$resumeStage.status -cne "PASS" -or [int]$resumeStage.timingCount -ne 250 -or
      [string]$resumeStage.traceSha256 -cne [string]$existing.rawTrace.sha256 -or
      (($resumeTimings | ConvertTo-Json -Depth 20 -Compress) -cne (@($resumeStage.timings) | ConvertTo-Json -Depth 20 -Compress))) {
    throw "ALPHA5_RANDOM_RESUME_STAGE_TIMING_MISMATCH"
  }
  $resumeMerged = Merge-CcrAlpha4TraceStageTiming $resumeRawPerformance $resumeTimings ([string]$existing.rawTrace.sha256)
  if (($resumeMerged | ConvertTo-Json -Depth 20 -Compress) -cne ($resumePerformance | ConvertTo-Json -Depth 20 -Compress)) {
    throw "ALPHA5_RANDOM_RESUME_MERGED_REPORT_MISMATCH"
  }
  $recomputed = Assert-CcrAlpha5RandomTargetIdentityAndPerformance $resumeExact $resumePerformance
  if ([string]$existing.status -cne [string]$recomputed.status -or
      ($recomputed | ConvertTo-Json -Depth 10 -Compress) -cne ($existing.performanceGate | ConvertTo-Json -Depth 10 -Compress)) {
    throw "ALPHA5_RANDOM_RESUME_PERFORMANCE_GATE_MISMATCH"
  }
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}
if (Test-Path -LiteralPath $summaryPath) { throw "ALPHA5_RANDOM_SUMMARY_ALREADY_EXISTS" }

if ($PreflightOnly) {
  $preflight = [ordered]@{
    schemaVersion = 1; kind = "alpha5-random-preflight"; status = "PASS"
    preflightOnly = $true; deviceMutationCount = 0; maxMinutes = $MaxMinutes
    identity = New-CcrAlpha5IdentityRecord $context
    order = @("exactness-250-targets", "performance-250-targets")
    hardStop = "exactness failure blocks performance"
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-Output (Write-CcrAlpha5ImmutableJson $summaryPath $preflight)
  return
}

$primaryFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$mutationStarted = $false
$result = $null
$traceStarted = $false
$traceStopped = $false
$remoteTracePath = $null
$localTracePath = $null
try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $mutationStarted = $true
  Install-CcrPinnedArtifactSet $context "Debug"

  # Exactness is deliberately first and fail-closed.  The timing run is never
  # invoked if this report or its pixel/frame identity contract fails.
  Assert-CcrAlpha5Deadline $deadlineUtc "random-before-exactness"
  $exactRunId = New-CcrPinnedRunId $context.OutputDirectory "a5-random-exact"
  $exactName = "s24-alpha5-random-exactness-v1.json"
  Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $exactName
  $exactInvocation = Invoke-CcrPinnedInstrumentation `
    -Context $context -TestRole "debugTest" `
    -ClassName "com.snowberried.ctcinereviewer.gate.Alpha5RandomSeekExactnessTest#deterministicRandomTargetsRemainExact" `
    -RunId $exactRunId -ExpectedTestCount 1 `
    -FailureReportPath (Join-Path $context.OutputDirectory "failure-$exactRunId-instrumentation-v1.json")
  $exact = Receive-CcrPinnedReport `
    -Context $context -ReportName $exactName -RunId $exactRunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $exactInvocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "alpha5-cost-aware-random-exactness" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  Assert-CcrAlpha5RandomReport $exact.Report "alpha5-cost-aware-random-exactness"
  [System.IO.File]::SetAttributes($exact.Path, [System.IO.FileAttributes]::ReadOnly)

  Assert-CcrAlpha5Deadline $deadlineUtc "random-before-performance"
  $perfRunId = New-CcrPinnedRunId $context.OutputDirectory "a5-random-perf"
  $perfName = "s24-alpha5-random-performance-v1.json"
  Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $perfName
  $remoteTracePath = "/data/local/tmp/ccr-alpha5-random-$perfRunId.atrace"
  $localTracePath = Join-Path $context.OutputDirectory "$perfRunId-alpha5-random.atrace"
  Start-CcrAlpha5RandomTrace $context $remoteTracePath
  $traceStarted = $true
  try {
    $perfInvocation = Invoke-CcrPinnedInstrumentation `
      -Context $context -TestRole "debugTest" `
      -ClassName "com.snowberried.ctcinereviewer.gate.Alpha5RandomSeekPerformanceTest#deterministicCostAwareRandomSeekAlpha5" `
      -RunId $perfRunId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $context.OutputDirectory "failure-$perfRunId-instrumentation-v1.json")
  } finally {
    Stop-CcrAlpha5RandomTrace $context $remoteTracePath $localTracePath | Out-Null
    $traceStopped = $true
  }
  Assert-CcrAlpha5Deadline $deadlineUtc "random-after-performance"
  $performance = Receive-CcrPinnedReport `
    -Context $context -ReportName $perfName -RunId $perfRunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $perfInvocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "alpha5-cost-aware-random-performance" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  Assert-CcrAlpha5RandomReport $performance.Report "alpha5-cost-aware-random-performance"
  $stageTimings = @(Get-CcrAlpha4TraceStageTiming -TracePath $localTracePath -Report $performance.Report)
  $traceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $localTracePath).Hash.ToLowerInvariant()
  $stageEvidence = [ordered]@{
    schemaVersion = 1; kind = "alpha5-random-decoder-stage-timing"; status = "PASS"
    runId = $perfRunId; traceSha256 = $traceSha256
    traceBytes = [long](Get-Item -LiteralPath $localTracePath).Length
    timingCount = $stageTimings.Count
    acceptedToFirstDecoderOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
    acceptedToTargetOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
    timings = $stageTimings
    syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  $stageTimingPath = Write-CcrAlpha5ImmutableJson `
    (Join-Path $context.OutputDirectory "$perfRunId-alpha5-random-stage-timing-v1.json") $stageEvidence
  $mergedReport = Merge-CcrAlpha4TraceStageTiming $performance.Report $stageTimings $traceSha256
  Assert-CcrAlpha4MergedBaselineReport $mergedReport | Out-Null
  $mergedReportPath = Write-CcrAlpha5ImmutableJson `
    (Join-Path $context.OutputDirectory "$perfRunId-alpha5-random-trace-merged-v1.json") $mergedReport
  $performanceMetrics = Assert-CcrAlpha5RandomTargetIdentityAndPerformance $exact.Report $mergedReport
  [System.IO.File]::SetAttributes($performance.Path, [System.IO.FileAttributes]::ReadOnly)
  [System.IO.File]::SetAttributes($localTracePath, [System.IO.FileAttributes]::ReadOnly)

  $summary = [ordered]@{
    schemaVersion = 1; kind = "alpha5-cost-aware-random"; status = [string]$performanceMetrics.status
    preflightOnly = $false
    completedAtUtc = [DateTime]::UtcNow.ToString("o"); maxMinutes = $MaxMinutes
    identity = New-CcrAlpha5IdentityRecord $context
    exactnessRunId = $exactRunId; performanceRunId = $perfRunId
    exactnessReport = Get-CcrAlpha5FileRecord $exact.Path
    performanceInstrumentationReport = Get-CcrAlpha5FileRecord $performance.Path
    performanceReport = Get-CcrAlpha5FileRecord $mergedReportPath
    rawTrace = Get-CcrAlpha5FileRecord $localTracePath
    stageTiming = Get-CcrAlpha5FileRecord $stageTimingPath
    decoderStageTimingStatus = "PASS"
    fixtureCount = 5; exactTargetCount = 250; performanceTargetCount = 250
    mismatchCount = 0; writeOpenCount = 0; correctnessHardStopSatisfied = $true
    alpha4ExactPerformanceTargetIdentity = "PASS"; exactPerformanceTargetIdentity = "PASS"
    alpha4FrozenSummarySha256 = $script:CcrAlpha4FrozenRandomSummarySha256
    alpha4FrozenReportSha256 = $script:CcrAlpha4FrozenRandomReportSha256
    performanceGate = $performanceMetrics
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  $result = Write-CcrAlpha5ImmutableJson $summaryPath $summary
} catch { $primaryFailure = $_ } finally {
  if ($traceStarted -and -not $traceStopped) {
    try {
      if ($localTracePath -and -not (Test-Path -LiteralPath $localTracePath)) {
        Stop-CcrAlpha5RandomTrace $context $remoteTracePath $localTracePath | Out-Null
      } else {
        $stop = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "atrace", "--async_stop")
        if ($stop.exitCode -ne 0) { throw "ALPHA5_RANDOM_TRACE_EMERGENCY_STOP_FAILED" }
      }
      $traceStopped = $true
    } catch { $cleanupFailures.Add("ALPHA5_RANDOM_TRACE_FINALIZE_FAILED:$($_.Exception.Message)") | Out-Null }
  }
  if ($remoteTracePath) {
    try { Remove-CcrAlpha5RandomRemoteTrace $context $remoteTracePath } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
  if ($localTracePath -and (Test-Path -LiteralPath $localTracePath -PathType Leaf)) {
    try { [System.IO.File]::SetAttributes($localTracePath, [System.IO.FileAttributes]::ReadOnly) } catch {
      $cleanupFailures.Add("ALPHA5_RANDOM_LOCAL_TRACE_READ_ONLY_FAILED:$($_.Exception.Message)") | Out-Null
    }
  }
  if ($mutationStarted) {
    Enter-CcrAlpha5CleanupWindow
    try {
      foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
    } catch { $cleanupFailures.Add("CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null }
    try { Assert-CcrAlpha5SettingsRestored $context | Out-Null } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
}
if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) { throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')" }
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }
Write-Output $result
