param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)]
  [ValidateSet("Full", "ReleaseCancel", "Representative", "Forward", "Reverse", "Direction", "ReverseLifecycle", "Resource")]
  [string]$Stage,
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
$allowedStages = @("Full", "ReleaseCancel", "Representative", "Forward", "Reverse", "Direction", "ReverseLifecycle", "Resource")
if ($Stage -cnotin $allowedStages) { throw "ALPHA5_INSTRUMENTATION_STAGE_NOT_CANONICAL:$Stage" }

function Assert-CcrAlpha5RequiredZero {
  param([object]$Value, [string]$Field, [string]$Failure)
  if (-not (Test-CcrPinnedProperty $Value $Field) -or [long]$Value.$Field -ne 0) { throw "$Failure/$Field" }
}

function Assert-CcrAlpha5FullStaleDiscardContract {
  param([object]$Report, [string]$Failure)
  if ([long](Get-CcrPinnedRequiredProperty $Report "staleDiscardAssessmentVersion") -ne 1L) {
    throw "$Failure/assessment-version"
  }
  $gate = Get-CcrPinnedRequiredProperty $Report "gateCounters"
  $events = @((Get-CcrPinnedRequiredProperty $Report "staleDiscardEvents"))
  $rawCount = [long](Get-CcrPinnedRequiredProperty $gate "staleDiscard")
  $eventCount = [long](Get-CcrPinnedRequiredProperty $gate "staleDiscardEventCount")
  $expectedCount = [long](Get-CcrPinnedRequiredProperty $gate "expectedSupersededDiscardCount")
  $unexpectedCount = [long](Get-CcrPinnedRequiredProperty $gate "unexpectedStaleViolationCount")
  if ($rawCount -lt 0L -or $eventCount -ne $events.Count -or $expectedCount -lt 0L -or
      $unexpectedCount -lt 0L) { throw "$Failure/count-contract" }

  $expectedEvents = 0L
  $unexpectedEvents = 0L
  $expectedBurstEvents = 0L
  $expectedFileSwitchEvents = 0L
  $seenTokens = @{}
  foreach ($event in $events) {
    foreach ($field in @(
      "phase", "fixture", "fileGeneration", "requestGeneration", "requestedFrameIndex", "stage",
      "supersedingRequestGeneration", "supersedingFileGeneration", "classification"
    )) {
      if (-not (Test-CcrPinnedProperty $event $field)) { throw "$Failure/event-missing-$field" }
    }
    $phase = [string]$event.phase
    $fixture = [string]$event.fixture
    $classification = [string]$event.classification
    if ([long]$event.fileGeneration -lt 1L -or [long]$event.requestGeneration -lt 1L -or
        [long]$event.requestedFrameIndex -lt 0L -or [string]::IsNullOrWhiteSpace([string]$event.stage)) {
      throw "$Failure/event-identity"
    }
    $tokenKey = "$([long]$event.fileGeneration)/$([long]$event.requestGeneration)"
    if ($seenTokens.ContainsKey($tokenKey)) { throw "$Failure/duplicate-token" }
    $seenTokens[$tokenKey] = $true
    if ($classification -ceq "EXPECTED_SUPERSEDED") {
      $expectedEvents += 1L
      if (($phase -ceq "burst-supersede" -and $fixture -cne "burst.mp4") -or
          ($phase -ceq "file-switch-supersede" -and $fixture -cne "switch-a.mp4") -or
          $phase -cnotin @("burst-supersede", "file-switch-supersede")) {
        throw "$Failure/expected-event-scope"
      }
      if ([string]$event.stage -cnotin @(
        "before-decode", "after-test-hook", "decode-loop", "input-batch", "output-batch",
        "TEXTURE_GENERATION_STALE"
      )) {
        throw "$Failure/expected-event-stage"
      }
      if ($phase -ceq "burst-supersede") {
        $expectedBurstEvents += 1L
        if ([long]$event.requestedFrameIndex -notin @(1L, 6L, 12L, 24L)) {
          throw "$Failure/burst-target"
        }
        if ($null -eq $event.supersedingRequestGeneration -or
            [long]$event.supersedingRequestGeneration -le [long]$event.requestGeneration -or
            $null -eq $event.supersedingFileGeneration -or
            [long]$event.supersedingFileGeneration -ne [long]$event.fileGeneration) {
          throw "$Failure/burst-request-boundary"
        }
      } else {
        $expectedFileSwitchEvents += 1L
        if ([long]$event.requestedFrameIndex -ne 11L) { throw "$Failure/file-switch-target" }
        if ($null -eq $event.supersedingRequestGeneration -or
            [long]$event.supersedingRequestGeneration -le [long]$event.requestGeneration) {
          throw "$Failure/file-switch-request-boundary"
        }
        if ($null -eq $event.supersedingFileGeneration -or
            [long]$event.supersedingFileGeneration -ne ([long]$event.fileGeneration + 1L)) {
          throw "$Failure/file-switch-boundary"
        }
      }
    } elseif ($classification -ceq "UNEXPECTED") {
      $unexpectedEvents += 1L
    } else {
      throw "$Failure/event-classification"
    }
  }
  if ($expectedBurstEvents -gt 4L -or $expectedFileSwitchEvents -gt 1L) {
    throw "$Failure/expected-event-limit"
  }
  if ($expectedCount -ne $expectedEvents -or $unexpectedCount -ne $unexpectedEvents -or
      $eventCount -ne ($expectedEvents + $unexpectedEvents)) { throw "$Failure/event-count" }
  if ($rawCount -gt $eventCount) { throw "$Failure/raw-exceeds-events" }
  if ($unexpectedCount -ne 0L) { throw "$Failure/unexpected" }
}

