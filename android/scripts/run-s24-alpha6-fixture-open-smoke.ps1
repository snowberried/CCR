param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
  [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
  [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$RunId,
  [ValidateRange(1, 30)][int]$MaxMinutes = 10,
  [Parameter(DontShow = $true)][ValidateSet("Smoke", "Diagnostic")][string]$Mode = "Smoke",
  [Parameter(DontShow = $true)][object]$TestOnlyAndroidTools = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyIdentityReader = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySourceIdentityVerifier = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyAdbInvoker = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyExecutor = $null
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$diagnosticRunnerPath = Join-Path $PSScriptRoot "run-s24-alpha6-fixture-open-diagnostic.ps1"
$candidateBridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
$candidateArtifactsPath = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
$candidateSigningCommonPath = Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"
$alpha6HistoricalPinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinnedPath = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
. $candidateBridgePath

$testHookUsed = $null -ne $TestOnlyAndroidTools -or $null -ne $TestOnlyIdentityReader -or
  $null -ne $TestOnlySourceIdentityVerifier -or $null -ne $TestOnlyAdbInvoker -or
  $null -ne $TestOnlyExecutor
if ($testHookUsed -and $env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE -cne "1") {
  throw "ALPHA6_FIXTURE_OPEN_TEST_HOOK_FORBIDDEN"
}

Assert-CcrPinnedRunId $RunId | Out-Null
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
$adbDeadlineState = [PSCustomObject]@{
  ValidationDeadlineUtc = $deadlineUtc
  CleanupMode = $false
  CleanupDeadlineUtc = $deadlineUtc
}
$modeSlug = $Mode.ToLowerInvariant()
$evidencePrefix = "alpha6-fixture-open-$modeSlug"
$summaryKind = "alpha6-candidate-fixture-open-$modeSlug"
$settingsMutationCode = if ($Mode -ceq "Smoke") {
  "DEVICE_SETTINGS_MUTATED_DURING_FIXTURE_OPEN_SMOKE"
} else {
  "DEVICE_SETTINGS_MUTATED_DURING_FIXTURE_OPEN_DIAGNOSTIC"
}

function Assert-CcrAlpha6FixtureOpenDeadline {
  param([Parameter(Mandatory = $true)][string]$Phase)
  if ([DateTime]::UtcNow -ge $deadlineUtc) {
    throw "ALPHA6_FIXTURE_OPEN_MAX_MINUTES_EXCEEDED:$Mode/$Phase"
  }
}

function Write-CcrAlpha6FixtureOpenImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $full) { throw "ALPHA6_FIXTURE_OPEN_EVIDENCE_ALREADY_EXISTS:$full" }
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
  $stream = [System.IO.File]::Open(
    $full,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read
  )
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
      (($Value | ConvertTo-Json -Depth 50) + "`n")
    )
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  (Get-Item -LiteralPath $full).IsReadOnly = $true
  return $full
}

function Get-CcrAlpha6FixtureOpenArtifactRecords {
  param([Parameter(Mandatory = $true)][object]$Context)
  return @($Context.ArtifactSet.Artifacts.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $item = Get-Item -LiteralPath ([string]$_.Value.path)
    [PSCustomObject][ordered]@{
      role = [string]$_.Key
      path = $item.FullName
      bytes = [long]$item.Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
    }
  })
}

function Test-CcrAlpha6FixtureOpenSettingsEqual {
  param([Parameter(Mandatory = $true)][object]$Before, [Parameter(Mandatory = $true)][object]$After)
  return ($Before | ConvertTo-Json -Compress) -ceq ($After | ConvertTo-Json -Compress)
}

