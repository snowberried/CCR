param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
  [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
  [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$RunId,
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [ValidateSet("Stage1", "Stage2")][string]$DecoderStage = "Stage1",
  [AllowEmptyString()][string]$OriginalStayAwakeSetting = "",
  [AllowEmptyString()][string]$OriginalScreenTimeoutSetting = "",
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($DecoderStage -ceq "Stage2") {
  throw "ALPHA6_RANDOM_STAGE2_NOT_IMPLEMENTED"
}

$script:CcrAlpha6FrozenTargetSetIdentities = [ordered]@{
  "fixture-01" = "e27c3831f54e977f8cbe66221fd8cbf636b255cbfbd06cbd31119ea2d5ec6da6"
  "fixture-02" = "e32cb87230d992d8e7b596b0c45f7ecb22d39d915808eaf5c626324e12295b83"
  "fixture-03" = "2e6ca49bd7c674bb8da39a459dc008d94b3c2550e44b964f86d07024893545ee"
  "fixture-04" = "10f5e83b3a0fa02669cbb846962d5441016fef533612edb00031e6acf049dbe9"
  "fixture-05" = "79481a4a5d9defe58d2e9baf16a00943bb0519b513877c2ba4433d8b343eb0a4"
}

$runnerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$alpha6PinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinnedPath = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
. $alpha6PinnedPath

Assert-CcrPinnedRunId $RunId | Out-Null
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
$adbDeadlineState = [PSCustomObject]@{
  ValidationDeadlineUtc = $deadlineUtc
  CleanupMode = $false
  CleanupDeadlineUtc = $deadlineUtc
}
$closedValidationScripts = @(
  $runnerPath,
  [System.IO.Path]::GetFullPath($alpha6PinnedPath),
  [System.IO.Path]::GetFullPath($basePinnedPath)
)
if (@($closedValidationScripts | Select-Object -Unique).Count -ne 3) {
  throw "ALPHA6_RANDOM_CLOSED_SCRIPT_SET_INVALID"
}

function Assert-CcrAlpha6RandomDeadline {
  param([Parameter(Mandatory = $true)][string]$Phase)
  if ([DateTime]::UtcNow -ge $deadlineUtc) { throw "ALPHA6_RANDOM_MAX_MINUTES_EXCEEDED:$Phase" }
}

function Write-CcrAlpha6RandomImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $full) { throw "ALPHA6_RANDOM_EVIDENCE_ALREADY_EXISTS:$full" }
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
  $stream = [System.IO.File]::Open(
    $full,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read
  )
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 50) + "`n"))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally { $stream.Dispose() }
  (Get-Item -LiteralPath $full).IsReadOnly = $true
  return $full
}

function Get-CcrAlpha6RandomFileRecord {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -Force -LiteralPath $Path
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
    throw "ALPHA6_RANDOM_EVIDENCE_FILE_INVALID:$Path"
  }
  return [PSCustomObject][ordered]@{
    path = $item.FullName
    bytes = [long]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
  }
}

function Assert-CcrAlpha6RandomFileRecord {
  param([Parameter(Mandatory = $true)][object]$Record, [Parameter(Mandatory = $true)][string]$Root)
  $path = [System.IO.Path]::GetFullPath([string](Get-CcrPinnedRequiredProperty $Record "path"))
  if (-not (Test-CcrPinnedPathWithin $path $Root) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ALPHA6_RANDOM_RESUME_EVIDENCE_PATH_MISMATCH"
  }
  $item = Get-Item -Force -LiteralPath $path
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      [long]$item.Length -ne [long](Get-CcrPinnedRequiredProperty $Record "bytes") -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne
        [string](Get-CcrPinnedRequiredProperty $Record "sha256")) {
    throw "ALPHA6_RANDOM_RESUME_EVIDENCE_HASH_MISMATCH"
  }
  return $path
}

function Get-CcrAlpha6RandomArtifactRecords {
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

function New-CcrAlpha6RandomIdentity {
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
    decoderStage = $DecoderStage
    artifactManifest = [string]$Context.ArtifactSet.ManifestPath
    artifactManifestSha256 = [string]$Context.ArtifactSet.ManifestSha256
    artifactSetRevision = 4
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    applicationId = $script:CcrPinnedAppPackage
    versionName = $script:CcrPinnedVersionName
    versionCode = $script:CcrPinnedVersionCode
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    artifacts = @(Get-CcrAlpha6RandomArtifactRecords $Context)
    closedValidationScripts = @($Context.ValidationScripts)
    device = $device
    buildCommandCount = 0L
  }
}