function Assert-CcrAlpha5DirectionStaleDiscardContract {
  param([object]$Report, [string]$Failure)
  if ([long](Get-CcrPinnedRequiredProperty $Report "staleDiscardAssessmentVersion") -ne 1L) {
    throw "$Failure/assessment-version"
  }
  $gate = Get-CcrPinnedRequiredProperty $Report "gateCounters"
  $events = @((Get-CcrPinnedRequiredProperty $Report "staleDiscardEvents"))
  $rawCount = [long](Get-CcrPinnedRequiredProperty $gate "staleDiscard")
  $eventCount = [long](Get-CcrPinnedRequiredProperty $gate "staleDiscardEventCount")
  $expectedCount = [long](Get-CcrPinnedRequiredProperty $gate "expectedSupersededDiscardCount")
  $unexpectedCount = [long](Get-CcrPinnedRequiredProperty $gate "unexpectedStaleViolationCount")
  if ($rawCount -lt 1L -or $rawCount -gt 2L -or $eventCount -ne 2L -or
      $expectedCount -ne 2L -or $unexpectedCount -ne 0L -or $events.Count -ne 2) {
    throw "$Failure/generation-invalidation-count"
  }
  $phases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($event in $events) {
    foreach ($field in @(
      "phase", "fixture", "fileGeneration", "requestGeneration", "requestedFrameIndex", "stage",
      "supersedingRequestGeneration", "supersedingFileGeneration", "classification"
    )) {
      if (-not (Test-CcrPinnedProperty $event $field)) { throw "$Failure/event-missing-$field" }
    }
    $phase = [string]$event.phase
    if ($phase -cnotin @("surface-generation-supersede", "lifecycle-stop-supersede") -or
        -not $phases.Add($phase) -or [string]$event.fixture -cne "h264-bframes.mp4" -or
        [string]$event.classification -cne "EXPECTED_SUPERSEDED" -or
        [string]$event.stage -cne "reverse-window-build" -or
        $null -ne $event.supersedingRequestGeneration -or $null -ne $event.supersedingFileGeneration -or
        [long]$event.fileGeneration -lt 1L -or [long]$event.requestGeneration -lt 1L -or
        [long]$event.requestedFrameIndex -lt 0L -or
        -not $tokens.Add("$([long]$event.fileGeneration)/$([long]$event.requestGeneration)")) {
      throw "$Failure/generation-invalidation-event"
    }
  }
}