$androidTools = if ($null -ne $TestOnlyAndroidTools) {
  $TestOnlyAndroidTools
} else {
  Get-CcrPinnedAndroidSdkTools
}
$effectiveAdbInvoker = if ($null -ne $TestOnlyAdbInvoker) {
  $TestOnlyAdbInvoker
} else {
  New-CcrAlpha6TimedAdbInvoker ([string]$androidTools.Adb) $adbDeadlineState
}
$closedValidationScripts = @(
  $runnerPath,
  [System.IO.Path]::GetFullPath($diagnosticRunnerPath),
  [System.IO.Path]::GetFullPath($candidateBridgePath),
  [System.IO.Path]::GetFullPath($candidateArtifactsPath),
  [System.IO.Path]::GetFullPath($candidateSigningCommonPath),
  [System.IO.Path]::GetFullPath($alpha6HistoricalPinnedPath),
  [System.IO.Path]::GetFullPath($basePinnedPath)
)
$hostParameters = @{
  ArtifactManifest = $ArtifactManifest
  ArtifactManifestSha256 = $ArtifactManifestSha256
  OutputDirectory = $OutputDirectory
  RunId = $RunId
  RuntimeSourceSha = $RuntimeSourceSha
  HarnessSourceSha = $HarnessSourceSha
  RuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256
  ExpectedDebugAppSha256 = $ExpectedDebugAppSha256
  PreflightOnly = $false
  BuildCommandCount = 0L
  ValidationScriptPaths = $closedValidationScripts
  AndroidTools = $androidTools
}
if ($null -ne $TestOnlyIdentityReader) { $hostParameters.IdentityReader = $TestOnlyIdentityReader }
if ($null -ne $TestOnlySourceIdentityVerifier) {
  $hostParameters.SourceIdentityVerifier = $TestOnlySourceIdentityVerifier
}
$context = Invoke-CcrAlpha6CandidateDeviceHostPreflight @hostParameters
$context | Add-Member -Force -NotePropertyName AndroidTools -NotePropertyValue $androidTools
$context | Add-Member -Force -NotePropertyName Adb -NotePropertyValue ([string]$androidTools.Adb)
$context | Add-Member -Force -NotePropertyName AdbInvoker -NotePropertyValue $effectiveAdbInvoker
$device = Get-CcrPinnedS24Device $androidTools.Adb $effectiveAdbInvoker
foreach ($name in @("Serial", "Model", "Fingerprint", "SecurityPatch", "Sdk")) {
  $context | Add-Member -Force -NotePropertyName $name -NotePropertyValue $device.$name
}

$summaryPath = Join-Path $context.OutputDirectory "$evidencePrefix-summary-$RunId.json"
$settingsPath = Join-Path $context.OutputDirectory "$evidencePrefix-settings-$RunId.json"
$attemptDirectory = Join-Path $context.OutputDirectory "attempt-$RunId-fixture-open-$modeSlug"
$preRunArtifactRehash = @(Get-CcrAlpha6FixtureOpenArtifactRecords $context)
$preRunPublicSigningIdentity = $context.PublicSigningIdentity
$settingsBefore = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
$fixtureOpenResult = $null
$settingsAfter = $null
$postRunArtifactRehash = $null
$postRunPublicSigningIdentity = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null

