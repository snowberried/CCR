param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")
. (Join-Path $PSScriptRoot "alpha4-baseline-contract.ps1")
$deadlineUtc = New-CcrAlpha4DeadlineUtc -MaxMinutes $MaxMinutes

function Write-CcrAlpha4BaselineCheckpoint {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::ReadOnly)
  return $Path
}

function ConvertFrom-CcrAlpha4ScriptOutput {
  param([Parameter(Mandatory = $true)][object[]]$Output, [Parameter(Mandatory = $true)][string]$Stage)
  $text = ($Output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw "ALPHA4_BASELINE_STAGE_OUTPUT_EMPTY:$Stage" }
  try { return $text | ConvertFrom-Json } catch { throw "ALPHA4_BASELINE_STAGE_OUTPUT_INVALID:$Stage" }
}

function Read-CcrAlpha4BaselineJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Failure)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $Failure }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw $Failure }
}

function Assert-CcrAlpha4BaselineFile {
  param([string]$Path, [string]$Sha256, [string]$Failure)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or $Sha256 -notmatch '^[0-9a-f]{64}$' -or
      (Get-Item -LiteralPath $Path).Length -le 0 -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -cne $Sha256) {
    throw $Failure
  }
}

function Assert-CcrAlpha4NavigationCheckpointIdentity {
  param([object]$Checkpoint, [object]$Context, [int]$ExpectedMaxMinutes)
  if ([int]$Checkpoint.schemaVersion -ne 1 -or
      [string]$Checkpoint.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [int]$Checkpoint.artifactSetRevision -ne $script:CcrPinnedArtifactSetRevision -or
      [string]$Checkpoint.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Checkpoint.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Checkpoint.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Checkpoint.debugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Checkpoint.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Checkpoint.benchmarkAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256 -or
      [string]$Checkpoint.macrobenchmarkTestSha256 -cne [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256 -or
      [string]$Checkpoint.device.serial -cne $Context.Serial -or
      [string]$Checkpoint.device.fingerprint -cne $Context.Fingerprint -or
      [int]$Checkpoint.maxMinutes -ne $ExpectedMaxMinutes -or
      [string]$Checkpoint.runtimeIdentityMode -cne
        "same-manifest-runtime-source-and-input-tree; benchmarkApp-is-not-byte-identical-to-fixed-debugApp") {
    throw "ALPHA4_BASELINE_RESUME_CHECKPOINT_IDENTITY_MISMATCH"
  }
}

function Assert-CcrAlpha4RandomStageSummary {
  param([object]$Summary, [object]$Context)
  if ([string]$Summary.status -cne "PASS" -or [string]$Summary.kind -cne "s24-alpha4-random-baseline" -or
      [string]$Summary.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [string]$Summary.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Summary.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Summary.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Summary.debugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Summary.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Summary.renderMode -cne "PILOT_SOURCE_EQUIVALENT" -or
      [string]$Summary.pixelExactnessEvidence -cne "SEPARATE_FROZEN_GATES" -or
      [string]$Summary.memoryMeasurement -cne "POST_ACTIVITY_CLEANUP_SNAPSHOT" -or
      @($Summary.inSessionMemory).Count -ne 5 -or
      $Summary.timingBaselineOnly -ne $true -or
      [string]$Summary.decoderStageTimingStatus -cne "PASS" -or
      [string]$Summary.deterministicNodeContractValidation -cne "PASS" -or
      [string]$Summary.baselineCompleteness -cne "COMPLETE_TRACE_MERGED" -or
      [long]$Summary.mismatchCount -ne 0 -or [long]$Summary.writeOpenCount -ne 0) {
    throw "ALPHA4_BASELINE_RANDOM_STAGE_MISMATCH"
  }
  foreach ($measurement in @($Summary.inSessionMemory)) {
    if ([string]$measurement.fixtureId -notmatch '^fixture-0[1-5]$' -or
        [long]$measurement.javaUsedBytes -lt 0 -or [long]$measurement.nativeAllocatedBytes -lt 0 -or
        [long]$measurement.totalPssBytes -le 0) {
      throw "ALPHA4_BASELINE_RANDOM_MEMORY_SUMMARY_MISMATCH"
    }
  }
  $measurementIds = @($Summary.inSessionMemory | ForEach-Object { [string]$_.fixtureId } | Sort-Object)
  if (($measurementIds -join ",") -cne "fixture-01,fixture-02,fixture-03,fixture-04,fixture-05") {
    throw "ALPHA4_BASELINE_RANDOM_MEMORY_SUMMARY_MISMATCH"
  }
  Assert-CcrAlpha4BaselineFile ([string]$Summary.report) ([string]$Summary.reportSha256) "ALPHA4_BASELINE_RANDOM_REPORT_IDENTITY_MISMATCH"
  Assert-CcrAlpha4BaselineFile ([string]$Summary.rawTrace) ([string]$Summary.rawTraceSha256) "ALPHA4_BASELINE_RANDOM_TRACE_IDENTITY_MISMATCH"
  Assert-CcrAlpha4BaselineFile ([string]$Summary.stageTiming) ([string]$Summary.stageTimingSha256) "ALPHA4_BASELINE_RANDOM_STAGE_TIMING_IDENTITY_MISMATCH"
  Assert-CcrAlpha4BaselineFile ([string]$Summary.mergedReport) ([string]$Summary.mergedReportSha256) "ALPHA4_BASELINE_RANDOM_MERGED_REPORT_IDENTITY_MISMATCH"
  $merged = Read-CcrAlpha4BaselineJson ([string]$Summary.mergedReport) "ALPHA4_BASELINE_RANDOM_MERGED_REPORT_INVALID"
  Assert-CcrAlpha4MergedBaselineReport $merged | Out-Null
  if ([string]$merged.memoryMeasurement -cne [string]$Summary.memoryMeasurement) {
    throw "ALPHA4_BASELINE_RANDOM_MEMORY_SUMMARY_MISMATCH"
  }
  foreach ($fixture in @($merged.fixtures)) {
    $measurement = @($Summary.inSessionMemory | Where-Object { [string]$_.fixtureId -ceq [string]$fixture.fixtureId })
    if ($measurement.Count -ne 1 -or
        [long]$measurement[0].javaUsedBytes -ne [long]$fixture.inSessionMemory.javaUsedBytes -or
        [long]$measurement[0].nativeAllocatedBytes -ne [long]$fixture.inSessionMemory.nativeAllocatedBytes -or
        [long]$measurement[0].totalPssBytes -ne [long]$fixture.inSessionMemory.totalPssBytes) {
      throw "ALPHA4_BASELINE_RANDOM_MEMORY_SUMMARY_MISMATCH"
    }
  }
  return $Summary
}

function Assert-CcrAlpha4ReverseStageSummary {
  param([object]$Summary, [object]$Context)
  if ([string]$Summary.status -cne "PASS" -or [string]$Summary.kind -cne "s24-alpha4-reverse-baseline" -or
      [string]$Summary.scenarioProfile -cne "Alpha4Reverse" -or $Summary.baselineOnly -ne $true -or
      [string]$Summary.performanceJudgement -cne "MEASURED_NOT_GATED" -or
      [string]$Summary.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [string]$Summary.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Summary.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Summary.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Summary.fixedDebugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Summary.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Summary.benchmarkAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256 -or
      [string]$Summary.macrobenchmarkTestSha256 -cne [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256 -or
      @($Summary.scenarios).Count -ne 2) {
    throw "ALPHA4_BASELINE_REVERSE_STAGE_MISMATCH"
  }
  foreach ($scenario in @($Summary.scenarios)) {
    if ([string]$scenario.status -cne "PASS" -or [int]$scenario.traceCount -ne 3 -or
        @($scenario.requestStageTraceMetrics).Count -ne 3 -or @($scenario.iterations).Count -ne 3) {
      throw "ALPHA4_BASELINE_REVERSE_SCENARIO_MISMATCH:$($scenario.scenario)"
    }
    Assert-CcrAlpha4ReverseBaselineEvidence ([PSCustomObject]@{ iterations = @($scenario.iterations) }) | Out-Null
    Assert-CcrAlpha4BaselineFile ([string]$scenario.benchmarkDataPath) ([string]$scenario.benchmarkDataSha256) "ALPHA4_BASELINE_REVERSE_BENCHMARK_DATA_IDENTITY_MISMATCH"
    Assert-CcrAlpha4BaselineFile ([string]$scenario.evidencePath) ([string]$scenario.evidenceSha256) "ALPHA4_BASELINE_REVERSE_EVIDENCE_IDENTITY_MISMATCH"
    $traceArtifacts = @($scenario.traceArtifacts)
    if ($traceArtifacts.Count -ne 3) { throw "ALPHA4_BASELINE_REVERSE_TRACE_COUNT_MISMATCH" }
    foreach ($trace in $traceArtifacts) {
      Assert-CcrAlpha4BaselineFile ([string]$trace.path) ([string]$trace.sha256) "ALPHA4_BASELINE_REVERSE_TRACE_IDENTITY_MISMATCH"
      if ([long]$trace.bytes -ne (Get-Item -LiteralPath ([string]$trace.path)).Length -or
          [string]$trace.parserStatus -cne "PASS_REQUEST_STAGE_METRIC") {
        throw "ALPHA4_BASELINE_REVERSE_TRACE_METADATA_MISMATCH"
      }
    }
  }
  return $Summary
}

function Get-CcrAlpha4ChildMaxMinutes {
  param([Parameter(Mandatory = $true)][DateTimeOffset]$DeadlineUtc, [Parameter(Mandatory = $true)][string]$Stage)
  $seconds = Get-CcrAlpha4RemainingSeconds -DeadlineUtc $DeadlineUtc -Stage $Stage
  $minutes = [int][Math]::Floor($seconds / 60.0)
  if ($minutes -lt 1) { throw "ALPHA4_BASELINE_INSUFFICIENT_REMAINING_BUDGET:$Stage" }
  return $minutes
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-preflight"
if ($Resume -and $PreflightOnly) { throw "ALPHA4_BASELINE_RESUME_PREFLIGHT_ONLY_CONFLICT" }
if ($Resume) {
  $resumeCandidates = @(Get-ChildItem -LiteralPath $context.OutputDirectory -Directory | Where-Object {
    $_.Name.StartsWith("alpha4-navigation-baseline-", [System.StringComparison]::Ordinal) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName "checkpoint-00-preflight.json") -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $_.FullName "alpha4-navigation-baseline-v1-summary.json") -PathType Leaf)
  })
  if ($resumeCandidates.Count -ne 1) { throw "ALPHA4_BASELINE_RESUME_EXACTLY_ONE_INCOMPLETE_RUN_REQUIRED:$($resumeCandidates.Count)" }
  $runDirectory = $resumeCandidates[0].FullName
  $baselineRunId = $resumeCandidates[0].Name
} else {
  $baselineRunId = New-CcrPinnedRunId $context.OutputDirectory $(if ($PreflightOnly) { "alpha4-baseline-preflight" } else { "alpha4-navigation-baseline" })
  $runDirectory = Join-Path $context.OutputDirectory $baselineRunId
  [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
}
$plannedRandomMaxMinutes = if ($PreflightOnly -or $Resume) {
  $null
} else {
  Get-CcrAlpha4ChildMaxMinutes -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-plan-random"
}
$baseEvidence = [ordered]@{
  schemaVersion = 1
  baselineRunId = $baselineRunId
  artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
  artifactSetRevision = $script:CcrPinnedArtifactSetRevision
  runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
  harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
  runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
  debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
  debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
  benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256
  macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256
  device = [ordered]@{
    serial = $context.Serial
    model = $context.Model
    fingerprint = $context.Fingerprint
    securityPatch = $context.SecurityPatch
    sdk = $context.Sdk
  }
  syntheticOnly = $true
  containsRealMediaMetadata = $false
  maxMinutes = $MaxMinutes
  deadlineUtc = $deadlineUtc.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
  runtimeIdentityMode = "same-manifest-runtime-source-and-input-tree; benchmarkApp-is-not-byte-identical-to-fixed-debugApp"
  parameters = [ordered]@{
    maxMinutes = $MaxMinutes
    randomResumeGranularity = "whole-instrumentation-restart; complete-pass-evidence-only-reuse"
    reverseResumeGranularity = "complete-three-iteration-scenario"
    randomMaxMinutes = $plannedRandomMaxMinutes
  }
}

if ($Resume) {
  $resumePreflight = Read-CcrAlpha4BaselineJson `
    (Join-Path $runDirectory "checkpoint-00-preflight.json") "ALPHA4_BASELINE_RESUME_PREFLIGHT_CHECKPOINT_INVALID"
  Assert-CcrAlpha4NavigationCheckpointIdentity $resumePreflight $context $MaxMinutes
  if ([string]$resumePreflight.kind -cne "s24-alpha4-navigation-baseline-checkpoint" -or
      [string]$resumePreflight.status -cne "PASS" -or
      [string]$resumePreflight.completedStage -cne "preflight" -or
      [string]$resumePreflight.baselineRunId -cne $baselineRunId -or
      [string]$resumePreflight.parameters.randomResumeGranularity -cne
        "whole-instrumentation-restart; complete-pass-evidence-only-reuse" -or
      [string]$resumePreflight.parameters.reverseResumeGranularity -cne "complete-three-iteration-scenario" -or
      [int]$resumePreflight.parameters.randomMaxMinutes -lt 1 -or
      [int]$resumePreflight.parameters.randomMaxMinutes -gt 240) {
    throw "ALPHA4_BASELINE_RESUME_PARAMETER_MISMATCH"
  }
  $randomMaxMinutes = [int]$resumePreflight.parameters.randomMaxMinutes
  $baseEvidence.parameters.randomMaxMinutes = $randomMaxMinutes
} elseif (-not $PreflightOnly) {
  $randomMaxMinutes = $plannedRandomMaxMinutes
}

if ($PreflightOnly) {
  $preflight = [ordered]@{}
  foreach ($entry in $baseEvidence.GetEnumerator()) { $preflight[$entry.Key] = $entry.Value }
  $preflight.kind = "s24-alpha4-navigation-baseline-preflight"
  $preflight.status = "PASS"
  $preflight.preflightOnly = $true
  $preflight.deviceMutationCount = 0
  $path = Write-CcrAlpha4BaselineCheckpoint (Join-Path $runDirectory "checkpoint-00-preflight.json") $preflight
  Get-Content -Raw -Encoding UTF8 -LiteralPath $path
  return
}

$randomDirectory = Join-Path $runDirectory "random"
$reverseDirectory = Join-Path $runDirectory "reverse"
[System.IO.Directory]::CreateDirectory($randomDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($reverseDirectory) | Out-Null
$checkpoint = [ordered]@{}
foreach ($entry in $baseEvidence.GetEnumerator()) { $checkpoint[$entry.Key] = $entry.Value }
$checkpoint.kind = "s24-alpha4-navigation-baseline-checkpoint"
$checkpoint.status = "PASS"
$checkpoint.completedStage = "preflight"
$checkpoint.nextStage = "random-source-equivalent-timing"
if (-not $Resume) {
  Write-CcrAlpha4BaselineCheckpoint (Join-Path $runDirectory "checkpoint-00-preflight.json") $checkpoint | Out-Null
}

$primaryFailure = $null
$randomSummary = $null
$reverseSummary = $null
$randomStageCompleted = $false
$reverseStageCompleted = $false
try {
  $randomCheckpointPath = Join-Path $runDirectory "checkpoint-01-random-pass.json"
  $randomSummaryPath = Join-Path $randomDirectory "alpha4-random-baseline-v1-summary.json"
  if ($Resume -and (Test-Path -LiteralPath $randomCheckpointPath -PathType Leaf)) {
    $randomCheckpoint = Read-CcrAlpha4BaselineJson $randomCheckpointPath "ALPHA4_BASELINE_RANDOM_CHECKPOINT_INVALID"
    Assert-CcrAlpha4NavigationCheckpointIdentity $randomCheckpoint $context $MaxMinutes
    if ([string]$randomCheckpoint.completedStage -cne "random-source-equivalent-timing" -or
        [string]$randomCheckpoint.randomSummary -cne $randomSummaryPath -or
        [int]$randomCheckpoint.randomMaxMinutes -lt 1 -or [int]$randomCheckpoint.randomMaxMinutes -gt 240 -or
        [int]$randomCheckpoint.reverseMaxMinutes -lt 1 -or [int]$randomCheckpoint.reverseMaxMinutes -gt 240) {
      throw "ALPHA4_BASELINE_RANDOM_CHECKPOINT_PARAMETER_MISMATCH"
    }
    Assert-CcrAlpha4BaselineFile $randomSummaryPath ([string]$randomCheckpoint.randomSummarySha256) "ALPHA4_BASELINE_RANDOM_SUMMARY_IDENTITY_MISMATCH"
    $randomSummary = Read-CcrAlpha4BaselineJson $randomSummaryPath "ALPHA4_BASELINE_RANDOM_SUMMARY_INVALID"
    Assert-CcrAlpha4RandomStageSummary $randomSummary $context | Out-Null
    $randomStageCompleted = $true
    if ([int]$randomCheckpoint.randomMaxMinutes -ne $randomMaxMinutes) {
      throw "ALPHA4_BASELINE_RANDOM_CHECKPOINT_PARAMETER_MISMATCH"
    }
    $reverseMaxMinutes = [int]$randomCheckpoint.reverseMaxMinutes
  } else {
    $randomParameters = @{
      ArtifactManifest = $ArtifactManifest
      OutputDirectory = $randomDirectory
      MaxMinutes = $randomMaxMinutes
    }
    if ($Resume -and (Test-Path -LiteralPath (Join-Path $randomDirectory "checkpoint-alpha4-random-00-session.json"))) {
      $randomParameters.Resume = $true
    }
    $randomOutput = @(& (Join-Path $PSScriptRoot "run-s24-alpha4-random-baseline.ps1") @randomParameters)
    $randomSummary = ConvertFrom-CcrAlpha4ScriptOutput $randomOutput "random-source-equivalent-timing"
    Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-after-random"
    Assert-CcrAlpha4RandomStageSummary $randomSummary $context | Out-Null
    $randomStageCompleted = $true
    $reverseMaxMinutes = Get-CcrAlpha4ChildMaxMinutes -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-before-reverse"
    $randomCheckpoint = [ordered]@{}
    foreach ($entry in $baseEvidence.GetEnumerator()) { $randomCheckpoint[$entry.Key] = $entry.Value }
    $randomCheckpoint.kind = "s24-alpha4-navigation-baseline-checkpoint"
    $randomCheckpoint.status = "PASS"
    $randomCheckpoint.completedStage = "random-source-equivalent-timing"
    $randomCheckpoint.nextStage = "reverse-hold"
    $randomCheckpoint.randomSummary = $randomSummaryPath
    $randomCheckpoint.randomSummarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $randomSummaryPath).Hash.ToLowerInvariant()
    $randomCheckpoint.randomMaxMinutes = $randomMaxMinutes
    $randomCheckpoint.reverseMaxMinutes = $reverseMaxMinutes
    Write-CcrAlpha4BaselineCheckpoint $randomCheckpointPath $randomCheckpoint | Out-Null
  }

  $reverseCheckpointPath = Join-Path $runDirectory "checkpoint-02-reverse-pass.json"
  $reverseSummaryPath = Join-Path $reverseDirectory "alpha4-reverse-baseline-v1-summary.json"
  if ($Resume -and (Test-Path -LiteralPath $reverseCheckpointPath -PathType Leaf)) {
    $reverseCheckpoint = Read-CcrAlpha4BaselineJson $reverseCheckpointPath "ALPHA4_BASELINE_REVERSE_CHECKPOINT_INVALID"
    Assert-CcrAlpha4NavigationCheckpointIdentity $reverseCheckpoint $context $MaxMinutes
    if ([string]$reverseCheckpoint.completedStage -cne "reverse-hold" -or
        [string]$reverseCheckpoint.reverseSummary -cne $reverseSummaryPath -or
        [int]$reverseCheckpoint.reverseMaxMinutes -ne $reverseMaxMinutes) {
      throw "ALPHA4_BASELINE_REVERSE_CHECKPOINT_PARAMETER_MISMATCH"
    }
    Assert-CcrAlpha4BaselineFile $reverseSummaryPath ([string]$reverseCheckpoint.reverseSummarySha256) "ALPHA4_BASELINE_REVERSE_SUMMARY_IDENTITY_MISMATCH"
    $reverseSummary = Read-CcrAlpha4BaselineJson $reverseSummaryPath "ALPHA4_BASELINE_REVERSE_SUMMARY_INVALID"
    Assert-CcrAlpha4ReverseStageSummary $reverseSummary $context | Out-Null
    $reverseStageCompleted = $true
  } else {
    $reverseParameters = @{
      ArtifactManifest = $ArtifactManifest
      OutputDirectory = $reverseDirectory
      ScenarioProfile = "Alpha4Reverse"
      MaxMinutes = $reverseMaxMinutes
    }
    if ($Resume -and (Test-Path -LiteralPath (Join-Path $reverseDirectory "checkpoint-perf-00-session.json"))) {
      $reverseParameters.Resume = $true
    }
    $reverseOutput = @(& (Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1") @reverseParameters)
    $reverseSummary = ConvertFrom-CcrAlpha4ScriptOutput $reverseOutput "reverse-hold"
    Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-after-reverse"
    Assert-CcrAlpha4ReverseStageSummary $reverseSummary $context | Out-Null
    $reverseStageCompleted = $true
    $reverseCheckpoint = [ordered]@{}
    foreach ($entry in $baseEvidence.GetEnumerator()) { $reverseCheckpoint[$entry.Key] = $entry.Value }
    $reverseCheckpoint.kind = "s24-alpha4-navigation-baseline-checkpoint"
    $reverseCheckpoint.status = "PASS"
    $reverseCheckpoint.completedStage = "reverse-hold"
    $reverseCheckpoint.nextStage = "complete"
    $reverseCheckpoint.reverseSummary = $reverseSummaryPath
    $reverseCheckpoint.reverseSummarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $reverseSummaryPath).Hash.ToLowerInvariant()
    $reverseCheckpoint.reverseMaxMinutes = $reverseMaxMinutes
    Write-CcrAlpha4BaselineCheckpoint $reverseCheckpointPath $reverseCheckpoint | Out-Null
  }
} catch {
  $primaryFailure = $_
  $failedCheckpoint = [ordered]@{}
  foreach ($entry in $baseEvidence.GetEnumerator()) { $failedCheckpoint[$entry.Key] = $entry.Value }
  $failedCheckpoint.kind = "s24-alpha4-navigation-baseline-checkpoint"
  $failedCheckpoint.status = "FAIL"
  $failedCheckpoint.failure = $primaryFailure.Exception.Message
  $failedCheckpoint.randomStageCompleted = $randomStageCompleted
  $failedCheckpoint.reverseStageCompleted = $reverseStageCompleted
  $failedCheckpoint.resumeAttempt = $Resume.IsPresent
  $failedCheckpointPath = Join-Path $runDirectory "checkpoint-failed.json"
  if (Test-Path -LiteralPath $failedCheckpointPath) {
    $failedCheckpointPath = Join-Path $runDirectory "checkpoint-failed-resume-$([Guid]::NewGuid().ToString('N')).json"
  }
  Write-CcrAlpha4BaselineCheckpoint $failedCheckpointPath $failedCheckpoint | Out-Null
}

if ($null -ne $primaryFailure) { throw $primaryFailure }

Assert-CcrPinnedInstalledArtifact $context "debugApp"

$randomSummaryPath = Join-Path $randomDirectory "alpha4-random-baseline-v1-summary.json"
$reverseSummaryPath = Join-Path $reverseDirectory "alpha4-reverse-baseline-v1-summary.json"
$final = [ordered]@{}
foreach ($entry in $baseEvidence.GetEnumerator()) { $final[$entry.Key] = $entry.Value }
$final.kind = "s24-alpha4-navigation-baseline"
$final.status = "PASS"
$final.baselineOnly = $true
$final.performanceJudgement = "MEASURED_NOT_GATED"
$final.randomPilotIdentityGate = "PASS"
$final.randomExactnessEvidence = "PREEXISTING_SEPARATE_17_FIXTURE_GATE_NOT_RERUN_BY_THIS_SCRIPT"
$final.randomTimingBaselineOnly = $true
$final.randomMemoryMeasurement = [string]$randomSummary.memoryMeasurement
$final.randomInSessionMemory = @($randomSummary.inSessionMemory)
$final.randomDecoderStageTiming = "PASS"
$final.reverseMeasurement = "PASS"
$final.resumed = $Resume.IsPresent
$final.randomSummary = $randomSummaryPath
$final.randomSummarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $randomSummaryPath).Hash.ToLowerInvariant()
$final.reverseSummary = $reverseSummaryPath
$final.reverseSummarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $reverseSummaryPath).Hash.ToLowerInvariant()
Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-baseline-complete"
$finalPath = Write-CcrAlpha4BaselineCheckpoint (Join-Path $runDirectory "alpha4-navigation-baseline-v1-summary.json") $final
Get-Content -Raw -Encoding UTF8 -LiteralPath $finalPath