function Assert-CcrAlpha5ExactGateCounters {
  param(
    [object]$Report,
    [string]$Failure,
    [switch]$AllowExpectedSupersededStale,
    [switch]$AllowDirectionGenerationInvalidationStale
  )
  if ($AllowExpectedSupersededStale -and $AllowDirectionGenerationInvalidationStale) {
    throw "$Failure/stale-contract-ambiguous"
  }
  if ([long](Get-CcrPinnedRequiredProperty $Report "staleDiscardAssessmentVersion") -ne 1L) {
    throw "$Failure/assessment-version"
  }
  $gate = Get-CcrPinnedRequiredProperty $Report "gateCounters"
  foreach ($field in @(
    "staleBeforeSwap", "swapFailures", "surfaceInvalid",
    "publicationInvariantViolations", "cacheRejectionCount", "cacheThrashCount",
    "textureDoubleReleaseCount"
  )) { Assert-CcrAlpha5RequiredZero $gate $field $Failure }
  if ($AllowExpectedSupersededStale) {
    Assert-CcrAlpha5FullStaleDiscardContract $Report $Failure
  } elseif ($AllowDirectionGenerationInvalidationStale) {
    Assert-CcrAlpha5DirectionStaleDiscardContract $Report $Failure
  } else {
    Assert-CcrAlpha5RequiredZero $gate "staleDiscard" $Failure
    Assert-CcrAlpha5RequiredZero $gate "staleDiscardEventCount" $Failure
    Assert-CcrAlpha5RequiredZero $gate "expectedSupersededDiscardCount" $Failure
    Assert-CcrAlpha5RequiredZero $gate "unexpectedStaleViolationCount" $Failure
    if (@((Get-CcrPinnedRequiredProperty $Report "staleDiscardEvents")).Count -ne 0) {
      throw "$Failure/stale-events"
    }
  }
  $decoder = Get-CcrPinnedRequiredProperty $Report "decoder"
  if ([long](Get-CcrPinnedRequiredProperty $decoder "cacheBytes") -gt 67108864L -or
      [long](Get-CcrPinnedRequiredProperty $decoder "peakCacheBytes") -gt 67108864L) {
    throw "$Failure/cache-cap"
  }
}

function Assert-CcrAlpha5HardwareFixtures {
  param([object[]]$Fixtures, [int]$ExpectedCount, [string]$Failure)
  if ($Fixtures.Count -ne $ExpectedCount) { throw "$Failure/count" }
  foreach ($fixture in $Fixtures) {
    foreach ($field in @("sourceSha256", "codecComponent", "hardwareAccelerated", "frameCount")) {
      if (-not (Test-CcrPinnedProperty $fixture $field)) { throw "$Failure/missing-$field" }
    }
    if ([string]$fixture.sourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$fixture.codecComponent) -or
        $fixture.hardwareAccelerated -ne $true -or [int]$fixture.frameCount -le 0) { throw "$Failure/identity" }
  }
}