function Assert-CcrAlpha6RandomIdentity {
  param([Parameter(Mandatory = $true)][object]$Actual, [Parameter(Mandatory = $true)][object]$Context)
  $expected = New-CcrAlpha6RandomIdentity $Context
  if (($Actual | ConvertTo-Json -Depth 40 -Compress) -cne ($expected | ConvertTo-Json -Depth 40 -Compress)) {
    throw "ALPHA6_RANDOM_RESUME_IDENTITY_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6RandomCompletedSummary {
  param(
    [Parameter(Mandatory = $true)][object]$Summary,
    [Parameter(Mandatory = $true)][object]$CompletedExact,
    [Parameter(Mandatory = $true)][object]$CompletedPerformance,
    [Parameter(Mandatory = $true)][int]$ExpectedMaxMinutes
  )
  if ([string](Get-CcrPinnedRequiredProperty $Summary "kind") -cne "alpha6-cost-aware-random-gate" -or
      [string](Get-CcrPinnedRequiredProperty $Summary "status") -cne "PASS" -or
      [int](Get-CcrPinnedRequiredProperty $Summary "maxMinutes") -ne $ExpectedMaxMinutes -or
      (Get-CcrPinnedRequiredProperty $Summary "exactness250Of250") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Summary "correctnessFailureBlocksPerformance") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Summary "traceRequiredForSuccess") -ne $true -or
      [long](Get-CcrPinnedRequiredProperty $Summary "buildCommandCount") -ne 0L -or
      (Get-CcrPinnedRequiredProperty $Summary "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Summary "containsRealMediaMetadata") -ne $false) {
    throw "ALPHA6_RANDOM_RESUME_SUMMARY_CONTRACT_MISMATCH"
  }
  if (($CompletedExact | ConvertTo-Json -Depth 50 -Compress) -cne
      ((Get-CcrPinnedRequiredProperty $Summary "exactness") | ConvertTo-Json -Depth 50 -Compress) -or
      ($CompletedPerformance | ConvertTo-Json -Depth 50 -Compress) -cne
      ((Get-CcrPinnedRequiredProperty $Summary "performance") | ConvertTo-Json -Depth 50 -Compress)) {
    throw "ALPHA6_RANDOM_RESUME_COMPLETED_CHECKPOINT_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6RandomPreflightSummary {
  param(
    [Parameter(Mandatory = $true)][object]$Summary,
    [Parameter(Mandatory = $true)][int]$ExpectedMaxMinutes,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$CurrentArtifactRecords
  )
  if ([string](Get-CcrPinnedRequiredProperty $Summary "kind") -cne "alpha6-random-preflight" -or
      [string](Get-CcrPinnedRequiredProperty $Summary "status") -cne "PREFLIGHT_PASS" -or
      [int](Get-CcrPinnedRequiredProperty $Summary "maxMinutes") -ne $ExpectedMaxMinutes -or
      [int](Get-CcrPinnedRequiredProperty $Summary "exactnessTargetCount") -ne 250 -or
      [int](Get-CcrPinnedRequiredProperty $Summary "performanceTargetCount") -ne 250 -or
      [int](Get-CcrPinnedRequiredProperty $Summary "sameGopAllowedPlanPercentMinimum") -ne 95 -or
      [long](Get-CcrPinnedRequiredProperty $Summary "sameGopP95MaximumUs") -ne 150000L -or
      [long](Get-CcrPinnedRequiredProperty $Summary "farRandomP95MaximumUs") -ne 300000L -or
      [long](Get-CcrPinnedRequiredProperty $Summary "overallP95MaximumUs") -ne 150000L -or
      (Get-CcrPinnedRequiredProperty $Summary "correctnessFailureBlocksPerformance") -ne $true -or
      [long](Get-CcrPinnedRequiredProperty $Summary "deviceMutationCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $Summary "buildCommandCount") -ne 0L -or
      (Get-CcrPinnedRequiredProperty $Summary "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Summary "containsRealMediaMetadata") -ne $false -or
      (($CurrentArtifactRecords | ConvertTo-Json -Depth 20 -Compress) -cne
        ((Get-CcrPinnedRequiredProperty $Summary "preRunArtifactRehash") | ConvertTo-Json -Depth 20 -Compress)) -or
      (($CurrentArtifactRecords | ConvertTo-Json -Depth 20 -Compress) -cne
        ((Get-CcrPinnedRequiredProperty $Summary "postRunArtifactRehash") | ConvertTo-Json -Depth 20 -Compress))) {
    throw "ALPHA6_RANDOM_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6RandomSettingsRestored {
  param([Parameter(Mandatory = $true)][object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings")) { throw "ALPHA6_RANDOM_SAVED_SETTINGS_MISSING" }
  foreach ($entry in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    if ((Get-CcrPinnedDeviceSetting $Context $entry[0] $entry[1]) -cne [string]$entry[2]) {
      throw "ALPHA6_RANDOM_SETTING_RESTORE_MISMATCH:$($entry[0])/$($entry[1])"
    }
  }
  return $true
}

function Assert-CcrAlpha6RandomNonNegativeInteger {
  param([object]$Value, [string]$Field, [bool]$AllowNull = $false)
  if ($null -eq $Value) {
    if ($AllowNull) { return $null }
    throw "ALPHA6_RANDOM_TARGET_FIELD_NULL:$Field"
  }
  $parsed = 0L
  if (-not [long]::TryParse(
      [string]$Value,
      [System.Globalization.NumberStyles]::Integer,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [ref]$parsed
    ) -or $parsed -lt 0L) {
    throw "ALPHA6_RANDOM_TARGET_FIELD_INVALID:$Field"
  }
  return $parsed
}

function Assert-CcrAlpha6RandomReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][string]$ExpectedKind,
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][ValidateSet("Stage1", "Stage2")][string]$ExpectedDecoderStage
  )
  if ([string](Get-CcrPinnedRequiredProperty $Report "kind") -cne $ExpectedKind -or
      [string](Get-CcrPinnedRequiredProperty $Report "status") -cne "PASS" -or
      [string](Get-CcrPinnedRequiredProperty $Report "applicationId") -cne $script:CcrPinnedAppPackage -or
      [string](Get-CcrPinnedRequiredProperty $Report "appVersionName") -cne $script:CcrPinnedVersionName -or
      [int](Get-CcrPinnedRequiredProperty $Report "appVersionCode") -ne $script:CcrPinnedVersionCode -or
      [string](Get-CcrPinnedRequiredProperty $Report "appCommitSha") -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [int](Get-CcrPinnedRequiredProperty $Report "fixtureCount") -ne 5 -or
      [int](Get-CcrPinnedRequiredProperty $Report "targetCount") -ne 250 -or
      [long](Get-CcrPinnedRequiredProperty $Report "mismatchCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $Report "writeOpenCount") -ne 0L) {
    throw "ALPHA6_RANDOM_REPORT_CONTRACT_MISMATCH:$ExpectedKind"
  }
  foreach ($field in @(
    "syntheticOnly", "containsRealMediaMetadata", "mediaFileNameIncluded", "mediaUriIncluded",
    "mediaPathIncluded", "mediaSourceHashIncluded"
  )) { Get-CcrPinnedRequiredProperty $Report $field | Out-Null }
  if ($Report.syntheticOnly -ne $true -or $Report.containsRealMediaMetadata -ne $false -or
      $Report.mediaFileNameIncluded -ne $false -or $Report.mediaUriIncluded -ne $false -or
      $Report.mediaPathIncluded -ne $false -or $Report.mediaSourceHashIncluded -ne $false) {
    throw "ALPHA6_RANDOM_REPORT_PRIVACY_MISMATCH:$ExpectedKind"
  }

  $allowedCategories = @(
    "cache-or-history-hit", "ahead-of-cursor", "same-gop", "adjacent-gop", "far-random"
  )
  $allowedPlans = @(
    "NO_OP", "CACHE_HIT", "HISTORY", "REVERSE_WINDOW", "SEQUENTIAL_AHEAD",
    "SAME_GOP_CURSOR", "PREVIOUS_SYNC", "PREPARED_AUXILIARY"
  )
  $fixtures = @((Get-CcrPinnedRequiredProperty $Report "fixtures"))
  if ($fixtures.Count -ne 5 -or @($fixtures.fixtureId | Select-Object -Unique).Count -ne 5) {
    throw "ALPHA6_RANDOM_FIXTURE_COUNT_MISMATCH:$ExpectedKind"
  }
  $observedTargetCount = 0
  foreach ($fixture in $fixtures) {
    $fixtureId = [string](Get-CcrPinnedRequiredProperty $fixture "fixtureId")
    $targets = @((Get-CcrPinnedRequiredProperty $fixture "targets"))
    if ([int](Get-CcrPinnedRequiredProperty $fixture "targetCount") -ne 50 -or
        [long](Get-CcrPinnedRequiredProperty $fixture "mismatchCount") -ne 0L -or
        $targets.Count -ne 50 -or
        [string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $fixture "targetSetIdentity"))) {
      throw "ALPHA6_RANDOM_FIXTURE_CONTRACT_MISMATCH:$ExpectedKind/$fixtureId"
    }
    if (-not $script:CcrAlpha6FrozenTargetSetIdentities.Contains($fixtureId) -or
        [string](Get-CcrPinnedRequiredProperty $fixture "targetSetIdentity") -cne
          [string]$script:CcrAlpha6FrozenTargetSetIdentities[$fixtureId]) {
      throw "ALPHA6_RANDOM_TARGET_SET_IDENTITY_MISMATCH:$ExpectedKind/$fixtureId"
    }
    foreach ($field in @(
      "cacheRejectionCount", "cacheThrashCount", "textureDoubleReleaseCount", "staleBeforeSwapCount",
      "swapFailureCount", "surfaceInvalidCount", "publicationInvariantViolationCount"
    )) {
      if ([long](Get-CcrPinnedRequiredProperty $fixture $field) -ne 0L) {
        throw "ALPHA6_RANDOM_FIXTURE_SAFETY_NONZERO:$ExpectedKind/$fixtureId/$field"
      }
    }
    $burst = Get-CcrPinnedRequiredProperty $fixture "burst"
    foreach ($field in @(
      "nonTargetPublishedCount", "nonFinalPublishedAfterFinalAcceptanceCount", "staleDiscardCount"
    )) {
      if ([long](Get-CcrPinnedRequiredProperty $burst $field) -ne 0L) {
        throw "ALPHA6_RANDOM_BURST_FINAL_ONLY_VIOLATION:$ExpectedKind/$fixtureId/$field"
      }
    }
    if ([int](Get-CcrPinnedRequiredProperty $burst "requestCount") -ne
        [int](Get-CcrPinnedRequiredProperty $burst "acceptedRequestCount") -or
        [long](Get-CcrPinnedRequiredProperty $burst "acceptedToPublicationUs") -lt 0L) {
      throw "ALPHA6_RANDOM_BURST_CONTRACT_MISMATCH:$ExpectedKind/$fixtureId"
    }

    $ordinals = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($target in $targets) {
      $ordinal = [int](Get-CcrPinnedRequiredProperty $target "ordinal")
      if (-not $ordinals.Add($ordinal)) { throw "ALPHA6_RANDOM_TARGET_ORDINAL_DUPLICATE:$fixtureId/$ordinal" }
      $category = [string](Get-CcrPinnedRequiredProperty $target "requestedCategory")
      $selectedPlan = [string](Get-CcrPinnedRequiredProperty $target "selectedPlan")
      if ($category -cnotin $allowedCategories -or $selectedPlan -cnotin $allowedPlans) {
        throw "ALPHA6_RANDOM_TARGET_PLAN_WIRE_INVALID:$fixtureId/$ordinal"
      }
      foreach ($field in @(
        "fallbackReason", "decoderCursorFrame", "previousSyncFrame", "estimatedOutputCount",
        "actualOutputCount", "seekCount", "flushCount", "auxiliaryUsed"
      )) { Get-CcrPinnedRequiredProperty $target $field | Out-Null }
      foreach ($field in @("decoderCursorFrame", "previousSyncFrame", "estimatedOutputCount", "actualOutputCount")) {
        Assert-CcrAlpha6RandomNonNegativeInteger (Get-CcrPinnedRequiredProperty $target $field) $field $true | Out-Null
      }
      foreach ($field in @("seekCount", "flushCount")) {
        Assert-CcrAlpha6RandomNonNegativeInteger (Get-CcrPinnedRequiredProperty $target $field) $field $false | Out-Null
      }
      $fallback = Get-CcrPinnedRequiredProperty $target "fallbackReason"
      if ($null -ne $fallback -and [string]::IsNullOrWhiteSpace([string]$fallback)) {
        throw "ALPHA6_RANDOM_TARGET_FALLBACK_REASON_INVALID:$fixtureId/$ordinal"
      }
      $auxiliaryUsed = Get-CcrPinnedRequiredProperty $target "auxiliaryUsed"
      if ($auxiliaryUsed -isnot [bool]) { throw "ALPHA6_RANDOM_TARGET_AUXILIARY_WIRE_INVALID:$fixtureId/$ordinal" }
      if ($ExpectedDecoderStage -ceq "Stage1" -and ($auxiliaryUsed -eq $true -or $selectedPlan -ceq "PREPARED_AUXILIARY")) {
        throw "ALPHA6_RANDOM_STAGE1_AUXILIARY_FORBIDDEN:$fixtureId/$ordinal"
      }
      if ($ExpectedDecoderStage -ceq "Stage2" -and $auxiliaryUsed -eq $true -and
          $selectedPlan -cne "PREPARED_AUXILIARY") {
        throw "ALPHA6_RANDOM_AUXILIARY_PLAN_MISMATCH:$fixtureId/$ordinal"
      }
      if ($selectedPlan -cin @("SEQUENTIAL_AHEAD", "SAME_GOP_CURSOR", "PREVIOUS_SYNC", "PREPARED_AUXILIARY")) {
        if ($null -eq (Get-CcrPinnedRequiredProperty $target "estimatedOutputCount") -or
            $null -eq (Get-CcrPinnedRequiredProperty $target "actualOutputCount")) {
          throw "ALPHA6_RANDOM_TARGET_OUTPUT_COUNT_MISSING:$fixtureId/$ordinal"
        }
      }
      if ([long](Get-CcrPinnedRequiredProperty $target "acceptedToPublicationUs") -lt 0L -or
          [long](Get-CcrPinnedRequiredProperty $target "staleDiscardCount") -ne 0L -or
          [long](Get-CcrPinnedRequiredProperty $target "nonTargetPublishedCount") -ne 0L -or
          [int](Get-CcrPinnedRequiredProperty $target "publishedDisplayedFrameIndex") -ne
            [int](Get-CcrPinnedRequiredProperty $target "targetFrameIndex")) {
        throw "ALPHA6_RANDOM_TARGET_EXACT_PUBLICATION_MISMATCH:$fixtureId/$ordinal"
      }
      $observedTargetCount += 1
    }
    if ($ordinals.Count -ne 50 -or @(0..49 | Where-Object { -not $ordinals.Contains([int]$_) }).Count -ne 0) {
      throw "ALPHA6_RANDOM_TARGET_ORDINAL_SET_MISMATCH:$ExpectedKind/$fixtureId"
    }
  }
  if ($observedTargetCount -ne 250) { throw "ALPHA6_RANDOM_TARGET_COUNT_MISMATCH:$ExpectedKind" }
  return $Report
}

function Get-CcrAlpha6RandomNearestRankPercentile {
  param([Parameter(Mandatory = $true)][long[]]$Values, [Parameter(Mandatory = $true)][double]$Fraction)
  if ($Values.Count -eq 0 -or $Fraction -le 0.0 -or $Fraction -gt 1.0) {
    throw "ALPHA6_RANDOM_PERCENTILE_INPUT_INVALID"
  }
  $sorted = @($Values | Sort-Object)
  $index = [Math]::Ceiling($sorted.Count * $Fraction) - 1
  return [long]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))]
}

