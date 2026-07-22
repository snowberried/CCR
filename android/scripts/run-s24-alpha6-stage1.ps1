param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
  [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
  [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$RunId,
  [ValidateRange(1, 240)][int]$MaxMinutes = 120,
  [AllowEmptyString()][string]$OriginalStayAwakeSetting = "",
  [AllowEmptyString()][string]$OriginalScreenTimeoutSetting = "",
  [switch]$Resume,
  [switch]$PreflightOnly,
  [Parameter(DontShow = $true)][object]$TestOnlyAndroidTools = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyIdentityReader = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySourceIdentityVerifier = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyAdbInvoker = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyStageExecutor = $null
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$alpha6PinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinnedPath = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
$tailContractPath = Join-Path $PSScriptRoot "alpha6-tail-contract.ps1"
. $alpha6PinnedPath
. $tailContractPath

$testHookUsed = $null -ne $TestOnlyAndroidTools -or $null -ne $TestOnlyIdentityReader -or
  $null -ne $TestOnlySourceIdentityVerifier -or $null -ne $TestOnlyAdbInvoker -or
  $null -ne $TestOnlyStageExecutor
if ($testHookUsed -and $env:CCR_ALPHA6_STAGE1_TEST_MODE -cne "1") {
  throw "ALPHA6_STAGE1_TEST_HOOK_FORBIDDEN"
}

Assert-CcrPinnedRunId $RunId | Out-Null
if ($RunId.Length -gt 80) { throw "ALPHA6_STAGE1_RUN_ID_TOO_LONG" }
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
$adbDeadlineState = [PSCustomObject]@{
  ValidationDeadlineUtc = $deadlineUtc
  CleanupMode = $false
  CleanupDeadlineUtc = $deadlineUtc
}
$closedValidationScripts = @(
  $runnerPath,
  [System.IO.Path]::GetFullPath($alpha6PinnedPath),
  [System.IO.Path]::GetFullPath($basePinnedPath),
  [System.IO.Path]::GetFullPath($tailContractPath)
)
if (@($closedValidationScripts | Select-Object -Unique).Count -ne 4) {
  throw "ALPHA6_STAGE1_CLOSED_SCRIPT_SET_INVALID"
}

function Assert-CcrAlpha6Stage1Deadline {
  param([Parameter(Mandatory = $true)][string]$Phase)
  if ([DateTime]::UtcNow -ge $deadlineUtc) { throw "ALPHA6_STAGE1_MAX_MINUTES_EXCEEDED:$Phase" }
}

function Write-CcrAlpha6Stage1ImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $full) { throw "ALPHA6_STAGE1_EVIDENCE_ALREADY_EXISTS:$full" }
  $parent = Split-Path -Parent $full
  [System.IO.Directory]::CreateDirectory($parent) | Out-Null
  $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 40) + "`n"))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally { $stream.Dispose() }
  (Get-Item -LiteralPath $full).IsReadOnly = $true
  return $full
}

function Get-CcrAlpha6Stage1FileRecord {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -Force -LiteralPath $Path
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
    throw "ALPHA6_STAGE1_EVIDENCE_FILE_INVALID:$Path"
  }
  return [PSCustomObject][ordered]@{
    path = $item.FullName
    bytes = [long]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
  }
}

function Assert-CcrAlpha6Stage1FileRecord {
  param([Parameter(Mandatory = $true)][object]$Record, [Parameter(Mandatory = $true)][string]$Root)
  $path = [System.IO.Path]::GetFullPath([string](Get-CcrPinnedRequiredProperty $Record "path"))
  if (-not (Test-CcrPinnedPathWithin $path $Root) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ALPHA6_STAGE1_RESUME_EVIDENCE_PATH_MISMATCH"
  }
  $item = Get-Item -Force -LiteralPath $path
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      [long]$item.Length -ne [long](Get-CcrPinnedRequiredProperty $Record "bytes") -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne
        [string](Get-CcrPinnedRequiredProperty $Record "sha256")) {
    throw "ALPHA6_STAGE1_RESUME_EVIDENCE_HASH_MISMATCH"
  }
  return $path
}

function Get-CcrAlpha6Stage1ArtifactRecords {
  param([Parameter(Mandatory = $true)][object]$Context)
  return @($script:CcrPinnedRoles | ForEach-Object {
    $artifact = Get-CcrPinnedArtifact $Context $_
    [PSCustomObject][ordered]@{
      role = $_
      path = [string]$artifact.path
      bytes = [long]$artifact.bytes
      sha256 = [string]$artifact.sha256
    }
  })
}

function New-CcrAlpha6Stage1Identity {
  param([Parameter(Mandatory = $true)][object]$Context)
  $device = $null
  if (Test-CcrPinnedProperty $Context "Serial") {
    $device = [PSCustomObject][ordered]@{
      serial = [string]$Context.Serial
      model = [string]$Context.Model
      fingerprint = [string]$Context.Fingerprint
      securityPatch = [string]$Context.SecurityPatch
      sdk = [string]$Context.Sdk
    }
  }
  return [PSCustomObject][ordered]@{
    runId = $RunId
    preflightOnly = [bool]$PreflightOnly
    artifactManifest = [string]$Context.ArtifactSet.ManifestPath
    artifactManifestSha256 = [string]$Context.ArtifactSet.ManifestSha256
    artifactSetRevision = 4
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    versionName = $script:CcrPinnedVersionName
    versionCode = $script:CcrPinnedVersionCode
    applicationId = $script:CcrPinnedAppPackage
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    artifacts = @(Get-CcrAlpha6Stage1ArtifactRecords $Context)
    closedValidationScripts = @($Context.ValidationScripts)
    device = $device
    buildCommandCount = 0L
  }
}

