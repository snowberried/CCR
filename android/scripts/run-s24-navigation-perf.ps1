param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateSet("Forward", "Alpha4Reverse")][string]$ScenarioProfile = "Forward",
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")
. (Join-Path $PSScriptRoot "alpha4-baseline-contract.ps1")
$deadlineUtc = New-CcrAlpha4DeadlineUtc -MaxMinutes $MaxMinutes

function Write-CcrPerfJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  [System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($Path),
    ($Value | ConvertTo-Json -Depth 20),
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Write-CcrPerfCheckpoint {
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

function Read-CcrPerfJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Failure)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $Failure }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw $Failure }
}

function Assert-CcrPerfFileIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [string]$Failure = "PINNED_PERF_RESUME_FILE_IDENTITY_MISMATCH"
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or $ExpectedSha256 -notmatch '^[0-9a-f]{64}$' -or
      (Get-Item -LiteralPath $Path).Length -le 0 -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
    throw $Failure
  }
}

function New-CcrPerfCheckpointBase {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$ScenarioProfile,
    [Parameter(Mandatory = $true)][int]$MaxMinutes
  )
  return [ordered]@{
    schemaVersion = 1
    kind = $Kind
    status = "PASS"
    artifactManifestSha256 = $Context.ArtifactSet.ManifestSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $Context "debugTest").sha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256
    serial = $Context.Serial
    fingerprint = $Context.Fingerprint
    scenarioProfile = $ScenarioProfile
    maxMinutes = $MaxMinutes
    partialIterationResumeSupported = $false
  }
}

function Get-CcrBenchmarkEvidenceFromOutput {
  param([Parameter(Mandatory = $true)][string]$Output)
  $matches = [regex]::Matches(
    $Output,
    '(?m)^INSTRUMENTATION_STATUS: ccrBenchmarkHarnessV2=(?<json>\{[^\r\n]*\})\r?$'
  )
  if ($matches.Count -ne 1) { throw "PINNED_BENCHMARK_STATUS_JSON_COUNT_MISMATCH" }
  try {
    return $matches[0].Groups["json"].Value | ConvertFrom-Json
  } catch {
    throw "PINNED_BENCHMARK_STATUS_JSON_INVALID"
  }
}