function Get-CcrAlpha6RandomFlattenedTargets {
  param([Parameter(Mandatory = $true)][object]$Report)
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($fixture in @($Report.fixtures)) {
    foreach ($target in @($fixture.targets)) {
      $result.Add([PSCustomObject][ordered]@{
        fixtureId = [string]$fixture.fixtureId
        targetSetIdentity = [string]$fixture.targetSetIdentity
        target = $target
      }) | Out-Null
    }
  }
  return @($result | Sort-Object fixtureId, { [int]$_.target.ordinal })
}

function Assert-CcrAlpha6RandomGate {
  param(
    [Parameter(Mandatory = $true)][object]$ExactReport,
    [Parameter(Mandatory = $true)][object]$PerformanceReport,
    [Parameter(Mandatory = $true)][ValidateSet("Stage1", "Stage2")][string]$ExpectedDecoderStage
  )
  $exact = @(Get-CcrAlpha6RandomFlattenedTargets $ExactReport)
  $performance = @(Get-CcrAlpha6RandomFlattenedTargets $PerformanceReport)
  if ($exact.Count -ne 250 -or $performance.Count -ne 250) { throw "ALPHA6_RANDOM_EXACT_250_OF_250_FAILED" }
  $allLatencies = [System.Collections.Generic.List[long]]::new()
  $sameGopLatencies = [System.Collections.Generic.List[long]]::new()
  $farLatencies = [System.Collections.Generic.List[long]]::new()
  $sameGopAllowed = 0
  $sameGopCount = 0
  $planMatrix = [ordered]@{}
  $allowedSameGopPlans = @("CACHE_HIT", "SAME_GOP_CURSOR", "SEQUENTIAL_AHEAD")
  if ($ExpectedDecoderStage -ceq "Stage2") { $allowedSameGopPlans += "PREPARED_AUXILIARY" }

  for ($index = 0; $index -lt 250; $index += 1) {
    $left = $exact[$index]
    $right = $performance[$index]
    if ($left.fixtureId -cne $right.fixtureId -or $left.targetSetIdentity -cne $right.targetSetIdentity) {
      throw "ALPHA6_RANDOM_EXACT_PERFORMANCE_FIXTURE_IDENTITY_MISMATCH:$index"
    }
    foreach ($field in @(
      "ordinal", "requestedCategory", "setupFrameIndex", "targetFrameIndex", "targetPtsUs"
    )) {
      if ([string](Get-CcrPinnedRequiredProperty $left.target $field) -cne
          [string](Get-CcrPinnedRequiredProperty $right.target $field)) {
        throw "ALPHA6_RANDOM_EXACT_PERFORMANCE_TARGET_IDENTITY_MISMATCH:$index/$field"
      }
    }
    $target = $right.target
    $latency = [long]$target.acceptedToPublicationUs
    $category = [string]$target.requestedCategory
    $plan = [string]$target.selectedPlan
    $allLatencies.Add($latency) | Out-Null
    if (-not $planMatrix.Contains($category)) { $planMatrix[$category] = [ordered]@{} }
    if (-not $planMatrix[$category].Contains($plan)) { $planMatrix[$category][$plan] = 0 }
    $planMatrix[$category][$plan] = [int]$planMatrix[$category][$plan] + 1
    if ($category -ceq "same-gop") {
      $sameGopCount += 1
      $sameGopLatencies.Add($latency) | Out-Null
      if ($plan -cin $allowedSameGopPlans) { $sameGopAllowed += 1 }
    }
    if ($category -ceq "far-random") { $farLatencies.Add($latency) | Out-Null }
  }
  if ($sameGopCount -eq 0 -or $farLatencies.Count -eq 0) { throw "ALPHA6_RANDOM_REQUIRED_CATEGORY_EMPTY" }
  if (($sameGopAllowed * 100) -lt ($sameGopCount * 95)) {
    throw "ALPHA6_RANDOM_SAME_GOP_ALLOWED_PLAN_RATIO_BELOW_95"
  }
  $sameGopP95Us = Get-CcrAlpha6RandomNearestRankPercentile $sameGopLatencies.ToArray() 0.95
  $farP95Us = Get-CcrAlpha6RandomNearestRankPercentile $farLatencies.ToArray() 0.95
  $overallP95Us = Get-CcrAlpha6RandomNearestRankPercentile $allLatencies.ToArray() 0.95
  $overallMaxUs = [long](($allLatencies | Measure-Object -Maximum).Maximum)
  if ($sameGopP95Us -gt 150000L) { throw "ALPHA6_RANDOM_SAME_GOP_P95_EXCEEDED" }
  if ($farP95Us -gt 300000L) { throw "ALPHA6_RANDOM_FAR_P95_EXCEEDED" }
  if ($overallP95Us -gt 150000L) { throw "ALPHA6_RANDOM_OVERALL_P95_EXCEEDED" }
  if ($overallMaxUs -gt 406783L) { throw "ALPHA6_RANDOM_MAX_REGRESSION" }
  return [PSCustomObject][ordered]@{
    status = "PASS"
    exactTargets = 250
    exactMatches = 250
    mismatchCount = 0L
    decoderStage = $ExpectedDecoderStage
    sameGopAllowedPlanCount = $sameGopAllowed
    sameGopTargetCount = $sameGopCount
    sameGopAllowedPlanPercent = [Math]::Round(($sameGopAllowed * 100.0) / $sameGopCount, 3)
    sameGopP50Us = Get-CcrAlpha6RandomNearestRankPercentile $sameGopLatencies.ToArray() 0.50
    sameGopP95Us = $sameGopP95Us
    sameGopMaxUs = [long](($sameGopLatencies | Measure-Object -Maximum).Maximum)
    farP50Us = Get-CcrAlpha6RandomNearestRankPercentile $farLatencies.ToArray() 0.50
    farP95Us = $farP95Us
    farMaxUs = [long](($farLatencies | Measure-Object -Maximum).Maximum)
    overallP50Us = Get-CcrAlpha6RandomNearestRankPercentile $allLatencies.ToArray() 0.50
    overallP95Us = $overallP95Us
    overallMaxUs = $overallMaxUs
    alpha5ObservedMaxUs = 406783L
    maxComparison = "NOT_GREATER_THAN_ALPHA5_OBSERVED_MAX"
    categorySelectedPlanMatrix = $planMatrix
    burstFinalTargetOnly = $true
    approximatePreviewUsed = $false
  }
}

