$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "alpha6-tail-contract.ps1")

$passed = 0
function Assert-Alpha6Equal {
  param([object]$Actual, [object]$Expected, [string]$Name)
  if ($Actual -ne $Expected) { throw "ALPHA6_TEST_ASSERTION_FAILED:$Name/$Actual/$Expected" }
  $script:passed += 1
}
function Assert-Alpha6Throws {
  param([scriptblock]$Action, [string]$Expected, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ([string]$message -cne $Expected) {
    throw "ALPHA6_TEST_EXPECTED_THROW_FAILED:$Name/$message/$Expected"
  }
  $script:passed += 1
}

$metrics = Get-CcrAlpha6PublicationTailMetrics ([long[]]@(100L, 200L, 300L)) 200L
Assert-Alpha6Equal $metrics.cvDefinition "population" "population-cv-definition"
Assert-Alpha6Equal $metrics.percentileDefinition "nearest-rank" "nearest-rank-definition"
Assert-Alpha6Equal $metrics.coefficientOfVariationPpm 408248L "population-cv-value"
Assert-Alpha6Equal $metrics.p50Ns 200L "nearest-rank-p50"
Assert-Alpha6Equal $metrics.p95Ns 300L "nearest-rank-p95"
Assert-Alpha6Equal $metrics.p99Ns 300L "nearest-rank-p99"
Assert-Alpha6Equal $metrics.p995Ns 300L "nearest-rank-p995"

$boundary = Get-CcrAlpha6PublicationTailMetrics ([long[]]@(150L, 151L, 201L, 160L, 100L, 151L)) 100L
Assert-Alpha6Equal $boundary.overOnePointFiveCadenceCount 4 "strict-over-1.5x"
Assert-Alpha6Equal $boundary.overTwoCadenceCount 1 "strict-over-2x"
Assert-Alpha6Equal $boundary.longestConsecutiveOverOnePointFiveCadenceCount 3 "longest-tail-run"
Assert-Alpha6Equal $boundary.longestConsecutivePublicationGapNs 201L "longest-publication-gap"
Assert-Alpha6Throws { Get-CcrAlpha6PublicationTailMetrics ([long[]]@()) 1L } `
  "ALPHA6_PUBLICATION_INTERVAL_INPUT_INVALID" "empty-intervals"
Assert-Alpha6Throws { Get-CcrAlpha6PublicationTailMetrics ([long[]]@(0L)) 1L } `
  "ALPHA6_PUBLICATION_INTERVAL_INPUT_INVALID" "zero-interval"

$minusOneCorrelation = Get-CcrAlpha6RefillGapCorrelation -Stride -1 -IntervalEvents @(
  [PSCustomObject]@{ intervalNs = 100000000L; refillActive = $true; windowBuildActive = $false },
  [PSCustomObject]@{ intervalNs = 100000001L; refillActive = $true; windowBuildActive = $false },
  [PSCustomObject]@{ intervalNs = 110000000L; refillActive = $false; windowBuildActive = $true },
  [PSCustomObject]@{ intervalNs = 200000000L; refillActive = $false; windowBuildActive = $false }
)
Assert-Alpha6Equal $minusOneCorrelation.thresholdNs 100000000L "minus-one-refill-threshold"
Assert-Alpha6Equal $minusOneCorrelation.associatedLongGapCount 2L "minus-one-refill-correlation-count"

$minusFiveCorrelation = Get-CcrAlpha6RefillGapCorrelation -Stride -5 -IntervalEvents @(
  [PSCustomObject]@{ intervalNs = 125000000L; refillActive = $true; windowBuildActive = $true },
  [PSCustomObject]@{ intervalNs = 125000001L; refillActive = $false; windowBuildActive = $true },
  [PSCustomObject]@{ intervalNs = 170000000L; refillActive = $false; windowBuildActive = $false }
)
Assert-Alpha6Equal $minusFiveCorrelation.thresholdNs 125000000L "minus-five-refill-threshold"
Assert-Alpha6Equal $minusFiveCorrelation.associatedLongGapCount 1L "minus-five-refill-correlation-count"
Assert-Alpha6Throws {
  Get-CcrAlpha6RefillGapCorrelation -Stride -1 -IntervalEvents @() | Out-Null
} "ALPHA6_REFILL_GAP_EVENTS_EMPTY" "refill-events-empty"
Assert-Alpha6Throws {
  Get-CcrAlpha6RefillGapCorrelation -Stride -1 -IntervalEvents @(
    [PSCustomObject]@{ intervalNs = 100000001L; refillActive = $true }
  ) | Out-Null
} "ALPHA6_REQUIRED_PROPERTY_MISSING:windowBuildActive" "refill-state-property-missing"
Assert-Alpha6Throws {
  Get-CcrAlpha6RefillGapCorrelation -Stride -5 -IntervalEvents @(
    [PSCustomObject]@{ intervalNs = "125000001"; refillActive = $true; windowBuildActive = $false }
  ) | Out-Null
} "ALPHA6_REFILL_GAP_INTERVAL_INVALID" "refill-interval-string-rejected"
Assert-Alpha6Throws {
  Get-CcrAlpha6RefillGapCorrelation -Stride -5 -IntervalEvents @(
    [PSCustomObject]@{ intervalNs = 125000001L; refillActive = "false"; windowBuildActive = $false }
  ) | Out-Null
} "ALPHA6_REFILL_GAP_STATE_INVALID" "refill-state-string-rejected"

$cadence = [long](1000000000L / 15L)
$passIntervals = [System.Collections.Generic.List[long]]::new()
1..199 | ForEach-Object { $passIntervals.Add($cadence) }
$passIntervals.Add($cadence * 2L)
$passTail = Get-CcrAlpha6PublicationTailMetrics ([long[]]$passIntervals.ToArray()) $cadence
$passCorrelationEvents = @($passIntervals | ForEach-Object {
  [PSCustomObject]@{ intervalNs = [long]$_; refillActive = $false; windowBuildActive = $false }
})
$passCorrelation = Get-CcrAlpha6RefillGapCorrelation -Stride -1 `
  -IntervalEvents $passCorrelationEvents
$gate = Assert-CcrAlpha6ReverseTailGate -Stride -1 -Metrics $passTail `
  -ForwardCoefficientOfVariationPpm 180000L -RefillCorrelation $passCorrelation
Assert-Alpha6Equal $gate.status "PASS" "two-cadence-boundary"
$maxGapFailure = $passTail.PSObject.Copy()
$maxGapFailure.maxNs = $cadence * 2L + 1L
$maxGapFailure.overTwoCadenceCount = 1L
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -1 -Metrics $maxGapFailure `
    -ForwardCoefficientOfVariationPpm 180000L -RefillCorrelation $passCorrelation | Out-Null
} "ALPHA6_TAIL_GATE_MAX_GAP_FAIL" "max-gap-hard-fail"
$passRefillFailureEvents = @($passCorrelationEvents | ForEach-Object {
  [PSCustomObject]@{
    intervalNs = [long]$_.intervalNs
    refillActive = [long]$_.intervalNs -gt 100000000L
    windowBuildActive = $false
  }
})
$passRefillFailure = Get-CcrAlpha6RefillGapCorrelation -Stride -1 `
  -IntervalEvents $passRefillFailureEvents
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -1 -Metrics $passTail `
    -ForwardCoefficientOfVariationPpm 180000L -RefillCorrelation $passRefillFailure | Out-Null
} "ALPHA6_TAIL_GATE_REFILL_GAP_FAIL" "refill-associated-gap"

$minusFiveCadence = [long](1000000000L / 12L)
$minusFiveIntervals = [System.Collections.Generic.List[long]]::new()
1..199 | ForEach-Object { $minusFiveIntervals.Add($minusFiveCadence) }
$minusFiveIntervals.Add($minusFiveCadence * 2L)
$minusFiveTail = Get-CcrAlpha6PublicationTailMetrics `
  ([long[]]$minusFiveIntervals.ToArray()) $minusFiveCadence
$minusFivePassEvents = @($minusFiveIntervals | ForEach-Object {
  [PSCustomObject]@{ intervalNs = [long]$_; refillActive = $false; windowBuildActive = $false }
})
$minusFivePassCorrelation = Get-CcrAlpha6RefillGapCorrelation -Stride -5 `
  -IntervalEvents $minusFivePassEvents
$minusFiveGate = Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveTail `
  -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFivePassCorrelation
Assert-Alpha6Equal $minusFiveGate.status "PASS" "minus-five-tail-gate-pass"
Assert-Alpha6Equal $minusFiveGate.targetCadenceNs 83333333L "minus-five-cadence"
Assert-Alpha6Equal $minusFiveGate.coefficientOfVariationLimitPpm 250000L "minus-five-forward-cv-relative-limit"

$minusFiveCvFail = $minusFiveTail.PSObject.Copy()
$minusFiveCvFail.coefficientOfVariationPpm = 250001L
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveCvFail `
    -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFivePassCorrelation | Out-Null
} "ALPHA6_TAIL_GATE_CV_FAIL" "minus-five-cv-fail"

$minusFiveP99Fail = $minusFiveTail.PSObject.Copy()
$minusFiveP99Fail.p99Ns = $minusFiveCadence * 2L + 1L
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveP99Fail `
    -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFivePassCorrelation | Out-Null
} "ALPHA6_TAIL_GATE_P99_FAIL" "minus-five-p99-fail"