function Assert-CcrAlpha5StageReport {
  param([object]$Report, [string]$Stage)
  if ((Get-CcrPinnedRequiredProperty $Report "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Report "containsRealMediaMetadata") -ne $false) {
    throw "ALPHA5_REPORT_PRIVACY_MISMATCH:$Stage"
  }
  $device = Get-CcrPinnedRequiredProperty $Report "device"
  if ([string](Get-CcrPinnedRequiredProperty $device "model") -cne $context.Model -or
      [string](Get-CcrPinnedRequiredProperty $device "securityPatch") -cne $context.SecurityPatch -or
      [string](Get-CcrPinnedRequiredProperty $device "sdk") -cne [string]$context.Sdk) {
    throw "ALPHA5_REPORT_DEVICE_MISMATCH:$Stage"
  }
  switch ($Stage) {
    "Full" {
      Assert-CcrAlpha5RequiredZero $Report "mismatchCount" "ALPHA5_FULL_COUNTER"
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_FULL_COUNTER"
      $fixtures = @((Get-CcrPinnedRequiredProperty $Report "fixtures"))
      Assert-CcrAlpha5HardwareFixtures $fixtures 17 "ALPHA5_FULL_FIXTURES"
      if ([long](($fixtures | Measure-Object frameCount -Sum).Sum) -ne 236L) { throw "ALPHA5_FULL_FRAME_COUNT_MISMATCH" }
      Assert-CcrAlpha5ExactGateCounters $Report "ALPHA5_FULL_GATE" -AllowExpectedSupersededStale
    }
    "Representative" {
      Assert-CcrAlpha5RequiredZero $Report "mismatchCount" "ALPHA5_REPRESENTATIVE_COUNTER"
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_REPRESENTATIVE_COUNTER"
      $fixtures = @((Get-CcrPinnedRequiredProperty $Report "fixtures"))
      Assert-CcrAlpha5HardwareFixtures $fixtures 7 "ALPHA5_REPRESENTATIVE_FIXTURES"
      if (@((Get-CcrPinnedRequiredProperty $Report "selectionContract")).Count -ne 9) { throw "ALPHA5_REPRESENTATIVE_SELECTION_COUNT_MISMATCH" }
      foreach ($fixture in $fixtures) {
        $sequences = @((Get-CcrPinnedRequiredProperty $fixture "holdExactSequences"))
        if ([int](Get-CcrPinnedRequiredProperty $fixture "holdExactRequestCount") -ne 116 -or
            [string](Get-CcrPinnedRequiredProperty $fixture "holdExactSequenceDigest") -notmatch '^[0-9a-f]{64}$' -or
            $sequences.Count -ne 2 -or
            [long](Get-CcrPinnedRequiredProperty $fixture "cacheBudgetBytes") -ne 67108864L -or
            [long](Get-CcrPinnedRequiredProperty $fixture "cacheBytes") -lt 0L -or
            [long]$fixture.cacheBytes -gt 67108864L -or
            [long](Get-CcrPinnedRequiredProperty $fixture "peakCacheBytes") -lt [long]$fixture.cacheBytes -or
            [long]$fixture.peakCacheBytes -gt 67108864L -or
            [long](Get-CcrPinnedRequiredProperty $fixture "textureDoubleReleaseCount") -ne 0L -or
            [long](Get-CcrPinnedRequiredProperty $fixture "reverseWindowBuildCount") -le 0L) {
          throw "ALPHA5_REPRESENTATIVE_HOLD_CONTRACT_MISMATCH:$($fixture.fixture)"
        }
        foreach ($stride in @(1, 5)) {
          $sequence = @($sequences | Where-Object { [int]$_.stride -eq $stride })
          if ($sequence.Count -ne 1 -or [int](Get-CcrPinnedRequiredProperty $sequence[0] "reverseStride") -ne -$stride -or
              [int](Get-CcrPinnedRequiredProperty $sequence[0] "requestCount") -ne 58 -or
              @((Get-CcrPinnedRequiredProperty $sequence[0] "forwardTargets")).Count -ne 29 -or
              @((Get-CcrPinnedRequiredProperty $sequence[0] "reverseTargets")).Count -ne 29 -or
              [string](Get-CcrPinnedRequiredProperty $sequence[0] "sequenceDigest") -notmatch '^[0-9a-f]{64}$') {
            throw "ALPHA5_REPRESENTATIVE_HOLD_SEQUENCE_MISMATCH:$($fixture.fixture)/$stride"
          }
        }
      }
    }
    { $_ -ceq "Forward" -or $_ -ceq "Reverse" } {
      Assert-CcrAlpha5RequiredZero $Report "mismatchCount" "ALPHA5_SEQUENTIAL_COUNTER"
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_SEQUENTIAL_COUNTER"
      Assert-CcrAlpha5ExactGateCounters $Report "ALPHA5_SEQUENTIAL_GATE"
      $runs = @((Get-CcrPinnedRequiredProperty $Report "forwardSequentialRuns"))
      if ($runs.Count -ne 6 -or [long](($runs | Measure-Object requestCount -Sum).Sum) -ne 77L) { throw "ALPHA5_SEQUENTIAL_RUN_COUNT_MISMATCH:$Stage" }
      $strides = if ($Stage -ceq "Forward") { @(1, 5) } else { @(-1, -5) }
      foreach ($fixture in @("h264-bframes.mp4", "long-gop.mp4", "vfr.mp4")) {
        foreach ($stride in $strides) {
          $match = @($runs | Where-Object { [string]$_.fixture -ceq $fixture -and [int]$_.stride -eq $stride })
          if ($match.Count -ne 1 -or [long]$match[0].mismatchCount -ne 0 -or [long]$match[0].requestCount -le 0) {
            throw "ALPHA5_SEQUENTIAL_REQUIRED_RUN_MISSING:$Stage/$fixture/$stride"
          }
        }
      }
    }
    "Direction" {
      Assert-CcrAlpha5RequiredZero $Report "mismatchCount" "ALPHA5_DIRECTION_COUNTER"
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_DIRECTION_COUNTER"
      Assert-CcrAlpha5ExactGateCounters $Report "ALPHA5_DIRECTION_GATE" -AllowDirectionGenerationInvalidationStale
      $events = @((Get-CcrPinnedRequiredProperty (Get-CcrPinnedRequiredProperty $Report "decoder") "publicationEventHistory"))
      if ($events.Count -lt 1) { throw "ALPHA5_DIRECTION_PUBLICATION_EVIDENCE_EMPTY" }
    }
    "ReleaseCancel" {
      foreach ($field in @(
        "requestedFrameIndexChangeAfterRelease", "acceptedForegroundRequestCountAfterRelease",
        "requestedFrameIndexChangeAfterCancel", "acceptedForegroundRequestCountAfterCancel", "writeOpenCount"
      )) { Assert-CcrAlpha5RequiredZero $Report $field "ALPHA5_RELEASE_CANCEL_COUNTER" }
      if ((Get-CcrPinnedRequiredProperty $Report "hardwareDecoderRequired") -ne $true -or
          [string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $Report "codecComponent"))) {
        throw "ALPHA5_RELEASE_CANCEL_HARDWARE_DECODER_MISSING"
      }
    }
    "ReverseLifecycle" {
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_REVERSE_LIFECYCLE_COUNTER"
      if ((Get-CcrPinnedRequiredProperty $Report "hardwareDecoderRequired") -ne $true -or
          [string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $Report "codecComponent")) -or
          [long](Get-CcrPinnedRequiredProperty $Report "requestedInCreated") -ne [long](Get-CcrPinnedRequiredProperty $Report "requestedAfterCreatedGrace") -or
          [long](Get-CcrPinnedRequiredProperty $Report "decodedInCreated") -ne [long](Get-CcrPinnedRequiredProperty $Report "decodedAfterCreatedGrace") -or
          [long](Get-CcrPinnedRequiredProperty $Report "publicationsInCreated") -ne [long](Get-CcrPinnedRequiredProperty $Report "publicationsAfterCreatedGrace") -or
          [long](Get-CcrPinnedRequiredProperty $Report "publicationEventsInCreated") -ne [long](Get-CcrPinnedRequiredProperty $Report "publicationEventsAfterCreatedGrace") -or
          ((Get-CcrPinnedRequiredProperty $Report "expectedFrame") | ConvertTo-Json -Compress) -cne ((Get-CcrPinnedRequiredProperty $Report "restoredFrame") | ConvertTo-Json -Compress)) {
        throw "ALPHA5_REVERSE_LIFECYCLE_CONTRACT_MISMATCH"
      }
      $diagnostics = Get-CcrPinnedRequiredProperty $Report "diagnostics"
      foreach ($field in @("staleDiscardCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount", "publicationInvariantViolationCount", "textureDoubleReleaseCount")) {
        Assert-CcrAlpha5RequiredZero $diagnostics $field "ALPHA5_REVERSE_LIFECYCLE_DIAGNOSTICS"
      }
      if ([long](Get-CcrPinnedRequiredProperty $diagnostics "peakCacheBytes") -gt [long](Get-CcrPinnedRequiredProperty $diagnostics "cacheBudgetBytes") -or
          [long]$diagnostics.cacheBudgetBytes -ne 67108864L) { throw "ALPHA5_REVERSE_LIFECYCLE_CACHE_CAP_MISMATCH" }
    }
    "Resource" {
      foreach ($field in @("mediaFileNameIncluded", "mediaUriIncluded", "mediaPathIncluded")) {
        if ((Get-CcrPinnedRequiredProperty $Report $field) -ne $false) { throw "ALPHA5_RESOURCE_PRIVACY_MISMATCH:$field" }
      }
      if ([double](Get-CcrPinnedRequiredProperty $Report "requestedDurationMinutes") -ne 10.0 -or
          [long](Get-CcrPinnedRequiredProperty $Report "actualMeasurementDurationMs") -lt 600000L -or
          [long](Get-CcrPinnedRequiredProperty $Report "operations") -le 0 -or
          [long](Get-CcrPinnedRequiredProperty $Report "codecSwitches") -le 0 -or
          [long](Get-CcrPinnedRequiredProperty $Report "requiredCacheBudgetBytes") -ne 67108864L) {
        throw "ALPHA5_RESOURCE_DURATION_OR_OPERATION_MISMATCH"
      }
      Assert-CcrAlpha5RequiredZero $Report "writeOpenCount" "ALPHA5_RESOURCE_COUNTER"
      $strides = Get-CcrPinnedRequiredProperty $Report "strideOperationCounts"
      foreach ($field in @("+1", "+5", "-1", "-5")) {
        if (-not (Test-CcrPinnedProperty $strides $field) -or [long]$strides.$field -le 0) { throw "ALPHA5_RESOURCE_STRIDE_MISSING:$field" }
      }
      $codecs = Get-CcrPinnedRequiredProperty $Report "codecOperationCounts"
      foreach ($field in @("H264", "HEVC")) {
        if (-not (Test-CcrPinnedProperty $codecs $field) -or [long]$codecs.$field -le 0) { throw "ALPHA5_RESOURCE_CODEC_MISSING:$field" }
      }
      $assessment = Get-CcrPinnedRequiredProperty $Report "resourceAssessment"
      if ([string](Get-CcrPinnedRequiredProperty $assessment "status") -cne "PASS" -or
          [long](Get-CcrPinnedRequiredProperty $assessment "cacheBudgetBytes") -ne 67108864L -or
          [long](Get-CcrPinnedRequiredProperty $assessment "maxObservedCacheBytes") -gt 67108864L -or
          [long](Get-CcrPinnedRequiredProperty $assessment "maxObservedPeakCacheBytes") -gt 67108864L) {
        throw "ALPHA5_RESOURCE_ASSESSMENT_MISMATCH"
      }
      foreach ($field in @(
        "staleDiscardCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount",
        "publicationInvariantViolationCount", "textureDoubleReleaseCount", "holdPrefetchStarted",
        "holdPrefetchCompleted", "holdPrefetchViolationCount", "cacheBudgetViolationCount",
        "cachePeakViolationCount", "totalViolationCount"
      )) { Assert-CcrAlpha5RequiredZero $assessment $field "ALPHA5_RESOURCE_ASSESSMENT" }
      $final = Get-CcrPinnedRequiredProperty $Report "finalDiagnostics"
      if ([long](Get-CcrPinnedRequiredProperty $final "cacheBudgetBytes") -ne 67108864L -or
          [long](Get-CcrPinnedRequiredProperty $final "cacheBytes") -gt 67108864L -or
          [long](Get-CcrPinnedRequiredProperty $final "peakCacheBytes") -gt 67108864L) { throw "ALPHA5_RESOURCE_FINAL_CACHE_MISMATCH" }
      foreach ($field in @("cacheRejectionCount", "cacheThrashCount", "staleDiscardCount", "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount", "publicationInvariantViolationCount", "textureDoubleReleaseCount")) {
        Assert-CcrAlpha5RequiredZero $final $field "ALPHA5_RESOURCE_FINAL_DIAGNOSTICS"
      }
    }
    default { throw "ALPHA5_STAGE_REPORT_VALIDATOR_MISSING:$Stage" }
  }
}