try {
  Assert-CcrAlpha6FixtureOpenDeadline "instrumentation"
  if ($null -ne $TestOnlyExecutor) {
    $fixtureOpenResult = & $TestOnlyExecutor $context $RunId $attemptDirectory $Mode
  } else {
    $fixtureOpenResult = Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation `
      -Context $context `
      -RunId $RunId `
      -EvidenceDirectory $attemptDirectory `
      -Mode $Mode
  }
  if ($null -eq $fixtureOpenResult -or [string]$fixtureOpenResult.status -cne "PASS") {
    $fixtureFailure = if ($null -ne $fixtureOpenResult -and
        (Test-CcrPinnedProperty $fixtureOpenResult "failure")) {
      Get-CcrPinnedRequiredProperty $fixtureOpenResult "failure"
    } else {
      $null
    }
    $failureSuffix = if ($null -ne $fixtureFailure) {
      ":" +
        [string](Get-CcrPinnedRequiredProperty $fixtureFailure "classification") +
        "/" +
        [string](Get-CcrPinnedRequiredProperty $fixtureFailure "stageCode")
    } else {
      ""
    }
    throw "ALPHA6_FIXTURE_OPEN_$($Mode.ToUpperInvariant())_FAILED$failureSuffix"
  }
  $expectedFixtureCount = if ($Mode -ceq "Smoke") { 17L } else { 1L }
  if ([long](Get-CcrPinnedRequiredProperty $fixtureOpenResult "fixtureCount") -ne
        $expectedFixtureCount -or
      [long](Get-CcrPinnedRequiredProperty $fixtureOpenResult "buildCommandCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $fixtureOpenResult "fullFrameDecodeCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $fixtureOpenResult "performanceScenarioCount") -ne 0L) {
    throw "ALPHA6_FIXTURE_OPEN_$($Mode.ToUpperInvariant())_RESULT_CONTRACT_MISMATCH"
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6FixtureOpenArtifactRecords $context)
  Assert-CcrAlpha6FixtureOpenDeadline "complete"
} catch {
  $primaryFailure = $_
  try {
    $postRunArtifactRehash = @(Get-CcrAlpha6FixtureOpenArtifactRecords $context)
  } catch {
    $cleanupFailures.Add("ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
} finally {
  $adbDeadlineState.CleanupMode = $true
  $adbDeadlineState.CleanupDeadlineUtc = [DateTime]::UtcNow.AddMinutes(2)
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) {
      $cleanupFailures.Add([string]$failure) | Out-Null
    }
  } catch {
    $cleanupFailures.Add("PACKAGE_CLEANUP:$($_.Exception.Message)") | Out-Null
  }
  try {
    $settingsAfter = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
    if (-not (Test-CcrAlpha6FixtureOpenSettingsEqual $settingsBefore $settingsAfter)) {
      $cleanupFailures.Add($settingsMutationCode) | Out-Null
    }
  } catch {
    $cleanupFailures.Add("DEVICE_SETTINGS_READBACK:$($_.Exception.Message)") | Out-Null
  }
  try {
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  } catch {
    $cleanupFailures.Add("FINAL_ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
  try {
    $postRunPublicSigningIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity
    if (($preRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress) -cne
        ($postRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress)) {
      $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_CHANGED_DURING_FIXTURE_OPEN") | Out-Null
    }
  } catch {
    $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_REHASH:$($_.Exception.Message)") | Out-Null
  }
}

$settingsEvidence = [ordered]@{
  schemaVersion = 1
  kind = "$evidencePrefix-device-settings"
  status = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6FixtureOpenSettingsEqual $settingsBefore $settingsAfter)) { "PASS" } else { "FAIL" })
  mode = $Mode
  runId = $RunId
  before = $settingsBefore
  after = $settingsAfter
  deviceSettingsMutationCount = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6FixtureOpenSettingsEqual $settingsBefore $settingsAfter)) { 0L } else { 1L })
}
Write-CcrAlpha6FixtureOpenImmutableJson $settingsPath $settingsEvidence | Out-Null

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  $failurePath = Join-Path $context.OutputDirectory (
    "failure-$evidencePrefix-$RunId-$([Guid]::NewGuid().ToString('N')).json"
  )
  $failure = [ordered]@{
    schemaVersion = 1
    kind = "$summaryKind-failure"
    status = "FAIL"
    mode = $Mode
    runId = $RunId
    error = $(if ($null -ne $primaryFailure) {
        $primaryFailure.Exception.Message
      } else {
        "ALPHA6_FIXTURE_OPEN_$($Mode.ToUpperInvariant())_CLEANUP_FAILED"
      })
    fixtureOpen = $fixtureOpenResult
    cleanupFailures = $cleanupFailures.ToArray()
    settingsEvidencePath = $settingsPath
    identity = [ordered]@{
      runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
      harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
      runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
      artifactSetRevision =
        [int](Get-CcrPinnedRequiredProperty $context.ArtifactSet.Manifest "artifactSetRevision")
      signingLineage = [string]$context.PublicSigningIdentity.signingLineage
      expectedSigningCertificateSha256 =
        [string]$context.PublicSigningIdentity.expectedSigningCertificateSha256
      manifestPath = $context.ArtifactSet.ManifestPath
      manifestSha256 = $context.ArtifactSet.ManifestSha256
      device = [ordered]@{
        model = $context.Model
        fingerprint = $context.Fingerprint
        securityPatch = $context.SecurityPatch
        sdk = $context.Sdk
      }
    }
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    preRunPublicSigningIdentity = $preRunPublicSigningIdentity
    postRunPublicSigningIdentity = $postRunPublicSigningIdentity
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6FixtureOpenImmutableJson $failurePath $failure | Out-Null
  if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
    throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
  }
  if ($null -ne $primaryFailure) { throw $primaryFailure }
  throw "ALPHA6_FIXTURE_OPEN_$($Mode.ToUpperInvariant())_CLEANUP_FAILED:$($cleanupFailures -join '|')"
}

$summary = [ordered]@{
  schemaVersion = 1
  kind = $summaryKind
  status = "PASS"
  mode = $Mode
  runId = $RunId
  identity = [ordered]@{
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision =
      [int](Get-CcrPinnedRequiredProperty $context.ArtifactSet.Manifest "artifactSetRevision")
    signingLineage = [string]$context.PublicSigningIdentity.signingLineage
    expectedSigningCertificateSha256 =
      [string]$context.PublicSigningIdentity.expectedSigningCertificateSha256
    manifestPath = $context.ArtifactSet.ManifestPath
    manifestSha256 = $context.ArtifactSet.ManifestSha256
    device = [ordered]@{
      model = $context.Model
      fingerprint = $context.Fingerprint
      securityPatch = $context.SecurityPatch
      sdk = $context.Sdk
    }
  }
  fixtureOpen = $fixtureOpenResult
  settingsEvidencePath = $settingsPath
  deviceSettingsMutationCount = 0L
  cleanupFailures = @()
  preRunArtifactRehash = $preRunArtifactRehash
  postRunArtifactRehash = $postRunArtifactRehash
  preRunPublicSigningIdentity = $preRunPublicSigningIdentity
  postRunPublicSigningIdentity = $postRunPublicSigningIdentity
  buildCommandCount = 0L
  syntheticOnly = $true
  containsRealMediaMetadata = $false
}
Write-CcrAlpha6FixtureOpenImmutableJson $summaryPath $summary | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