function Start-CcrAlpha6RandomTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$RemotePath)
  if ($RemotePath -notmatch '^/data/local/tmp/ccr-alpha6-random-[A-Za-z0-9._-]+\.atrace$') {
    throw "ALPHA6_RANDOM_TRACE_PATH_INVALID"
  }
  $categories = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace", "--list_categories")
  if ($categories.exitCode -ne 0 -or $categories.output -notmatch '(?m)^\s*view\s+-') {
    throw "ALPHA6_RANDOM_ATRACE_VIEW_UNAVAILABLE"
  }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA6_RANDOM_STALE_TRACE_CLEAR_FAILED" }
  $start = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "shell", "atrace", "--async_start", "-c", "-b", "65536",
    "-a", $script:CcrPinnedAppPackage, "view"
  )
  if ($start.exitCode -ne 0) { throw "ALPHA6_RANDOM_TRACE_START_FAILED" }
}

function Stop-CcrAlpha6RandomTrace {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath
  )
  if (Test-Path -LiteralPath $LocalPath) { throw "ALPHA6_RANDOM_LOCAL_TRACE_ALREADY_EXISTS" }
  $stop = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace --async_stop > $RemotePath")
  if ($stop.exitCode -ne 0) { throw "ALPHA6_RANDOM_TRACE_STOP_FAILED" }
  $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $RemotePath, $LocalPath)
  if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $LocalPath -PathType Leaf) -or
      (Get-Item -LiteralPath $LocalPath).Length -le 0) {
    throw "ALPHA6_RANDOM_TRACE_PULL_FAILED"
  }
  return [System.IO.Path]::GetFullPath($LocalPath)
}