$minusFiveOutlierFail = $minusFiveTail.PSObject.Copy()
$minusFiveOutlierFail.overTwoCadenceCount = 2L
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveOutlierFail `
    -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFivePassCorrelation | Out-Null
} "ALPHA6_TAIL_GATE_OVER_2X_COUNT_FAIL" "minus-five-over-two-count-fail"

$minusFiveRefillFailureEvents = @($minusFivePassEvents | ForEach-Object {
  [PSCustomObject]@{
    intervalNs = [long]$_.intervalNs
    refillActive = $false
    windowBuildActive = [long]$_.intervalNs -gt 125000000L
  }
})
$minusFiveRefillFailure = Get-CcrAlpha6RefillGapCorrelation -Stride -5 `
  -IntervalEvents $minusFiveRefillFailureEvents
Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveTail `
    -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFiveRefillFailure | Out-Null
} "ALPHA6_TAIL_GATE_REFILL_GAP_FAIL" "minus-five-refill-associated-fail"

Assert-Alpha6Throws {
  Assert-CcrAlpha6ReverseTailGate -Stride -5 -Metrics $minusFiveTail `
    -ForwardCoefficientOfVariationPpm 200000L -RefillCorrelation $minusFiveCorrelation | Out-Null
} "ALPHA6_TAIL_GATE_REFILL_CORRELATION_MISMATCH" "refill-event-coverage-mismatch"

