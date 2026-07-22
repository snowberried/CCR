param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateSet("Forward", "Reverse", "All")][string]$Direction = "All",
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [datetime]$AbsoluteDeadlineUtc = [datetime]::MinValue,
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-alpha5-pinned-artifacts.ps1")
$localDeadlineUtc = New-CcrAlpha5DeadlineUtc $MaxMinutes
$deadlineUtc = if ($AbsoluteDeadlineUtc -eq [datetime]::MinValue) { $localDeadlineUtc } else {
  $candidate = $AbsoluteDeadlineUtc.ToUniversalTime()
  if ($candidate -lt $localDeadlineUtc) { $candidate } else { $localDeadlineUtc }
}
Set-CcrAlpha5ActiveDeadline $deadlineUtc
if ($Direction -cnotin @("Forward", "Reverse", "All")) { throw "ALPHA5_PERF_DIRECTION_NOT_CANONICAL:$Direction" }

function Get-CcrAlpha5BenchmarkEvidence {
  param([Parameter(Mandatory = $true)][string]$Output)
  $matches = [regex]::Matches($Output, '(?m)^INSTRUMENTATION_STATUS: ccrBenchmarkHarnessV2=(?<json>\{[^\r\n]*\})\r?$')
  if ($matches.Count -ne 1) { throw "ALPHA5_PERF_STATUS_JSON_COUNT_MISMATCH" }
  try { return $matches[0].Groups["json"].Value | ConvertFrom-Json } catch {
    throw "ALPHA5_PERF_STATUS_JSON_INVALID"
  }
}

function Assert-CcrAlpha5BenchmarkData {
  param([string]$Path, [string]$Method)
  try { $document = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
    throw "ALPHA5_PERF_BENCHMARK_DATA_INVALID:$Method"
  }
  $benchmarks = @($document.benchmarks)
  if ($benchmarks.Count -ne 1 -or [string]$benchmarks[0].name -cne $Method -or
      [int]$benchmarks[0].repeatIterations -ne 3) {
    throw "ALPHA5_PERF_BENCHMARK_IDENTITY_MISMATCH:$Method"
  }
  foreach ($metric in @("ccrRunIteration", "ccrCounterComplete", "ccrValidTraceIdentity")) {
    $property = $benchmarks[0].metrics.PSObject.Properties[$metric]
    if ($null -eq $property -or @($property.Value.runs).Count -ne 3) {
      throw "ALPHA5_PERF_METRIC_RUN_COUNT_MISMATCH:$Method/$metric"
    }
  }
  if (((@($benchmarks[0].metrics.ccrRunIteration.runs) | ForEach-Object { [int]$_ }) -join ",") -cne "1,2,3" -or
      @($benchmarks[0].metrics.ccrCounterComplete.runs | Where-Object { [int]$_ -ne 1 }).Count -ne 0 -or
      @($benchmarks[0].metrics.ccrValidTraceIdentity.runs | Where-Object { [int]$_ -ne 1 }).Count -ne 0) {
    throw "ALPHA5_PERF_TRACE_COUNTER_INCOMPLETE:$Method"
  }
  return $benchmarks[0]
}