$specs = @{
  Full = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#allGoldenVectorsRemainExactOnS24Ultra"
    reportName = "s24-frame-accuracy-report.json"
    kind = "frame-accuracy-exact"
  }
  ReleaseCancel = [ordered]@{
    className = "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest#releaseThenCancelAcceptsNoNewForegroundRequestDuringGracePeriods"
    reportName = "s24-release-cancel-grace-report.json"
    kind = "release-cancel-grace"
  }
  Representative = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24RepresentativeResolutionAccuracyTest#representativeResolutionExactSubsetRemainsExact"
    reportName = "representative-resolution-exact-report.json"
    kind = "representative-resolution-exact-subset"
  }
  Forward = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#forwardSequentialStrideOneAndFiveRemainExactOnS24Ultra"
    reportName = "s24-forward-sequential-report.json"
    kind = "forward-sequential-exact"
  }
  Reverse = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#reverseWindowStrideMinusOneAndFiveRemainExactOnS24Ultra"
    reportName = "s24-reverse-window-report.json"
    kind = "reverse-window-exact"
  }
  Direction = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#directionReversalAndGenerationInvalidationRemainExactOnS24Ultra"
    reportName = "s24-alpha5-direction-reversal-report.json"
    kind = "bidirectional-transition-exact"
  }
  ReverseLifecycle = [ordered]@{
    className = "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest#reverseHoldLifecycleInvalidationRestoresExactFrameOnS24Ultra"
    reportName = "s24-alpha5-reverse-lifecycle-report.json"
    kind = "alpha5-reverse-lifecycle-exact"
  }
  Resource = [ordered]@{
    className = "com.snowberried.ctcinereviewer.gate.S24BidirectionalResourceTest#tenMinuteBidirectionalCacheResource"
    reportName = "s24-alpha5-resource-10m-report.json"
    kind = "alpha5-bidirectional-resource-10m"
  }
}
$spec = $specs[$Stage]
if ($null -eq $spec -or @($specs.Keys).Count -ne $allowedStages.Count) {
  throw "ALPHA5_INSTRUMENTATION_STAGE_SPEC_MISSING:$Stage"
}
$context = Invoke-CcrAlpha5PinnedPreflight `
  -ArtifactManifest $ArtifactManifest `
  -ArtifactManifestSha256 $ArtifactManifestSha256 `
  -OutputDirectory $OutputDirectory
Assert-CcrAlpha5Deadline $deadlineUtc "instrumentation-preflight-$Stage"

$summaryPath = Join-Path $context.OutputDirectory "alpha5-$($Stage.ToLowerInvariant())-summary-v1.json"
if ($Resume -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
  $existing = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $storedMaxMinutes = [int]$existing.maxMinutes
  Assert-CcrAlpha5PreflightDomain $existing ([bool]$PreflightOnly) "ALPHA5_INSTRUMENTATION_RESUME_PREFLIGHT_DOMAIN_MISMATCH:$Stage"
  if ($PreflightOnly) {
    if ([string]$existing.kind -cne "alpha5-instrumentation-preflight" -or
        [string]$existing.status -cne "PASS" -or [string]$existing.stage -cne $Stage -or
        [int]$existing.deviceMutationCount -ne 0 -or
        $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240) {
      throw "ALPHA5_INSTRUMENTATION_PREFLIGHT_RESUME_IDENTITY_MISMATCH:$Stage"
    }
    Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_INSTRUMENTATION_PREFLIGHT_RESUME_IDENTITY_MISMATCH:$Stage" | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
  if ([string]$existing.status -cne "PASS" -or
      [string]$existing.stage -cne $Stage -or
      $storedMaxMinutes -lt 1 -or $storedMaxMinutes -gt 240) {
    throw "ALPHA5_INSTRUMENTATION_RESUME_IDENTITY_MISMATCH:$Stage"
  }
  Assert-CcrAlpha5IdentityRecord $existing.identity $context "ALPHA5_INSTRUMENTATION_RESUME_IDENTITY_MISMATCH:$Stage" | Out-Null
  $reportPath = Assert-CcrAlpha5EvidenceFileRecord `
    $existing.report $context.OutputDirectory "ALPHA5_INSTRUMENTATION_RESUME_REPORT_MISMATCH:$Stage"
  $resumeReport = [System.IO.File]::ReadAllText($reportPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-CcrPinnedReport `
    -Report $resumeReport -ArtifactSet $context.ArtifactSet -RunId ([string]$existing.runId) `
    -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind $spec.kind `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
  if ([string](Get-CcrPinnedRequiredProperty $resumeReport "appVersionName") -cne $script:CcrPinnedVersionName -or
      [int](Get-CcrPinnedRequiredProperty $resumeReport "appVersionCode") -ne $script:CcrPinnedVersionCode -or
      [string](Get-CcrPinnedRequiredProperty $resumeReport "appCommitSha") -cne $context.ArtifactSet.RuntimeSourceSha) {
    throw "ALPHA5_INSTRUMENTATION_RESUME_REPORT_IDENTITY_MISMATCH:$Stage"
  }
  Assert-CcrAlpha5StageReport $resumeReport $Stage
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}
if (Test-Path -LiteralPath $summaryPath) { throw "ALPHA5_INSTRUMENTATION_SUMMARY_ALREADY_EXISTS:$Stage" }

if ($PreflightOnly) {
  $preflight = [ordered]@{
    schemaVersion = 1; kind = "alpha5-instrumentation-preflight"; status = "PASS"; stage = $Stage
    preflightOnly = $true; deviceMutationCount = 0; maxMinutes = $MaxMinutes
    identity = New-CcrAlpha5IdentityRecord $context
    testClass = $spec.className; reportName = $spec.reportName; expectedKind = $spec.kind
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-Output (Write-CcrAlpha5ImmutableJson $summaryPath $preflight)
  return
}

$primaryFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$mutationStarted = $false
$result = $null
try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $runId = New-CcrPinnedRunId $context.OutputDirectory "a5-$($Stage.ToLowerInvariant())"
  $failureReportPath = Join-Path $context.OutputDirectory "failure-$runId-instrumentation-v1.json"
  $mutationStarted = $true
  Install-CcrPinnedArtifactSet $context "Debug"
  Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $spec.reportName
  $arguments = @{}
  if ($Stage -ceq "Resource") { $arguments["alpha5.resourceMinutes"] = "10" }
  $invocation = Invoke-CcrPinnedInstrumentation `
    -Context $context -TestRole "debugTest" -ClassName $spec.className `
    -RunId $runId -ExpectedTestCount 1 -AdditionalArguments $arguments `
    -FailureReportPath $failureReportPath
  Assert-CcrAlpha5Deadline $deadlineUtc "instrumentation-after-run-$Stage"
  $received = Receive-CcrPinnedReport `
    -Context $context -ReportName $spec.reportName -RunId $runId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $invocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind $spec.kind -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  $report = $received.Report
  if ([string]$report.appVersionName -cne $script:CcrPinnedVersionName -or
      [int]$report.appVersionCode -ne $script:CcrPinnedVersionCode -or
      [string]$report.appCommitSha -cne $context.ArtifactSet.RuntimeSourceSha) {
    throw "ALPHA5_INSTRUMENTATION_APP_IDENTITY_MISMATCH:$Stage"
  }
  Assert-CcrAlpha5StageReport $report $Stage
  foreach ($field in @("mismatchCount", "writeOpenCount")) {
    if ((Test-CcrPinnedProperty $report $field) -and [long]$report.$field -ne 0) {
      throw "ALPHA5_INSTRUMENTATION_COUNTER_NONZERO:$Stage/$field"
    }
  }
  if (Test-CcrPinnedProperty $report "gateCounters") {
    foreach ($field in @(
      "staleDiscard", "staleBeforeSwap", "swapFailures", "surfaceInvalid",
      "publicationInvariantViolations", "cacheRejectionCount", "cacheThrashCount",
      "textureDoubleReleaseCount"
    )) {
      if ($Stage -cin @("Full", "Direction") -and $field -ceq "staleDiscard") { continue }
      if ((Test-CcrPinnedProperty $report.gateCounters $field) -and [long]$report.gateCounters.$field -ne 0) {
        throw "ALPHA5_INSTRUMENTATION_GATE_COUNTER_NONZERO:$Stage/$field"
      }
    }
  }
  foreach ($candidate in @("cacheBytes", "peakCacheBytes", "cachePeakBytes")) {
    if ((Test-CcrPinnedProperty $report $candidate) -and [long]$report.$candidate -gt 67108864L) {
      throw "ALPHA5_INSTRUMENTATION_CACHE_CAP_EXCEEDED:$Stage/$candidate"
    }
  }
  if ($Stage -ceq "ReleaseCancel") {
    foreach ($field in @(
      "requestedFrameIndexChangeAfterRelease", "acceptedForegroundRequestCountAfterRelease",
      "requestedFrameIndexChangeAfterCancel", "acceptedForegroundRequestCountAfterCancel",
      "writeOpenCount"
    )) {
      if (-not (Test-CcrPinnedProperty $report $field) -or [long]$report.$field -ne 0) {
        throw "ALPHA5_RELEASE_CANCEL_COUNTER_NONZERO_OR_MISSING:$field"
      }
    }
    if ($report.hardwareDecoderRequired -ne $true -or [string]::IsNullOrWhiteSpace([string]$report.codecComponent)) {
      throw "ALPHA5_RELEASE_CANCEL_HARDWARE_DECODER_MISSING"
    }
  }
  [System.IO.File]::SetAttributes($received.Path, [System.IO.FileAttributes]::ReadOnly)
  $summary = [ordered]@{
    schemaVersion = 1; kind = "alpha5-instrumentation-stage"; status = "PASS"; stage = $Stage
    preflightOnly = $false
    completedAtUtc = [DateTime]::UtcNow.ToString("o"); maxMinutes = $MaxMinutes
    identity = New-CcrAlpha5IdentityRecord $context
    testClass = $spec.className; expectedKind = $spec.kind; runId = $runId
    report = [ordered]@{
      path = $received.Path
      bytes = [long](Get-Item -LiteralPath $received.Path).Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $received.Path).Hash.ToLowerInvariant()
    }
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  $result = Write-CcrAlpha5ImmutableJson $summaryPath $summary
} catch { $primaryFailure = $_ } finally {
  if ($mutationStarted) {
    Enter-CcrAlpha5CleanupWindow
    try {
      foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
    } catch { $cleanupFailures.Add("CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null }
    try { Assert-CcrAlpha5SettingsRestored $context | Out-Null } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
}
if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }
Write-Output $result
