param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
  [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
  [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
  [string]$ExpectedVersionName = "0.2.0-alpha.6",
  [int]$ExpectedVersionCode = 7,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$RunId,
  [ValidateRange(1, 240)][int]$MaxMinutes = 120,
  [AllowEmptyString()][string]$OriginalStayAwakeSetting = "",
  [AllowEmptyString()][string]$OriginalScreenTimeoutSetting = "",
  [switch]$Resume,
  [switch]$PreflightOnly,
  [switch]$SurfaceTransitionGateOnly,
  [Parameter(DontShow = $true)][object]$TestOnlyAndroidTools = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyIdentityReader = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySourceIdentityVerifier = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyAdbInvoker = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyIdentitySmokeExecutor = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyFixtureOpenSmokeExecutor = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySettingsSettleExecutor = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyRenderOpenSmokeExecutor = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyStageExecutor = $null
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$candidateBridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
$candidateArtifactsPath = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
$candidateSigningCommonPath = Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"
$alpha6HistoricalPinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinnedPath = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
$tailContractPath = Join-Path $PSScriptRoot "alpha6-tail-contract.ps1"
. $candidateBridgePath
. $tailContractPath

$testHookUsed = $null -ne $TestOnlyAndroidTools -or $null -ne $TestOnlyIdentityReader -or
  $null -ne $TestOnlySourceIdentityVerifier -or $null -ne $TestOnlyAdbInvoker -or
  $null -ne $TestOnlyIdentitySmokeExecutor -or
  $null -ne $TestOnlyFixtureOpenSmokeExecutor -or
  $null -ne $TestOnlySettingsSettleExecutor -or
  $null -ne $TestOnlyRenderOpenSmokeExecutor -or $null -ne $TestOnlyStageExecutor
if ($testHookUsed -and $env:CCR_ALPHA6_STAGE1_TEST_MODE -cne "1") {
  throw "ALPHA6_STAGE1_TEST_HOOK_FORBIDDEN"
}
if ($SurfaceTransitionGateOnly -and ($Resume -or $PreflightOnly)) {
  throw "ALPHA6_STAGE1_SURFACE_TRANSITION_MODE_CONFLICT"
}

Assert-CcrPinnedRunId $RunId | Out-Null
# The longest performance suffix ("-a6-hevc-m5") must fit the app's 48-character run ID contract.
if ($RunId.Length -gt 37) { throw "ALPHA6_STAGE1_RUN_ID_TOO_LONG" }
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
$adbDeadlineState = [PSCustomObject]@{
  ValidationDeadlineUtc = $deadlineUtc
  CleanupMode = $false
  CleanupDeadlineUtc = $deadlineUtc
}
$closedValidationScripts = @(
  $runnerPath,
  [System.IO.Path]::GetFullPath($candidateBridgePath),
  [System.IO.Path]::GetFullPath($candidateArtifactsPath),
  [System.IO.Path]::GetFullPath($candidateSigningCommonPath),
  [System.IO.Path]::GetFullPath($alpha6HistoricalPinnedPath),
  [System.IO.Path]::GetFullPath($basePinnedPath),
  [System.IO.Path]::GetFullPath($tailContractPath)
)
if (@($closedValidationScripts | Select-Object -Unique).Count -ne 7) {
  throw "ALPHA6_STAGE1_CLOSED_SCRIPT_SET_INVALID"
}
$script:CcrAlpha6Stage1StageOrder =
  @("IdentitySmoke", "FixtureOpenSmoke", "DeviceSettings", "SettingsSettle", "RenderOpenSmoke", "Correctness", "Performance")
$script:CcrAlpha6Stage1StageOrderToken = $script:CcrAlpha6Stage1StageOrder -join "|"
$script:CcrAlpha6SurfaceTransitionRenderOpenRequiredCount = 10L

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

function Get-CcrAlpha6Stage1Sha256Text {
  param([Parameter(Mandatory = $true)][string]$Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString(
        $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
      )).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-CcrAlpha6Stage1Identity {
  param([Parameter(Mandatory = $true)][object]$Context)
  $revision = [int](Get-CcrPinnedRequiredProperty $Context.ArtifactSet.Manifest "artifactSetRevision")
  if ($revision -ne 5) { throw "ALPHA6_STAGE1_CANDIDATE_REVISION_MISMATCH" }
  $signing = Get-CcrPinnedRequiredProperty $Context "PublicSigningIdentity"
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
    artifactSetRevision = $revision
    signingMode = [string](Get-CcrPinnedRequiredProperty $signing "signingMode")
    candidateSigning = [bool](Get-CcrPinnedRequiredProperty $signing "candidateSigning")
    signingLineage = [string](Get-CcrPinnedRequiredProperty $signing "signingLineage")
    expectedSigningCertificateSha256 = [string](Get-CcrPinnedRequiredProperty $signing "expectedSigningCertificateSha256")
    publicSigningPolicySha256 = [string](Get-CcrPinnedRequiredProperty $signing.publicPolicy "sha256")
    publicSigningPolicy = Get-CcrPinnedRequiredProperty $signing "publicPolicy"
    publicSigningFingerprint = Get-CcrPinnedRequiredProperty $signing "publicFingerprint"
    publicSigningCertificate = Get-CcrPinnedRequiredProperty $signing "publicCertificate"
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    versionName = $script:CcrPinnedVersionName
    versionCode = $script:CcrPinnedVersionCode
    applicationId = $script:CcrPinnedAppPackage
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    artifacts = @(Get-CcrAlpha6Stage1ArtifactRecords $Context)
    closedValidationScripts = @($Context.ValidationScripts)
    stageOrder = @($script:CcrAlpha6Stage1StageOrder)
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

function Assert-CcrAlpha6Stage1IdentitySmokeCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context
  )
  $result = Get-CcrPinnedRequiredProperty $Checkpoint "result"
  if ([string](Get-CcrPinnedRequiredProperty $Checkpoint "kind") -cne "alpha6-stage1-identity-smoke" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "deviceSettingsMutationCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "buildCommandCount") -ne 0L -or
      [string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $result "debugArtifactInstallSetCount") -ne 1L -or
      [long](Get-CcrPinnedRequiredProperty $result "debugArtifactInstallCommandCount") -ne 2L) {
    throw "ALPHA6_STAGE1_IDENTITY_SMOKE_CHECKPOINT_INVALID"
  }
  Assert-CcrAlpha6Stage1Identity (Get-CcrPinnedRequiredProperty $Checkpoint "identity") $Context | Out-Null
  return $true
}

function Assert-CcrAlpha6Stage1FixtureOpenSmokeCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context
  )
  $result = Get-CcrPinnedRequiredProperty $Checkpoint "result"
  $expectedChildRunId = "$([string](Get-CcrPinnedRequiredProperty $Checkpoint 'attemptRunId'))-fx"
  if ([string](Get-CcrPinnedRequiredProperty $Checkpoint "kind") -cne
        "alpha6-stage1-fixture-open-smoke" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "deviceSettingsMutationCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "buildCommandCount") -ne 0L -or
      [string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS" -or
      [string](Get-CcrPinnedRequiredProperty $result "runId") -cne $expectedChildRunId -or
      [long](Get-CcrPinnedRequiredProperty $result "fixtureCount") -ne 17L -or
      [long](Get-CcrPinnedRequiredProperty $result "fullFrameDecodeCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "performanceScenarioCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "buildCommandCount") -ne 0L) {
    throw "ALPHA6_STAGE1_FIXTURE_OPEN_SMOKE_CHECKPOINT_INVALID"
  }
  Assert-CcrAlpha6Stage1FileRecord ([PSCustomObject][ordered]@{
      path = [string](Get-CcrPinnedRequiredProperty $result "reportPath")
      bytes = [long](Get-CcrPinnedRequiredProperty $result "reportBytes")
      sha256 = [string](Get-CcrPinnedRequiredProperty $result "reportSha256")
    }) ([string]$Context.OutputDirectory) | Out-Null
  Assert-CcrAlpha6Stage1Identity (Get-CcrPinnedRequiredProperty $Checkpoint "identity") $Context | Out-Null
  return $true
}

function Assert-CcrAlpha6Stage1SettingsSettleResult {
  param([Parameter(Mandatory = $true)][object]$Result)
  $target = Get-CcrPinnedRequiredProperty $Result "targetSettings"
  $samples = @((Get-CcrPinnedRequiredProperty $Result "samples"))
  $preparationFailures = @((Get-CcrPinnedRequiredProperty $Result "preparationFailures"))
  $lastSamples = @($samples | Select-Object -Last 3)
  if ([string](Get-CcrPinnedRequiredProperty $Result "kind") -cne
        "alpha6-stage1-device-settings-settle" -or
      [string](Get-CcrPinnedRequiredProperty $Result "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $Result "pollIntervalMs") -ne 250L -or
      [long](Get-CcrPinnedRequiredProperty $Result "requiredConsecutiveSamples") -ne 3L -or
      [long](Get-CcrPinnedRequiredProperty $Result "stableIntervalMs") -ne 500L -or
      [long](Get-CcrPinnedRequiredProperty $Result "timeoutMs") -ne 10000L -or
      [long](Get-CcrPinnedRequiredProperty $Result "observedConsecutiveSamples") -ne 3L -or
      $preparationFailures.Count -ne 0 -or
      -not [string]::IsNullOrEmpty(
        [string](Get-CcrPinnedRequiredProperty $Result "lastReadFailure")
      ) -or
      [long](Get-CcrPinnedRequiredProperty $Result "buildCommandCount") -ne 0L -or
      $lastSamples.Count -ne 3 -or
      [string](Get-CcrPinnedRequiredProperty $target "stayAwake") -cne "7" -or
      [string](Get-CcrPinnedRequiredProperty $target "brightnessMode") -cne "0" -or
      [string](Get-CcrPinnedRequiredProperty $target "brightness") -cne "128" -or
      [string](Get-CcrPinnedRequiredProperty $target "screenTimeout") -cne "1800000" -or
      [string](Get-CcrPinnedRequiredProperty $target "accelerometerRotation") -cne "0" -or
      [string](Get-CcrPinnedRequiredProperty $target "userRotation") -cne "0") {
    throw "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED"
  }
  $stableKey = $null
  foreach ($sample in $lastSamples) {
    $sampleSettings = Get-CcrPinnedRequiredProperty $sample "settings"
    $sampleStableKey = [string](Get-CcrPinnedRequiredProperty $sample "stabilityKeySha256")
    if ((Get-CcrPinnedRequiredProperty $sample "ready") -ne $true -or
        (Get-CcrPinnedRequiredProperty $sample "wakefulnessAwake") -ne $true -or
        (Get-CcrPinnedRequiredProperty $sample "displayOn") -ne $true -or
        [long](Get-CcrPinnedRequiredProperty $sample "surfaceOrientation") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $sample "priorValidationProcessCount") -ne 0L -or
        -not (Test-CcrPinnedSha256 (
          Get-CcrPinnedRequiredProperty $sample "configurationSignatureSha256"
        )) -or
        -not (Test-CcrPinnedSha256 $sampleStableKey) -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "stayAwake") -cne "7" -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "brightnessMode") -cne "0" -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "brightness") -cne "128" -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "screenTimeout") -cne "1800000" -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "accelerometerRotation") -cne "0" -or
        [string](Get-CcrPinnedRequiredProperty $sampleSettings "userRotation") -cne "0" -or
        ($null -ne $stableKey -and $sampleStableKey -cne $stableKey)) {
      throw "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED"
    }
    $stableKey = $sampleStableKey
  }
  return $true
}