function Assert-CcrBenchmarkData {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedMethod,
    [Parameter(Mandatory = $true)][object]$ExpectedEvidence,
    [Parameter(Mandatory = $true)][object[]]$TraceFiles,
    [bool]$RequireRequestStageMetrics = $false
  )
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  try { $document = $text | ConvertFrom-Json } catch { throw "PINNED_BENCHMARK_DATA_JSON_INVALID" }
  $benchmarks = @($document.benchmarks)
  if ($benchmarks.Count -ne 1) { throw "PINNED_BENCHMARK_DATA_BENCHMARK_COUNT_MISMATCH" }
  $benchmark = $benchmarks[0]
  if ([string]$benchmark.name -cne $ExpectedMethod -or
      [string]$benchmark.className -cne "com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark" -or
      [int]$benchmark.repeatIterations -ne 3) {
    throw "PINNED_BENCHMARK_DATA_IDENTITY_MISMATCH"
  }
  $requiredMetrics = @(
    "ccrActiveDurationMs",
    "ccrPublicationCount",
    "ccrPublicationIntervalP50Us",
    "ccrPublicationIntervalP95Us",
    "ccrPublicationIntervalMaxUs",
    "ccrPublishedFpsMilli",
    "ccrRawLagP50",
    "ccrRawLagP95",
    "ccrRawLagMax",
    "ccrOutstandingForegroundTargetDepthMax",
    "ccrAcceptedTargetCount",
    "ccrReleaseAfterAcceptedTargetCount",
    "ccrHoldPrefetchStarted",
    "ccrHoldPrefetchCompleted",
    "ccrCounterComplete",
    "ccrRunIteration",
    "ccrRunIdHash53",
    "ccrTraceIdentityHash53",
    "ccrRuntimeSourceHash53",
    "ccrHarnessSourceHash53",
    "ccrRuntimeInputsTreeHash53",
    "ccrValidTraceIdentity"
  )
  if ($RequireRequestStageMetrics) { $requiredMetrics += @(
    "ccrAcceptedToFirstOutputP50Us",
    "ccrAcceptedToFirstOutputP95Us",
    "ccrAcceptedToFirstOutputMaxUs",
    "ccrAcceptedToTargetOutputP50Us",
    "ccrAcceptedToTargetOutputP95Us",
    "ccrAcceptedToTargetOutputMaxUs",
    "ccrAcceptedToSuccessfulPublicationP50Us",
    "ccrAcceptedToSuccessfulPublicationP95Us",
    "ccrAcceptedToSuccessfulPublicationMaxUs",
    "ccrSuccessfulPublicationTraceCount",
    "ccrDecoderOutputTraceCount",
    "ccrMissingDecoderOutputTraceCount"
  ) }
  $runsByMetric = @{}
  foreach ($metric in $requiredMetrics) {
    $property = $benchmark.metrics.PSObject.Properties[$metric]
    if ($null -eq $property) { throw "PINNED_BENCHMARK_DATA_METRIC_MISSING:$metric" }
    $runs = @($property.Value.runs)
    if ($runs.Count -ne 3 -or @($runs | Where-Object { $null -eq $_ }).Count -ne 0) {
      throw "PINNED_BENCHMARK_DATA_METRIC_RUN_COUNT_MISMATCH:$metric"
    }
    $runsByMetric[$metric] = $runs
  }
  if (($runsByMetric.ccrRunIteration | ForEach-Object { [int]$_ }) -join "," -cne "1,2,3" -or
      @($runsByMetric.ccrCounterComplete | Where-Object { [int]$_ -ne 1 }).Count -ne 0 -or
      @($runsByMetric.ccrValidTraceIdentity | Where-Object { [int]$_ -ne 1 }).Count -ne 0) {
    throw "PINNED_BENCHMARK_DATA_COMPLETENESS_MISMATCH"
  }
  $evidenceIterations = @($ExpectedEvidence.iterations)
  for ($index = 0; $index -lt 3; $index += 1) {
    $expected = $evidenceIterations[$index]
    foreach ($mapping in @(
      @("ccrActiveDurationMs", "activeMs"),
      @("ccrPublicationCount", "published"),
      @("ccrPublicationIntervalP50Us", "publicationIntervalP50Us"),
      @("ccrPublicationIntervalP95Us", "publicationIntervalP95Us"),
      @("ccrPublicationIntervalMaxUs", "publicationIntervalMaxUs"),
      @("ccrRawLagP50", "rawLagP50"),
      @("ccrRawLagP95", "rawLagP95"),
      @("ccrRawLagMax", "rawLagMax"),
      @("ccrOutstandingForegroundTargetDepthMax", "outstandingForegroundTargetDepthMax"),
      @("ccrAcceptedTargetCount", "acceptedTargetCount"),
      @("ccrReleaseAfterAcceptedTargetCount", "releaseAfterAcceptedTargetCount"),
      @("ccrHoldPrefetchStarted", "holdPrefetchStarted"),
      @("ccrHoldPrefetchCompleted", "holdPrefetchCompleted")
    )) {
      if ([long]$runsByMetric[$mapping[0]][$index] -ne [long]$expected.($mapping[1])) {
        throw "PINNED_BENCHMARK_DATA_EVIDENCE_MISMATCH:$($mapping[0])/$($index + 1)"
      }
    }
    $fpsMilli = [long]$runsByMetric.ccrPublishedFpsMilli[$index]
    $expectedFpsMilli = [long][Math]::Round([double]$expected.publishedFps * 1000.0)
    if ([Math]::Abs($fpsMilli - $expectedFpsMilli) -gt 1) {
      throw "PINNED_BENCHMARK_DATA_EVIDENCE_MISMATCH:ccrPublishedFpsMilli/$($index + 1)"
    }
  }
  $requestStageMetrics = [System.Collections.Generic.List[object]]::new()
  if ($RequireRequestStageMetrics) { for ($index = 0; $index -lt 3; $index += 1) {
    $values = [ordered]@{}
    foreach ($name in @(
      "ccrAcceptedToFirstOutputP50Us", "ccrAcceptedToFirstOutputP95Us", "ccrAcceptedToFirstOutputMaxUs",
      "ccrAcceptedToTargetOutputP50Us", "ccrAcceptedToTargetOutputP95Us", "ccrAcceptedToTargetOutputMaxUs",
      "ccrAcceptedToSuccessfulPublicationP50Us", "ccrAcceptedToSuccessfulPublicationP95Us",
      "ccrAcceptedToSuccessfulPublicationMaxUs", "ccrSuccessfulPublicationTraceCount",
      "ccrDecoderOutputTraceCount", "ccrMissingDecoderOutputTraceCount"
    )) { $values[$name] = [long]$runsByMetric[$name][$index] }
    foreach ($prefix in @("ccrAcceptedToFirstOutput", "ccrAcceptedToTargetOutput", "ccrAcceptedToSuccessfulPublication")) {
      if ($values["${prefix}P50Us"] -lt 0 -or $values["${prefix}P95Us"] -lt $values["${prefix}P50Us"] -or
          $values["${prefix}MaxUs"] -lt $values["${prefix}P95Us"]) {
        throw "PINNED_BENCHMARK_REQUEST_STAGE_PERCENTILE_INVALID:$prefix/$($index + 1)"
      }
    }
    if ($values.ccrAcceptedToTargetOutputP50Us -lt $values.ccrAcceptedToFirstOutputP50Us -or
        $values.ccrAcceptedToTargetOutputP95Us -lt $values.ccrAcceptedToFirstOutputP95Us -or
        $values.ccrAcceptedToTargetOutputMaxUs -lt $values.ccrAcceptedToFirstOutputMaxUs -or
        $values.ccrAcceptedToSuccessfulPublicationP50Us -lt $values.ccrAcceptedToTargetOutputP50Us -or
        $values.ccrAcceptedToSuccessfulPublicationP95Us -lt $values.ccrAcceptedToTargetOutputP95Us -or
        $values.ccrAcceptedToSuccessfulPublicationMaxUs -lt $values.ccrAcceptedToTargetOutputMaxUs) {
      throw "PINNED_BENCHMARK_REQUEST_STAGE_ORDER_INVALID:$($index + 1)"
    }
    if ($values.ccrSuccessfulPublicationTraceCount -ne [long]$evidenceIterations[$index].published -or
        $values.ccrDecoderOutputTraceCount -le 0 -or
        $values.ccrDecoderOutputTraceCount + $values.ccrMissingDecoderOutputTraceCount -ne $values.ccrSuccessfulPublicationTraceCount) {
      throw "PINNED_BENCHMARK_REQUEST_STAGE_COUNT_MISMATCH:$($index + 1)"
    }
    $values.runIteration = $index + 1
    $requestStageMetrics.Add([PSCustomObject]$values) | Out-Null
  } }
  $profilerOutputs = @($benchmark.profilerOutputs | Where-Object { [string]$_.type -ceq "PerfettoTrace" })
  $expectedTraceNames = @($TraceFiles | ForEach-Object Name | Sort-Object)
  $actualTraceNames = @($profilerOutputs | ForEach-Object filename | Sort-Object)
  if ($profilerOutputs.Count -ne 3 -or ($expectedTraceNames -join "`n") -cne ($actualTraceNames -join "`n")) {
    throw "PINNED_BENCHMARK_DATA_TRACE_FILESET_MISMATCH"
  }
  return @($requestStageMetrics)
}