function New-Alpha6MetricRuns {
  param([object]$Value)
  return [ordered]@{ runs = @($Value, $Value, $Value) }
}

$benchmarkMetrics = [ordered]@{}
foreach ($entry in @(
  @("ccrRunIteration", @(1, 2, 3)),
  @("ccrCounterComplete", @(1, 1, 1)),
  @("ccrValidTraceIdentity", @(1, 1, 1))
)) { $benchmarkMetrics[$entry[0]] = [ordered]@{ runs = $entry[1] } }
foreach ($entry in @(
  @("ccrPublicationCount", 100),
  @("ccrPublicationIntervalP50Us", 66666),
  @("ccrPublicationIntervalP95Us", 70000),
  @("ccrPublicationIntervalP99Us", 80000),
  @("ccrPublicationIntervalP995Us", 90000),
  @("ccrPublicationIntervalMaxUs", 100000),
  @("ccrPublicationIntervalCvPpm", 180000),
  @("ccrPublicationIntervalOver1_5xCount", 1),
  @("ccrPublicationIntervalOver2xCount", 0),
  @("ccrPublicationIntervalLongestOver1_5xRun", 1),
  @("ccrPublicationIntervalSampleCount", 99),
  @("ccrPublicationIntervalSequenceStartCount", 1),
  @("ccrTargetCadenceNs", $cadence),
  @("ccrTailMetricAvailable", 1),
  @("ccrMeasuredRefillAssociatedLongGapCount", 0),
  @("ccrMeasuredWindowBuildAssociatedLongGapCount", 0),
  @("ccrAcceptedToActorStartAvailable", 1),
  @("ccrAcceptedToActorStartP50Us", 1000),
  @("ccrAcceptedToActorStartP95Us", 2000),
  @("ccrAcceptedToActorStartP99Us", 3000),
  @("ccrAcceptedToActorStartMaxUs", 4000),
  @("ccrAcceptedToExecutionStartP50Us", 500),
  @("ccrAcceptedToExecutionStartP95Us", 1500),
  @("ccrAcceptedToExecutionStartP99Us", 2500),
  @("ccrAcceptedToExecutionStartMaxUs", 4000),
  @("ccrAcceptedToFirstOutputAvailable", 1),
  @("ccrAcceptedToTargetOutputAvailable", 1),
  @("ccrSuccessfulPublicationTraceCount", 100),
  @("ccrActorStartedPublicationTraceCount", 70),
  @("ccrCacheOnlyActorBypassTraceCount", 30),
  @("ccrCacheOnlyActorStartUs", 0),
  @("ccrDecoderOutputTraceCount", 40),
  @("ccrMissingDecoderOutputTraceCount", 60)
)) { $benchmarkMetrics[$entry[0]] = New-Alpha6MetricRuns $entry[1] }