function Assert-CcrAlpha6Stage1SettingsSettleCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context
  )
  if ([string](Get-CcrPinnedRequiredProperty $Checkpoint "kind") -cne
        "alpha6-stage1-device-settings-settle" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "buildCommandCount") -ne 0L) {
    throw "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED"
  }
  Assert-CcrAlpha6Stage1Identity `
    (Get-CcrPinnedRequiredProperty $Checkpoint "identity") $Context | Out-Null
  Assert-CcrAlpha6Stage1SettingsSettleResult `
    (Get-CcrPinnedRequiredProperty $Checkpoint "result") | Out-Null
  return $true
}

function Assert-CcrAlpha6Stage1RenderOpenSmokeCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$Checkpoint,
    [Parameter(Mandatory = $true)][object]$Context
  )
  $result = Get-CcrPinnedRequiredProperty $Checkpoint "result"
  $attemptCleanup = Get-CcrPinnedRequiredProperty $Checkpoint "attemptCleanup"
  $expectedChildRunId = "$([string](Get-CcrPinnedRequiredProperty $Checkpoint 'attemptRunId'))-ro"
  if ([string](Get-CcrPinnedRequiredProperty $Checkpoint "kind") -cne
        "alpha6-stage1-render-open-smoke" -or
      [string](Get-CcrPinnedRequiredProperty $Checkpoint "status") -cne "PASS" -or
      [long](Get-CcrPinnedRequiredProperty $Checkpoint "buildCommandCount") -ne 0L -or
      [string](Get-CcrPinnedRequiredProperty $result "status") -cne "PASS" -or
      [string](Get-CcrPinnedRequiredProperty $result "runId") -cne $expectedChildRunId -or
      [long](Get-CcrPinnedRequiredProperty $result "buildCommandCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "stableIntervalMs") -lt 200L -or
      [long](Get-CcrPinnedRequiredProperty $result "stableIntervalMs") -gt 500L -or
      [long](Get-CcrPinnedRequiredProperty $result "activityInstanceDriftCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "surfaceGenerationDriftCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "surfaceLossCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $result "videoOpenFailedCount") -ne 0L -or
      [string](Get-CcrPinnedRequiredProperty $attemptCleanup "kind") -cne
        "alpha6-stage1-render-open-attempt-cleanup" -or
      [string](Get-CcrPinnedRequiredProperty $attemptCleanup "status") -cne "PASS" -or
      [string](Get-CcrPinnedRequiredProperty $attemptCleanup "attemptRunId") -cne
        [string](Get-CcrPinnedRequiredProperty $Checkpoint "attemptRunId") -or
      [long](Get-CcrPinnedRequiredProperty $attemptCleanup "totalValidationProcessCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $attemptCleanup "buildCommandCount") -ne 0L -or
      @((Get-CcrPinnedRequiredProperty $attemptCleanup "cleanupFailures")).Count -ne 0) {
    throw "ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED"
  }
  Assert-CcrAlpha6Stage1FileRecord `
    (Get-CcrPinnedRequiredProperty $Checkpoint "settingsSettleCheckpoint") `
    ([string]$Context.OutputDirectory) | Out-Null
  Assert-CcrAlpha6Stage1FileRecord `
    (Get-CcrPinnedRequiredProperty $Checkpoint "evidence") `
    ([string]$Context.OutputDirectory) | Out-Null
  Assert-CcrAlpha6Stage1Identity `
    (Get-CcrPinnedRequiredProperty $Checkpoint "identity") $Context | Out-Null
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
    # Android can immediately recompute the raw brightness after automatic mode is restored.
    if ($entry[1] -ceq "screen_brightness" -and [string]$Context.SavedSettings.brightnessMode -ceq "1") {
      continue
    }
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

function Get-CcrAlpha6Stage1TargetSettings {
  return [PSCustomObject][ordered]@{
    stayAwake = "7"
    brightnessMode = "0"
    brightness = "128"
    screenTimeout = "1800000"
    accelerometerRotation = "0"
    userRotation = "0"
  }
}

function Get-CcrAlpha6Stage1DeviceSettleSample {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][object]$TargetSettings
  )
  $settings = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $Context
  $power = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "dumpsys", "power")
  $display = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "dumpsys", "display")
  $inputState = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "dumpsys", "input")
  $configuration = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "shell", "cmd", "activity", "get-config"
  )
  if ($power.exitCode -ne 0 -or $display.exitCode -ne 0 -or
      $inputState.exitCode -ne 0 -or $configuration.exitCode -ne 0 -or
      [string]::IsNullOrWhiteSpace([string]$configuration.output)) {
    throw "ALPHA6_STAGE1_DEVICE_STATE_READ_FAILED"
  }
  $processCount = 0L
  $processCounts = [ordered]@{}
  foreach ($packageName in @(
    $script:CcrPinnedAppPackage,
    $script:CcrPinnedDebugTestPackage,
    $script:CcrPinnedMacrobenchmarkPackage
  )) {
    $pidResult = Invoke-CcrPinnedAdb $Context @(
      "-s", $Context.Serial, "shell", "pidof", $packageName
    )
    if ($pidResult.exitCode -notin @(0, 1)) {
      throw "ALPHA6_STAGE1_DEVICE_PROCESS_READ_FAILED:$packageName"
    }
    $packageProcessCount = if (
      [string]::IsNullOrWhiteSpace([string]$pidResult.output)
    ) {
      0L
    } else {
      @(([string]$pidResult.output).Trim() -split "\s+").Count
    }
    $processCounts[$packageName] = $packageProcessCount
    $processCount += $packageProcessCount
  }
  $legacyOrientationFieldMatches = [regex]::Matches(
    [string]$inputState.output,
    "(?m)^[ \t]*SurfaceOrientation:[^\r\n]*\r?$"
  )
  $legacyOrientationMatches = [regex]::Matches(
    [string]$inputState.output,
    "(?m)^[ \t]*SurfaceOrientation:[ \t]*(?<value>[0-3])[ \t]*\r?$"
  )
  $legacyOrientationValues = @(
    $legacyOrientationMatches |
      ForEach-Object { [long]$_.Groups["value"].Value } |
      Select-Object -Unique
  )
  $legacyOrientation = $null
  if ($legacyOrientationFieldMatches.Count -gt 0) {
    if (
      $legacyOrientationMatches.Count -eq $legacyOrientationFieldMatches.Count -and
      $legacyOrientationValues.Count -eq 1
    ) {
      $legacyOrientation = [long]$legacyOrientationValues[0]
    }
  }
  $activeInternalViewportLines = @(
    [regex]::Matches(
      [string]$inputState.output,
      "(?m)^[ \t]*Viewport\s+INTERNAL:[ \t]*(?<details>[^\r\n]*)\r?$"
    ) |
      ForEach-Object { [string]$_.Groups["details"].Value } |
      Where-Object {
        [regex]::IsMatch(
          [string]$_,
          "(?:^|,\s*)displayId=0(?=\s*(?:,|$))"
        ) -and
        [regex]::IsMatch(
          [string]$_,
          "(?:^|,\s*)isActive=\[1\](?=\s*(?:,|$))"
        )
      }
  )
  $viewportOrientationValues = [System.Collections.Generic.List[long]]::new()
  $viewportRecordsValid = $activeInternalViewportLines.Count -gt 0
  foreach ($viewportLine in $activeInternalViewportLines) {
    $viewportOrientationMatches = [regex]::Matches(
      [string]$viewportLine,
      "(?:^|,\s*)orientation=(?<value>[0-3])(?=\s*(?:,|$))"
    )
    if ($viewportOrientationMatches.Count -ne 1) {
      $viewportRecordsValid = $false
      break
    }
    $viewportOrientationValues.Add(
      [long]$viewportOrientationMatches[0].Groups["value"].Value
    )
  }
  $uniqueViewportOrientationValues = @(
    $viewportOrientationValues | Select-Object -Unique
  )
  $viewportOrientation = $null
  if ($viewportRecordsValid -and $uniqueViewportOrientationValues.Count -eq 1) {
    $viewportOrientation = [long]$uniqueViewportOrientationValues[0]
  }
  $surfaceOrientation = -1L
  if ($legacyOrientationFieldMatches.Count -gt 0) {
    if (
      $null -ne $legacyOrientation -and
      (
        $activeInternalViewportLines.Count -eq 0 -or
        (
          $null -ne $viewportOrientation -and
          [long]$viewportOrientation -eq [long]$legacyOrientation
        )
      )
    ) {
      $surfaceOrientation = [long]$legacyOrientation
    }
  } elseif ($null -ne $viewportOrientation) {
    $surfaceOrientation = [long]$viewportOrientation
  }
  $settingsMatch =
    [string]$settings.stayAwake -ceq [string]$TargetSettings.stayAwake -and
    [string]$settings.brightnessMode -ceq [string]$TargetSettings.brightnessMode -and
    [string]$settings.brightness -ceq [string]$TargetSettings.brightness -and
    [string]$settings.screenTimeout -ceq [string]$TargetSettings.screenTimeout -and
    [string]$settings.accelerometerRotation -ceq [string]$TargetSettings.accelerometerRotation -and
    [string]$settings.userRotation -ceq [string]$TargetSettings.userRotation
  $wakefulnessAwake = [string]$power.output -cmatch "(?m)\bmWakefulness=Awake\b"
  $displayOn = [string]$display.output -cmatch (
    "(?m)\b(?:mDisplayState|mState)=ON\b|Display Power:\s*state=ON\b"
  )
  $configurationSignature = ([string]$configuration.output).Trim()
  $sampleIdentity = [ordered]@{
    settings = $settings
    wakefulnessAwake = $wakefulnessAwake
    displayOn = $displayOn
    surfaceOrientation = $surfaceOrientation
    configurationSignatureSha256 = Get-CcrAlpha6Stage1Sha256Text $configurationSignature
    priorValidationProcessCounts = [PSCustomObject]$processCounts
    priorValidationProcessCount = $processCount
  }
  $ready = $settingsMatch -and $wakefulnessAwake -and $displayOn -and
    $surfaceOrientation -eq 0L -and $processCount -eq 0L
  return [PSCustomObject][ordered]@{
    observedAtUtc = [DateTime]::UtcNow.ToString("o")
    ready = $ready
    settings = $settings
    wakefulnessAwake = $wakefulnessAwake
    displayOn = $displayOn
    surfaceOrientation = $surfaceOrientation
    configurationSignatureSha256 = [string]$sampleIdentity.configurationSignatureSha256
    priorValidationProcessCounts = [PSCustomObject]$processCounts
    priorValidationProcessCount = $processCount
    stabilityKeySha256 = Get-CcrAlpha6Stage1Sha256Text (
      $sampleIdentity | ConvertTo-Json -Depth 10 -Compress
    )
  }
}

function Wait-CcrAlpha6Stage1DeviceSettingsSettled {
  param([Parameter(Mandatory = $true)][object]$Context)
  $pollIntervalMs = 250L
  $requiredConsecutiveSamples = 3L
  $stableIntervalMs = 500L
  $targetSettings = Get-CcrAlpha6Stage1TargetSettings
  $samples = [System.Collections.Generic.List[object]]::new()
  $preparationFailures = [System.Collections.Generic.List[string]]::new()
  $localDeadline = [DateTime]::UtcNow.AddSeconds(10)
  if ($deadlineUtc -lt $localDeadline) { $localDeadline = $deadlineUtc }
  $priorValidationDeadline = [datetime]$adbDeadlineState.ValidationDeadlineUtc
  $adbDeadlineState.ValidationDeadlineUtc = $localDeadline
  $consecutiveSamples = 0L
  $lastStabilityKey = $null
  $lastReadFailure = $null
  try {
    foreach ($command in @(
      @("shell", "input", "keyevent", "KEYCODE_WAKEUP"),
      @("shell", "wm", "dismiss-keyguard"),
      @("shell", "am", "force-stop", $script:CcrPinnedAppPackage),
      @("shell", "am", "force-stop", $script:CcrPinnedDebugTestPackage),
      @("shell", "am", "force-stop", $script:CcrPinnedMacrobenchmarkPackage)
    )) {
      try {
        $arguments = @("-s", $Context.Serial) + $command
        $result = Invoke-CcrPinnedAdb $Context $arguments
        if ($result.exitCode -ne 0) {
          $preparationFailures.Add(
            "DEVICE_PREPARATION_COMMAND_FAILED:$($command -join '/')"
          ) | Out-Null
        }
      } catch {
        $preparationFailures.Add(
          "DEVICE_PREPARATION_COMMAND_FAILED:$($command -join '/')"
        ) | Out-Null
      }
    }
    while ([DateTime]::UtcNow -lt $localDeadline -and $preparationFailures.Count -eq 0) {
      try {
        $sample = Get-CcrAlpha6Stage1DeviceSettleSample $Context $targetSettings
        $samples.Add($sample) | Out-Null
        $lastReadFailure = $null
        if ($sample.ready -eq $true) {
          if ([string]$sample.stabilityKeySha256 -ceq [string]$lastStabilityKey) {
            $consecutiveSamples += 1L
          } else {
            $lastStabilityKey = [string]$sample.stabilityKeySha256
            $consecutiveSamples = 1L
          }
        } else {
          $lastStabilityKey = $null
          $consecutiveSamples = 0L
        }
        if ($consecutiveSamples -ge $requiredConsecutiveSamples) { break }
      } catch {
        $lastReadFailure = $_.Exception.Message
        $lastStabilityKey = $null
        $consecutiveSamples = 0L
      }
      Start-Sleep -Milliseconds $pollIntervalMs
    }
  } finally {
    $adbDeadlineState.ValidationDeadlineUtc = $priorValidationDeadline
  }
  $status = if ($preparationFailures.Count -eq 0 -and
      $consecutiveSamples -ge $requiredConsecutiveSamples) { "PASS" } else { "FAIL" }
  return [PSCustomObject][ordered]@{
    kind = "alpha6-stage1-device-settings-settle"
    status = $status
    targetSettings = $targetSettings
    pollIntervalMs = $pollIntervalMs
    requiredConsecutiveSamples = $requiredConsecutiveSamples
    stableIntervalMs = $stableIntervalMs
    timeoutMs = 10000L
    observedConsecutiveSamples = $consecutiveSamples
    preparationFailures = $preparationFailures.ToArray()
    lastReadFailure = $lastReadFailure
    samples = $samples.ToArray()
    buildCommandCount = 0L
  }
}

function Invoke-CcrAlpha6Stage1RenderAttemptCleanup {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$AttemptRunId
  )
  $failures = [System.Collections.Generic.List[string]]::new()
  $processCounts = [ordered]@{}
  $packages = @(
    $script:CcrPinnedAppPackage,
    $script:CcrPinnedDebugTestPackage,
    $script:CcrPinnedMacrobenchmarkPackage
  )
  foreach ($packageName in $packages) {
    try {
      $result = Invoke-CcrPinnedAdb $Context @(
        "-s", $Context.Serial, "shell", "am", "force-stop", $packageName
      )
      if ($result.exitCode -ne 0) {
        $failures.Add("FORCE_STOP_FAILED:$packageName") | Out-Null
      }
    } catch {
      $failures.Add("FORCE_STOP_FAILED:$packageName") | Out-Null
    }
  }
  foreach ($packageName in $packages) {
    try {
      $pidResult = Invoke-CcrPinnedAdb $Context @(
        "-s", $Context.Serial, "shell", "pidof", $packageName
      )
      if ($pidResult.exitCode -notin @(0, 1)) {
        $failures.Add("PROCESS_READ_FAILED:$packageName") | Out-Null
        $processCounts[$packageName] = -1L
      } else {
        $processCounts[$packageName] = if (
          [string]::IsNullOrWhiteSpace([string]$pidResult.output)
        ) {
          0L
        } else {
          @(([string]$pidResult.output).Trim() -split "\s+").Count
        }
      }
    } catch {
      $failures.Add("PROCESS_READ_FAILED:$packageName") | Out-Null
      $processCounts[$packageName] = -1L
    }
  }
  $totalProcessCount = [long](
    @($processCounts.Values | Measure-Object -Sum).Sum
  )
  $status = if ($failures.Count -eq 0 -and $totalProcessCount -eq 0L) {
    "PASS"
  } else {
    "FAIL"
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-render-open-attempt-cleanup"
    status = $status
    attemptRunId = $AttemptRunId
    forceStoppedPackages = $packages
    processCounts = [PSCustomObject]$processCounts
    totalValidationProcessCount = $totalProcessCount
    cleanupFailures = $failures.ToArray()
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    buildCommandCount = 0L
  }
}

function Get-CcrAlpha6Stage1CleanupVerification {
  param([Parameter(Mandatory = $true)][object]$Context)
  $settings = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $Context
  $expectedSettings = Get-CcrPinnedRequiredProperty $Context "SavedSettings"
  $rawBrightnessExactRequired =
    [string]$expectedSettings.brightnessMode -cne "1"
  $rawBrightnessRestored =
    -not $rawBrightnessExactRequired -or
    [string]$settings.brightness -ceq [string]$expectedSettings.brightness
  $settingsRestored =
    [string]$settings.stayAwake -ceq [string]$expectedSettings.stayAwake -and
    [string]$settings.brightnessMode -ceq [string]$expectedSettings.brightnessMode -and
    $rawBrightnessRestored -and
    [string]$settings.screenTimeout -ceq [string]$expectedSettings.screenTimeout -and
    [string]$settings.accelerometerRotation -ceq
      [string]$expectedSettings.accelerometerRotation -and
    [string]$settings.userRotation -ceq [string]$expectedSettings.userRotation
  $debugTestInstalled =
    Test-CcrPinnedPackageInstalled $Context $script:CcrPinnedDebugTestPackage
  $macrobenchmarkTestInstalled =
    Test-CcrPinnedPackageInstalled $Context $script:CcrPinnedMacrobenchmarkPackage
  $processCounts = [ordered]@{}
  foreach ($packageName in @(
    $script:CcrPinnedAppPackage,
    $script:CcrPinnedDebugTestPackage,
    $script:CcrPinnedMacrobenchmarkPackage
  )) {
    $pidResult = Invoke-CcrPinnedAdb $Context @(
      "-s", $Context.Serial, "shell", "pidof", $packageName
    )
    if ($pidResult.exitCode -notin @(0, 1)) {
      throw "ALPHA6_STAGE1_CLEANUP_PROCESS_READ_FAILED:$packageName"
    }
    $processCounts[$packageName] = if (
      [string]::IsNullOrWhiteSpace([string]$pidResult.output)
    ) {
      0L
    } else {
      @(([string]$pidResult.output).Trim() -split "\s+").Count
    }
  }
  $allProcessCount = [long](
    @($processCounts.Values | Measure-Object -Sum).Sum
  )
  $status = if ($settingsRestored -and
      -not $debugTestInstalled -and
      -not $macrobenchmarkTestInstalled -and
      $allProcessCount -eq 0L) {
    "PASS"
  } else {
    "FAIL"
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-cleanup-verification"
    status = $status
    settingsRestored = $settingsRestored
    rawBrightnessExactRequired = $rawBrightnessExactRequired
    settings = $settings
    debugTestPackageInstalled = $debugTestInstalled
    macrobenchmarkTestPackageInstalled = $macrobenchmarkTestInstalled
    processCounts = [PSCustomObject]$processCounts
    totalValidationProcessCount = $allProcessCount
    verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
    buildCommandCount = 0L
  }
}

function Invoke-CcrAlpha6Stage1RenderOpenSmoke {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$AttemptRunId,
    [Parameter(Mandatory = $true)][string]$StageDirectory
  )
  $childRunId = "$AttemptRunId-ro"
  if ($null -ne $TestOnlyRenderOpenSmokeExecutor) {
    return & $TestOnlyRenderOpenSmokeExecutor $Context $childRunId $StageDirectory
  }
  return Invoke-CcrAlpha6CandidateRenderOpenInstrumentation `
    -Context $Context `
    -RunId $childRunId `
    -EvidenceDirectory $StageDirectory `
    -SkipInstall
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
  Assert-CcrPinnedInstalledArtifact $Context "debugApp"
  Assert-CcrPinnedInstalledArtifact $Context "debugTest"
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
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
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
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
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
    $requireRequestStageMetrics = [string]$scenario.direction -ceq "reverse"
    Assert-CcrAlpha6BenchmarkData `
      -Path $benchmarkData[0].FullName -ExpectedMethod $scenario.method `
      -ExpectedEvidence $harnessEvidence `
      -RequireRequestStageMetrics:$requireRequestStageMetrics | Out-Null
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

function Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract {
  param(
    [Parameter(Mandatory = $true)][string]$Leaf,
    [Parameter(Mandatory = $true)][object[]]$Contracts,
    [Parameter(Mandatory = $true)][string]$ParentRunId
  )
  $matches = @($Contracts | ForEach-Object {
    $stage = [string]$_.stage
    $expectedChildRunId = "$ParentRunId-c-$($stage.ToLowerInvariant())"
    if ($Leaf -ceq "$expectedChildRunId-$([string]$_.reportName)") {
      [PSCustomObject]@{
        contract = $_
        expectedChildRunId = $expectedChildRunId
      }
    }
  })
  if ($matches.Count -ne 1) {
    throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_IDENTITY_MISMATCH:$Leaf"
  }
  return $matches[0]
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
  $contracts = @(
    [PSCustomObject]@{ stage = "Full"; reportName = "s24-frame-accuracy-report.json"; kind = "frame-accuracy-exact" },
    [PSCustomObject]@{ stage = "Representative"; reportName = "representative-resolution-exact-report.json"; kind = "representative-resolution-exact-subset" },
    [PSCustomObject]@{ stage = "Forward"; reportName = "s24-forward-sequential-report.json"; kind = "forward-sequential-exact" },
    [PSCustomObject]@{ stage = "Reverse"; reportName = "s24-reverse-window-report.json"; kind = "reverse-window-exact" },
    [PSCustomObject]@{ stage = "ReleaseCancel"; reportName = "s24-release-cancel-grace-report.json"; kind = "release-cancel-grace" },
    [PSCustomObject]@{ stage = "Direction"; reportName = "s24-alpha5-direction-reversal-report.json"; kind = "bidirectional-transition-exact" },
    [PSCustomObject]@{ stage = "ReverseLifecycle"; reportName = "s24-alpha5-reverse-lifecycle-report.json"; kind = "alpha5-reverse-lifecycle-exact" }
  )
  $records = @((Get-CcrPinnedRequiredProperty $Result "evidence"))
  if ($records.Count -ne $contracts.Count) { throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_COUNT_MISMATCH" }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($record in $records) {
    $path = Assert-CcrAlpha6Stage1FileRecord $record $Context.OutputDirectory
    $leaf = [System.IO.Path]::GetFileName($path)
    $resolved = Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract $leaf $contracts $RunId
    $contract = $resolved.contract
    $contractName = [string]$contract.reportName
    if (-not $seen.Add($contractName)) {
      throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_IDENTITY_MISMATCH:$leaf"
    }
    try { $report = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
      throw "ALPHA6_STAGE1_CORRECTNESS_RESULT_JSON_INVALID:$leaf"
    }
    $stage = [string]$contract.stage
    $kind = [string]$contract.kind
    Assert-CcrPinnedReport `
      -Report $report -ArtifactSet $Context.ArtifactSet `
      -RunId ([string]$resolved.expectedChildRunId) `
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
  $scenarioContracts = @{
    "hold1080PlusOne" = [PSCustomObject]@{ evidence = "1080p-hold-plus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 1; direction = "forward"; prefix = "a6-bf-p1" }
    "hold1080PlusFive" = [PSCustomObject]@{ evidence = "1080p-hold-plus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = 5; direction = "forward"; prefix = "a6-bf-p5" }
    "hold1080MinusOne" = [PSCustomObject]@{ evidence = "1080p-hold-minus-one"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -1; direction = "reverse"; prefix = "a6-bf-m1" }
    "hold1080MinusFive" = [PSCustomObject]@{ evidence = "1080p-hold-minus-five"; fixtureIdentity = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; stride = -5; direction = "reverse"; prefix = "a6-bf-m5" }
    "hold1080H264LongGopMinusOne" = [PSCustomObject]@{ evidence = "1080p-h264-long-gop-hold-minus-one"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -1; direction = "reverse"; prefix = "a6-lg-m1" }
    "hold1080H264LongGopMinusFive" = [PSCustomObject]@{ evidence = "1080p-h264-long-gop-hold-minus-five"; fixtureIdentity = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; stride = -5; direction = "reverse"; prefix = "a6-lg-m5" }
    "hold1080HevcMain8MinusOne" = [PSCustomObject]@{ evidence = "1080p-hevc-main8-hold-minus-one"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -1; direction = "reverse"; prefix = "a6-hevc-m1" }
    "hold1080HevcMain8MinusFive" = [PSCustomObject]@{ evidence = "1080p-hevc-main8-hold-minus-five"; fixtureIdentity = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; stride = -5; direction = "reverse"; prefix = "a6-hevc-m5" }
    "hold1080VfrMinusOne" = [PSCustomObject]@{ evidence = "1080p-vfr-hold-minus-one"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -1; direction = "reverse"; prefix = "a6-vfr-m1" }
    "hold1080VfrMinusFive" = [PSCustomObject]@{ evidence = "1080p-vfr-hold-minus-five"; fixtureIdentity = "vfr"; fixture = "1080p-vfr.mp4"; stride = -5; direction = "reverse"; prefix = "a6-vfr-m5" }
  }
  $scenarios = @((Get-CcrPinnedRequiredProperty $Result "scenarios"))
  if ($scenarios.Count -ne $scenarioContracts.Count) {
    throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_SCENARIO_MISMATCH"
  }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $seenTracePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $seenTraceHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($scenario in $scenarios) {
    $method = [string](Get-CcrPinnedRequiredProperty $scenario "method")
    $contractMethods = @($scenarioContracts.Keys | Where-Object { $_ -ceq $method })
    if ($contractMethods.Count -ne 1 -or -not $seen.Add($method)) {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_SCENARIO_MISMATCH"
    }
    $contract = $scenarioContracts[[string]$contractMethods[0]]
    $strideValue = Get-CcrPinnedRequiredProperty $scenario "stride"
    if (($strideValue -isnot [int] -and $strideValue -isnot [long]) -or
        [long]$strideValue -ne [long]$contract.stride) {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_SCENARIO_MISMATCH:$method"
    }
    if ([string](Get-CcrPinnedRequiredProperty $scenario "evidenceScenario") -cne [string]$contract.evidence -or
        [string](Get-CcrPinnedRequiredProperty $scenario "fixtureIdentity") -cne [string]$contract.fixtureIdentity -or
        [string](Get-CcrPinnedRequiredProperty $scenario "fixture") -cne [string]$contract.fixture -or
        [string](Get-CcrPinnedRequiredProperty $scenario "direction") -cne [string]$contract.direction -or
        [string](Get-CcrPinnedRequiredProperty $scenario "runId") -cne "$RunId-$([string]$contract.prefix)") {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_SCENARIO_MISMATCH:$method"
    }
    $traces = @((Get-CcrPinnedRequiredProperty $scenario "traces"))
    if ($traces.Count -ne 3) { throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_TRACE_COUNT_MISMATCH" }
    $traceOrdinals = [System.Collections.Generic.HashSet[int]]::new()
    $tracePattern =
      "^CcrProductMacrobenchmark_$([regex]::Escape($method))_iter00(?<ordinal>[0-2])_.+\.perfetto-trace$"
    foreach ($trace in $traces) {
      $tracePath = Assert-CcrAlpha6Stage1FileRecord $trace $Context.OutputDirectory
      $traceMatch = [regex]::Match(
        [System.IO.Path]::GetFileName($tracePath),
        $tracePattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
      )
      $traceHash = [string](Get-CcrPinnedRequiredProperty $trace "sha256")
      if (-not $traceMatch.Success -or
          [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($tracePath)) -cne
            "$RunId-$([string]$contract.prefix)" -or
          -not $traceOrdinals.Add([int]$traceMatch.Groups["ordinal"].Value) -or
          -not $seenTracePaths.Add($tracePath) -or -not $seenTraceHashes.Add($traceHash)) {
        throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_TRACE_IDENTITY_MISMATCH:$method"
      }
    }
    if ($traceOrdinals.Count -ne 3) {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_TRACE_IDENTITY_MISMATCH:$method"
    }
    $benchmarkDataPath = Assert-CcrAlpha6Stage1FileRecord `
      (Get-CcrPinnedRequiredProperty $scenario "benchmarkData") $Context.OutputDirectory
    $harnessEvidencePath = Assert-CcrAlpha6Stage1FileRecord `
      (Get-CcrPinnedRequiredProperty $scenario "harnessEvidence") $Context.OutputDirectory
    try { $harnessEvidence = [System.IO.File]::ReadAllText($harnessEvidencePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_JSON_INVALID"
    }
    $scenarioContract = [PSCustomObject]@{
      method = $method
      evidence = [string]$contract.evidence
      fixture = [string]$contract.fixture
    }
    $validatedIterations = @(Assert-CcrAlpha6Stage1BenchmarkEvidence `
      $harnessEvidence $scenarioContract $Context "$RunId-$([string]$contract.prefix)")
    if (($validatedIterations | ConvertTo-Json -Depth 30 -Compress) -cne
        (@((Get-CcrPinnedRequiredProperty $scenario "iterations")) | ConvertTo-Json -Depth 30 -Compress)) {
      throw "ALPHA6_STAGE1_PERFORMANCE_RESULT_ITERATION_MISMATCH"
    }
    $requireRequestStageMetrics = [string]$contract.direction -ceq "reverse"
    Assert-CcrAlpha6BenchmarkData `
      -Path $benchmarkDataPath -ExpectedMethod $scenarioContract.method `
      -ExpectedEvidence $harnessEvidence `
      -RequireRequestStageMetrics:$requireRequestStageMetrics | Out-Null
  }
  Assert-CcrAlpha6Stage1TailGate $scenarios | Out-Null
  return $true
}

function Assert-CcrAlpha6Stage1Checkpoint {
  param([Parameter(Mandatory = $true)][object]$Checkpoint, [Parameter(Mandatory = $true)][string]$Stage, [Parameter(Mandatory = $true)][object]$Context)
  if ([int]$Checkpoint.schemaVersion -ne 1 -or
      [string]$Checkpoint.kind -cne "alpha6-stage1-checkpoint" -or
      [string]$Checkpoint.status -cne "PASS" -or
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
    [AllowNull()][object]$PostRunArtifactRehash = $null,
    [AllowNull()][object]$FixtureOpenSmokeResult = $null,
    [AllowNull()][object]$SettingsSettleCheckpoint = $null,
    [AllowNull()][object]$RenderOpenSmokeCheckpoint = $null
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
    fixtureOpenSmokeResult = $FixtureOpenSmokeResult
    settingsSettleCheckpoint = $SettingsSettleCheckpoint
    renderOpenSmokeCheckpoint = $RenderOpenSmokeCheckpoint
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  return Write-CcrAlpha6Stage1ImmutableJson $path $report
}

function Get-CcrAlpha6Stage1ResumeRestoreBaseline {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$LogicalRunId
  )
  $escapedRunId = [regex]::Escape($LogicalRunId)
  $namePattern =
    "^checkpoint-alpha6-stage1-device-settings-$escapedRunId(?:-resume-[a-f0-9]{32})?\.json$"
  $records = @(
    Get-ChildItem -LiteralPath $Context.OutputDirectory `
      -Filter "checkpoint-alpha6-stage1-device-settings-$LogicalRunId*.json" -File |
      Where-Object { $_.Name -cmatch $namePattern } |
      Sort-Object Name
  )
  $baseline = $null
  $baselineJson = $null
  foreach ($record in $records) {
    if (($record.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "ALPHA6_STAGE1_RESUME_SETTINGS_BASELINE_REPARSE_POINT"
    }
    try {
      $settings = [System.IO.File]::ReadAllText(
        $record.FullName,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
    } catch {
      throw "ALPHA6_STAGE1_RESUME_SETTINGS_BASELINE_JSON_INVALID"
    }
    if ([string](Get-CcrPinnedRequiredProperty $settings "kind") -cne
          "alpha6-device-settings-preflight" -or
        [string](Get-CcrPinnedRequiredProperty $settings "status") -cne "PASS" -or
        [string](Get-CcrPinnedRequiredProperty $settings "runId") -cne $LogicalRunId) {
      throw "ALPHA6_STAGE1_RESUME_SETTINGS_BASELINE_CONTRACT_MISMATCH"
    }
    Assert-CcrAlpha6Stage1Identity `
      (Get-CcrPinnedRequiredProperty $settings "identity") $Context | Out-Null
    $candidate = Get-CcrPinnedRequiredProperty $settings "effectiveRestoreBaseline"
    $candidateJson = $candidate | ConvertTo-Json -Depth 20 -Compress
    if ($null -eq $baseline) {
      $baseline = $candidate
      $baselineJson = $candidateJson
    } elseif ($candidateJson -cne $baselineJson) {
      throw "ALPHA6_STAGE1_RESUME_SETTINGS_BASELINE_DRIFT"
    }
  }
  return $baseline
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
  ExpectedVersionName = $ExpectedVersionName
  ExpectedVersionCode = $ExpectedVersionCode
  PreflightOnly = [bool]$PreflightOnly
  BuildCommandCount = 0L
  ValidationScriptPaths = $closedValidationScripts
  AndroidTools = $androidTools
}
if ($null -ne $TestOnlyIdentityReader) { $hostParameters.IdentityReader = $TestOnlyIdentityReader }
if ($null -ne $TestOnlySourceIdentityVerifier) { $hostParameters.SourceIdentityVerifier = $TestOnlySourceIdentityVerifier }
$context = Invoke-CcrAlpha6CandidateDeviceHostPreflight @hostParameters
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
      [string](Get-CcrPinnedRequiredProperty $session "originalScreenTimeoutSetting") -cne $OriginalScreenTimeoutSetting -or
      (@((Get-CcrPinnedRequiredProperty $session "stageOrder")) -join "|") -cne
        $script:CcrAlpha6Stage1StageOrderToken) {
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
          (@((Get-CcrPinnedRequiredProperty $summary "stageOrder")) -join "|") -cne
            $script:CcrAlpha6Stage1StageOrderToken -or
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
          (@((Get-CcrPinnedRequiredProperty $summary "stageOrder")) -join "|") -cne
            $script:CcrAlpha6Stage1StageOrderToken -or
          (Get-CcrPinnedRequiredProperty $summary "releaseEligible") -ne $false -or
          (Get-CcrPinnedRequiredProperty $summary "auxiliaryDecoderUsed") -ne $false -or
          [string](Get-CcrPinnedRequiredProperty $summary "userReverseSmoothness") -cne "PENDING_USER" -or
          [long](Get-CcrPinnedRequiredProperty $summary "debugArtifactInstallSetCount") -ne 1L -or
          [long](Get-CcrPinnedRequiredProperty $summary "debugArtifactInstallCommandCount") -ne 2L -or
          [long](Get-CcrPinnedRequiredProperty $summary "buildCommandCount") -ne 0L -or
          (Get-CcrPinnedRequiredProperty $summary "syntheticOnly") -ne $true -or
          (Get-CcrPinnedRequiredProperty $summary "containsRealMediaMetadata") -ne $false) {
        throw "ALPHA6_STAGE1_RESUME_SUMMARY_CONTRACT_MISMATCH"
      }
      Assert-CcrAlpha6Stage1IdentitySmokeCheckpoint `
        (Get-CcrPinnedRequiredProperty $summary "identitySmoke") $context | Out-Null
      Assert-CcrAlpha6Stage1FixtureOpenSmokeCheckpoint `
        (Get-CcrPinnedRequiredProperty $summary "fixtureOpenSmoke") $context | Out-Null
      $completedSettingsSettle =
        Get-CcrPinnedRequiredProperty $summary "settingsSettle"
      $completedRenderOpenSmoke =
        Get-CcrPinnedRequiredProperty $summary "renderOpenSmoke"
      Assert-CcrAlpha6Stage1SettingsSettleCheckpoint `
        $completedSettingsSettle $context | Out-Null
      Assert-CcrAlpha6Stage1RenderOpenSmokeCheckpoint `
        $completedRenderOpenSmoke $context | Out-Null
      $completedSettingsSettlePath = Assert-CcrAlpha6Stage1FileRecord `
        (Get-CcrPinnedRequiredProperty $summary "settingsSettleCheckpointFile") `
        ([string]$context.OutputDirectory)
      $completedRenderOpenSmokePath = Assert-CcrAlpha6Stage1FileRecord `
        (Get-CcrPinnedRequiredProperty $summary "renderOpenSmokeCheckpointFile") `
        ([string]$context.OutputDirectory)
      $persistedSettingsSettle = [System.IO.File]::ReadAllText(
        $completedSettingsSettlePath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      $persistedRenderOpenSmoke = [System.IO.File]::ReadAllText(
        $completedRenderOpenSmokePath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
      if (($persistedSettingsSettle | ConvertTo-Json -Depth 40 -Compress) -cne
            ($completedSettingsSettle | ConvertTo-Json -Depth 40 -Compress) -or
          ($persistedRenderOpenSmoke | ConvertTo-Json -Depth 40 -Compress) -cne
            ($completedRenderOpenSmoke | ConvertTo-Json -Depth 40 -Compress)) {
        throw "ALPHA6_STAGE1_RESUME_COMPLETED_CHECKPOINT_MISMATCH"
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
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
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
    stageOrder = @($script:CcrAlpha6Stage1StageOrder)
    resumeContract = "completed-stage-only; exact artifact, helper hash, source and device identity"
    correctnessFailureBlocksPerformance = $true
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6Stage1ImmutableJson $sessionPath $session | Out-Null
}

$preRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
if ($PreflightOnly) {
  $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $summary = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-preflight"
    status = "PREFLIGHT_PASS"
    identity = $identity
    maxMinutes = $MaxMinutes
    stageOrder = @($script:CcrAlpha6Stage1StageOrder)
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
$currentPhase = "identity-smoke"
$primaryFailure = $null
$identitySmokeCheckpoint = $null
$fixtureOpenSmokeCheckpoint = $null
$fixtureOpenSmokeResult = $null
$settingsSettleCheckpoint = $null
$settingsSettleCheckpointPath = $null
$renderOpenSmokeCheckpoint = $null
$renderOpenSmokeCheckpointPath = $null
$renderOpenSmokeCheckpoints = [System.Collections.Generic.List[object]]::new()
$renderOpenSmokeCheckpointFiles = [System.Collections.Generic.List[object]]::new()
$renderOpenSmokeRunIds = [System.Collections.Generic.List[string]]::new()
$correctnessCheckpoint = $null
$performanceCheckpoint = $null
$cleanupVerification = $null
$cleanupVerificationCheckpointPath = $null
$postRunArtifactRehash = $null
$settingsPreflight = $null
$preSettingsGateBaseline = $null
$identitySmokeSettingsAfter = $null
$fixtureOpenSmokeSettingsAfter = $null
$resumeRestoreBaseline = $null
if ($Resume) {
  $resumeRestoreBaseline = Get-CcrAlpha6Stage1ResumeRestoreBaseline `
    -Context $context -LogicalRunId $RunId
}
try {
  $preSettingsGateBaseline = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
  $identitySmokeDirectory = Join-Path $context.OutputDirectory "attempt-$hostPreflightRunId-stage-identity-smoke"
  $identitySmokeResult = if ($null -ne $TestOnlyIdentitySmokeExecutor) {
    & $TestOnlyIdentitySmokeExecutor $context "$hostPreflightRunId-id" $identitySmokeDirectory
  } else {
    Invoke-CcrAlpha6CandidateIdentitySmokeInstrumentation `
      -Context $context `
      -RunId "$hostPreflightRunId-id" `
      -EvidenceDirectory $identitySmokeDirectory
  }
  if ($null -eq $identitySmokeResult -or [string]$identitySmokeResult.status -cne "PASS") {
    throw "ALPHA6_STAGE1_IDENTITY_SMOKE_FAILED"
  }
  $identitySmokeSettingsAfter = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
  if (($preSettingsGateBaseline | ConvertTo-Json -Compress) -cne
      ($identitySmokeSettingsAfter | ConvertTo-Json -Compress)) {
    throw "DEVICE_SETTINGS_MUTATED_DURING_IDENTITY_SMOKE"
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $identitySmokeCheckpoint = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-identity-smoke"
    status = "PASS"
    runId = $RunId
    attemptRunId = $hostPreflightRunId
    identity = $identity
    result = $identitySmokeResult
    deviceSettingsBefore = $preSettingsGateBaseline
    deviceSettingsAfter = $identitySmokeSettingsAfter
    deviceSettingsMutationCount = 0L
    buildCommandCount = 0L
  }
  Assert-CcrAlpha6Stage1IdentitySmokeCheckpoint $identitySmokeCheckpoint $context | Out-Null
  $identitySmokeCheckpointPath = Join-Path $context.OutputDirectory (
    "checkpoint-alpha6-stage1-identity-smoke-$hostPreflightRunId.json"
  )
  Write-CcrAlpha6Stage1ImmutableJson $identitySmokeCheckpointPath $identitySmokeCheckpoint | Out-Null

  $currentPhase = "fixture-open-smoke"
  $fixtureOpenSmokeDirectory = Join-Path $context.OutputDirectory (
    "attempt-$hostPreflightRunId-stage-fixture-open-smoke"
  )
  $fixtureOpenSmokeResult = if ($null -ne $TestOnlyFixtureOpenSmokeExecutor) {
    & $TestOnlyFixtureOpenSmokeExecutor `
      $context "$hostPreflightRunId-fx" $fixtureOpenSmokeDirectory
  } else {
    Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation `
      -Context $context `
      -RunId "$hostPreflightRunId-fx" `
      -EvidenceDirectory $fixtureOpenSmokeDirectory `
      -Mode "Smoke" `
      -SkipInstall
  }
  if ($null -eq $fixtureOpenSmokeResult -or
      [string]$fixtureOpenSmokeResult.status -cne "PASS") {
    throw "ALPHA6_STAGE1_FIXTURE_OPEN_SMOKE_FAILED"
  }
  $fixtureOpenSmokeSettingsAfter = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
  if (($preSettingsGateBaseline | ConvertTo-Json -Compress) -cne
      ($fixtureOpenSmokeSettingsAfter | ConvertTo-Json -Compress)) {
    throw "DEVICE_SETTINGS_MUTATED_DURING_FIXTURE_OPEN_SMOKE"
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $fixtureOpenSmokeCheckpoint = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-fixture-open-smoke"
    status = "PASS"
    runId = $RunId
    attemptRunId = $hostPreflightRunId
    identity = $identity
    result = $fixtureOpenSmokeResult
    deviceSettingsBefore = $preSettingsGateBaseline
    deviceSettingsAfter = $fixtureOpenSmokeSettingsAfter
    deviceSettingsMutationCount = 0L
    buildCommandCount = 0L
  }
  Assert-CcrAlpha6Stage1FixtureOpenSmokeCheckpoint `
    $fixtureOpenSmokeCheckpoint $context | Out-Null
  $fixtureOpenSmokeCheckpointPath = Join-Path $context.OutputDirectory (
    "checkpoint-alpha6-stage1-fixture-open-smoke-$hostPreflightRunId.json"
  )
  Write-CcrAlpha6Stage1ImmutableJson `
    $fixtureOpenSmokeCheckpointPath $fixtureOpenSmokeCheckpoint | Out-Null

  $currentPhase = "device-settings"
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

  $currentPhase = "settings-settle"
  $settingsSettleResult = if ($null -ne $TestOnlySettingsSettleExecutor) {
    & $TestOnlySettingsSettleExecutor $context $hostPreflightRunId
  } else {
    Wait-CcrAlpha6Stage1DeviceSettingsSettled $context
  }
  if ($null -eq $settingsSettleResult) {
    throw "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED"
  }
  $settingsSettleCheckpoint = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-device-settings-settle"
    status = [string]$settingsSettleResult.status
    runId = $RunId
    attemptRunId = $hostPreflightRunId
    identity = $identity
    result = $settingsSettleResult
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    buildCommandCount = 0L
  }
  $settingsSettleCheckpointPath = Join-Path $context.OutputDirectory (
    "checkpoint-alpha6-stage1-settings-settle-$hostPreflightRunId.json"
  )
  Write-CcrAlpha6Stage1ImmutableJson `
    $settingsSettleCheckpointPath $settingsSettleCheckpoint | Out-Null
  if ([string]$settingsSettleResult.status -cne "PASS") {
    throw "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED"
  }
  Assert-CcrAlpha6Stage1SettingsSettleCheckpoint `
    $settingsSettleCheckpoint $context | Out-Null

  $currentPhase = "render-open-smoke"
  $renderOpenSmokeAttemptCount = if ($SurfaceTransitionGateOnly) {
    [long]$script:CcrAlpha6SurfaceTransitionRenderOpenRequiredCount
  } else {
    1L
  }
  for ($renderOrdinal = 1L; $renderOrdinal -le $renderOpenSmokeAttemptCount; $renderOrdinal += 1L) {
    $renderAttemptRunId = if ($SurfaceTransitionGateOnly) {
      "{0}-g{1:D2}" -f $hostPreflightRunId, $renderOrdinal
    } else {
      $hostPreflightRunId
    }
    $renderOpenSmokeDirectory = Join-Path $context.OutputDirectory (
      "attempt-$renderAttemptRunId-stage-render-open-smoke"
    )
    $renderOpenSmokeResult = $null
    $renderInvocationFailure = $null
    try {
      $renderOpenSmokeResult = Invoke-CcrAlpha6Stage1RenderOpenSmoke `
        -Context $context `
        -AttemptRunId $renderAttemptRunId `
        -StageDirectory $renderOpenSmokeDirectory
    } catch {
      $renderInvocationFailure = $_
    }
    $renderAttemptCleanup = Invoke-CcrAlpha6Stage1RenderAttemptCleanup `
      -Context $context -AttemptRunId $renderAttemptRunId
    if ($null -ne $renderInvocationFailure) {
      if ([string]$renderAttemptCleanup.status -cne "PASS") {
        throw "PRIMARY=$($renderInvocationFailure.Exception.Message); CLEANUP=ALPHA6_STAGE1_RENDER_ATTEMPT_CLEANUP_FAILED"
      }
      throw $renderInvocationFailure
    }
    if ($null -eq $renderOpenSmokeResult) {
      throw "ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED"
    }
    $renderEvidence = $null
    if (Test-CcrPinnedProperty $renderOpenSmokeResult "reportPath") {
      $renderEvidence = Get-CcrAlpha6Stage1FileRecord (
        [string](Get-CcrPinnedRequiredProperty $renderOpenSmokeResult "reportPath")
      )
    }
    $renderOpenSmokeCheckpoint = [PSCustomObject][ordered]@{
      schemaVersion = 1
      kind = "alpha6-stage1-render-open-smoke"
      status = [string]$renderOpenSmokeResult.status
      runId = $RunId
      attemptRunId = $renderAttemptRunId
      identity = $identity
      result = $renderOpenSmokeResult
      settingsSettleCheckpoint =
        Get-CcrAlpha6Stage1FileRecord $settingsSettleCheckpointPath
      attemptCleanup = $renderAttemptCleanup
      evidence = $renderEvidence
      completedAtUtc = [DateTime]::UtcNow.ToString("o")
      buildCommandCount = 0L
    }
    $renderOpenSmokeCheckpointPath = Join-Path $context.OutputDirectory (
      "checkpoint-alpha6-stage1-render-open-smoke-$renderAttemptRunId.json"
    )
    Write-CcrAlpha6Stage1ImmutableJson `
      $renderOpenSmokeCheckpointPath $renderOpenSmokeCheckpoint | Out-Null
    if ([string]$renderOpenSmokeResult.status -cne "PASS") {
      throw "ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED"
    }
    if ([string]$renderAttemptCleanup.status -cne "PASS") {
      throw "ALPHA6_STAGE1_RENDER_ATTEMPT_CLEANUP_FAILED"
    }
    Assert-CcrAlpha6Stage1RenderOpenSmokeCheckpoint `
      $renderOpenSmokeCheckpoint $context | Out-Null
    $renderOpenSmokeCheckpoints.Add($renderOpenSmokeCheckpoint) | Out-Null
    $renderOpenSmokeCheckpointFiles.Add(
      (Get-CcrAlpha6Stage1FileRecord $renderOpenSmokeCheckpointPath)
    ) | Out-Null
    $renderOpenSmokeRunIds.Add(
      [string](Get-CcrPinnedRequiredProperty $renderOpenSmokeResult "runId")
    ) | Out-Null
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  }

  if (-not $SurfaceTransitionGateOnly) {
    $currentPhase = "correctness"
    if ($Resume -and (Test-Path -LiteralPath $correctnessCheckpointPath -PathType Leaf)) {
    $correctnessCheckpoint = [System.IO.File]::ReadAllText($correctnessCheckpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null
  } else {
    if (Test-Path -LiteralPath $correctnessCheckpointPath) { throw "ALPHA6_STAGE1_CORRECTNESS_CHECKPOINT_ALREADY_EXISTS" }
    $correctnessDirectory = Join-Path $context.OutputDirectory "attempt-$hostPreflightRunId-stage-correctness"
    $correctnessResult = Invoke-CcrAlpha6Stage1Correctness $context $correctnessDirectory
    if ([string]$correctnessResult.status -cne "PASS") { throw "ALPHA6_STAGE1_CORRECTNESS_FAILED" }
    $evidence = @(if (Test-CcrPinnedProperty $correctnessResult "evidence") {
        @((Get-CcrPinnedRequiredProperty $correctnessResult "evidence"))
      } else {
        @(Get-CcrAlpha6Stage1DirectoryEvidence $correctnessDirectory)
      })
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
    Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null
    Write-CcrAlpha6Stage1ImmutableJson $correctnessCheckpointPath $correctnessCheckpoint | Out-Null
  }

  # Performance is intentionally unreachable unless the exact same artifact set
  # has a verified PASS correctness checkpoint in this session.
    Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
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
    Assert-CcrAlpha6Stage1Checkpoint $performanceCheckpoint "Performance" $context | Out-Null
    Write-CcrAlpha6Stage1ImmutableJson $performanceCheckpointPath $performanceCheckpoint | Out-Null
    }
  }
  Assert-CcrAlpha6Stage1Deadline "complete"
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
} catch {
  $primaryFailure = $_
  try {
    $postRunArtifactRehash = @(Get-CcrAlpha6Stage1ArtifactRecords $context)
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
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
  } elseif ($null -ne $preSettingsGateBaseline) {
    try {
      $finalPreSettingsGateSnapshot = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
      if (($preSettingsGateBaseline | ConvertTo-Json -Compress) -cne
          ($finalPreSettingsGateSnapshot | ConvertTo-Json -Compress)) {
        $cleanupFailures.Add("DEVICE_SETTINGS_MUTATED_BEFORE_STAGE1_SETTINGS") | Out-Null
      }
    } catch {
      $cleanupFailures.Add("PRE_SETTINGS_GATE_READBACK:$($_.Exception.Message)") | Out-Null
    }
  }
  try { Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null } catch {
    $cleanupFailures.Add("FINAL_ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
  if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
    $message = if ($null -ne $primaryFailure) { $primaryFailure.Exception.Message } else { "ALPHA6_STAGE1_CLEANUP_FAILED" }
    try {
      Write-CcrAlpha6Stage1Failure `
        -Context $context -Phase $currentPhase -Message $message `
        -RecoveredTraces $recovered -CleanupFailures $cleanupFailures.ToArray() `
        -PostRunArtifactRehash $postRunArtifactRehash `
        -FixtureOpenSmokeResult $fixtureOpenSmokeResult `
        -SettingsSettleCheckpoint $settingsSettleCheckpoint `
        -RenderOpenSmokeCheckpoint $renderOpenSmokeCheckpoint | Out-Null
    } catch { }
  }
}

if ($SurfaceTransitionGateOnly -and
    $null -eq $primaryFailure -and
    $cleanupFailures.Count -eq 0) {
  try {
    $cleanupVerification = Get-CcrAlpha6Stage1CleanupVerification $context
    $cleanupVerificationCheckpointPath = Join-Path $context.OutputDirectory (
      "checkpoint-alpha6-stage1-cleanup-$hostPreflightRunId.json"
    )
    Write-CcrAlpha6Stage1ImmutableJson `
      $cleanupVerificationCheckpointPath $cleanupVerification | Out-Null
    if ([string]$cleanupVerification.status -cne "PASS") {
      $cleanupFailures.Add("CLEANUP_VERIFICATION_FAILED") | Out-Null
    }
  } catch {
    $cleanupFailures.Add(
      "CLEANUP_VERIFICATION:$($_.Exception.Message)"
    ) | Out-Null
  }
}

if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }

if ($SurfaceTransitionGateOnly) {
  $requiredRenderCount =
    [long]$script:CcrAlpha6SurfaceTransitionRenderOpenRequiredCount
  if ($renderOpenSmokeCheckpoints.Count -ne $requiredRenderCount -or
      $renderOpenSmokeCheckpointFiles.Count -ne $requiredRenderCount -or
      $renderOpenSmokeRunIds.Count -ne $requiredRenderCount -or
      @($renderOpenSmokeRunIds | Select-Object -Unique).Count -ne
        $requiredRenderCount -or
      @($renderOpenSmokeCheckpoints | Where-Object {
        [string]$_.status -cne "PASS" -or
          [string]$_.attemptCleanup.status -cne "PASS" -or
          [long]$_.attemptCleanup.totalValidationProcessCount -ne 0L
      }).Count -ne 0 -or
      (Test-Path -LiteralPath $correctnessCheckpointPath) -or
      (Test-Path -LiteralPath $performanceCheckpointPath) -or
      (($preRunArtifactRehash | ConvertTo-Json -Depth 20 -Compress) -cne
        ($postRunArtifactRehash | ConvertTo-Json -Depth 20 -Compress))) {
    throw "ALPHA6_STAGE1_SURFACE_TRANSITION_SUMMARY_CONTRACT_MISMATCH"
  }
  $summary = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-stage1-surface-transition-gate"
    status = "PASS"
    technicalGateStatus = "PASS"
    s24GateStatus = "SURFACE_TRANSITION_GATE_PASS_STAGE1_PENDING"
    nextRequiredAction =
      "RUN_FRESH_FULL_STAGE1_WITH_THE_SURFACE_STABLE_REV5_ARTIFACT_SET"
    releaseEligible = $false
    resumeEligible = $false
    fullStage1Executed = $false
    identity = $identity
    maxMinutes = $MaxMinutes
    stageOrder = @($script:CcrAlpha6Stage1StageOrder)
    executedStageOrder = @(
      "IdentitySmoke",
      "FixtureOpenSmoke",
      "DeviceSettings",
      "SettingsSettle",
      "RenderOpenSmoke"
    )
    skippedStageOrder = @("Correctness", "Performance")
    identitySmoke = $identitySmokeCheckpoint
    identitySmokeCheckpointFile =
      Get-CcrAlpha6Stage1FileRecord $identitySmokeCheckpointPath
    fixtureOpenSmoke = $fixtureOpenSmokeCheckpoint
    fixtureOpenSmokeCheckpointFile =
      Get-CcrAlpha6Stage1FileRecord $fixtureOpenSmokeCheckpointPath
    settingsSettle = $settingsSettleCheckpoint
    settingsSettleCheckpointFile =
      Get-CcrAlpha6Stage1FileRecord $settingsSettleCheckpointPath
    renderOpenSmokes = $renderOpenSmokeCheckpoints.ToArray()
    renderOpenSmokeCheckpointFiles = $renderOpenSmokeCheckpointFiles.ToArray()
    renderOpenSmokeRunIds = $renderOpenSmokeRunIds.ToArray()
    renderOpenSmokeRequiredCount = $requiredRenderCount
    renderOpenSmokePassCount = $renderOpenSmokeCheckpoints.Count
    renderOpenAttemptCleanupPassCount = @(
      $renderOpenSmokeCheckpoints | Where-Object {
        [string]$_.attemptCleanup.status -ceq "PASS" -and
          [long]$_.attemptCleanup.totalValidationProcessCount -eq 0L
      }
    ).Count
    surfaceStableIntervalMs = 300L
    correctnessExecutedTestCount = 0L
    performanceScenarioCount = 0L
    deviceSettingsPreflight = $settingsPreflight
    cleanupVerification = $cleanupVerification
    cleanupVerificationCheckpointFile =
      Get-CcrAlpha6Stage1FileRecord $cleanupVerificationCheckpointPath
    debugArtifactInstallSetCount = 1L
    debugArtifactInstallCommandCount = 2L
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    settingsRestored = $cleanupVerification.settingsRestored
    packageCleanupStatus = "PASS"
    auxiliaryDecoderUsed = $false
    userSmoothnessStatus = "PENDING_USER"
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6Stage1ImmutableJson $summaryPath $summary | Out-Null
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}

$summary = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-stage1-single-decoder"
  status = "PENDING_USER"
  technicalGateStatus = "PASS"
  releaseEligible = $false
  identity = $identity
  maxMinutes = $MaxMinutes
  stageOrder = @($script:CcrAlpha6Stage1StageOrder)
  identitySmoke = $identitySmokeCheckpoint
  fixtureOpenSmoke = $fixtureOpenSmokeCheckpoint
  settingsSettle = $settingsSettleCheckpoint
  renderOpenSmoke = $renderOpenSmokeCheckpoint
  settingsSettleCheckpointFile =
    Get-CcrAlpha6Stage1FileRecord $settingsSettleCheckpointPath
  renderOpenSmokeCheckpointFile =
    Get-CcrAlpha6Stage1FileRecord $renderOpenSmokeCheckpointPath
  correctness = $correctnessCheckpoint
  performance = $performanceCheckpoint
  deviceSettingsPreflight = $settingsPreflight
  debugArtifactInstallSetCount = 1L
  debugArtifactInstallCommandCount = 2L
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