function Assert-CcrAlpha5PerfCheckpoint {
  param([object]$Value, [object]$Context, [object]$Scenario)
  if ([string]$Value.status -cnotin @("PASS", "PERFORMANCE_MISS") -or
      [string]$Value.method -cne $Scenario.method -or
      @($Value.traces).Count -ne 3) {
    throw "ALPHA5_PERF_RESUME_CHECKPOINT_IDENTITY_MISMATCH:$($Scenario.method)"
  }
  Assert-CcrAlpha5IdentityRecord $Value.identity $Context "ALPHA5_PERF_RESUME_CHECKPOINT_IDENTITY_MISMATCH:$($Scenario.method)" | Out-Null
  $traceHashes = @($Value.traces | ForEach-Object { [string]$_.sha256 })
  if (@($traceHashes | Select-Object -Unique).Count -ne 3 -or [int]$Value.iterationCount -ne 3 -or
      [string]$Value.privacyEvidence.basis -cne "PINNED_MANIFEST_SYNTHETIC_ONLY_AND_PULLED_FILE_WHITELIST") {
    throw "ALPHA5_PERF_RESUME_TRACE_OR_PRIVACY_MISMATCH:$($Scenario.method)"
  }
  foreach ($file in @($Value.traces) + @($Value.benchmarkData, $Value.evidence)) {
    Assert-CcrAlpha5EvidenceFileRecord $file $Context.OutputDirectory "ALPHA5_PERF_RESUME_FILE_MISMATCH:$($Scenario.method)" | Out-Null
  }
  $resumeEvidence = [System.IO.File]::ReadAllText([string]$Value.evidence.path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-CcrPinnedBenchmarkEvidence `
    $resumeEvidence $Context.ArtifactSet ([string]$Value.runId) $Scenario.evidence 3 | Out-Null
  $resumeIterations = @(Assert-CcrAlpha5BenchmarkEvidenceStrict $resumeEvidence $Scenario ([string]$Value.runId))
  $resumeGate = Assert-CcrAlpha5PerformanceThreshold $resumeIterations $Scenario
  if ([string]$Value.status -cne [string]$resumeGate.status -or
      ($resumeGate | ConvertTo-Json -Depth 10 -Compress) -cne ($Value.performanceGate | ConvertTo-Json -Depth 10 -Compress)) {
    throw "ALPHA5_PERF_RESUME_HARD_GATE_MISMATCH:$($Scenario.method)"
  }
  Assert-CcrAlpha5BenchmarkData ([string]$Value.benchmarkData.path) $Scenario.method | Out-Null
  $mapping = @($Value.traceIterationMapping)
  if ($mapping.Count -ne 3) { throw "ALPHA5_PERF_RESUME_TRACE_MAPPING_MISMATCH:$($Scenario.method)" }
  for ($index = 0; $index -lt 3; $index += 1) {
    if ([int]$mapping[$index].runIteration -ne ($index + 1) -or
        [string]$mapping[$index].traceIdentity -cne [string]$resumeIterations[$index].traceIdentity -or
        [string]$mapping[$index].traceSha256 -cne [string]$Value.traces[$index].sha256) {
      throw "ALPHA5_PERF_RESUME_TRACE_MAPPING_MISMATCH:$($Scenario.method)/$index"
    }
  }
}

function Assert-CcrAlpha5BenchmarkEvidenceStrict {
  param([object]$Evidence, [object]$Scenario, [string]$RunId)
  $expectedAppSha = [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256
  $expectedTestSha = [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256
  if ([string](Get-CcrPinnedRequiredProperty $Evidence "reportKind") -cne "ccr-benchmark-harness-v2" -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "runId") -cne $RunId -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "scenario") -cne $Scenario.evidence -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "appApkSha256") -cne $expectedAppSha -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "testApkSha256") -cne $expectedTestSha -or
      [int](Get-CcrPinnedRequiredProperty $Evidence "expectedTraceCount") -ne 3 -or
      [int](Get-CcrPinnedRequiredProperty $Evidence "traceIdentityCount") -ne 3) {
    throw "ALPHA5_PERF_EVIDENCE_IDENTITY_MISMATCH:$($Scenario.method)"
  }
  $iterations = @((Get-CcrPinnedRequiredProperty $Evidence "iterations"))
  if ($iterations.Count -ne 3) { throw "ALPHA5_PERF_EVIDENCE_ITERATION_COUNT_MISMATCH:$($Scenario.method)" }
  for ($index = 0; $index -lt 3; $index += 1) {
    $iteration = $iterations[$index]
    $expectedIdentity = "$RunId.$($Scenario.evidence).$($index + 1)"
    if ([int](Get-CcrPinnedRequiredProperty $iteration "runIteration") -ne ($index + 1) -or
        [string](Get-CcrPinnedRequiredProperty $iteration "traceIdentity") -cne $expectedIdentity -or
        [string](Get-CcrPinnedRequiredProperty $iteration "appApkSha256") -cne $expectedAppSha -or
        [string](Get-CcrPinnedRequiredProperty $iteration "testApkSha256") -cne $expectedTestSha -or
        (Get-CcrPinnedRequiredProperty $iteration "counterComplete") -ne $true) {
      throw "ALPHA5_PERF_EVIDENCE_ITERATION_IDENTITY_MISMATCH:$($Scenario.method)/$index"
    }
    $activeMs = [long](Get-CcrPinnedRequiredProperty $iteration "activeMs")
    $measurementTargetMs = [long](Get-CcrPinnedRequiredProperty $iteration "measurementTargetMs")
    $acceptedTargetCount = [long](Get-CcrPinnedRequiredProperty $iteration "acceptedTargetCount")
    if ($measurementTargetMs -ne 30000L -or $activeMs -lt $measurementTargetMs -or
        $activeMs -gt ($measurementTargetMs + 2000L)) {
      throw "ALPHA5_PERF_FIXED_HORIZON_MISMATCH:$($Scenario.method)/$index"
    }
    if ($acceptedTargetCount -le 0L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "acceptedTargetSequenceCount") -ne $acceptedTargetCount -or
        [long](Get-CcrPinnedRequiredProperty $iteration "rawLagSampleCount") -ne $acceptedTargetCount -or
        [long](Get-CcrPinnedRequiredProperty $iteration "outstandingForegroundTargetSampleCount") -lt $acceptedTargetCount -or
        [string](Get-CcrPinnedRequiredProperty $iteration "acceptedTargetSequenceSha256") -cnotmatch '^[0-9a-f]{64}$') {
      throw "ALPHA5_PERF_LAG_COVERAGE_MISMATCH:$($Scenario.method)/$index"
    }
    $cacheBudgetBytes = [long](Get-CcrPinnedRequiredProperty $iteration "cacheBudgetBytes")
    $cacheBytes = [long](Get-CcrPinnedRequiredProperty $iteration "cacheBytes")
    $peakCacheBytes = [long](Get-CcrPinnedRequiredProperty $iteration "peakCacheBytes")
    if ($cacheBudgetBytes -ne 67108864L -or $cacheBytes -lt 0L -or $cacheBytes -gt $cacheBudgetBytes -or
        $peakCacheBytes -lt $cacheBytes -or $peakCacheBytes -gt $cacheBudgetBytes) {
      throw "ALPHA5_PERF_CACHE_BUDGET_MISMATCH:$($Scenario.method)/$index"
    }
  }
  if (@($iterations.traceIdentity | Select-Object -Unique).Count -ne 3) { throw "ALPHA5_PERF_TRACE_IDENTITY_DUPLICATE:$($Scenario.method)" }
  return $iterations
}

function Assert-CcrAlpha5PerformanceThreshold {
  param([object[]]$Iterations, [object]$Scenario)
  $threshold = $null
  if ([string]$Scenario.label -ceq "-1") { $threshold = [ordered]@{ minimumFps = 12.0; maximumLagP95 = 1L; maximumLagMax = 1L } }
  if ([string]$Scenario.label -ceq "-5") { $threshold = [ordered]@{ minimumFps = 10.0; maximumLagP95 = 5L; maximumLagMax = 5L } }
  if ($null -eq $threshold) {
    return [ordered]@{
      applied = $false; status = "PASS"; failureCount = 0; failures = @()
      allThreeIterationsPassed = $true
    }
  }
  $failures = [System.Collections.Generic.List[object]]::new()
  foreach ($iteration in $Iterations) {
    $codes = [System.Collections.Generic.List[string]]::new()
    if ([double](Get-CcrPinnedRequiredProperty $iteration "publishedFps") -lt $threshold.minimumFps) { $codes.Add("FPS_BELOW_MINIMUM") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "rawLagP95") -gt $threshold.maximumLagP95) { $codes.Add("RAW_LAG_P95_EXCEEDED") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "rawLagMax") -gt $threshold.maximumLagMax) { $codes.Add("RAW_LAG_MAX_EXCEEDED") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "reverseWindowRefillStallOver250MsCount") -ne 0) { $codes.Add("REFILL_STALL_OVER_250MS") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "reverseWindowBuildCount") -le 0) { $codes.Add("REVERSE_WINDOW_NOT_BUILT") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "reverseWindowHitCount") -le 0) { $codes.Add("REVERSE_WINDOW_NO_HIT") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "reverseWindowSeekCount") -ge [long](Get-CcrPinnedRequiredProperty $iteration "acceptedTargetCount")) { $codes.Add("SEEK_PER_ACCEPTED_TARGET_NOT_REDUCED") | Out-Null }
    if ([long](Get-CcrPinnedRequiredProperty $iteration "holdPrefetchStarted") -ne 0 -or
        [long](Get-CcrPinnedRequiredProperty $iteration "holdPrefetchCompleted") -ne 0) { $codes.Add("HOLD_PREFETCH_DURING_HOLD") | Out-Null }
    if ($codes.Count -gt 0) {
      $failures.Add([ordered]@{ runIteration = [int]$iteration.runIteration; codes = @($codes) }) | Out-Null
    }
  }
  return [ordered]@{
    applied = $true; minimumFps = $threshold.minimumFps; maximumRawLagP95 = $threshold.maximumLagP95
    maximumRawLagMax = $threshold.maximumLagMax; maximumRefillStallOver250MsCount = 0
    thresholdContract = "ALPHA5_BIDIRECTIONAL_VALIDATION_V1_USER_APPROVED"
    status = if ($failures.Count -eq 0) { "PASS" } else { "PERFORMANCE_MISS" }
    failureCount = $failures.Count; failures = @($failures)
    allThreeIterationsPassed = $failures.Count -eq 0
  }
}

$allScenarios = @(
  [PSCustomObject]@{ method = "hold1080PlusOne"; evidence = "1080p-hold-plus-one"; label = "+1"; prefix = "a5-p1"; direction = "Forward" },
  [PSCustomObject]@{ method = "hold1080PlusFive"; evidence = "1080p-hold-plus-five"; label = "+5"; prefix = "a5-p5"; direction = "Forward" },
  [PSCustomObject]@{ method = "hold1080MinusOne"; evidence = "1080p-hold-minus-one"; label = "-1"; prefix = "a5-m1"; direction = "Reverse" },
  [PSCustomObject]@{ method = "hold1080MinusFive"; evidence = "1080p-hold-minus-five"; label = "-5"; prefix = "a5-m5"; direction = "Reverse" }
)
$scenarios = @($allScenarios | Where-Object { $Direction -ceq "All" -or $_.direction -ceq $Direction })
$expectedScenarioCount = if ($Direction -ceq "All") { 4 } else { 2 }
if ($scenarios.Count -ne $expectedScenarioCount) { throw "ALPHA5_PERF_SCENARIO_COUNT_MISMATCH:$Direction" }
$context = Invoke-CcrAlpha5PinnedPreflight `
  -ArtifactManifest $ArtifactManifest -ArtifactManifestSha256 $ArtifactManifestSha256 `
  -OutputDirectory $OutputDirectory
Assert-CcrAlpha5Deadline $deadlineUtc "perf-preflight"

$summaryPath = Join-Path $context.OutputDirectory "alpha5-navigation-perf-$($Direction.ToLowerInvariant())-v1.json"
if ($Resume -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
  $existing = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $storedMaxMinutes = [int]$existing.maxMinutes
  Assert-CcrAlpha5PreflightDomain $existing ([bool]$PreflightOnly) "ALPHA5_PERF_RESUME_PREFLIGHT_DOMAIN_MISMATCH"
  if ($PreflightOnly) {
    if ([string]$existing.kind -cne "alpha5-navigation-perf-preflight" -or
        [string]$existing.status -cne "PASS" -or [string]$existing.direction -cne $Direction -or
        [int]$existing.deviceMutationCount -ne 0 -or
        $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240 -or
        [int]$existing.scenarioCount -ne $expectedScenarioCount -or
        [int]$existing.totalIndependentTraceCount -ne ($expectedScenarioCount * 3)) {
      throw "ALPHA5_PERF_PREFLIGHT_RESUME_IDENTITY_MISMATCH"
    }
    Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_PERF_PREFLIGHT_RESUME_IDENTITY_MISMATCH" | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
  if ([string]$existing.status -cnotin @("PASS", "PERFORMANCE_MISS") -or
      [string]$existing.direction -cne $Direction -or
      $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240 -or [int]$existing.scenarioCount -ne $expectedScenarioCount -or
      [int]$existing.totalIndependentTraceCount -ne ($expectedScenarioCount * 3)) {
    throw "ALPHA5_PERF_RESUME_SUMMARY_IDENTITY_MISMATCH"
  }
  Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_PERF_RESUME_SUMMARY_IDENTITY_MISMATCH" | Out-Null
  foreach ($scenario in $scenarios) {
    $checkpoint = @($existing.scenarios | Where-Object { [string]$_.method -ceq $scenario.method })
    if ($checkpoint.Count -ne 1) { throw "ALPHA5_PERF_RESUME_SCENARIO_MISSING:$($scenario.method)" }
    Assert-CcrAlpha5PerfCheckpoint $checkpoint[0] $context $scenario
  }
  $expectedStatus = if (@($existing.scenarios | Where-Object { [string]$_.status -ceq "PERFORMANCE_MISS" }).Count -gt 0) {
    "PERFORMANCE_MISS"
  } else { "PASS" }
  if ([string]$existing.status -cne $expectedStatus) { throw "ALPHA5_PERF_RESUME_SUMMARY_STATUS_MISMATCH" }
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}
if (Test-Path -LiteralPath $summaryPath) { throw "ALPHA5_PERF_SUMMARY_ALREADY_EXISTS" }

if ($PreflightOnly) {
  $preflight = [ordered]@{
    schemaVersion = 1; kind = "alpha5-navigation-perf-preflight"; status = "PASS"
    preflightOnly = $true; deviceMutationCount = 0; direction = $Direction; maxMinutes = $MaxMinutes
    identity = New-CcrAlpha5IdentityRecord $context
    scenarios = @($scenarios | ForEach-Object { [ordered]@{ method = $_.method; label = $_.label; iterations = 3; independentTraceCount = 3 } })
    scenarioCount = $expectedScenarioCount; totalIndependentTraceCount = $expectedScenarioCount * 3
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-Output (Write-CcrAlpha5ImmutableJson $summaryPath $preflight)
  return
}

$results = [System.Collections.Generic.List[object]]::new()
$remoteDirectories = [System.Collections.Generic.List[string]]::new()
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null
$settingsSaved = $false
try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $settingsSaved = $true
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"
  Install-CcrPinnedArtifactSet $context "Benchmark"
  foreach ($scenario in $scenarios) {
    Assert-CcrAlpha5Deadline $deadlineUtc "perf-before-$($scenario.method)"
    $checkpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha5-perf-$($scenario.method).json"
    if ($Resume -and (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
      $checkpoint = [System.IO.File]::ReadAllText($checkpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      Assert-CcrAlpha5PerfCheckpoint $checkpoint $context $scenario
      $results.Add($checkpoint) | Out-Null
      continue
    }
    if (Test-Path -LiteralPath $checkpointPath) { throw "ALPHA5_PERF_CHECKPOINT_ALREADY_EXISTS:$($scenario.method)" }
    $runId = New-CcrPinnedRunId $context.OutputDirectory $scenario.prefix
    $remote = "/sdcard/Android/media/$script:CcrPinnedMacrobenchmarkPackage/$runId"
    $remoteDirectories.Add($remote) | Out-Null
    Remove-CcrPinnedRemoteTraceDirectory $context $remote
    $create = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "mkdir", "-p", $remote)
    if ($create.exitCode -ne 0) { throw "ALPHA5_PERF_REMOTE_DIRECTORY_CREATE_FAILED:$($scenario.method)" }
    $invocation = Invoke-CcrPinnedInstrumentation `
      -Context $context -TestRole "macrobenchmarkTest" `
      -ClassName "com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark#$($scenario.method)" `
      -RunId $runId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $context.OutputDirectory "failure-$runId-instrumentation-v1.json") `
      -AdditionalArguments @{ additionalTestOutputDir = $remote; "androidx.benchmark.output.enable" = "true" }
    Assert-CcrAlpha5Deadline $deadlineUtc "perf-after-$($scenario.method)"
    $evidence = Get-CcrAlpha5BenchmarkEvidence $invocation.Output
    $local = Join-Path $context.OutputDirectory $runId
    if (Test-Path -LiteralPath $local) { throw "ALPHA5_PERF_LOCAL_DIRECTORY_ALREADY_EXISTS:$runId" }
    $pull = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "pull", $remote, $local)
    if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $local -PathType Container)) {
      throw "ALPHA5_PERF_OUTPUT_PULL_FAILED:$($scenario.method)"
    }
    $pulledFiles = @(Get-ChildItem -LiteralPath $local -Recurse -File)
    if ($pulledFiles.Count -ne 4) { throw "ALPHA5_PERF_PULLED_FILE_COUNT_MISMATCH:$($scenario.method)" }
    foreach ($item in $pulledFiles) {
      $full = [System.IO.Path]::GetFullPath($item.FullName)
      if (-not (Test-CcrPinnedPathWithin $full $local) -or
          ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ALPHA5_PERF_PULLED_PATH_FORBIDDEN:$($scenario.method)"
      }
      $allowed = $item.Name -match '^CcrProductMacrobenchmark_[A-Za-z0-9]+_iter00[0-2]_.+\.perfetto-trace$' -or
        $item.Name.EndsWith("benchmarkData.json", [StringComparison]::OrdinalIgnoreCase)
      if (-not $allowed) { throw "ALPHA5_PERF_PULLED_FILE_NOT_WHITELISTED:$($item.Name)" }
    }
    [System.IO.File]::WriteAllText((Join-Path $local "instrumentation-output.txt"), $invocation.Output, [System.Text.UTF8Encoding]::new($false))
    $evidencePath = Join-Path $local "ccrBenchmarkHarnessV2.json"
    [System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
    $files = @(Get-ChildItem -LiteralPath $local -Recurse -File)
    $traces = @($files | Where-Object { $_.Name -match "perfetto-trace" -and $_.Length -gt 0 } | Sort-Object FullName)
    $benchmarkData = @($files | Where-Object { $_.Name.EndsWith("benchmarkData.json", [StringComparison]::OrdinalIgnoreCase) -and $_.Length -gt 0 })
    if ($traces.Count -ne 3) { throw "ALPHA5_PERF_TRACE_COUNT_MISMATCH:$($scenario.method)" }
    if ($benchmarkData.Count -ne 1) { throw "ALPHA5_PERF_BENCHMARK_DATA_COUNT_MISMATCH:$($scenario.method)" }
    $benchmark = Assert-CcrAlpha5BenchmarkData $benchmarkData[0].FullName $scenario.method
    Assert-CcrPinnedBenchmarkEvidence $evidence $context.ArtifactSet $runId $scenario.evidence 3 | Out-Null
    $iterations = @(Assert-CcrAlpha5BenchmarkEvidenceStrict $evidence $scenario $runId)
    $performanceGate = Assert-CcrAlpha5PerformanceThreshold $iterations $scenario
    $traceHashes = @($traces | ForEach-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() })
    if (@($traceHashes | Select-Object -Unique).Count -ne 3) { throw "ALPHA5_PERF_TRACE_SHA_DUPLICATE:$($scenario.method)" }
    for ($index = 0; $index -lt 3; $index += 1) {
      if ($traces[$index].Name -notmatch ("_iter{0:D3}_" -f $index)) { throw "ALPHA5_PERF_TRACE_ITERATION_MAPPING_MISMATCH:$($scenario.method)/$index" }
    }
    foreach ($iteration in $iterations) {
      if ([long]$iteration.cacheBudgetBytes -ne 67108864L -or
          [long]$iteration.cacheBytes -gt 67108864L -or [long]$iteration.peakCacheBytes -gt 67108864L -or
          [long]$iteration.outstandingForegroundTargetDepthMax -gt 1) {
        throw "ALPHA5_PERF_INVARIANT_MISMATCH:$($scenario.method)"
      }
    }
    $fileRecord = {
      param($item)
      [ordered]@{ path = $item.FullName; bytes = [long]$item.Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant() }
    }
    $checkpoint = [ordered]@{
      schemaVersion = 1; kind = "alpha5-navigation-perf-scenario"; status = [string]$performanceGate.status
      method = $scenario.method; label = $scenario.label; evidenceScenario = $scenario.evidence
      runId = $runId; identity = New-CcrAlpha5IdentityRecord $context
      traceValidation = "PASS_NONEMPTY_THREE_INDEPENDENT_TRACES"
      traces = @($traces | ForEach-Object { & $fileRecord $_ })
      benchmarkData = & $fileRecord $benchmarkData[0]
      evidence = & $fileRecord (Get-Item -LiteralPath $evidencePath)
      iterationCount = 3
      traceIterationMapping = @(0..2 | ForEach-Object {
        [ordered]@{ runIteration = $_ + 1; traceIdentity = [string]$iterations[$_].traceIdentity; traceSha256 = $traceHashes[$_] }
      })
      privacyEvidence = [ordered]@{
        basis = "PINNED_MANIFEST_SYNTHETIC_ONLY_AND_PULLED_FILE_WHITELIST"
        pulledFileCount = $pulledFiles.Count; pulledFileNames = @($pulledFiles.Name | Sort-Object)
        traceContentPrivacyInspected = $false; containsRealMediaMetadataClaim = "PINNED_SYNTHETIC_FIXTURES_ONLY"
      }
      performanceGate = $performanceGate
      publicationIntervalP50Us = @($benchmark.metrics.ccrPublicationIntervalP50Us.runs)
      publicationIntervalP95Us = @($benchmark.metrics.ccrPublicationIntervalP95Us.runs)
      publicationIntervalMaxUs = @($benchmark.metrics.ccrPublicationIntervalMaxUs.runs)
      publishedFpsMilli = @($benchmark.metrics.ccrPublishedFpsMilli.runs)
      rawLagP95 = @($benchmark.metrics.ccrRawLagP95.runs)
      rawLagMax = @($benchmark.metrics.ccrRawLagMax.runs)
      buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
    }
    foreach ($item in $files) { $item.IsReadOnly = $true }
    Write-CcrAlpha5ImmutableJson $checkpointPath $checkpoint | Out-Null
    $results.Add($checkpoint) | Out-Null
  }
} catch { $primaryFailure = $_ } finally {
  Enter-CcrAlpha5CleanupWindow
  foreach ($remote in $remoteDirectories) {
    try { Remove-CcrPinnedRemoteTraceDirectory $context $remote } catch { $cleanupFailures.Add("TRACE_CLEANUP:$($_.Exception.Message)") | Out-Null }
  }
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch { $cleanupFailures.Add("CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null }
  if ($settingsSaved) {
    try {
      foreach ($failure in @(Restore-CcrPinnedDeviceSettings $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
    } catch { $cleanupFailures.Add("SETTINGS_RESTORE:$($_.Exception.Message)") | Out-Null }
    try { Assert-CcrAlpha5SettingsRestored $context | Out-Null } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
}
if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) { throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')" }
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }
if ($results.Count -ne $expectedScenarioCount) { throw "ALPHA5_PERF_COMPLETED_SCENARIO_COUNT_MISMATCH:$Direction" }
$summaryStatus = if (@($results | Where-Object { [string]$_.status -ceq "PERFORMANCE_MISS" }).Count -gt 0) {
  "PERFORMANCE_MISS"
} else { "PASS" }
$summary = [ordered]@{
  schemaVersion = 1; kind = "alpha5-navigation-performance"; status = $summaryStatus
  preflightOnly = $false
  direction = $Direction; maxMinutes = $MaxMinutes; identity = New-CcrAlpha5IdentityRecord $context
  scenarios = @($results); scenarioCount = $results.Count; totalIndependentTraceCount = $results.Count * 3
  buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
}
Write-Output (Write-CcrAlpha5ImmutableJson $summaryPath $summary)