function Assert-CcrAlpha6RandomTrace {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 256) {
    throw "ALPHA6_RANDOM_TRACE_INVALID"
  }
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  foreach ($marker in @("TRACE:", "CCR.request.accept", "CCR.publish", "CCR.swap")) {
    if (-not $text.Contains($marker)) { throw "ALPHA6_RANDOM_TRACE_MARKER_MISSING:$marker" }
  }
  return Get-CcrAlpha6RandomFileRecord $Path
}

function Remove-CcrAlpha6RandomRemoteTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [string]$RemotePath)
  if ([string]::IsNullOrWhiteSpace($RemotePath)) { return }
  if ($RemotePath -notmatch '^/data/local/tmp/ccr-alpha6-random-[A-Za-z0-9._-]+\.atrace$') {
    throw "ALPHA6_RANDOM_REMOTE_TRACE_PATH_INVALID"
  }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA6_RANDOM_REMOTE_TRACE_REMOVE_FAILED" }
  $verify = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "ls", "-d", $RemotePath)
  if ($verify.exitCode -eq 0) { throw "ALPHA6_RANDOM_REMOTE_TRACE_STILL_PRESENT" }
}

function Assert-CcrAlpha6RandomCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][ValidateSet("Exactness", "Performance")][string]$Stage,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ([string](Get-CcrPinnedRequiredProperty $Checkpoint "kind") -cne "alpha6-random-checkpoint" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "status") -cne "PASS" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "stage") -cne $Stage) {
    throw "ALPHA6_RANDOM_CHECKPOINT_CONTRACT_MISMATCH:$Stage"
  }
  Assert-CcrAlpha6RandomIdentity (Get-CcrPinnedRequiredProperty $Checkpoint "identity") $Context | Out-Null
  Assert-CcrAlpha6RandomFileRecord (Get-CcrPinnedRequiredProperty $Checkpoint "report") $Context.OutputDirectory | Out-Null
  if ($Stage -ceq "Performance") {
    Assert-CcrAlpha6RandomFileRecord (Get-CcrPinnedRequiredProperty $Checkpoint "trace") $Context.OutputDirectory | Out-Null
    if ([string](Get-CcrPinnedRequiredProperty (Get-CcrPinnedRequiredProperty $Checkpoint "gate") "status") -cne "PASS") {
      throw "ALPHA6_RANDOM_PERFORMANCE_CHECKPOINT_GATE_MISMATCH"
    }
  }
  return $Checkpoint
}

$androidTools = Get-CcrPinnedAndroidSdkTools
$effectiveAdbInvoker = New-CcrAlpha6TimedAdbInvoker ([string]$androidTools.Adb) $adbDeadlineState
$hostPreflightRunId = if ($Resume) { "$RunId-resume-$([Guid]::NewGuid().ToString('N'))" } else { $RunId }
$context = Invoke-CcrAlpha6PinnedHostPreflight `
  -ArtifactManifest $ArtifactManifest `
  -ArtifactManifestSha256 $ArtifactManifestSha256 `
  -OutputDirectory $OutputDirectory `
  -RunId $hostPreflightRunId `
  -RuntimeSourceSha $RuntimeSourceSha `
  -HarnessSourceSha $HarnessSourceSha `
  -RuntimeInputsTreeSha256 $RuntimeInputsTreeSha256 `
  -ExpectedDebugAppSha256 $ExpectedDebugAppSha256 `
  -PreflightOnly ([bool]$PreflightOnly) `
  -BuildCommandCount 0L `
  -ValidationScriptPaths $closedValidationScripts `
  -AndroidTools $androidTools
$context | Add-Member -Force -NotePropertyName AndroidTools -NotePropertyValue $androidTools
$context | Add-Member -Force -NotePropertyName Adb -NotePropertyValue ([string]$androidTools.Adb
)
$context | Add-Member -Force -NotePropertyName AdbInvoker -NotePropertyValue $effectiveAdbInvoker

if (-not $PreflightOnly) {
  $device = Get-CcrPinnedS24Device $androidTools.Adb $effectiveAdbInvoker
  foreach ($name in @("Serial", "Model", "Fingerprint", "SecurityPatch", "Sdk")) {
    $context | Add-Member -Force -NotePropertyName $name -NotePropertyValue $device.$name
  }
}

$sessionPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-random-session-$RunId.json"
$exactCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-random-exactness-$RunId.json"
$performanceCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-random-performance-$RunId.json"
$summaryPath = Join-Path $context.OutputDirectory "alpha6-random-summary-$RunId.json"
$identity = New-CcrAlpha6RandomIdentity $context