function Assert-CcrAlpha6Stage1Identity {
  param([Parameter(Mandatory = $true)][object]$Actual, [Parameter(Mandatory = $true)][object]$Context)
  $expected = New-CcrAlpha6Stage1Identity $Context
  if (($Actual | ConvertTo-Json -Depth 30 -Compress) -cne ($expected | ConvertTo-Json -Depth 30 -Compress)) {
    throw "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6Stage1SettingsRestored {
  param([Parameter(Mandatory = $true)][object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings")) { throw "ALPHA6_STAGE1_SAVED_SETTINGS_MISSING" }
  foreach ($entry in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    if ((Get-CcrPinnedDeviceSetting $Context $entry[0] $entry[1]) -cne [string]$entry[2]) {
      throw "ALPHA6_STAGE1_SETTING_RESTORE_MISMATCH:$($entry[0])/$($entry[1])"
    }
  }
  return $true
}

function Assert-CcrAlpha6Stage1HardReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ((Get-CcrPinnedRequiredProperty $Report "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Report "containsRealMediaMetadata") -ne $false) {
    throw "ALPHA6_STAGE1_CORRECTNESS_PRIVACY_MISMATCH:$Stage"
  }
  foreach ($field in @("mismatchCount", "writeOpenCount")) {
    if ((Test-CcrPinnedProperty $Report $field) -and [long]$Report.$field -ne 0L) {
      throw "ALPHA6_STAGE1_CORRECTNESS_COUNTER_NONZERO:$Stage/$field"
    }
  }
  if (Test-CcrPinnedProperty $Report "device") {
    $device = $Report.device
    if ([string](Get-CcrPinnedRequiredProperty $device "model") -cne [string]$Context.Model -or
        [string](Get-CcrPinnedRequiredProperty $device "securityPatch") -cne [string]$Context.SecurityPatch -or
        [string](Get-CcrPinnedRequiredProperty $device "sdk") -cne [string]$Context.Sdk) {
      throw "ALPHA6_STAGE1_CORRECTNESS_DEVICE_MISMATCH:$Stage"
    }
  }
  if (Test-CcrPinnedProperty $Report "gateCounters") {
    $gate = $Report.gateCounters
    foreach ($field in @(
      "staleBeforeSwap", "swapFailures", "surfaceInvalid", "publicationInvariantViolations",
      "cacheRejectionCount", "cacheThrashCount", "textureDoubleReleaseCount",
      "unexpectedStaleViolationCount"
    )) {
      if (-not (Test-CcrPinnedProperty $gate $field) -or [long]$gate.$field -ne 0L) {
        throw "ALPHA6_STAGE1_CORRECTNESS_GATE_NONZERO:$Stage/$field"
      }
    }
  }
  foreach ($containerName in @("decoder", "diagnostics", "finalDiagnostics")) {
    if (-not (Test-CcrPinnedProperty $Report $containerName)) { continue }
    $container = $Report.$containerName
    foreach ($field in @(
      "staleBeforeSwapCount", "swapFailureCount", "surfaceInvalidCount",
      "publicationInvariantViolationCount", "textureDoubleReleaseCount"
    )) {
      if ((Test-CcrPinnedProperty $container $field) -and [long]$container.$field -ne 0L) {
        throw "ALPHA6_STAGE1_CORRECTNESS_DIAGNOSTIC_NONZERO:$Stage/$field"
      }
    }
    if ((Test-CcrPinnedProperty $container "cacheBudgetBytes") -and
        [long]$container.cacheBudgetBytes -ne 67108864L) {
      throw "ALPHA6_STAGE1_CORRECTNESS_CACHE_BUDGET_MISMATCH:$Stage"
    }
    foreach ($field in @("cacheBytes", "peakCacheBytes")) {
      if ((Test-CcrPinnedProperty $container $field) -and [long]$container.$field -gt 67108864L) {
        throw "ALPHA6_STAGE1_CORRECTNESS_CACHE_CAP_EXCEEDED:$Stage/$field"
      }
    }
  }
  switch ($Stage) {
    "Full" {
      $fixtures = @((Get-CcrPinnedRequiredProperty $Report "fixtures"))
      if ($fixtures.Count -ne 17 -or [long](($fixtures | Measure-Object frameCount -Sum).Sum) -ne 236L) {
        throw "ALPHA6_STAGE1_FULL_FIXTURE_CONTRACT_MISMATCH"
      }
    }
    "Representative" {
      if (@((Get-CcrPinnedRequiredProperty $Report "fixtures")).Count -ne 7) {
        throw "ALPHA6_STAGE1_REPRESENTATIVE_FIXTURE_COUNT_MISMATCH"
      }
    }
    { $_ -ceq "Forward" -or $_ -ceq "Reverse" } {
      $runs = @((Get-CcrPinnedRequiredProperty $Report "forwardSequentialRuns"))
      $strides = if ($Stage -ceq "Forward") { @(1, 5) } else { @(-1, -5) }
      foreach ($fixture in @("h264-bframes.mp4", "long-gop.mp4", "hevc-main8.mp4", "vfr.mp4")) {
        foreach ($stride in $strides) {
          $match = @($runs | Where-Object { [string]$_.fixture -ceq $fixture -and [int]$_.stride -eq $stride })
          if ($match.Count -ne 1 -or [long]$match[0].mismatchCount -ne 0L -or [long]$match[0].requestCount -le 0L) {
            throw "ALPHA6_STAGE1_SEQUENTIAL_RUN_MISSING:$Stage/$fixture/$stride"
          }
        }
      }
    }
    "ReleaseCancel" {
      foreach ($field in @(
        "requestedFrameIndexChangeAfterRelease", "acceptedForegroundRequestCountAfterRelease",
        "requestedFrameIndexChangeAfterCancel", "acceptedForegroundRequestCountAfterCancel", "writeOpenCount"
      )) {
        if ([long](Get-CcrPinnedRequiredProperty $Report $field) -ne 0L) {
          throw "ALPHA6_STAGE1_RELEASE_CANCEL_NONZERO:$field"
        }
      }
    }
    "Direction" {
      if (@((Get-CcrPinnedRequiredProperty (Get-CcrPinnedRequiredProperty $Report "decoder") "publicationEventHistory")).Count -lt 1) {
        throw "ALPHA6_STAGE1_DIRECTION_PUBLICATION_EVIDENCE_EMPTY"
      }
    }
    "ReverseLifecycle" {
      if (((Get-CcrPinnedRequiredProperty $Report "expectedFrame") | ConvertTo-Json -Compress) -cne
          ((Get-CcrPinnedRequiredProperty $Report "restoredFrame") | ConvertTo-Json -Compress)) {
        throw "ALPHA6_STAGE1_REVERSE_LIFECYCLE_FRAME_MISMATCH"
      }
    }
  }
  return $true
}

function Get-CcrAlpha6Stage1BenchmarkEvidence {
  param([Parameter(Mandatory = $true)][string]$Output)
  $matches = [regex]::Matches($Output, '(?m)^INSTRUMENTATION_STATUS: ccrBenchmarkHarnessV2=(?<json>\{[^\r\n]*\})\r?$')
  if ($matches.Count -ne 1) { throw "ALPHA6_STAGE1_BENCHMARK_STATUS_COUNT_MISMATCH" }
  try { return $matches[0].Groups["json"].Value | ConvertFrom-Json } catch {
    throw "ALPHA6_STAGE1_BENCHMARK_STATUS_JSON_INVALID"
  }
}

function Assert-CcrAlpha6Stage1BenchmarkEvidence {
  param([object]$Evidence, [object]$Scenario, [object]$Context, [string]$ScenarioRunId)
  Assert-CcrPinnedBenchmarkEvidence $Evidence $Context.ArtifactSet $ScenarioRunId $Scenario.evidence 3 | Out-Null
  if ([string](Get-CcrPinnedRequiredProperty $Evidence "scenario") -cne [string]$Scenario.evidence -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "fixture") -cne [string]$Scenario.fixture) {
    throw "ALPHA6_STAGE1_BENCHMARK_FIXTURE_IDENTITY_MISMATCH:$($Scenario.method)"
  }
  $iterations = @((Get-CcrPinnedRequiredProperty $Evidence "iterations"))
  if ($iterations.Count -ne 3) { throw "ALPHA6_STAGE1_BENCHMARK_ITERATION_COUNT_MISMATCH:$($Scenario.method)" }
  for ($index = 0; $index -lt 3; $index += 1) {
    $iteration = $iterations[$index]
    if ([int](Get-CcrPinnedRequiredProperty $iteration "runIteration") -ne ($index + 1) -or
        [string](Get-CcrPinnedRequiredProperty $iteration "fixture") -cne [string]$Scenario.fixture -or
        [string](Get-CcrPinnedRequiredProperty $iteration "traceIdentity") -cne
          "$ScenarioRunId.$($Scenario.evidence).$($index + 1)" -or
        (Get-CcrPinnedRequiredProperty $iteration "counterComplete") -ne $true -or
        [long](Get-CcrPinnedRequiredProperty $iteration "measurementTargetMs") -ne 30000L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "activeMs") -lt 30000L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "activeMs") -gt 32000L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "cacheBudgetBytes") -ne 67108864L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "cacheBytes") -gt 67108864L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "peakCacheBytes") -gt 67108864L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "outstandingForegroundTargetDepthMax") -gt 1L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "reverseRefillMaxSeekPerGeneration") -gt 1L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "reverseRefillMaxFlushPerGeneration") -gt 1L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "reverseRefillRestartCount") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "cachedNavigationStaleCount") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $iteration "cachedNavigationErrorCount") -ne 0L) {
      throw "ALPHA6_STAGE1_BENCHMARK_HARD_INVARIANT_MISMATCH:$($Scenario.method)/$($index + 1)"
    }
  }
  return $iterations
}