function Assert-CcrPerformanceGate {
  param(
    [Parameter(Mandatory = $true)][object]$Evidence,
    [Parameter(Mandatory = $true)][object]$Scenario
  )
  foreach ($iteration in @($Evidence.iterations)) {
    $iterationNumber = [int]$iteration.runIteration
    if ([long]$iteration.activeMs -le 0 -or [long]$iteration.published -le 0 -or
        [long]$iteration.acceptedTargetCount -le 0) {
      throw "PINNED_PERF_EMPTY_MEASUREMENT:$($Scenario.Method)/$iterationNumber"
    }
    if ($Scenario.PerformanceThresholdsApplied) {
      if ([long]$iteration.publicationIntervalP50Us -gt [long]$Scenario.IntervalP50UsMax) {
        throw "PINNED_PERF_INTERVAL_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
      }
      if ([double]$iteration.publishedFps -lt [double]$Scenario.PublishedFpsMin) {
        throw "PINNED_PERF_FPS_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
      }
    }
    if ([long]$iteration.rawLagMax -gt [long]$Scenario.RawLagMax) {
      throw "PINNED_PERF_RAW_LAG_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.outstandingForegroundTargetDepthMax -gt 1) {
      throw "PINNED_PERF_OUTSTANDING_TARGET_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.releaseAfterAcceptedTargetCount -ne 0) {
      throw "PINNED_PERF_RELEASE_ACCEPTANCE_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.holdPrefetchStarted -ne 0 -or [long]$iteration.holdPrefetchCompleted -ne 0) {
      throw "PINNED_PERF_HOLD_PREFETCH_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
  }
}

function Assert-CcrPerfCheckpointIdentity {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$ExpectedKind,
    [Parameter(Mandatory = $true)][string]$ExpectedScenarioProfile,
    [Parameter(Mandatory = $true)][int]$ExpectedMaxMinutes
  )
  if ([int]$Checkpoint.schemaVersion -ne 1 -or [string]$Checkpoint.kind -cne $ExpectedKind -or
      [string]$Checkpoint.status -cne "PASS" -or
      [string]$Checkpoint.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [int]$Checkpoint.artifactSetRevision -ne $script:CcrPinnedArtifactSetRevision -or
      [string]$Checkpoint.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Checkpoint.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Checkpoint.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Checkpoint.debugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Checkpoint.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Checkpoint.benchmarkAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256 -or
      [string]$Checkpoint.macrobenchmarkTestSha256 -cne [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256 -or
      [string]$Checkpoint.serial -cne $Context.Serial -or
      [string]$Checkpoint.fingerprint -cne $Context.Fingerprint -or
      [string]$Checkpoint.scenarioProfile -cne $ExpectedScenarioProfile -or
      [int]$Checkpoint.maxMinutes -ne $ExpectedMaxMinutes) {
    throw "PINNED_PERF_RESUME_CHECKPOINT_IDENTITY_MISMATCH:$ExpectedKind"
  }
}

function Assert-CcrPerfScenarioResult {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][object]$Scenario,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ([string]$Result.scenario -cne $Scenario.Method -or
      [string]$Result.evidenceScenario -cne $Scenario.EvidenceScenario -or
      [string]$Result.status -cne "PASS" -or
      [int]$Result.traceCount -ne 3 -or
      [string]$Result.traceArtifactValidation -cne "PASS") {
    throw "PINNED_PERF_RESUME_SCENARIO_IDENTITY_MISMATCH:$($Scenario.Method)"
  }
  $traceArtifacts = @($Result.traceArtifacts)
  if ($traceArtifacts.Count -ne 3) { throw "PINNED_PERF_RESUME_TRACE_COUNT_MISMATCH:$($Scenario.Method)" }
  foreach ($trace in $traceArtifacts) {
    Assert-CcrPerfFileIdentity ([string]$trace.path) ([string]$trace.sha256) `
      "PINNED_PERF_RESUME_TRACE_IDENTITY_MISMATCH:$($Scenario.Method)"
    if ([long]$trace.bytes -ne (Get-Item -LiteralPath ([string]$trace.path)).Length) {
      throw "PINNED_PERF_RESUME_TRACE_SIZE_MISMATCH:$($Scenario.Method)"
    }
    $expectedParserStatus = if ($Scenario.RequireAlpha4BaselineCounters) {
      "PASS_REQUEST_STAGE_METRIC"
    } else {
      "PASS_BENCHMARK_COUNTERS_ONLY"
    }
    if ([string]$trace.parserStatus -cne $expectedParserStatus) {
      throw "PINNED_PERF_RESUME_TRACE_PARSER_STATUS_MISMATCH:$($Scenario.Method)"
    }
  }
  Assert-CcrPerfFileIdentity ([string]$Result.benchmarkDataPath) ([string]$Result.benchmarkDataSha256) `
    "PINNED_PERF_RESUME_BENCHMARK_DATA_IDENTITY_MISMATCH:$($Scenario.Method)"
  Assert-CcrPerfFileIdentity ([string]$Result.evidencePath) ([string]$Result.evidenceSha256) `
    "PINNED_PERF_RESUME_EVIDENCE_IDENTITY_MISMATCH:$($Scenario.Method)"
  $evidence = Read-CcrPerfJson ([string]$Result.evidencePath) "PINNED_PERF_RESUME_EVIDENCE_JSON_INVALID:$($Scenario.Method)"
  Assert-CcrPinnedBenchmarkEvidence $evidence $Context.ArtifactSet ([string]$Result.runId) $Scenario.EvidenceScenario 3 | Out-Null
  if ($Scenario.RequireAlpha4BaselineCounters) { Assert-CcrAlpha4ReverseBaselineEvidence $evidence | Out-Null }
  Assert-CcrPerformanceGate $evidence $Scenario
  $traces = @($traceArtifacts | ForEach-Object { Get-Item -LiteralPath ([string]$_.path) })
  $recomputedMetrics = @(Assert-CcrBenchmarkData `
    ([string]$Result.benchmarkDataPath) $Scenario.Method $evidence $traces $Scenario.RequireAlpha4BaselineCounters)
  if (($recomputedMetrics | ConvertTo-Json -Depth 8 -Compress) -cne
      (@($Result.requestStageTraceMetrics) | ConvertTo-Json -Depth 8 -Compress)) {
    throw "PINNED_PERF_RESUME_REQUEST_STAGE_METRIC_MISMATCH:$($Scenario.Method)"
  }
  return $Result
}