if ($Resume) {
  if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { throw "ALPHA6_RANDOM_SESSION_MISSING" }
  $session = [System.IO.File]::ReadAllText($sessionPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  if ([string](Get-CcrPinnedRequiredProperty $session "kind") -cne "alpha6-random-session" -or
      [string](Get-CcrPinnedRequiredProperty $session "status") -cne "IN_PROGRESS" -or
      [int](Get-CcrPinnedRequiredProperty $session "maxMinutes") -ne $MaxMinutes -or
      [string](Get-CcrPinnedRequiredProperty $session "originalStayAwakeSetting") -cne $OriginalStayAwakeSetting -or
      [string](Get-CcrPinnedRequiredProperty $session "originalScreenTimeoutSetting") -cne $OriginalScreenTimeoutSetting) {
    throw "ALPHA6_RANDOM_SESSION_CONTRACT_MISMATCH"
  }
  Assert-CcrAlpha6RandomIdentity (Get-CcrPinnedRequiredProperty $session "identity") $context | Out-Null
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $expectedStatus = if ($PreflightOnly) { "PREFLIGHT_PASS" } else { "PASS" }
    if ([string](Get-CcrPinnedRequiredProperty $existing "status") -cne $expectedStatus) {
      throw "ALPHA6_RANDOM_RESUME_SUMMARY_STATUS_MISMATCH"
    }
    Assert-CcrAlpha6RandomIdentity (Get-CcrPinnedRequiredProperty $existing "identity") $context | Out-Null
    if ($PreflightOnly) {
      Assert-CcrAlpha6RandomPreflightSummary `
        $existing $MaxMinutes @(Get-CcrAlpha6RandomArtifactRecords $context) | Out-Null
    } else {
      if (-not (Test-Path -LiteralPath $exactCheckpointPath -PathType Leaf) -or
          -not (Test-Path -LiteralPath $performanceCheckpointPath -PathType Leaf)) {
        throw "ALPHA6_RANDOM_RESUME_COMPLETED_CHECKPOINT_MISSING"
      }
      $completedExact = [System.IO.File]::ReadAllText(
        $exactCheckpointPath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      $completedPerformance = [System.IO.File]::ReadAllText(
        $performanceCheckpointPath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      Assert-CcrAlpha6RandomCheckpoint $completedExact "Exactness" $context | Out-Null
      Assert-CcrAlpha6RandomCheckpoint $completedPerformance "Performance" $context | Out-Null
      Assert-CcrAlpha6RandomCompletedSummary $existing $completedExact $completedPerformance $MaxMinutes | Out-Null
      $completedExactPath = Assert-CcrAlpha6RandomFileRecord $completedExact.report $context.OutputDirectory
      $completedPerformancePath = Assert-CcrAlpha6RandomFileRecord $completedPerformance.report $context.OutputDirectory
      $completedTracePath = Assert-CcrAlpha6RandomFileRecord $completedPerformance.trace $context.OutputDirectory
      $completedExactReport = [System.IO.File]::ReadAllText(
        $completedExactPath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      $completedPerformanceReport = [System.IO.File]::ReadAllText(
        $completedPerformancePath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      Assert-CcrPinnedReport `
        -Report $completedExactReport -ArtifactSet $context.ArtifactSet -RunId ([string]$completedExact.runId) `
        -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha6-cost-aware-random-exactness" `
        -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
      Assert-CcrPinnedReport `
        -Report $completedPerformanceReport -ArtifactSet $context.ArtifactSet -RunId ([string]$completedPerformance.runId) `
        -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha6-cost-aware-random-performance" `
        -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
      Assert-CcrAlpha6RandomReport $completedExactReport "alpha6-cost-aware-random-exactness" $context $DecoderStage | Out-Null
      Assert-CcrAlpha6RandomReport $completedPerformanceReport "alpha6-cost-aware-random-performance" $context $DecoderStage | Out-Null
      Assert-CcrAlpha6RandomTrace $completedTracePath | Out-Null
      $completedGate = Assert-CcrAlpha6RandomGate $completedExactReport $completedPerformanceReport $DecoderStage
      if (($completedGate | ConvertTo-Json -Depth 30 -Compress) -cne
          ($completedPerformance.gate | ConvertTo-Json -Depth 30 -Compress) -or
          ($completedGate | ConvertTo-Json -Depth 30 -Compress) -cne
          ($existing.performanceGate | ConvertTo-Json -Depth 30 -Compress)) {
        throw "ALPHA6_RANDOM_RESUME_COMPLETED_GATE_MISMATCH"
      }
    }
    Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
    return
  }
} else {
  if (Test-Path -LiteralPath $sessionPath) { throw "ALPHA6_RANDOM_SESSION_ALREADY_EXISTS" }
  Write-CcrAlpha6RandomImmutableJson $sessionPath ([ordered]@{
    schemaVersion = 1
    kind = "alpha6-random-session"
    status = "IN_PROGRESS"
    maxMinutes = $MaxMinutes
    originalStayAwakeSetting = $OriginalStayAwakeSetting
    originalScreenTimeoutSetting = $OriginalScreenTimeoutSetting
    identity = $identity
    stageOrder = @("Exactness", "Performance")
    resumeContract = "completed-stage-only; exact artifact, script hash, source and device identity"
    correctnessFailureBlocksPerformance = $true
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }) | Out-Null
}

$preRunArtifactRehash = @(Get-CcrAlpha6RandomArtifactRecords $context)
Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
if ($PreflightOnly) {
  $postRunArtifactRehash = @(Get-CcrAlpha6RandomArtifactRecords $context)
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  Write-CcrAlpha6RandomImmutableJson $summaryPath ([ordered]@{
    schemaVersion = 1
    kind = "alpha6-random-preflight"
    status = "PREFLIGHT_PASS"
    identity = $identity
    maxMinutes = $MaxMinutes
    stageOrder = @("Exactness", "Performance")
    exactnessTargetCount = 250
    performanceTargetCount = 250
    sameGopAllowedPlanPercentMinimum = 95
    sameGopP95MaximumUs = 150000
    farRandomP95MaximumUs = 300000
    overallP95MaximumUs = 150000
    correctnessFailureBlocksPerformance = $true
    deviceMutationCount = 0L
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }) | Out-Null
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}

