Set-StrictMode -Version Latest

function Get-CcrAlpha6RequiredProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    throw "ALPHA6_REQUIRED_PROPERTY_MISSING:$Name"
  }
  return $property.Value
}

function Get-CcrAlpha6NearestRank {
  param(
    [Parameter(Mandatory = $true)][long[]]$SortedValues,
    [Parameter(Mandatory = $true)][double]$Fraction
  )
  if ($SortedValues.Count -eq 0 -or $Fraction -le 0.0 -or $Fraction -gt 1.0) {
    throw "ALPHA6_NEAREST_RANK_INPUT_INVALID"
  }
  $index = [Math]::Ceiling($SortedValues.Count * $Fraction) - 1
  return [long]$SortedValues[[int]$index]
}

function Get-CcrAlpha6PublicationTailMetrics {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][long[]]$IntervalsNs,
    [Parameter(Mandatory = $true)][long]$CadenceNs
  )
  if ($CadenceNs -le 0L -or $CadenceNs -gt [long]::MaxValue / 3L -or
      $IntervalsNs.Count -eq 0 -or
      @($IntervalsNs | Where-Object { $_ -le 0L -or $_ -gt [long]::MaxValue / 2L }).Count -ne 0) {
    throw "ALPHA6_PUBLICATION_INTERVAL_INPUT_INVALID"
  }
  $sorted = @($IntervalsNs | Sort-Object)
  $sum = 0.0
  foreach ($interval in $IntervalsNs) { $sum += [double]$interval }
  $mean = $sum / $IntervalsNs.Count
  $squaredDeltaSum = 0.0
  foreach ($interval in $IntervalsNs) {
    $delta = [double]$interval - $mean
    $squaredDeltaSum += $delta * $delta
  }
  $populationVariance = $squaredDeltaSum / $IntervalsNs.Count
  $cvPpm = [long][Math]::Floor(([Math]::Sqrt($populationVariance) / $mean * 1000000.0) + 0.5)
  $overOnePointFive = 0
  $overTwo = 0
  $currentRun = 0
  $longestRun = 0
  foreach ($interval in $IntervalsNs) {
    if ($interval * 2L -gt $CadenceNs * 3L) {
      $overOnePointFive += 1
      $currentRun += 1
      $longestRun = [Math]::Max($longestRun, $currentRun)
    } else {
      $currentRun = 0
    }
    if ($interval * 2L -gt $CadenceNs * 4L) { $overTwo += 1 }
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    cvDefinition = "population"
    percentileDefinition = "nearest-rank"
    sampleCount = $sorted.Count
    targetCadenceNs = $CadenceNs
    coefficientOfVariationPpm = $cvPpm
    p50Ns = Get-CcrAlpha6NearestRank $sorted 0.50
    p95Ns = Get-CcrAlpha6NearestRank $sorted 0.95
    p99Ns = Get-CcrAlpha6NearestRank $sorted 0.99
    p995Ns = Get-CcrAlpha6NearestRank $sorted 0.995
    maxNs = [long]$sorted[-1]
    longestConsecutivePublicationGapNs = [long]$sorted[-1]
    overOnePointFiveCadenceCount = $overOnePointFive
    overTwoCadenceCount = $overTwo
    longestConsecutiveOverOnePointFiveCadenceCount = $longestRun
  }
}

function Get-CcrAlpha6RefillGapCorrelation {
  param(
    [Parameter(Mandatory = $true)][ValidateSet(-1, -5)][int]$Stride,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$IntervalEvents
  )
  if ($IntervalEvents.Count -eq 0) { throw "ALPHA6_REFILL_GAP_EVENTS_EMPTY" }
  $thresholdNs = if ($Stride -eq -1) { 100000000L } else { 125000000L }
  $associatedLongGapCount = 0L
  $refillActiveEventCount = 0L
  $windowBuildActiveEventCount = 0L
  foreach ($event in $IntervalEvents) {
    if ($null -eq $event) { throw "ALPHA6_REFILL_GAP_EVENT_INVALID" }
    foreach ($name in @("intervalNs", "refillActive", "windowBuildActive")) {
      Get-CcrAlpha6RequiredProperty $event $name | Out-Null
    }
    if ($event.intervalNs -isnot [byte] -and $event.intervalNs -isnot [int16] -and
        $event.intervalNs -isnot [int32] -and $event.intervalNs -isnot [int64]) {
      throw "ALPHA6_REFILL_GAP_INTERVAL_INVALID"
    }
    $intervalNs = [long]$event.intervalNs
    if ($intervalNs -le 0L) { throw "ALPHA6_REFILL_GAP_INTERVAL_INVALID" }
    if ($event.refillActive -isnot [bool] -or $event.windowBuildActive -isnot [bool]) {
      throw "ALPHA6_REFILL_GAP_STATE_INVALID"
    }
    $refillActive = [bool]$event.refillActive
    $windowBuildActive = [bool]$event.windowBuildActive
    if ($refillActive) { $refillActiveEventCount += 1L }
    if ($windowBuildActive) { $windowBuildActiveEventCount += 1L }
    if ($intervalNs -gt $thresholdNs -and ($refillActive -or $windowBuildActive)) {
      $associatedLongGapCount += 1L
    }
  }
  return [PSCustomObject][ordered]@{
    stride = $Stride
    thresholdNs = $thresholdNs
    eventCount = [long]$IntervalEvents.Count
    refillActiveEventCount = $refillActiveEventCount
    windowBuildActiveEventCount = $windowBuildActiveEventCount
    associatedLongGapCount = $associatedLongGapCount
  }
}