$iterations = @(1..3 | ForEach-Object {
  [PSCustomObject][ordered]@{
    runIteration = $_
    published = 100
    publicationIntervalP50Us = 66666
    publicationIntervalP95Us = 70000
    publicationIntervalP99Us = 80000
    publicationIntervalP995Us = 90000
    publicationIntervalMaxUs = 100000
    publicationIntervalCvPpm = 180000
    publicationIntervalOver1_5xCadenceCount = 1
    publicationIntervalOver2xCadenceCount = 0
    longestConsecutiveOver1_5xCadenceRunCount = 1
    publicationIntervalSampleCount = 99
    publicationIntervalSequenceStartCount = 1
    targetCadenceNs = $cadence
    measuredRefillAssociatedLongGapCount = 0
    measuredWindowBuildAssociatedLongGapCount = 0
  }
})
$evidence = [PSCustomObject][ordered]@{ iterations = $iterations }
$document = [ordered]@{
  benchmarks = @([ordered]@{
    name = "hold1080MinusOne"
    repeatIterations = 3
    metrics = $benchmarkMetrics
  })
}
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-tail-contract-$PID.json"
try {
  [System.IO.File]::WriteAllText(
    $temporary,
    ($document | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false)
  )
  $parsed = Assert-CcrAlpha6BenchmarkData $temporary "hold1080MinusOne" $evidence `
    -RequireRequestStageMetrics
  Assert-Alpha6Equal $parsed.name "hold1080MinusOne" "benchmark-json-pass"

  $document.benchmarks[0].metrics.ccrCacheOnlyActorBypassTraceCount.runs[1] = 29
  [System.IO.File]::WriteAllText(
    $temporary,
    ($document | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Throws {
    Assert-CcrAlpha6BenchmarkData $temporary "hold1080MinusOne" $evidence `
      -RequireRequestStageMetrics | Out-Null
  } "ALPHA6_BENCHMARK_REQUEST_STAGE_COUNT_MISMATCH:2" "cache-only-actor-bypass-count"

  $document.benchmarks[0].metrics.ccrCacheOnlyActorBypassTraceCount.runs[1] = 30
  $document.benchmarks[0].metrics.ccrMeasuredRefillAssociatedLongGapCount.runs[0] = 1
  [System.IO.File]::WriteAllText(
    $temporary,
    ($document | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Throws {
    Assert-CcrAlpha6BenchmarkData $temporary "hold1080MinusOne" $evidence `
      -RequireRequestStageMetrics | Out-Null
  } "ALPHA6_BENCHMARK_DATA_EVIDENCE_MISMATCH:ccrMeasuredRefillAssociatedLongGapCount/1" `
    "refill-gap-counter-evidence"
} finally {
  if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
}

Write-Output "Alpha 6 tail contract tests passed: $passed"