function Test-CcrPackageAbsent {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$PackageName)
  return -not (Test-CcrPinnedPackageInstalled $Context $PackageName)
}

function Save-CcrPerfFailureArtifacts {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][object]$Attempt,
    [Parameter(Mandatory = $true)][string]$OutputRoot
  )
  $failureDirectory = Join-Path $OutputRoot (
    "$($Attempt.runId)-failure-artifacts-$([Guid]::NewGuid().ToString('N'))"
  )
  [System.IO.Directory]::CreateDirectory($failureDirectory) | Out-Null
  $pullExitCode = $null
  $recoveryFailure = $null
  try {
    $pull = Invoke-CcrPinnedAdb $Context @(
      "-s", $Context.Serial, "pull", [string]$Attempt.remoteDirectory, $failureDirectory
    )
    $pullExitCode = [int]$pull.exitCode
    if ($pull.exitCode -ne 0) { $recoveryFailure = "adb-pull-exit-$($pull.exitCode)" }
  } catch {
    $recoveryFailure = "adb-pull-exception:$($_.Exception.Message)"
  }
  $recoveredFiles = @(
    Get-ChildItem -LiteralPath $failureDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
      $relativePath = $_.FullName.Substring(
        [System.IO.Path]::GetFullPath($failureDirectory).TrimEnd('\', '/').Length
      ).TrimStart('\', '/')
      [ordered]@{
        relativePath = $relativePath
        bytes = [long]$_.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
      }
    }
  )
  if ($recoveredFiles.Count -eq 0 -and $null -eq $recoveryFailure) {
    $recoveryFailure = "remote-output-empty"
  }
  $recovery = [ordered]@{
    schemaVersion = 1
    kind = "s24-navigation-perf-failure-artifacts"
    status = if ($null -eq $recoveryFailure) { "RECOVERED" } else { "RECOVERY_FAILED" }
    scenario = [string]$Attempt.scenario
    runId = [string]$Attempt.runId
    remoteDirectory = [string]$Attempt.remoteDirectory
    localDirectory = $failureDirectory
    pullExitCode = $pullExitCode
    recoveryFailure = $recoveryFailure
    files = $recoveredFiles
    recoveredFileCount = $recoveredFiles.Count
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  $manifestPath = Join-Path $failureDirectory "failure-artifacts-v1.json"
  Write-CcrPerfJson $manifestPath $recovery
  $manifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  Get-ChildItem -LiteralPath $failureDirectory -Recurse -File | ForEach-Object { $_.IsReadOnly = $true }
  return [PSCustomObject]@{
    status = $recovery.status
    scenario = $recovery.scenario
    runId = $recovery.runId
    remoteDirectory = $recovery.remoteDirectory
    localDirectory = $failureDirectory
    manifest = $manifestPath
    manifestSha256 = $manifestSha256
    recoveredFileCount = $recoveredFiles.Count
    recoveredFiles = $recoveredFiles
    recoveryFailure = $recoveryFailure
  }
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-perf-preflight"
$isAlpha4ReverseBaseline = $ScenarioProfile -ceq "Alpha4Reverse"
if ($Resume -and $PreflightOnly) { throw "PINNED_PERF_RESUME_PREFLIGHT_ONLY_CONFLICT" }
$summaryPath = Join-Path $context.OutputDirectory $(
  if ($isAlpha4ReverseBaseline) { "alpha4-reverse-baseline-v1-summary.json" } else { "navigation-perf-v2-summary.json" }
)
if ((Test-Path -LiteralPath $summaryPath) -and -not $Resume) { throw "PINNED_PERF_SUMMARY_ALREADY_EXISTS" }

if ($PreflightOnly) {
  $preflight = [PSCustomObject]@{
    schemaVersion = 2
    kind = if ($isAlpha4ReverseBaseline) { "s24-alpha4-reverse-baseline-preflight" } else { "s24-navigation-perf-preflight" }
    status = "PASS"
    preflightOnly = $true
    deviceMutationCount = 0
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    artifactManifest = $context.ArtifactSet.ManifestPath
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256
    serial = $context.Serial
    model = $context.Model
    fingerprint = $context.Fingerprint
    securityPatch = $context.SecurityPatch
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    scenarioProfile = $ScenarioProfile
    baselineOnly = $isAlpha4ReverseBaseline
    runtimeIdentityMode = "same-manifest-runtime-source-and-input-tree; benchmarkApp-is-not-byte-identical-to-fixed-debugApp"
    maxMinutes = $MaxMinutes
    deadlineUtc = $deadlineUtc.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    resumeSupported = $true
    resumeGranularity = "complete-three-iteration-scenario"
  }
  Write-CcrPerfJson $summaryPath $preflight
  (Get-Item -LiteralPath $summaryPath).IsReadOnly = $true
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}

$scenarios = if ($isAlpha4ReverseBaseline) {
  @(
    [PSCustomObject]@{
      Method = "hold1080MinusOneAlpha4Baseline"
      EvidenceScenario = "1080p-hold-minus-one"
      Label = "-1"
      RunPrefix = "a4-r1"
      IntervalP50UsMax = $null
      PublishedFpsMin = $null
      RawLagMax = 1L
      PerformanceThresholdsApplied = $false
      RequireAlpha4BaselineCounters = $true
    },
    [PSCustomObject]@{
      Method = "hold1080MinusFiveAlpha4Baseline"
      EvidenceScenario = "1080p-hold-minus-five"
      Label = "-5"
      RunPrefix = "a4-r5"
      IntervalP50UsMax = $null
      PublishedFpsMin = $null
      RawLagMax = 5L
      PerformanceThresholdsApplied = $false
      RequireAlpha4BaselineCounters = $true
    }
  )
} else {
  @(
    [PSCustomObject]@{
      Method = "hold1080PlusOne"
      EvidenceScenario = "1080p-hold-plus-one"
      Label = "+1"
      RunPrefix = "perf-plus1"
      IntervalP50UsMax = 132200L
      PublishedFpsMin = 6.79
      RawLagMax = 1L
      PerformanceThresholdsApplied = $true
      RequireAlpha4BaselineCounters = $false
    },
    [PSCustomObject]@{
      Method = "hold1080PlusFive"
      EvidenceScenario = "1080p-hold-plus-five"
      Label = "+5"
      RunPrefix = "perf-plus5"
      IntervalP50UsMax = 151900L
      PublishedFpsMin = 6.45
      RawLagMax = 5L
      PerformanceThresholdsApplied = $true
      RequireAlpha4BaselineCounters = $false
    }
  )
}

if ($Resume -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
  $existingSummary = Read-CcrPerfJson $summaryPath "PINNED_PERF_RESUME_SUMMARY_INVALID"
  if ([int]$existingSummary.artifactSetRevision -ne $script:CcrPinnedArtifactSetRevision -or
      [string]$existingSummary.artifactManifestSha256 -cne $context.ArtifactSet.ManifestSha256 -or
      [string]$existingSummary.runtimeSourceSha -cne $context.ArtifactSet.RuntimeSourceSha -or
      [string]$existingSummary.harnessSourceSha -cne $context.ArtifactSet.HarnessSourceSha -or
      [string]$existingSummary.runtimeInputsTreeSha256 -cne $context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$existingSummary.fixedDebugAppSha256 -cne [string](Get-CcrPinnedArtifact $context "debugApp").sha256 -or
      [string]$existingSummary.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $context "debugTest").sha256 -or
      [string]$existingSummary.benchmarkAppSha256 -cne [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256 -or
      [string]$existingSummary.macrobenchmarkTestSha256 -cne [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256 -or
      [string]$existingSummary.serial -cne $context.Serial -or
      [string]$existingSummary.fingerprint -cne $context.Fingerprint -or
      [string]$existingSummary.scenarioProfile -cne $ScenarioProfile -or
      [int]$existingSummary.maxMinutes -ne $MaxMinutes) {
    throw "PINNED_PERF_RESUME_SUMMARY_IDENTITY_MISMATCH"
  }
  if ([string]$existingSummary.status -ceq "PASS") {
    if ($null -ne $existingSummary.primaryFailure -or @($existingSummary.cleanupFailures).Count -ne 0 -or
        @($existingSummary.failureArtifacts).Count -ne 0 -or $existingSummary.failedAttemptSuccessCounted -ne $false) {
      throw "PINNED_PERF_RESUME_PASS_SUMMARY_CONTAINS_FAILURE_EVIDENCE"
    }
    foreach ($scenario in $scenarios) {
      $matches = @($existingSummary.scenarios | Where-Object { [string]$_.scenario -ceq $scenario.Method })
      if ($matches.Count -ne 1) { throw "PINNED_PERF_RESUME_SUMMARY_SCENARIO_MISMATCH:$($scenario.Method)" }
      Assert-CcrPerfScenarioResult $matches[0] $scenario $context | Out-Null
    }
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
  if ([string]$existingSummary.status -cne "FAIL") { throw "PINNED_PERF_RESUME_SUMMARY_STATUS_INVALID" }
  $preservedFailurePath = Join-Path $context.OutputDirectory (
    "{0}-prior-failure-{1}.json" -f [System.IO.Path]::GetFileNameWithoutExtension($summaryPath), [Guid]::NewGuid().ToString("N")
  )
  [System.IO.File]::SetAttributes($summaryPath, [System.IO.FileAttributes]::Normal)
  Move-Item -LiteralPath $summaryPath -Destination $preservedFailurePath
  [System.IO.File]::SetAttributes($preservedFailurePath, [System.IO.FileAttributes]::ReadOnly)
}

if ($Resume) {
  $missingEarlierCheckpoint = $false
  foreach ($scenario in $scenarios) {
    $candidateCheckpoint = Join-Path $context.OutputDirectory "checkpoint-perf-$($scenario.Method).json"
    if (-not (Test-Path -LiteralPath $candidateCheckpoint -PathType Leaf)) {
      $missingEarlierCheckpoint = $true
    } elseif ($missingEarlierCheckpoint) {
      throw "PINNED_PERF_RESUME_NONCONTIGUOUS_SCENARIO_CHECKPOINT:$($scenario.Method)"
    }
  }
}

$remoteDirectories = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$failureArtifacts = [System.Collections.Generic.List[object]]::new()
$primaryFailure = $null
$activeFailureAttempt = $null
$failureCheckpointPath = $null
$failureCheckpointSha256 = $null
$manualReviewReady = $false
$settingsSaved = $false
$sessionCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-perf-00-session.json"

try {
  Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-perf-before-device-mutation"
  if ($Resume) {
    $sessionCheckpoint = Read-CcrPerfJson $sessionCheckpointPath "PINNED_PERF_RESUME_SESSION_CHECKPOINT_MISSING_OR_INVALID"
    Assert-CcrPerfCheckpointIdentity `
      $sessionCheckpoint $context "s24-navigation-perf-session-checkpoint" $ScenarioProfile $MaxMinutes
    $savedSettings = $sessionCheckpoint.savedSettings
    foreach ($field in @("stayAwake", "brightnessMode", "brightness", "screenTimeout", "accelerometerRotation", "userRotation")) {
      if ($null -eq $savedSettings.PSObject.Properties[$field]) {
        throw "PINNED_PERF_RESUME_SAVED_SETTING_MISSING:$field"
      }
    }
    $context | Add-Member -Force -NotePropertyName SavedSettings -NotePropertyValue $savedSettings
    $settingsSaved = $true
  } else {
    Save-CcrPinnedDeviceSettings $context | Out-Null
    $settingsSaved = $true
    $sessionCheckpoint = New-CcrPerfCheckpointBase `
      $context "s24-navigation-perf-session-checkpoint" $ScenarioProfile $MaxMinutes
    $sessionCheckpoint.savedSettings = $context.SavedSettings
    $sessionCheckpoint.resumeContract = "completed-scenario-only; partial macrobenchmark iteration is never reused"
    Write-CcrPerfCheckpoint $sessionCheckpointPath $sessionCheckpoint | Out-Null
  }
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"
  $wake = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
  if ($wake.exitCode -ne 0) { throw "PINNED_PERF_DEVICE_WAKE_FAILED" }
  $unlock = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "wm", "dismiss-keyguard")
  if ($unlock.exitCode -ne 0) { throw "PINNED_PERF_KEYGUARD_DISMISS_FAILED" }

  Install-CcrPinnedArtifactSet $context "Benchmark"

  foreach ($scenario in $scenarios) {
    Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-perf-before-$($scenario.Method)"
    $scenarioCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-perf-$($scenario.Method).json"
    if ($Resume -and (Test-Path -LiteralPath $scenarioCheckpointPath -PathType Leaf)) {
      $scenarioCheckpoint = Read-CcrPerfJson $scenarioCheckpointPath "PINNED_PERF_RESUME_SCENARIO_CHECKPOINT_INVALID:$($scenario.Method)"
      Assert-CcrPerfCheckpointIdentity `
        $scenarioCheckpoint $context "s24-navigation-perf-scenario-checkpoint" $ScenarioProfile $MaxMinutes
      if ([string]$scenarioCheckpoint.method -cne $scenario.Method -or
          [string]$scenarioCheckpoint.evidenceScenario -cne $scenario.EvidenceScenario -or
          [string]$scenarioCheckpoint.iterationResume -cne "COMPLETE_THREE_ITERATIONS_ONLY") {
        throw "PINNED_PERF_RESUME_SCENARIO_CHECKPOINT_MISMATCH:$($scenario.Method)"
      }
      $resumedResult = Assert-CcrPerfScenarioResult $scenarioCheckpoint.result $scenario $context
      $results.Add($resumedResult) | Out-Null
      if ([string]$scenarioCheckpoint.remoteDirectory) {
        $remoteDirectories.Add([string]$scenarioCheckpoint.remoteDirectory) | Out-Null
      }
      continue
    }
    if (-not $Resume -and (Test-Path -LiteralPath $scenarioCheckpointPath)) {
      throw "PINNED_PERF_SCENARIO_CHECKPOINT_ALREADY_EXISTS:$($scenario.Method)"
    }
    $runId = New-CcrPinnedRunId $context.OutputDirectory $scenario.RunPrefix
    $remoteDirectory = "/sdcard/Android/media/$script:CcrPinnedMacrobenchmarkPackage/$runId"
    $activeFailureAttempt = [PSCustomObject]@{
      scenario = $scenario.Method
      runId = $runId
      remoteDirectory = $remoteDirectory
    }
    $remoteDirectories.Add($remoteDirectory) | Out-Null
    Remove-CcrPinnedRemoteTraceDirectory $context $remoteDirectory
    $createRemote = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "mkdir", "-p", $remoteDirectory)
    if ($createRemote.exitCode -ne 0) { throw "PINNED_BENCHMARK_REMOTE_DIRECTORY_CREATE_FAILED:$($scenario.Method)" }

    $instrumentation = Invoke-CcrAlpha4TimedInstrumentation `
      -Context $context `
      -TestRole "macrobenchmarkTest" `
      -ClassName "com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark#$($scenario.Method)" `
      -RunId $runId `
      -DeadlineUtc $deadlineUtc `
      -ExpectedTestCount 1 `
      -AdditionalArguments @{
        "additionalTestOutputDir" = $remoteDirectory
        "androidx.benchmark.output.enable" = "true"
      }

    $evidence = Get-CcrBenchmarkEvidenceFromOutput $instrumentation.Output
    $localRunDirectory = Join-Path $context.OutputDirectory $runId
    if (Test-Path -LiteralPath $localRunDirectory) { throw "PINNED_BENCHMARK_LOCAL_RUN_ALREADY_EXISTS:$runId" }
    $pull = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "pull", $remoteDirectory, $localRunDirectory)
    if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $localRunDirectory -PathType Container)) {
      throw "PINNED_BENCHMARK_OUTPUT_PULL_FAILED:$($scenario.Method)"
    }
    Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-perf-after-pull-$($scenario.Method)"

    $instrumentationPath = Join-Path $localRunDirectory "instrumentation-output.txt"
    [System.IO.File]::WriteAllText($instrumentationPath, $instrumentation.Output, [System.Text.UTF8Encoding]::new($false))
    $evidencePath = Join-Path $localRunDirectory "ccrBenchmarkHarnessV2.json"
    Write-CcrPerfJson $evidencePath $evidence

    $files = @(Get-ChildItem -Recurse -File -LiteralPath $localRunDirectory)
    $traces = @($files | Where-Object {
      $_.Name.IndexOf("perfetto-trace", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.Length -gt 0
    })
    if ($traces.Count -ne 3) { throw "PINNED_BENCHMARK_VALID_TRACE_COUNT_MISMATCH:$($scenario.Method)" }
    $benchmarkDataFiles = @($files | Where-Object {
      $_.Name.EndsWith("benchmarkData.json", [System.StringComparison]::OrdinalIgnoreCase) -and $_.Length -gt 0
    })
    if ($benchmarkDataFiles.Count -ne 1) { throw "PINNED_BENCHMARK_DATA_COUNT_MISMATCH:$($scenario.Method)" }
    if ((Get-Item -LiteralPath $evidencePath).Length -le 0) { throw "PINNED_BENCHMARK_EVIDENCE_EMPTY:$($scenario.Method)" }

    $requestStageMetrics = @(Assert-CcrBenchmarkData `
      $benchmarkDataFiles[0].FullName $scenario.Method $evidence $traces $scenario.RequireAlpha4BaselineCounters)
    if ([string]$evidence.traceArtifactValidation -cne "PENDING_HOST") {
      throw "PINNED_BENCHMARK_TRACE_VALIDATION_STATE_MISMATCH:$($scenario.Method)"
    }
    Assert-CcrPinnedBenchmarkEvidence $evidence $context.ArtifactSet $runId $scenario.EvidenceScenario $traces.Count | Out-Null
    if ($scenario.RequireAlpha4BaselineCounters) { Assert-CcrAlpha4ReverseBaselineEvidence $evidence | Out-Null }
    Assert-CcrPerformanceGate $evidence $scenario
    $evidence.traceArtifactValidation = "PASS"
    $traceValidationMethod = if ($scenario.RequireAlpha4BaselineCounters) {
      "androidx-profiler-file-set+benchmarkData-3run-request-stage-metrics+nonempty-traces"
    } else {
      "androidx-profiler-file-set+benchmarkData-3run-counters+nonempty-traces"
    }
    $evidence | Add-Member -Force -NotePropertyName traceValidationMethod `
      -NotePropertyValue $traceValidationMethod
    Write-CcrPerfJson $evidencePath $evidence
    $traceArtifacts = @($traces | Sort-Object FullName | ForEach-Object {
      [PSCustomObject]@{
        path = $_.FullName
        bytes = [long]$_.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        parserStatus = if ($scenario.RequireAlpha4BaselineCounters) {
          "PASS_REQUEST_STAGE_METRIC"
        } else {
          "PASS_BENCHMARK_COUNTERS_ONLY"
        }
      }
    })
    if (@($traceArtifacts | Where-Object { $_.bytes -le 0 -or $_.sha256 -notmatch '^[0-9a-f]{64}$' }).Count -ne 0) {
      throw "PINNED_BENCHMARK_TRACE_ARTIFACT_INVALID:$($scenario.Method)"
    }
    Get-ChildItem -Recurse -File -LiteralPath $localRunDirectory | ForEach-Object { $_.IsReadOnly = $true }

    $scenarioResult = [PSCustomObject]@{
      scenario = $scenario.Method
      evidenceScenario = $scenario.EvidenceScenario
      label = $scenario.Label
      runId = $runId
      status = "PASS"
      traceCount = $traces.Count
      traceArtifactValidation = $evidence.traceArtifactValidation
      traceValidationMethod = $evidence.traceValidationMethod
      tracePaths = @($traces | ForEach-Object FullName)
      traceArtifacts = $traceArtifacts
      benchmarkDataPath = $benchmarkDataFiles[0].FullName
      benchmarkDataSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $benchmarkDataFiles[0].FullName).Hash.ToLowerInvariant()
      evidencePath = $evidencePath
      evidenceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant()
      thresholds = [PSCustomObject]@{
        performanceThresholdsApplied = $scenario.PerformanceThresholdsApplied
        publicationIntervalP50UsMax = $scenario.IntervalP50UsMax
        publishedFpsMin = $scenario.PublishedFpsMin
        rawLagMax = $scenario.RawLagMax
        outstandingForegroundTargetDepthMax = 1
        releaseAfterAcceptedTargetCount = 0
        holdPrefetchStarted = 0
        holdPrefetchCompleted = 0
        validTraceCount = 3
      }
      iterations = @($evidence.iterations)
      requestStageTraceMetrics = $requestStageMetrics
    }
    Assert-CcrPerfScenarioResult $scenarioResult $scenario $context | Out-Null
    $results.Add($scenarioResult) | Out-Null
    $scenarioCheckpoint = New-CcrPerfCheckpointBase `
      $context "s24-navigation-perf-scenario-checkpoint" $ScenarioProfile $MaxMinutes
    $scenarioCheckpoint.method = $scenario.Method
    $scenarioCheckpoint.evidenceScenario = $scenario.EvidenceScenario
    $scenarioCheckpoint.iterationResume = "COMPLETE_THREE_ITERATIONS_ONLY"
    $scenarioCheckpoint.remoteDirectory = $remoteDirectory
    $scenarioCheckpoint.result = $scenarioResult
    Write-CcrPerfCheckpoint $scenarioCheckpointPath $scenarioCheckpoint | Out-Null
    Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "navigation-perf-complete-$($scenario.Method)"
    $activeFailureAttempt = $null
  }
} catch {
  $primaryFailure = $_
} finally {
  if ($null -ne $primaryFailure -and $null -ne $activeFailureAttempt) {
    try {
      $failureArtifacts.Add((Save-CcrPerfFailureArtifacts $context $activeFailureAttempt $context.OutputDirectory)) | Out-Null
    } catch {
      $failureArtifacts.Add([PSCustomObject]@{
        status = "RECOVERY_FAILED"
        scenario = [string]$activeFailureAttempt.scenario
        runId = [string]$activeFailureAttempt.runId
        remoteDirectory = [string]$activeFailureAttempt.remoteDirectory
        localDirectory = $null
        manifest = $null
        manifestSha256 = $null
        recoveredFileCount = 0
        recoveredFiles = @()
        recoveryFailure = "host-recovery-exception:$($_.Exception.Message)"
      }) | Out-Null
    }
  }
  foreach ($remoteDirectory in $remoteDirectories) {
    try {
      Remove-CcrPinnedRemoteTraceDirectory $context $remoteDirectory
    } catch {
      $cleanupFailures.Add("REMOTE_OUTPUT_CLEANUP_FAILED:${remoteDirectory}:$($_.Exception.Message)") | Out-Null
    }
  }

  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch {
    $cleanupFailures.Add("PINNED_CLEANUP_FAILED:$($_.Exception.Message)") | Out-Null
  }

  if ($settingsSaved) {
    foreach ($setting in @(
      @("global", "stay_on_while_plugged_in", $context.SavedSettings.stayAwake),
      @("system", "screen_brightness_mode", $context.SavedSettings.brightnessMode),
      @("system", "screen_brightness", $context.SavedSettings.brightness),
      @("system", "screen_off_timeout", $context.SavedSettings.screenTimeout),
      @("system", "accelerometer_rotation", $context.SavedSettings.accelerometerRotation),
      @("system", "user_rotation", $context.SavedSettings.userRotation)
    )) {
      try {
        $actual = Get-CcrPinnedDeviceSetting $context $setting[0] $setting[1]
        if ([string]$actual -cne [string]$setting[2]) {
          $cleanupFailures.Add("SETTING_RESTORE_VERIFY_FAILED:$($setting[0])/$($setting[1])") | Out-Null
        }
      } catch {
        $cleanupFailures.Add("SETTING_RESTORE_VERIFY_FAILED:$($setting[0])/$($setting[1]):$($_.Exception.Message)") | Out-Null
      }
    }
  }

  foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
    try {
      if (-not (Test-CcrPackageAbsent $context $packageName)) {
        $cleanupFailures.Add("TEST_PACKAGE_STILL_INSTALLED:$packageName") | Out-Null
      }
    } catch {
      $cleanupFailures.Add("TEST_PACKAGE_ABSENCE_VERIFY_FAILED:${packageName}:$($_.Exception.Message)") | Out-Null
    }
  }

  try {
    $debugApp = Get-CcrPinnedArtifact $context "debugApp"
    $installDebug = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "install", "-r", [string]$debugApp.path)
    if ($installDebug.exitCode -ne 0 -or $installDebug.output -notmatch "(?m)^Success\s*$") {
      throw "PINNED_DEBUG_APP_REINSTALL_FAILED"
    }
    Assert-CcrPinnedInstalledArtifact $context "debugApp"
    $launch = Invoke-CcrPinnedAdb $context @(
      "-s", $context.Serial, "shell", "am", "start", "-W", "-n",
      "$script:CcrPinnedAppPackage/com.snowberried.ctcinereviewer.MainActivity"
    )
    if ($launch.exitCode -ne 0 -or $launch.output -notmatch "(?m)^Status:\s+ok\s*$" -or
        $launch.output -match "(?i)error|exception") {
      throw "PINNED_DEBUG_APP_LAUNCH_FAILED"
    }
    $manualReviewReady = $true
  } catch {
    $cleanupFailures.Add("MANUAL_REVIEW_APP_PREPARE_FAILED:$($_.Exception.Message)") | Out-Null
  }

  if ($null -ne $primaryFailure) {
    try {
      $failureCheckpoint = New-CcrPerfCheckpointBase `
        $context "s24-navigation-perf-failure-checkpoint" $ScenarioProfile $MaxMinutes
      $failureCheckpoint.status = "FAIL"
      $failureCheckpoint.primaryFailure = $primaryFailure.Exception.Message
      $failureCheckpoint.cleanupFailures = @($cleanupFailures)
      $failureCheckpoint.activeAttempt = $activeFailureAttempt
      $failureCheckpoint.failureArtifacts = @($failureArtifacts)
      $failureCheckpoint.successCounted = $false
      $failureCheckpointPath = Join-Path $context.OutputDirectory `
        "checkpoint-perf-failure-$([Guid]::NewGuid().ToString('N')).json"
      Write-CcrPerfCheckpoint $failureCheckpointPath $failureCheckpoint | Out-Null
      $failureCheckpointSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $failureCheckpointPath).Hash.ToLowerInvariant()
    } catch {
      $cleanupFailures.Add("FAILURE_CHECKPOINT_WRITE_FAILED:$($_.Exception.Message)") | Out-Null
      $failureCheckpointPath = $null
      $failureCheckpointSha256 = $null
    }
  }

  $status = if ($null -eq $primaryFailure -and $cleanupFailures.Count -eq 0 -and $results.Count -eq $scenarios.Count) { "PASS" } else { "FAIL" }
  $summary = [PSCustomObject]@{
    schemaVersion = 2
    kind = if ($isAlpha4ReverseBaseline) { "s24-alpha4-reverse-baseline" } else { "s24-navigation-perf" }
    status = $status
    primaryFailure = if ($null -eq $primaryFailure) { $null } else { $primaryFailure.Exception.Message }
    cleanupFailures = @($cleanupFailures)
    failureArtifacts = @($failureArtifacts)
    failureCheckpoint = $failureCheckpointPath
    failureCheckpointSha256 = $failureCheckpointSha256
    failedAttemptSuccessCounted = $false
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    artifactManifest = $context.ArtifactSet.ManifestPath
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256
    fixedDebugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    measurementDescription = "source-equivalent pinned benchmark measurement build"
    serial = $context.Serial
    model = $context.Model
    fingerprint = $context.Fingerprint
    securityPatch = $context.SecurityPatch
    scenarios = @($results)
    manualReviewReady = $manualReviewReady
    testPackagesRemoved = -not (@($cleanupFailures) | Where-Object { $_ -match "TEST_PACKAGE" })
    settingsRestored = -not (@($cleanupFailures) | Where-Object { $_ -match "SETTING_" })
    remoteOutputsRemoved = -not (@($cleanupFailures) | Where-Object { $_ -match "REMOTE_OUTPUT" })
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    scenarioProfile = $ScenarioProfile
    baselineOnly = $isAlpha4ReverseBaseline
    performanceJudgement = if ($isAlpha4ReverseBaseline) { "MEASURED_NOT_GATED" } else { "THRESHOLDS_APPLIED" }
    runtimeIdentityMode = "same-manifest-runtime-source-and-input-tree; benchmarkApp-is-not-byte-identical-to-fixed-debugApp"
    maxMinutes = $MaxMinutes
    deadlineUtc = $deadlineUtc.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    instrumentationTimeoutMode = "device-toybox-timeout+host-deadline-check"
    resumed = $Resume.IsPresent
    resumeGranularity = "complete-three-iteration-scenario; partial iteration never reused"
  }
  try {
    Write-CcrPerfJson $summaryPath $summary
    (Get-Item -LiteralPath $summaryPath).IsReadOnly = $true
  } catch {
    $cleanupFailures.Add("SUMMARY_WRITE_FAILED:$($_.Exception.Message)") | Out-Null
  }
}

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  $messages = [System.Collections.Generic.List[string]]::new()
  if ($null -ne $primaryFailure) { $messages.Add("PRIMARY:$($primaryFailure.Exception.Message)") | Out-Null }
  foreach ($failure in $cleanupFailures) { $messages.Add("CLEANUP:$failure") | Out-Null }
  throw ($messages -join " | ")
}

Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