function Assert-CcrAlpha6ReverseTailGate {
  param(
    [Parameter(Mandatory = $true)][ValidateSet(-1, -5)][int]$Stride,
    [Parameter(Mandatory = $true)][object]$Metrics,
    [Parameter(Mandatory = $true)][long]$ForwardCoefficientOfVariationPpm,
    [Parameter(Mandatory = $true)][object]$RefillCorrelation,
    [ValidateRange(0, 1)][int]$ClassifiedSystemSchedulingOutlierCount = 0
  )
  if ($ForwardCoefficientOfVariationPpm -lt 0L) { throw "ALPHA6_TAIL_GATE_INPUT_INVALID" }
  $cadenceNs = if ($Stride -eq -1) { [long](1000000000L / 15L) } else { [long](1000000000L / 12L) }
  $refillThresholdNs = if ($Stride -eq -1) { 100000000L } else { 125000000L }
  foreach ($name in @(
    "sampleCount", "targetCadenceNs", "coefficientOfVariationPpm", "p99Ns", "p995Ns", "maxNs",
    "longestConsecutivePublicationGapNs",
    "overOnePointFiveCadenceCount", "overTwoCadenceCount",
    "longestConsecutiveOverOnePointFiveCadenceCount"
  )) { Get-CcrAlpha6RequiredProperty $Metrics $name | Out-Null }
  foreach ($name in @("stride", "thresholdNs", "eventCount", "associatedLongGapCount")) {
    Get-CcrAlpha6RequiredProperty $RefillCorrelation $name | Out-Null
  }
  if ([long]$Metrics.sampleCount -le 0L -or [long]$Metrics.targetCadenceNs -ne $cadenceNs) {
    throw "ALPHA6_TAIL_GATE_EVIDENCE_INCOMPLETE"
  }
  if ([int]$RefillCorrelation.stride -ne $Stride -or
      [long]$RefillCorrelation.thresholdNs -ne $refillThresholdNs -or
      [long]$RefillCorrelation.eventCount -ne [long]$Metrics.sampleCount -or
      [long]$RefillCorrelation.associatedLongGapCount -lt 0L) {
    throw "ALPHA6_TAIL_GATE_REFILL_CORRELATION_MISMATCH"
  }
  $cvLimitPpm = [long][Math]::Max(
    [Math]::Ceiling($ForwardCoefficientOfVariationPpm * 1.25),
    220000.0
  )
  $overTwoCount = [long]$Metrics.overTwoCadenceCount
  if ([long]$Metrics.coefficientOfVariationPpm -gt $cvLimitPpm) {
    throw "ALPHA6_TAIL_GATE_CV_FAIL"
  }
  if ([long]$Metrics.p99Ns -gt $cadenceNs * 2L) { throw "ALPHA6_TAIL_GATE_P99_FAIL" }
  if ($overTwoCount -gt 1L) { throw "ALPHA6_TAIL_GATE_OVER_2X_COUNT_FAIL" }
  if ([long]$RefillCorrelation.associatedLongGapCount -ne 0L) { throw "ALPHA6_TAIL_GATE_REFILL_GAP_FAIL" }
  if ([long]$Metrics.maxNs -gt $cadenceNs * 2L -or
      [long]$Metrics.longestConsecutivePublicationGapNs -gt $cadenceNs * 2L) {
    throw "ALPHA6_TAIL_GATE_MAX_GAP_FAIL"
  }
  if ($ClassifiedSystemSchedulingOutlierCount -ne 0) {
    throw "ALPHA6_TAIL_GATE_FALSE_OUTLIER_CLASSIFICATION"
  }
  return [PSCustomObject][ordered]@{
    status = "PASS"
    stride = $Stride
    targetCadenceNs = $cadenceNs
    coefficientOfVariationLimitPpm = $cvLimitPpm
    classifiedSystemSchedulingOutlierCount = $ClassifiedSystemSchedulingOutlierCount
  }
}