function Assert-CcrAlpha6Stage1TailGate {
  param([Parameter(Mandatory = $true)][object[]]$ScenarioResults)
  $fixtureContracts = @(
    [PSCustomObject]@{ fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4" },
    [PSCustomObject]@{ fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4" },
    [PSCustomObject]@{ fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4" },
    [PSCustomObject]@{ fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4" }
  )
  foreach ($fixtureContract in $fixtureContracts) {
    foreach ($stride in @(-1, -5)) {
      $forwardStride = [Math]::Abs($stride)
      $forward = @($ScenarioResults | Where-Object {
        [string]$_.fixtureIdentity -ceq "h264-bframes" -and [int]$_.stride -eq $forwardStride
      })
      $reverse = @($ScenarioResults | Where-Object {
        [string]$_.fixtureIdentity -ceq [string]$fixtureContract.fixtureIdentity -and [int]$_.stride -eq $stride
      })
      if ($forward.Count -ne 1 -or $reverse.Count -ne 1 -or
          [string]$reverse[0].fixture -cne [string]$fixtureContract.fixture) {
        throw "ALPHA6_STAGE1_TAIL_SCENARIO_MISSING:$($fixtureContract.fixtureIdentity)/$stride"
      }
      for ($index = 0; $index -lt 3; $index += 1) {
        $f = $forward[0].iterations[$index]
        $r = $reverse[0].iterations[$index]
      $cadenceNs = if ($stride -eq -1) { [long](1000000000L / 15L) } else { [long](1000000000L / 12L) }
      $metrics = [PSCustomObject][ordered]@{
        sampleCount = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalSampleCount")
        targetCadenceNs = [long](Get-CcrPinnedRequiredProperty $r "targetCadenceNs")
        coefficientOfVariationPpm = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalCvPpm")
        p99Ns = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalP99Us") * 1000L
        p995Ns = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalP995Us") * 1000L
        maxNs = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalMaxUs") * 1000L
        longestConsecutivePublicationGapNs =
          [long](Get-CcrPinnedRequiredProperty $r "publicationGapMaxUs") * 1000L
        overOnePointFiveCadenceCount = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalOver1_5xCadenceCount")
        overTwoCadenceCount = [long](Get-CcrPinnedRequiredProperty $r "publicationIntervalOver2xCadenceCount")
        longestConsecutiveOverOnePointFiveCadenceCount = [long](Get-CcrPinnedRequiredProperty $r "longestConsecutiveOver1_5xCadenceRunCount")
      }
      if ($metrics.targetCadenceNs -ne $cadenceNs) { throw "ALPHA6_STAGE1_CADENCE_MISMATCH:$stride/$($index + 1)" }
      $refillAssociatedLongGapCount =
        [long](Get-CcrPinnedRequiredProperty $r "measuredRefillAssociatedLongGapCount")
      $windowBuildAssociatedLongGapCount =
        [long](Get-CcrPinnedRequiredProperty $r "measuredWindowBuildAssociatedLongGapCount")
      $correlation = [PSCustomObject][ordered]@{
        stride = $stride
        thresholdNs = if ($stride -eq -1) { 100000000L } else { 125000000L }
        eventCount = $metrics.sampleCount
        refillAssociatedLongGapCount = $refillAssociatedLongGapCount
        windowBuildAssociatedLongGapCount = $windowBuildAssociatedLongGapCount
        associatedLongGapCount = $refillAssociatedLongGapCount + $windowBuildAssociatedLongGapCount
      }
      Assert-CcrAlpha6ReverseTailGate `
        -Stride $stride -Metrics $metrics `
        -ForwardCoefficientOfVariationPpm ([long](Get-CcrPinnedRequiredProperty $f "publicationIntervalCvPpm")) `
        -RefillCorrelation $correlation | Out-Null
      $forwardFpsCap = if ($stride -eq -1) { 15.0 } else { 12.0 }
      $absoluteMinimumFps = if ($stride -eq -1) { 12.0 } else { 10.0 }
      $forwardFps = [double](Get-CcrPinnedRequiredProperty $f "publishedFps")
      $reverseFps = [double](Get-CcrPinnedRequiredProperty $r "publishedFps")
      $cappedForwardFps = [Math]::Min($forwardFps, $forwardFpsCap)
      if ([long](Get-CcrPinnedRequiredProperty $r "cachedNavigationActorBypassCount") -le 0L -or
          [long](Get-CcrPinnedRequiredProperty $r "reverseRefillGenerationCount") -le 0L -or
          [long](Get-CcrPinnedRequiredProperty $r "reverseRefillCachedTargetCount") -le 0L -or
          [long](Get-CcrPinnedRequiredProperty $r "reverseLowWaterTriggerCount") -le 0L -or
          [long](Get-CcrPinnedRequiredProperty $r "reversePartialAppendCount") -le 0L -or
          [long](Get-CcrPinnedRequiredProperty $r "reverseRefillCompletedBeforeDepletionCount") -le 0L) {
        throw "ALPHA6_STAGE1_REVERSE_MECHANISM_NOT_EXERCISED:$($fixtureContract.fixtureIdentity)/$stride/$($index + 1)"
      }
      if ($forwardFps -lt $absoluteMinimumFps -or $reverseFps -lt $absoluteMinimumFps -or
          $reverseFps -lt ($cappedForwardFps * 0.8) -or
          [long](Get-CcrPinnedRequiredProperty $r "rawLagP95") -gt $forwardStride -or
          [long](Get-CcrPinnedRequiredProperty $r "rawLagMax") -gt $forwardStride) {
        throw "ALPHA6_STAGE1_REVERSE_THROUGHPUT_OR_LAG_FAIL:$($fixtureContract.fixtureIdentity)/$stride/$($index + 1)"
        }
      }
    }
  }
  return $true
}

function Invoke-CcrAlpha6Stage1Correctness {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$StageDirectory)
  [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
  if ($null -ne $TestOnlyStageExecutor) {
    $result = & $TestOnlyStageExecutor "Correctness" $Context $StageDirectory
    if ($null -eq $result -or [string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS") {
      throw "ALPHA6_STAGE1_CORRECTNESS_FAILED"
    }
    return $result
  }
  Install-CcrPinnedArtifactSet $Context "Debug"
  $specs = @(
    [PSCustomObject]@{ stage = "Full"; className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#allGoldenVectorsRemainExactOnS24Ultra"; reportName = "s24-frame-accuracy-report.json"; kind = "frame-accuracy-exact" },
    [PSCustomObject]@{ stage = "Representative"; className = "com.snowberried.ctcinereviewer.gate.S24RepresentativeResolutionAccuracyTest#representativeResolutionExactSubsetRemainsExact"; reportName = "representative-resolution-exact-report.json"; kind = "representative-resolution-exact-subset" },
    [PSCustomObject]@{ stage = "Forward"; className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#forwardSequentialStrideOneAndFiveRemainExactOnS24Ultra"; reportName = "s24-forward-sequential-report.json"; kind = "forward-sequential-exact" },
    [PSCustomObject]@{ stage = "Reverse"; className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#reverseWindowStrideMinusOneAndFiveRemainExactOnS24Ultra"; reportName = "s24-reverse-window-report.json"; kind = "reverse-window-exact" },
    [PSCustomObject]@{ stage = "ReleaseCancel"; className = "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest#releaseThenCancelAcceptsNoNewForegroundRequestDuringGracePeriods"; reportName = "s24-release-cancel-grace-report.json"; kind = "release-cancel-grace" },
    [PSCustomObject]@{ stage = "Direction"; className = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest#directionReversalAndGenerationInvalidationRemainExactOnS24Ultra"; reportName = "s24-alpha5-direction-reversal-report.json"; kind = "bidirectional-transition-exact" },
    [PSCustomObject]@{ stage = "ReverseLifecycle"; className = "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest#reverseHoldLifecycleInvalidationRestoresExactFrameOnS24Ultra"; reportName = "s24-alpha5-reverse-lifecycle-report.json"; kind = "alpha5-reverse-lifecycle-exact" }
  )
  $evidence = [System.Collections.Generic.List[object]]::new()
  foreach ($spec in $specs) {
    Assert-CcrAlpha6Stage1Deadline "correctness-$($spec.stage)"
    Assert-CcrAlpha6ArtifactSetUnchanged $Context | Out-Null
    Clear-CcrPinnedRemoteReport $Context $script:CcrPinnedAppPackage $spec.reportName
    $childRunId = "$RunId-c-$($spec.stage.ToLowerInvariant())"
    $invocation = Invoke-CcrPinnedInstrumentation `
      -Context $Context -TestRole "debugTest" -ClassName $spec.className -RunId $childRunId `
      -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $StageDirectory "failure-$($spec.stage.ToLowerInvariant())-instrumentation-v1.json")
    $received = Receive-CcrPinnedReport `
      -Context $Context -ReportName $spec.reportName -RunId $childRunId `
      -AppRole "debugApp" -TestRole "debugTest" `
      -MinimumStartedAtElapsedRealtimeNs $invocation.MinimumStartedAtElapsedRealtimeNs `
      -ExpectedKind $spec.kind -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
    if ([string]$received.Report.appVersionName -cne $script:CcrPinnedVersionName -or
        [int]$received.Report.appVersionCode -ne $script:CcrPinnedVersionCode -or
        [string]$received.Report.appCommitSha -cne $Context.ArtifactSet.RuntimeSourceSha) {
      throw "ALPHA6_STAGE1_CORRECTNESS_APP_IDENTITY_MISMATCH:$($spec.stage)"
    }
    Assert-CcrAlpha6Stage1HardReport $received.Report $spec.stage $Context | Out-Null
    (Get-Item -LiteralPath $received.Path).IsReadOnly = $true
    $evidence.Add((Get-CcrAlpha6Stage1FileRecord $received.Path)) | Out-Null
  }
  return [PSCustomObject][ordered]@{
    status = "PASS"
    executedTestCount = $specs.Count
    evidence = $evidence.ToArray()
    buildCommandCount = 0L
  }
}

function Invoke-CcrAlpha6Stage1Performance {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$StageDirectory,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$RemoteDirectories
  )
  [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
  if ($null -ne $TestOnlyStageExecutor) {
    $result = & $TestOnlyStageExecutor "Performance" $Context $StageDirectory
    if ($null -eq $result -or [string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS") {
      throw "ALPHA6_STAGE1_PERFORMANCE_FAILED"
    }
    return $result
  }
  Install-CcrPinnedArtifactSet $Context "Benchmark"
  $scenarios = @(
    [PSCustomObject]@{ method = "hold1080PlusOne"; evidence = "1080p-hold-plus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 1; direction = "forward"; prefix = "a6-bf-p1" },
    [PSCustomObject]@{ method = "hold1080PlusFive"; evidence = "1080p-hold-plus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 5; direction = "forward"; prefix = "a6-bf-p5" },
    [PSCustomObject]@{ method = "hold1080MinusOne"; evidence = "1080p-hold-minus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -1; direction = "reverse"; prefix = "a6-bf-m1" },
    [PSCustomObject]@{ method = "hold1080MinusFive"; evidence = "1080p-hold-minus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -5; direction = "reverse"; prefix = "a6-bf-m5" },
    [PSCustomObject]@{ method = "hold1080H264LongGopMinusOne"; evidence = "1080p-h264-long-gop-hold-minus-one"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -1; direction = "reverse"; prefix = "a6-lg-m1" },
    [PSCustomObject]@{ method = "hold1080H264LongGopMinusFive"; evidence = "1080p-h264-long-gop-hold-minus-five"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -5; direction = "reverse"; prefix = "a6-lg-m5" },
    [PSCustomObject]@{ method = "hold1080HevcMain8MinusOne"; evidence = "1080p-hevc-main8-hold-minus-one"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -1; direction = "reverse"; prefix = "a6-hevc-m1" },
    [PSCustomObject]@{ method = "hold1080HevcMain8MinusFive"; evidence = "1080p-hevc-main8-hold-minus-five"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -5; direction = "reverse"; prefix = "a6-hevc-m5" },
    [PSCustomObject]@{ method = "hold1080VfrMinusOne"; evidence = "1080p-vfr-hold-minus-one"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -1; direction = "reverse"; prefix = "a6-vfr-m1" },
    [PSCustomObject]@{ method = "hold1080VfrMinusFive"; evidence = "1080p-vfr-hold-minus-five"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -5; direction = "reverse"; prefix = "a6-vfr-m5" }
  )
  $results = [System.Collections.Generic.List[object]]::new()
  foreach ($scenario in $scenarios) {
    Assert-CcrAlpha6Stage1Deadline "performance-$($scenario.method)"
    Assert-CcrAlpha6ArtifactSetUnchanged $Context | Out-Null
    $scenarioRunId = "$RunId-$($scenario.prefix)"
    $remote = "/sdcard/Android/media/$script:CcrPinnedMacrobenchmarkPackage/$scenarioRunId"
    $RemoteDirectories.Add($remote) | Out-Null
    Remove-CcrPinnedRemoteTraceDirectory $Context $remote
    $create = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "mkdir", "-p", $remote)
    if ($create.exitCode -ne 0) { throw "ALPHA6_STAGE1_REMOTE_TRACE_CREATE_FAILED:$($scenario.method)" }
    $invocation = Invoke-CcrPinnedInstrumentation `
      -Context $Context -TestRole "macrobenchmarkTest" `
      -ClassName "com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark#$($scenario.method)" `
      -RunId $scenarioRunId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $StageDirectory "failure-$($scenario.method)-instrumentation-v1.json") `
      -AdditionalArguments @{ additionalTestOutputDir = $remote; "androidx.benchmark.output.enable" = "true" }
    $harnessEvidence = Get-CcrAlpha6Stage1BenchmarkEvidence $invocation.Output
    $local = Join-Path $StageDirectory $scenarioRunId
    if (Test-Path -LiteralPath $local) { throw "ALPHA6_STAGE1_LOCAL_TRACE_DIRECTORY_EXISTS:$($scenario.method)" }
    $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $remote, $local)
    if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $local -PathType Container)) {
      throw "ALPHA6_STAGE1_TRACE_PULL_FAILED:$($scenario.method)"
    }
    $pulled = @(Get-ChildItem -LiteralPath $local -Recurse -File)
    if ($pulled.Count -ne 4) { throw "ALPHA6_STAGE1_TRACE_FILE_COUNT_MISMATCH:$($scenario.method)" }
    foreach ($item in $pulled) {
      $allowed = $item.Name -match '^CcrProductMacrobenchmark_[A-Za-z0-9]+_iter00[0-2]_.+\.perfetto-trace$' -or
        $item.Name.EndsWith("benchmarkData.json", [StringComparison]::OrdinalIgnoreCase)
      if (-not $allowed -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ALPHA6_STAGE1_TRACE_FILE_NOT_ALLOWED:$($item.Name)"
      }
    }
    $traces = @($pulled | Where-Object { $_.Name -match 'perfetto-trace$' -and $_.Length -gt 0 } | Sort-Object Name)
    $benchmarkData = @($pulled | Where-Object { $_.Name.EndsWith("benchmarkData.json", [StringComparison]::OrdinalIgnoreCase) -and $_.Length -gt 0 })
    if ($traces.Count -ne 3 -or $benchmarkData.Count -ne 1 -or
        @($traces | ForEach-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash } | Select-Object -Unique).Count -ne 3) {
      throw "ALPHA6_STAGE1_TRACE_RECOVERY_CONTRACT_MISMATCH:$($scenario.method)"
    }
    $iterations = @(Assert-CcrAlpha6Stage1BenchmarkEvidence $harnessEvidence $scenario $Context $scenarioRunId)
    Assert-CcrAlpha6BenchmarkData `
      -Path $benchmarkData[0].FullName -ExpectedMethod $scenario.method `
      -ExpectedEvidence $harnessEvidence -RequireRequestStageMetrics | Out-Null
    $evidencePath = Join-Path $local "ccrBenchmarkHarnessV2.json"
    Write-CcrAlpha6Stage1ImmutableJson $evidencePath $harnessEvidence | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $local -Recurse -File)) { $item.IsReadOnly = $true }
    $results.Add([PSCustomObject][ordered]@{
      method = $scenario.method
      evidenceScenario = $scenario.evidence
      fixtureIdentity = $scenario.fixtureIdentity
      fixture = $scenario.fixture
      stride = $scenario.stride
      direction = $scenario.direction
      runId = $scenarioRunId
      iterations = $iterations
      traces = @($traces | ForEach-Object { Get-CcrAlpha6Stage1FileRecord $_.FullName })
      benchmarkData = Get-CcrAlpha6Stage1FileRecord $benchmarkData[0].FullName
      harnessEvidence = Get-CcrAlpha6Stage1FileRecord $evidencePath
    }) | Out-Null
  }
  Assert-CcrAlpha6Stage1TailGate $results.ToArray() | Out-Null
  return [PSCustomObject][ordered]@{
    status = "PASS"
    scenarioCount = 10
    independentTraceCount = 30
    scenarios = $results.ToArray()
    buildCommandCount = 0L
  }
}

function Get-CcrAlpha6Stage1DirectoryEvidence {
  param([Parameter(Mandatory = $true)][string]$Directory)
  return @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName | ForEach-Object {
    Get-CcrAlpha6Stage1FileRecord $_.FullName
  })
}

function Assert-CcrAlpha6Stage1CorrectnessResult {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ([string](Get-CcrPinnedRequiredProperty $Result "status") -cne "PASS" -or
      [int](Get-CcrPinnedRequiredProperty $Result "executedTestCount") -ne 7 -or
      [long](Get-CcrPinnedRequiredProperty $Result "buildCommandCount") -ne 0L) {
    throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_CONTRACT_MISMATCH"
  }
  $contracts = @{
    "s24-frame-accuracy-report.json" = @("Full", "frame-accuracy-exact")
    "representative-resolution-exact-report.json" = @("Representative", "representative-resolution-exact-subset")
    "s24-forward-sequential-report.json" = @("Forward", "forward-sequential-exact")
    "s24-reverse-window-report.json" = @("Reverse", "reverse-window-exact")
    "s24-release-cancel-grace-report.json" = @("ReleaseCancel", "release-cancel-grace")
    "s24-alpha5-direction-reversal-report.json" = @("Direction", "bidirectional-transition-exact")
    "s24-alpha5-reverse-lifecycle-report.json" = @("ReverseLifecycle", "alpha5-reverse-lifecycle-exact")
  }
  $records = @((Get-CcrPinnedRequiredProperty $Result "evidence"))
  if ($records.Count -ne $contracts.Count) { throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_COUNT_MISMATCH" }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $records) {
    $path = Assert-CcrAlpha6Stage1FileRecord $record $Context.OutputDirectory
    $leaf = [System.IO.Path]::GetFileName($path)
    if (-not $contracts.ContainsKey($leaf) -or -not $seen.Add($leaf)) {
      throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_IDENTITY_MISMATCH:$leaf"
    }
    try { $report = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
      throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_JSON_INVALID:$leaf"
    }
    $stage = [string]$contracts[$leaf][0]
    $kind = [string]$contracts[$leaf][1]
    Assert-CcrPinnedReport `
      -Report $report -ArtifactSet $Context.ArtifactSet `
      -RunId ([string](Get-CcrPinnedRequiredProperty $report "runId")) `
      -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind $kind `
      -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
    Assert-CcrAlpha6Stage1HardReport $report $stage $Context | Out-Null
  }
  return $true
}

function Assert-CcrAlpha6Stage1PerformanceResult {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ([string](Get-CcrPinnedRequiredProperty $Result "status") -cne "PASS" -or
      [int](Get-CcrPinnedRequiredProperty $Result "scenarioCount") -ne 10 -or
      [int](Get-CcrPinnedRequiredProperty $Result "independentTraceCount") -ne 30 -or
      [long](Get-CcrPinnedRequiredProperty $Result "buildCommandCount") -ne 0L) {
    throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_CONTRACT_MISMATCH"
  }
  $scenarios = @((Get-CcrPinnedRequiredProperty $Result "scenarios"))
  if ($scenarios.Count -ne 10 -or @($scenarios.method | Select-Object -Unique).Count -ne 10) {
    throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_SCENARIO_MISMATCH"
  }
  foreach ($scenario in $scenarios) {
    $traces = @((Get-CcrPinnedRequiredProperty $scenario "traces"))
    if ($traces.Count -ne 3) { throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_TRACE_COUNT_MISMATCH" }
    foreach ($trace in $traces) { Assert-CcrAlpha6Stage1FileRecord $trace $Context.OutputDirectory | Out-Null }
    $benchmarkDataPath = Assert-CcrAlpha6Stage1FileRecord `
      (Get-CcrPinnedRequiredProperty $scenario "benchmarkData") $Context.OutputDirectory
    $harnessEvidencePath = Assert-CcrAlpha6Stage1FileRecord `
      (Get-CcrPinnedRequiredProperty $scenario "harnessEvidence") $Context.OutputDirectory
    try { $harnessEvidence = [System.IO.File]::ReadAllText($harnessEvidencePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_JSON_INVALID"
    }
    $scenarioContract = [PSCustomObject]@{
      method = [string](Get-CcrPinnedRequiredProperty $scenario "method")
      evidence = [string](Get-CcrPinnedRequiredProperty $scenario "evidenceScenario")
      fixture = [string](Get-CcrPinnedRequiredProperty $scenario "fixture")
    }
    $validatedIterations = @(Assert-CcrAlpha6Stage1BenchmarkEvidence `
      $harnessEvidence $scenarioContract $Context ([string](Get-CcrPinnedRequiredProperty $scenario "runId")))
    if (($validatedIterations | ConvertTo-Json -Depth 30 -Compress) -cne
        (@((Get-CcrPinnedRequiredProperty $scenario "iterations")) | ConvertTo-Json -Depth 30 -Compress)) {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_ITERATION_MISMATCH"
    }
    Assert-CcrAlpha6BenchmarkData `
      -Path $benchmarkDataPath -ExpectedMethod $scenarioContract.method `
      -ExpectedEvidence $harnessEvidence -RequireRequestStageMetrics | Out-Null
  }
  Assert-CcrAlpha6Stage1TailGate $scenarios | Out-Null
  return $true
}

function Assert-CcrAlpha6Stage1Checkpoint {
  param([Parameter(Mandatory = $true)][object]$Checkpoint, [Parameter(Mandatory = $true)][string]$Stage, [Parameter(Mandatory = $true)][object]$Context)
  if ([string]$Checkpoint.status -cne "PASS" -or
      [string]$Checkpoint.stage -cne $Stage -or
      [long]$Checkpoint.buildCommandCount -ne 0L) {
    throw "ALPHA6_STAGE1_CHECKPOINT_STATUS_MISMATCH:$Stage"
  }
  Assert-CcrAlpha6Stage1Identity $Checkpoint.identity $Context | Out-Null
  $records = @($Checkpoint.evidence)
  if ($records.Count -eq 0) { throw "ALPHA6_STAGE1_CHECKPOINT_EVIDENCE_EMPTY:$Stage" }
  foreach ($record in $records) { Assert-CcrAlpha6Stage1FileRecord $record $Context.OutputDirectory | Out-Null }
  $result = $Checkpoint.result
  if ($null -eq $result) { throw "ALPHA6_STAGE1_CHECKPOINT_RESULT_MISSING:$Stage" }
  if ([string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $result "buildCommandCount") -ne 0L) {
    throw "ALPHA6_STAGE1_CHECKPOINT_RESULT_MISMATCH:$Stage"
  }
  if ($null -eq $TestOnlyStageExecutor) {
    if ($Stage -ceq "Correctness") {
      Assert-CcrAlpha6Stage1CorrectnessResult $result $Context | Out-Null
    } else {
      Assert-CcrAlpha6Stage1PerformanceResult $result $Context | Out-Null
    }
  }
  return $true
}

function Recover-CcrAlpha6Stage1Traces {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$RemoteDirectories,
    [Parameter(Mandatory = $true)][string]$RecoveryDirectory
  )
  $records = [System.Collections.Generic.List[object]]::new()
  if ($RemoteDirectories.Count -eq 0) { return @() }
  [System.IO.Directory]::CreateDirectory($RecoveryDirectory) | Out-Null
  foreach ($remote in @($RemoteDirectories | Select-Object -Unique)) {
    $leaf = [System.IO.Path]::GetFileName($remote.TrimEnd('/'))
    $local = Join-Path $RecoveryDirectory $leaf
    try {
      $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $remote, $local)
      if ($pull.exitCode -eq 0 -and (Test-Path -LiteralPath $local)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $local -Recurse -File -ErrorAction SilentlyContinue)) {
          $records.Add((Get-CcrAlpha6Stage1FileRecord $file.FullName)) | Out-Null
        }
      }
    } catch { }
  }
  return $records.ToArray()
}