$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null
$settingsSaved = $false
$traceStarted = $false
$traceStopped = $false
$remoteTracePath = $null
$localTracePath = $null
$recoveredTrace = $null
$exactCheckpoint = $null
$performanceCheckpoint = $null
$postRunArtifactRehash = $null
$currentPhase = "device-settings"
$settingsPreflight = $null
$resumeRestoreBaseline = $null
if ($Resume) {
  $initialSettingsPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-random-device-settings-$RunId.json"
  if (Test-Path -LiteralPath $initialSettingsPath -PathType Leaf) {
    $initialSettings = [System.IO.File]::ReadAllText($initialSettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string](Get-CcrPinnedRequiredProperty $initialSettings "kind") -cne "alpha6-device-settings-preflight" -or
        [string](Get-CcrPinnedRequiredProperty $initialSettings "status") -cne "PASS" -or
        [string](Get-CcrPinnedRequiredProperty $initialSettings "runId") -cne $RunId) {
      throw "ALPHA6_RANDOM_RESUME_SETTINGS_BASELINE_CONTRACT_MISMATCH"
    }
    Assert-CcrAlpha6RandomIdentity (Get-CcrPinnedRequiredProperty $initialSettings "identity") $context | Out-Null
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
  $settingsPreflightPath = Join-Path $context.OutputDirectory "checkpoint-alpha6-random-device-settings-$hostPreflightRunId.json"
  if (Test-Path -LiteralPath $settingsPreflightPath) { throw "ALPHA6_RANDOM_SETTINGS_PREFLIGHT_ALREADY_EXISTS" }
  Write-CcrAlpha6RandomImmutableJson $settingsPreflightPath $settingsPreflight | Out-Null
  if ([string]$settingsPreflight.status -cne "PASS") {
    throw "ALPHA6_RANDOM_STALE_DEVICE_SETTINGS_REQUIRE_TRUSTED_ORIGINAL"
  }
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_brightness_mode" "0"
  Set-CcrPinnedDeviceSetting $context "system" "screen_brightness" "128"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"
  Assert-CcrAlpha6RandomDeadline "before-install"
  Install-CcrPinnedArtifactSet $context "Debug"
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null

  $currentPhase = "exactness"
  if ($Resume -and (Test-Path -LiteralPath $exactCheckpointPath -PathType Leaf)) {
    $exactCheckpoint = [System.IO.File]::ReadAllText($exactCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha6RandomCheckpoint $exactCheckpoint "Exactness" $context | Out-Null
    $exactPath = Assert-CcrAlpha6RandomFileRecord $exactCheckpoint.report $context.OutputDirectory
    $exactReport = [System.IO.File]::ReadAllText($exactPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrPinnedReport `
      -Report $exactReport -ArtifactSet $context.ArtifactSet -RunId ([string]$exactCheckpoint.runId) `
      -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha6-cost-aware-random-exactness" `
      -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
    Assert-CcrAlpha6RandomReport $exactReport "alpha6-cost-aware-random-exactness" $context $DecoderStage | Out-Null
  } else {
    Assert-CcrAlpha6RandomDeadline "before-exactness"
    $exactRunId = New-CcrPinnedRunId $context.OutputDirectory "a6-random-exact"
    $exactName = "s24-alpha6-random-exactness-v1.json"
    Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $exactName
    $exactInvocation = Invoke-CcrPinnedInstrumentation `
      -Context $context -TestRole "debugTest" `
      -ClassName "com.snowberried.ctcinereviewer.gate.Alpha6RandomSeekExactnessTest#deterministicRandomTargetsRemainExact" `
      -RunId $exactRunId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $context.OutputDirectory "failure-$exactRunId-instrumentation-v1.json")
    Assert-CcrAlpha6RandomDeadline "after-exactness-instrumentation"
    $receivedExact = Receive-CcrPinnedReport `
      -Context $context -ReportName $exactName -RunId $exactRunId `
      -AppRole "debugApp" -TestRole "debugTest" `
      -MinimumStartedAtElapsedRealtimeNs $exactInvocation.MinimumStartedAtElapsedRealtimeNs `
      -ExpectedKind "alpha6-cost-aware-random-exactness" `
      -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
    $exactReport = $receivedExact.Report
    Assert-CcrAlpha6RandomReport $exactReport "alpha6-cost-aware-random-exactness" $context $DecoderStage | Out-Null
    (Get-Item -LiteralPath $receivedExact.Path).IsReadOnly = $true
    $exactCheckpoint = [ordered]@{
      schemaVersion = 1
      kind = "alpha6-random-checkpoint"
      status = "PASS"
      stage = "Exactness"
      identity = $identity
      runId = $exactRunId
      report = Get-CcrAlpha6RandomFileRecord $receivedExact.Path
      exactTargets = 250
      exactMatches = 250
      mismatchCount = 0L
      completedAtUtc = [DateTime]::UtcNow.ToString("o")
      buildCommandCount = 0L
    }
    Write-CcrAlpha6RandomImmutableJson $exactCheckpointPath $exactCheckpoint | Out-Null
  }

  # The performance instrumentation is deliberately unreachable unless the
  # exact same artifact set has a revalidated 250/250 exact checkpoint.
  Assert-CcrAlpha6RandomCheckpoint $exactCheckpoint "Exactness" $context | Out-Null
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  $currentPhase = "performance"
  if ($Resume -and (Test-Path -LiteralPath $performanceCheckpointPath -PathType Leaf)) {
    $performanceCheckpoint = [System.IO.File]::ReadAllText($performanceCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha6RandomCheckpoint $performanceCheckpoint "Performance" $context | Out-Null
    $performancePath = Assert-CcrAlpha6RandomFileRecord $performanceCheckpoint.report $context.OutputDirectory
    $tracePath = Assert-CcrAlpha6RandomFileRecord $performanceCheckpoint.trace $context.OutputDirectory
    $performanceReport = [System.IO.File]::ReadAllText($performancePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrPinnedReport `
      -Report $performanceReport -ArtifactSet $context.ArtifactSet -RunId ([string]$performanceCheckpoint.runId) `
      -AppRole "debugApp" -TestRole "debugTest" -ExpectedKind "alpha6-cost-aware-random-performance" `
      -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1 | Out-Null
    Assert-CcrAlpha6RandomReport $performanceReport "alpha6-cost-aware-random-performance" $context $DecoderStage | Out-Null
    Assert-CcrAlpha6RandomTrace $tracePath | Out-Null
    $recomputedGate = Assert-CcrAlpha6RandomGate $exactReport $performanceReport $DecoderStage
    if (($recomputedGate | ConvertTo-Json -Depth 30 -Compress) -cne
        ($performanceCheckpoint.gate | ConvertTo-Json -Depth 30 -Compress)) {
      throw "ALPHA6_RANDOM_RESUME_GATE_MISMATCH"
    }
  } else {
    Assert-CcrAlpha6RandomDeadline "before-performance"
    $performanceRunId = New-CcrPinnedRunId $context.OutputDirectory "a6-random-perf"
    $performanceName = "s24-alpha6-random-performance-v1.json"
    Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $performanceName
    $remoteTracePath = "/data/local/tmp/ccr-alpha6-random-$performanceRunId.atrace"
    $localTracePath = Join-Path $context.OutputDirectory "$performanceRunId-alpha6-random.atrace"
    Start-CcrAlpha6RandomTrace $context $remoteTracePath
    $traceStarted = $true
    $instrumentationFailure = $null
    $traceFailure = $null
    try {
      $performanceInvocation = Invoke-CcrPinnedInstrumentation `
        -Context $context -TestRole "debugTest" `
        -ClassName "com.snowberried.ctcinereviewer.gate.Alpha6RandomSeekPerformanceTest#deterministicCostAwareRandomSeekAlpha6" `
        -RunId $performanceRunId -ExpectedTestCount 1 `
        -FailureReportPath (Join-Path $context.OutputDirectory "failure-$performanceRunId-instrumentation-v1.json")
    } catch { $instrumentationFailure = $_ } finally {
      try {
        Stop-CcrAlpha6RandomTrace $context $remoteTracePath $localTracePath | Out-Null
        $traceStopped = $true
      } catch { $traceFailure = $_ }
    }
    if ($null -ne $instrumentationFailure -and $null -ne $traceFailure) {
      throw "INSTRUMENTATION=$($instrumentationFailure.Exception.Message); TRACE=$($traceFailure.Exception.Message)"
    }
    if ($null -ne $instrumentationFailure) { throw $instrumentationFailure }
    if ($null -ne $traceFailure) { throw $traceFailure }
    Assert-CcrAlpha6RandomDeadline "after-performance-instrumentation"
    $receivedPerformance = Receive-CcrPinnedReport `
      -Context $context -ReportName $performanceName -RunId $performanceRunId `
      -AppRole "debugApp" -TestRole "debugTest" `
      -MinimumStartedAtElapsedRealtimeNs $performanceInvocation.MinimumStartedAtElapsedRealtimeNs `
      -ExpectedKind "alpha6-cost-aware-random-performance" `
      -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
    $performanceReport = $receivedPerformance.Report
    Assert-CcrAlpha6RandomReport $performanceReport "alpha6-cost-aware-random-performance" $context $DecoderStage | Out-Null
    $traceRecord = Assert-CcrAlpha6RandomTrace $localTracePath
    $gate = Assert-CcrAlpha6RandomGate $exactReport $performanceReport $DecoderStage
    (Get-Item -LiteralPath $receivedPerformance.Path).IsReadOnly = $true
    (Get-Item -LiteralPath $localTracePath).IsReadOnly = $true
    $performanceCheckpoint = [ordered]@{
      schemaVersion = 1
      kind = "alpha6-random-checkpoint"
      status = "PASS"
      stage = "Performance"
      identity = $identity
      runId = $performanceRunId
      report = Get-CcrAlpha6RandomFileRecord $receivedPerformance.Path
      trace = $traceRecord
      gate = $gate
      completedAtUtc = [DateTime]::UtcNow.ToString("o")
      buildCommandCount = 0L
    }
    Write-CcrAlpha6RandomImmutableJson $performanceCheckpointPath $performanceCheckpoint | Out-Null
  }
  Assert-CcrAlpha6RandomCheckpoint $performanceCheckpoint "Performance" $context | Out-Null
  Assert-CcrAlpha6RandomDeadline "complete"
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6RandomArtifactRecords $context)
} catch {
  $primaryFailure = $_
  try {
    $postRunArtifactRehash = @(Get-CcrAlpha6RandomArtifactRecords $context)
    Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  } catch { $cleanupFailures.Add("ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null }
} finally {
  $adbDeadlineState.CleanupMode = $true
  $adbDeadlineState.CleanupDeadlineUtc = [DateTime]::UtcNow.AddMinutes(2)
  if ($traceStarted -and -not $traceStopped) {
    try {
      $recoveryPath = Join-Path $context.OutputDirectory "failure-$hostPreflightRunId-alpha6-random.atrace"
      if (-not (Test-Path -LiteralPath $recoveryPath)) {
        Stop-CcrAlpha6RandomTrace $context $remoteTracePath $recoveryPath | Out-Null
        $recoveredTrace = Get-CcrAlpha6RandomFileRecord $recoveryPath
        (Get-Item -LiteralPath $recoveryPath).IsReadOnly = $true
      } else {
        $emergencyStop = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "atrace", "--async_stop")
        if ($emergencyStop.exitCode -ne 0) { throw "ALPHA6_RANDOM_TRACE_EMERGENCY_STOP_FAILED" }
      }
      $traceStopped = $true
    } catch { $cleanupFailures.Add("TRACE_RECOVERY:$($_.Exception.Message)") | Out-Null }
  }
  if ($remoteTracePath) {
    try { Remove-CcrAlpha6RandomRemoteTrace $context $remoteTracePath } catch {
      $cleanupFailures.Add("REMOTE_TRACE_CLEANUP:$($_.Exception.Message)") | Out-Null
    }
  }
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch { $cleanupFailures.Add("PACKAGE_CLEANUP:$($_.Exception.Message)") | Out-Null }
  if ($settingsSaved) {
    try { Assert-CcrAlpha6RandomSettingsRestored $context | Out-Null } catch {
      $cleanupFailures.Add("SETTINGS_RESTORE:$($_.Exception.Message)") | Out-Null
    }
  }
  try { Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null } catch {
    $cleanupFailures.Add("FINAL_ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
  if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
    $failurePath = Join-Path $context.OutputDirectory "failure-alpha6-random-$hostPreflightRunId.json"
    if (-not (Test-Path -LiteralPath $failurePath)) {
      try {
        Write-CcrAlpha6RandomImmutableJson $failurePath ([ordered]@{
          schemaVersion = 1
          kind = "alpha6-random-failure"
          status = "FAIL"
          phase = $currentPhase
          message = if ($null -ne $primaryFailure) { $primaryFailure.Exception.Message } else { "CLEANUP_FAILED" }
          identity = $identity
          recoveredTrace = $recoveredTrace
          cleanupFailures = @($cleanupFailures)
          postRunArtifactRehash = $postRunArtifactRehash
          performanceCountedAsSuccess = $false
          deviceSettingsPreflight = $settingsPreflight
          buildCommandCount = 0L
          syntheticOnly = $true
          containsRealMediaMetadata = $false
        }) | Out-Null
      } catch { }
    }
  }
}

if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }

$summary = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-cost-aware-random-gate"
  status = "PASS"
  identity = $identity
  maxMinutes = $MaxMinutes
  exactness = $exactCheckpoint
  performance = $performanceCheckpoint
  performanceGate = $performanceCheckpoint.gate
  deviceSettingsPreflight = $settingsPreflight
  exactness250Of250 = $true
  correctnessFailureBlocksPerformance = $true
  preRunArtifactRehash = $preRunArtifactRehash
  postRunArtifactRehash = $postRunArtifactRehash
  traceRequiredForSuccess = $true
  buildCommandCount = 0L
  syntheticOnly = $true
  containsRealMediaMetadata = $false
}
Write-CcrAlpha6RandomImmutableJson $summaryPath $summary | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