function Assert-CcrAlpha6BenchmarkData {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedMethod,
    [Parameter(Mandatory = $true)][object]$ExpectedEvidence,
    [switch]$RequireRequestStageMetrics
  )
  try {
    $document = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "ALPHA6_BENCHMARK_DATA_JSON_INVALID"
  }
  $benchmarks = @($document.benchmarks)
  if ($benchmarks.Count -ne 1 -or [string]$benchmarks[0].name -cne $ExpectedMethod -or
      [int]$benchmarks[0].repeatIterations -ne 3) {
    throw "ALPHA6_BENCHMARK_DATA_IDENTITY_MISMATCH"
  }
  $requiredMetrics = @(
    "ccrRunIteration", "ccrCounterComplete", "ccrValidTraceIdentity",
    "ccrPublicationCount", "ccrPublicationIntervalP50Us", "ccrPublicationIntervalP95Us",
    "ccrPublicationIntervalP99Us", "ccrPublicationIntervalP995Us", "ccrPublicationIntervalMaxUs",
    "ccrPublicationGapMaxUs",
    "ccrPublicationIntervalCvPpm", "ccrPublicationIntervalOver1_5xCount",
    "ccrPublicationIntervalOver2xCount", "ccrPublicationIntervalLongestOver1_5xRun",
    "ccrPublicationIntervalSampleCount", "ccrPublicationIntervalSequenceStartCount",
    "ccrTargetCadenceNs", "ccrTailMetricAvailable",
    "ccrMeasuredRefillAssociatedLongGapCount",
    "ccrMeasuredWindowBuildAssociatedLongGapCount"
  )
  if ($RequireRequestStageMetrics) {
    $requiredMetrics += @(
      "ccrAcceptedToActorStartAvailable", "ccrAcceptedToActorStartP50Us",
      "ccrAcceptedToActorStartP95Us", "ccrAcceptedToActorStartP99Us",
      "ccrAcceptedToActorStartMaxUs", "ccrAcceptedToExecutionStartP50Us",
      "ccrAcceptedToExecutionStartP95Us", "ccrAcceptedToExecutionStartP99Us",
      "ccrAcceptedToExecutionStartMaxUs", "ccrAcceptedToFirstOutputAvailable",
      "ccrAcceptedToTargetOutputAvailable", "ccrSuccessfulPublicationTraceCount",
      "ccrActorStartedPublicationTraceCount", "ccrCacheOnlyActorBypassTraceCount",
      "ccrCacheOnlyActorStartUs", "ccrDecoderOutputTraceCount",
      "ccrMissingDecoderOutputTraceCount"
    )
  }
  $runsByMetric = @{}
  foreach ($metric in $requiredMetrics) {
    $property = $benchmarks[0].metrics.PSObject.Properties[$metric]
    if ($null -eq $property) { throw "ALPHA6_BENCHMARK_DATA_METRIC_MISSING:$metric" }
    $runs = @($property.Value.runs)
    if ($runs.Count -ne 3 -or @($runs | Where-Object { $null -eq $_ }).Count -ne 0) {
      throw "ALPHA6_BENCHMARK_DATA_METRIC_RUN_COUNT_MISMATCH:$metric"
    }
    $runsByMetric[$metric] = $runs
  }
  $iterations = @((Get-CcrAlpha6RequiredProperty $ExpectedEvidence "iterations"))
  if ($iterations.Count -ne 3) { throw "ALPHA6_BENCHMARK_EVIDENCE_ITERATION_COUNT_MISMATCH" }
  for ($index = 0; $index -lt 3; $index += 1) {
    if ([int]$runsByMetric.ccrRunIteration[$index] -ne ($index + 1) -or
        [int]$runsByMetric.ccrCounterComplete[$index] -ne 1 -or
        [int]$runsByMetric.ccrValidTraceIdentity[$index] -ne 1 -or
        [int]$runsByMetric.ccrTailMetricAvailable[$index] -ne 1) {
      throw "ALPHA6_BENCHMARK_DATA_COMPLETENESS_MISMATCH:$($index + 1)"
    }
    $iteration = $iterations[$index]
    foreach ($mapping in @(
      @("ccrPublicationCount", "published"),
      @("ccrPublicationIntervalP50Us", "publicationIntervalP50Us"),
      @("ccrPublicationIntervalP95Us", "publicationIntervalP95Us"),
      @("ccrPublicationIntervalP99Us", "publicationIntervalP99Us"),
      @("ccrPublicationIntervalP995Us", "publicationIntervalP995Us"),
      @("ccrPublicationIntervalMaxUs", "publicationIntervalMaxUs"),
      @("ccrPublicationGapMaxUs", "publicationGapMaxUs"),
      @("ccrPublicationIntervalCvPpm", "publicationIntervalCvPpm"),
      @("ccrPublicationIntervalOver1_5xCount", "publicationIntervalOver1_5xCadenceCount"),
      @("ccrPublicationIntervalOver2xCount", "publicationIntervalOver2xCadenceCount"),
      @("ccrPublicationIntervalLongestOver1_5xRun", "longestConsecutiveOver1_5xCadenceRunCount"),
      @("ccrPublicationIntervalSampleCount", "publicationIntervalSampleCount"),
      @("ccrPublicationIntervalSequenceStartCount", "publicationIntervalSequenceStartCount"),
      @("ccrTargetCadenceNs", "targetCadenceNs"),
      @("ccrMeasuredRefillAssociatedLongGapCount", "measuredRefillAssociatedLongGapCount"),
      @("ccrMeasuredWindowBuildAssociatedLongGapCount", "measuredWindowBuildAssociatedLongGapCount")
    )) {
      $expected = [long](Get-CcrAlpha6RequiredProperty $iteration $mapping[1])
      if ([long]$runsByMetric[$mapping[0]][$index] -ne $expected) {
        throw "ALPHA6_BENCHMARK_DATA_EVIDENCE_MISMATCH:$($mapping[0])/$($index + 1)"
      }
    }
    $published = [long]$runsByMetric.ccrPublicationCount[$index]
    if ([long]$runsByMetric.ccrPublicationIntervalSampleCount[$index] +
        [long]$runsByMetric.ccrPublicationIntervalSequenceStartCount[$index] -ne $published) {
      throw "ALPHA6_BENCHMARK_DATA_INTERVAL_COVERAGE_MISMATCH:$($index + 1)"
    }
    if ($RequireRequestStageMetrics) {
      $actor = [long]$runsByMetric.ccrActorStartedPublicationTraceCount[$index]
      $cached = [long]$runsByMetric.ccrCacheOnlyActorBypassTraceCount[$index]
      $decoded = [long]$runsByMetric.ccrDecoderOutputTraceCount[$index]
      $missingOutput = [long]$runsByMetric.ccrMissingDecoderOutputTraceCount[$index]
      $traceCount = [long]$runsByMetric.ccrSuccessfulPublicationTraceCount[$index]
      if ($traceCount -ne $published -or $actor + $cached -ne $traceCount -or
          $decoded -gt $actor -or $decoded + $missingOutput -ne $traceCount -or
          [long]$runsByMetric.ccrCacheOnlyActorStartUs[$index] -ne 0L) {
        throw "ALPHA6_BENCHMARK_REQUEST_STAGE_COUNT_MISMATCH:$($index + 1)"
      }
      if ($actor -eq 0L -and [int]$runsByMetric.ccrAcceptedToActorStartAvailable[$index] -ne 0) {
        throw "ALPHA6_BENCHMARK_ACTOR_START_AVAILABILITY_MISMATCH:$($index + 1)"
      }
      if ($actor -gt 0L -and [int]$runsByMetric.ccrAcceptedToActorStartAvailable[$index] -ne 1) {
        throw "ALPHA6_BENCHMARK_ACTOR_START_AVAILABILITY_MISMATCH:$($index + 1)"
      }
      if ($decoded -eq 0L -and (
          [int]$runsByMetric.ccrAcceptedToFirstOutputAvailable[$index] -ne 0 -or
          [int]$runsByMetric.ccrAcceptedToTargetOutputAvailable[$index] -ne 0)) {
        throw "ALPHA6_BENCHMARK_DECODER_OUTPUT_AVAILABILITY_MISMATCH:$($index + 1)"
      }
    }
  }
  return $benchmarks[0]
}