function Write-CcrAlpha6Stage1Failure {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$Message,
    [object[]]$RecoveredTraces = @(),
    [object[]]$CleanupFailures = @(),
    [AllowNull()][object]$PostRunArtifactRehash = $null
  )
  $path = Join-Path $Context.OutputDirectory "failure-alpha6-stage1-$RunId-$([Guid]::NewGuid().ToString('N')).json"
  $report = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-failure"
    status = "FAIL"
    phase = $Phase
    error = $Message
    identity = New-CcrAlpha6Stage1Identity $Context
    recoveredTraces = @($RecoveredTraces)
    cleanupFailures = @($CleanupFailures)
    postRunArtifactRehash = $PostRunArtifactRehash
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  return Write-CcrAlpha6Stage1ImmutableJson $path $report
}

$androidTools = if ($null -ne $TestOnlyAndroidTools) { $TestOnlyAndroidTools } else { Get-CcrPinnedAndroidSdkTools }
$effectiveAdbInvoker = if ($null -ne $TestOnlyAdbInvoker) {
  $TestOnlyAdbInvoker
} else {
  New-CcrAlpha6TimedAdbInvoker ([string]$androidTools.Adb) $adbDeadlineState
}
$hostPreflightRunId = if ($Resume) { "$RunId-resume-$([Guid]::NewGuid().ToString('N'))" } else { $RunId }
$hostParameters = @{
  ArtifactManifest = $ArtifactManifest
  ArtifactManifestSha256 = $ArtifactManifestSha256
  OutputDirectory = $OutputDirectory
  RunId = $hostPreflightRunId
  RuntimeSourceSha = $RuntimeSourceSha
  HarnessSourceSha = $HarnessSourceSha
  RuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256
  ExpectedDebugAppSha256 = $ExpectedDebugAppSha256
  PreflightOnly = [bool]$PreflightOnly
  BuildCommandCount = 0L
  ValidationScriptPaths = $closedValidationScripts
  AndroidTools = $androidTools
}
if ($null -ne $TestOnlyIdentityReader) { $hostParameters.IdentityReader = $TestOnlyIdentityReader }
if ($null -ne $TestOnlySourceIdentityVerifier) { $hostParameters.SourceIdentityVerifier = $TestOnlySourceIdentityVerifier }
$context = Invoke-CcrAlpha6PinnedHostPreflight @hostParameters
$context | Add-Member -Force -NotePropertyName AndroidTools -NotePropertyValue $androidTools
$context | Add-Member -Force -NotePropertyName Adb -NotePropertyValue ([string]$androidTools.Adb)
$context | Add-Member -Force -NotePropertyName AdbInvoker -NotePropertyValue $effectiveAdbInvoker

if (-not $PreflightOnly) {
  $device = Get-CcrPinnedS24Device $androidTools.Adb $effectiveAdbInvoker
  foreach ($name in @("Serial", "Model", "Fingerprint", "SecurityPatch", "Sdk")) {
    $context | Add-Member -Force -NotePropertyName $name -NotePropertyValue $device.$name
  }
}

$sessionPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-stage1-session-$RunId.json"
$summaryPath = Join-Path $context.OutputDirectory "alpha6-stage1-summary-$RunId.json"
$correctnessCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-stage1-correctness-$RunId.json"
$performanceCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-stage1-performance-$RunId.json"
$identity = New-CcrAlpha6Stage1Identity $context
if ($Resume) {
  if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { throw "ALPHA6_STAGE1_SESSION_MISSING" }
  $session = [System.IO.File]::ReadAllText($sessionPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  if ([string](Get-CcrPinnedRequiredProperty $session "status") -cne "IN_PROGRESS" -or
      [int](Get-CcrPinnedRequiredProperty $session "maxMinutes") -ne $MaxMinutes -or
      [string](Get-CcrPinnedRequiredProperty $session "originalStayAwakeSetting") -cne $OriginalStayAwakeSetting -or
      [string](Get-CcrPinnedRequiredProperty $session "originalScreenTimeoutSetting") -cne $OriginalScreenTimeoutSetting) {
    throw "ALPHA6_STAGE1_SESSION_CONTRACT_MISMATCH"
  }
  Assert-CcrAlpha6Stage1Identity $session.identity $context | Out-Null
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    $summary = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string](Get-CcrPinnedRequiredProperty $summary "status") -cne $(if ($PreflightOnly) { "PREFLIGHT_PASS" } else { "PENDING_USER" })) {
      throw "ALPHA6_STAGE1_RESUME_SUMMARY_STATUS_MISMATCH"
    }
    Assert-CcrAlpha6Stage1Identity $summary.identity $context | Out-Null
    if ($PreflightOnly) {
      $currentArtifactRecords = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
      $plannedTokens = @((Get-CcrPinnedRequiredProperty $summary "plannedPerformanceScenarios") | ForEach-Object {
        "$($_.scenario)|$($_.fixtureIdentity)|$($_.fixture)|$($_.stride)"
      } | Sort-Object)
      $expectedTokens = @(
        "1080p-h264-long-gop-hold-minus-five|h264-long-gop|1080p-h264-long-gop.mp4|-5",
        "1080p-h264-long-gop-hold-minus-one|h264-long-gop|1080p-h264-long-gop.mp4|-1",
        "1080p-hevc-main8-hold-minus-five|hevc-main8|1080p-hevc-main8.mp4|-5",
        "1080p-hevc-main8-hold-minus-one|hevc-main8|1080p-hevc-main8.mp4|-1",
        "1080p-hold-minus-five|h264-bframes|1080p-h264-bframes.mp4|-5",
        "1080p-hold-minus-one|h264-bframes|1080p-h264-bframes.mp4|-1",
        "1080p-hold-plus-five|h264-bframes|1080p-h264-bframes.mp4|5",
        "1080p-hold-plus-one|h264-bframes|1080p-h264-bframes.mp4|1",
        "1080p-vfr-hold-minus-five|vfr|1080p-vfr.mp4|-5",
        "1080p-vfr-hold-minus-one|vfr|1080p-vfr.mp4|-1"
      ) | Sort-Object
      if ([string](Get-CcrPinnedRequiredProperty $summary "kind") -cne "alpha6-stage1-preflight" -or
          [int](Get-CcrPinnedRequiredProperty $summary "maxMinutes") -ne $MaxMinutes -or
          [int](Get-CcrPinnedRequiredProperty $summary "plannedCorrectnessTestCount") -ne 7 -or
          $plannedTokens.Count -ne 10 -or ($plannedTokens -join "`n") -cne ($expectedTokens -join "`n") -or
          [int](Get-CcrPinnedRequiredProperty $summary "plannedIndependentTraceCount") -ne 30 -or
          [long](Get-CcrPinnedRequiredProperty $summary "deviceMutationCount") -ne 0L -or
          [long](Get-CcrPinnedRequiredProperty $summary "buildCommandCount") -ne 0L -or
          (Get-CcrPinnedRequiredProperty $summary "syntheticOnly") -ne $true -or
          (Get-CcrPinnedRequiredProperty $summary "containsRealMediaMetadata") -ne $false -or
          (($currentArtifactRecords | ConvertTo-Json -Depth 20 -Compress) -cne
            ((Get-CcrPinnedRequiredProperty $summary "preRunArtifactRehash") | ConvertTo-Json -Depth 20 -Compress)) -or
          (($currentArtifactRecords | ConvertTo-Json -Depth 20 -Compress) -cne
            ((Get-CcrPinnedRequiredProperty $summary "postRunArtifactRehash") | ConvertTo-Json -Depth 20 -Compress))) {
        throw "ALPHA6_STAGE1_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH"
      }
    } else {
      if ([string](Get-CcrPinnedRequiredProperty $summary "kind") -cne "alpha6-stage1-single-decoder" -or
          [string](Get-CcrPinnedRequiredProperty $summary "technicalGateStatus") -cne "PASS" -or
          (Get-CcrPinnedRequiredProperty $summary "releaseEligible") -ne $false -or
          (Get-CcrPinnedRequiredProperty $summary "auxiliaryDecoderUsed") -ne $false -or
          [string](Get-CcrPinnedRequiredProperty $summary "userReverseSmoothness") -cne "PENDING_USER" -or
          [long](Get-CcrPinnedRequiredProperty $summary "buildCommandCount") -ne 0L -or
          (Get-CcrPinnedRequiredProperty $summary "syntheticOnly") -ne $true -or
          (Get-CcrPinnedRequiredProperty $summary "containsRealMediaMetadata") -ne $false) {
        throw "ALPHA6_STAGE1_RESUME_SUMMARY_CONTRACT_MISMATCH"
      }
      if (-not (Test-Path -LiteralPath $correctnessCheckpointPath -PathType Leaf) -or
          -not (Test-Path -LiteralPath $performanceCheckpointPath -PathType Leaf)) {
        throw "ALPHA6_STAGE1_RESUME_COMPLETED_CHECKPOINT_MISSING"
      }
      $completedCorrectness = [System.IO.File]::ReadAllText($correctnessCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $completedPerformance = [System.IO.File]::ReadAllText($performanceCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      Assert-CcrAlpha6Stage1Checkpoint $completedCorrectness "Correctness" $context | Out-Null
      Assert-CcrAlpha6Stage1Checkpoint $completedPerformance "Performance" $context | Out-Null
      if (($completedCorrectness | ConvertTo-Json -Depth 40 -Compress) -cne
          ($summary.correctness | ConvertTo-Json -Depth 40 -Compress) -or
          ($completedPerformance | ConvertTo-Json -Depth 40 -Compress) -cne
          ($summary.performance | ConvertTo-Json -Depth 40 -Compress)) {
        throw "ALPHA6_STAGE1_RESUME_COMPLETED_CHECKPOINT_MISMATCH"
      }
    }
    Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
} else {
  if (Test-Path -LiteralPath $sessionPath) { throw "ALPHA6_STAGE1_SESSION_ALREADY_EXISTS" }
  $session = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-session"
    status = "IN_PROGRESS"
    maxMinutes = $MaxMinutes
    originalStayAwakeSetting = $OriginalStayAwakeSetting
    originalScreenTimeoutSetting = $OriginalScreenTimeoutSetting
    identity = $identity
    stageOrder = @("Correctness", "Performance")
    resumeContract = "completed-stage-only; exact artifact, helper hash, source and device identity"
    correctnessFailureBlocksPerformance = $true
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6Stage1ImmutableJson $sessionPath $session | Out-Null
}

$preRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
if ($PreflightOnly) {
  $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  $summary = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-preflight"
    status = "PREFLIGHT_PASS"
    identity = $identity
    maxMinutes = $MaxMinutes
    stageOrder = @("Correctness", "Performance")
    plannedCorrectnessTestCount = 7
    plannedPerformanceScenarios = @(
      [ordered]@{ scenario = "1080p-hold-plus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 1 },
      [ordered]@{ scenario = "1080p-hold-plus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 5 },
      [ordered]@{ scenario = "1080p-hold-minus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -1 },
      [ordered]@{ scenario = "1080p-hold-minus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -5 },
      [ordered]@{ scenario = "1080p-h264-long-gop-hold-minus-one"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -1 },
      [ordered]@{ scenario = "1080p-h264-long-gop-hold-minus-five"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -5 },
      [ordered]@{ scenario = "1080p-hevc-main8-hold-minus-one"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -1 },
      [ordered]@{ scenario = "1080p-hevc-main8-hold-minus-five"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -5 },
      [ordered]@{ scenario = "1080p-vfr-hold-minus-one"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -1 },
      [ordered]@{ scenario = "1080p-vfr-hold-minus-five"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -5 }
    )
    plannedIndependentTraceCount = 30
    deviceMutationCount = 0L
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6Stage1ImmutableJson $summaryPath $summary | Out-Null
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}

$remoteTraceDirectories = [System.Collections.Generic.List[string]]::new()
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$settingsSaved = $false
$currentPhase = "device-settings"
$primaryFailure = $null
$correctnessCheckpoint = $null
$performanceCheckpoint = $null
$postRunArtifactRehash = $null
$settingsPreflight = $null
$resumeRestoreBaseline = $null
if ($Resume) {
  $initialSettingsPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-stage1-device-settings-$RunId.json"
  if (Test-Path -LiteralPath $initialSettingsPath -PathType Leaf) {
    $initialSettings = [System.IO.File]::ReadAllText($initialSettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string](Get-CcrPinnedRequiredProperty $initialSettings "kind") -cne "alpha6-device-settings-preflight" -or
        [string](Get-CcrPinnedRequiredProperty $initialSettings "status") -cne "PASS" -or
        [string](Get-CcrPinnedRequiredProperty $initialSettings "runId") -cne $RunId) {
      throw "ALPHA6_STAGE1_RESUME_SETTINGS_BASELINE_CONTRACT_MISMATCH"
    }
    Assert-CcrAlpha6Stage1Identity (Get-CcrPinnedRequiredProperty $initialSettings "identity") $context | Out-Null
    $resumeRestoreBaseline = Get-CcrPinnedRequiredProperty $initialSettings "effectiveRestoreBaseline"
  }
}
try {
  $settingsSaved = $true
  $settingsPreflight = Initialize-CcrAlpha6PinnedDeviceSettings `
    -Context $context `
    -OriginalStayAwakeSetting $OriginalStayAwakeSetting `
    -OriginalScreenTimeoutSetting $OriginalScreenTimeoutSetting `
    -ResumeRestoreBaseline $resumeRestoreBaseline
  $settingsPreflight | Add-Member -NotePropertyName runId -NotePropertyValue $RunId
  $settingsPreflight | Add-Member -NotePropertyName attemptRunId -NotePropertyValue $hostPreflightRunId
  $settingsPreflight | Add-Member -NotePropertyName identity -NotePropertyValue $identity
  $settingsPreflightPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-stage1-device-settings-$hostPreflightRunId.json"
  if (Test-Path -LiteralPath $settingsPreflightPath) { throw "ALPHA6_STAGE1_SETTINGS_PREFLIGHT_ALREADY_EXISTS" }
  Write-CcrAlpha6Stage1ImmutableJson $settingsPreflightPath $settingsPreflight | Out-Null
  if ([string]$settingsPreflight.status -cne "PASS") {
    throw "ALPHA6_STAGE1_STALE_DEVICE_SETTINGS_REQUIRE_TRUSTED_ORIGINAL"
  }
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_brightness_mode" "0"
  Set-CcrPinnedDeviceSetting $context "system" "screen_brightness" "128"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"

  $currentPhase = "correctness"
  if ($Resume -and (Test-Path -LiteralPath $correctnessCheckpointPath -PathType Leaf)) {
    $correctnessCheckpoint = [System.IO.File]::ReadAllText($correctnessCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null
  } else {
    if (Test-Path -LiteralPath $correctnessCheckpointPath) { throw "ALPHA6_STAGE1_CORRECTNESS_CHECKPOINT_ALREADY_EXISTS" }
    $correctnessDirectory = Join-Path $context.OutputDirectory "attempt-$hostPreflightRunId-stage-correctness"
    $correctnessResult = Invoke-CcrAlpha6Stage1Correctness $context $correctnessDirectory
    if ([string]$correctnessResult.status -cne "PASS") { throw "ALPHA6_STAGE1_CORRECTNESS_FAILED" }
    $evidence = @(Get-CcrAlpha6Stage1DirectoryEvidence $correctnessDirectory)
    if ($evidence.Count -eq 0) { throw "ALPHA6_STAGE1_CORRECTNESS_EVIDENCE_EMPTY" }
    $correctnessCheckpoint = [ordered]@{
      schemaVersion = 1
      kind = "alpha6-stage1-checkpoint"
      status = "PASS"
      stage = "Correctness"
      identity = $identity
      result = $correctnessResult
      evidence = $evidence
      completedAtUtc = [DateTime]::UtcNow.ToString("o")
      buildCommandCount = 0L
    }
    Write-CcrAlpha6Stage1ImmutableJson $correctnessCheckpointPath $correctnessCheckpoint | Out-Null
  }

  # Performance is intentionally unreachable unless the exact same artifact set
  # has a verified PASS correctness checkpoint in this session.
  Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  $currentPhase = "performance"
  if ($Resume -and (Test-Path -LiteralPath $performanceCheckpointPath -PathType Leaf)) {
    $performanceCheckpoint = [System.IO.File]::ReadAllText($performanceCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha6Stage1Checkpoint $performanceCheckpoint "Performance" $context | Out-Null
  } else {
    if (Test-Path -LiteralPath $performanceCheckpointPath) { throw "ALPHA6_STAGE1_PERFORMANCE_CHECKPOINT_ALREADY_EXISTS" }
    $performanceDirectory = Join-Path $context.OutputDirectory "attempt-$hostPreflightRunId-stage-performance"
    $performanceResult = Invoke-CcrAlpha6Stage1Performance $context $performanceDirectory $remoteTraceDirectories
    if ([string]$performanceResult.status -cne "PASS") { throw "ALPHA6_STAGE1_PERFORMANCE_FAILED" }
    $evidence = @(Get-CcrAlpha6Stage1DirectoryEvidence $performanceDirectory)
    if ($evidence.Count -eq 0) { throw "ALPHA6_STAGE1_PERFORMANCE_EVIDENCE_EMPTY" }
    $performanceCheckpoint = [ordered]@{
      schemaVersion = 1
      kind = "alpha6-stage1-checkpoint"
      status = "PASS"
      stage = "Performance"
      identity = $identity
      result = $performanceResult
      evidence = $evidence
      completedAtUtc = [DateTime]::UtcNow.ToString("o")
      buildCommandCount = 0L
    }
    Write-CcrAlpha6Stage1ImmutableJson $performanceCheckpointPath $performanceCheckpoint | Out-Null
  }
  Assert-CcrAlpha6Stage1Deadline "complete"
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
} catch {
  $primaryFailure = $_
  try {
    $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
    Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  } catch {
    $cleanupFailures.Add("ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
} finally {
  $adbDeadlineState.CleanupMode = $true
  $adbDeadlineState.CleanupDeadlineUtc = [DateTime]::UtcNow.AddMinutes(2)
  $recovered = @()
  if ($null -ne $primaryFailure) {
    try {
      $recovered = @(Recover-CcrAlpha6Stage1Traces $context $remoteTraceDirectories (Join-Path $context.OutputDirectory "failure-trace-recovery"))
    } catch { $cleanupFailures.Add("TRACE_RECOVERY:$($_.Exception.Message)") | Out-Null }
  }
  foreach ($remote in @($remoteTraceDirectories | Select-Object -Unique)) {
    try { Remove-CcrPinnedRemoteTraceDirectory $context $remote } catch {
      $cleanupFailures.Add("REMOTE_TRACE_CLEANUP:$($_.Exception.Message)") | Out-Null
    }
  }
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch { $cleanupFailures.Add("PACKAGE_CLEANUP:$($_.Exception.Message)") | Out-Null }
  if ($settingsSaved) {
    try { Assert-CcrAlpha6Stage1SettingsRestored $context | Out-Null } catch {
      $cleanupFailures.Add("SETTINGS_RESTORE:$($_.Exception.Message)") | Out-Null
    }
  }
  try { Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null } catch {
    $cleanupFailures.Add("FINAL_ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
  if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
    $message = if ($null -ne $primaryFailure) { $primaryFailure.Exception.Message } else { "ALPHA6_STAGE1_CLEANUP_FAILED" }
    try {
      Write-CcrAlpha6Stage1Failure `
        -Context $context -Phase $currentPhase -Message $message `
        -RecoveredTraces $recovered -CleanupFailures $cleanupFailures.ToArray() `
        -PostRunArtifactRehash $postRunArtifactRehash | Out-Null
    } catch { }
  }
}

if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }

$summary = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-stage1-single-decoder"
  status = "PENDING_USER"
  technicalGateStatus = "PASS"
  releaseEligible = $false
  identity = $identity
  maxMinutes = $MaxMinutes
  correctness = $correctnessCheckpoint
  performance = $performanceCheckpoint
  deviceSettingsPreflight = $settingsPreflight
  preRunArtifactRehash = $preRunArtifactRehash
  postRunArtifactRehash = $postRunArtifactRehash
  auxiliaryDecoderUsed = $false
  userReverseSmoothness = "PENDING_USER"
  buildCommandCount = 0L
  syntheticOnly = $true
  containsRealMediaMetadata = $false
}
Write-CcrAlpha6Stage1ImmutableJson $summaryPath $summary | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
