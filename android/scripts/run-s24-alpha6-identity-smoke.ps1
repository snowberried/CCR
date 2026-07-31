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
  [Parameter(DontShow = $true)][object]$TestOnlyAndroidTools = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyIdentityReader = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySourceIdentityVerifier = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyAdbInvoker = $null,
  [Parameter(DontShow = $true)][scriptblock]$TestOnlySmokeExecutor = $null
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$candidateBridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
$candidateArtifactsPath = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
$candidateSigningCommonPath = Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"
$alpha6HistoricalPinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinnedPath = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
. $candidateBridgePath

$testHookUsed = $null -ne $TestOnlyAndroidTools -or $null -ne $TestOnlyIdentityReader -or
  $null -ne $TestOnlySourceIdentityVerifier -or $null -ne $TestOnlyAdbInvoker -or
  $null -ne $TestOnlySmokeExecutor
if ($testHookUsed -and $env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE -cne "1") {
  throw "ALPHA6_IDENTITY_SMOKE_TEST_HOOK_FORBIDDEN"
}

Assert-CcrPinnedRunId $RunId | Out-Null
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)

function Assert-CcrAlpha6IdentitySmokeDeadline {
  param([Parameter(Mandatory = $true)][string]$Phase)
  if ([DateTime]::UtcNow -ge $deadlineUtc) {
    throw "ALPHA6_IDENTITY_SMOKE_MAX_MINUTES_EXCEEDED:$Phase"
  }
}

function Write-CcrAlpha6IdentitySmokeImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $full) { throw "ALPHA6_IDENTITY_SMOKE_EVIDENCE_ALREADY_EXISTS:$full" }
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
  [System.IO.File]::WriteAllText(
    $full,
    (($Value | ConvertTo-Json -Depth 40) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  (Get-Item -LiteralPath $full).IsReadOnly = $true
  return $full
}

function Get-CcrAlpha6IdentitySmokeArtifactRecords {
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

function Test-CcrAlpha6IdentitySmokeSettingsEqual {
  param([Parameter(Mandatory = $true)][object]$Before, [Parameter(Mandatory = $true)][object]$After)
  return ($Before | ConvertTo-Json -Compress) -ceq ($After | ConvertTo-Json -Compress)
}

$androidTools = if ($null -ne $TestOnlyAndroidTools) {
  $TestOnlyAndroidTools
} else {
  Get-CcrPinnedAndroidSdkTools
}
$closedValidationScripts = @(
  $runnerPath,
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
$context | Add-Member -Force -NotePropertyName AdbInvoker -NotePropertyValue $TestOnlyAdbInvoker
$device = Get-CcrPinnedS24Device $androidTools.Adb $TestOnlyAdbInvoker
foreach ($name in @("Serial", "Model", "Fingerprint", "SecurityPatch", "Sdk")) {
  $context | Add-Member -Force -NotePropertyName $name -NotePropertyValue $device.$name
}

$summaryPath = Join-Path $context.OutputDirectory "alpha6-identity-smoke-summary-$RunId.json"
$settingsPath = Join-Path $context.OutputDirectory "alpha6-identity-smoke-settings-$RunId.json"
$attemptDirectory = Join-Path $context.OutputDirectory "attempt-$RunId-identity-smoke"
$preRunArtifactRehash = @(Get-CcrAlpha6IdentitySmokeArtifactRecords $context)
$preRunPublicSigningIdentity = $context.PublicSigningIdentity
$settingsBefore = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
$smokeResult = $null
$settingsAfter = $null
$postRunArtifactRehash = $null
$postRunPublicSigningIdentity = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null

try {
  Assert-CcrAlpha6IdentitySmokeDeadline "instrumentation"
  if ($null -ne $TestOnlySmokeExecutor) {
    $smokeResult = & $TestOnlySmokeExecutor $context $RunId $attemptDirectory
  } else {
    $smokeResult = Invoke-CcrAlpha6CandidateIdentitySmokeInstrumentation `
      -Context $context -RunId "$RunId-id" -EvidenceDirectory $attemptDirectory
  }
  if ($null -eq $smokeResult -or [string]$smokeResult.status -cne "PASS") {
    throw "ALPHA6_IDENTITY_SMOKE_INSTRUMENTATION_FAILED"
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6IdentitySmokeArtifactRecords $context)
} catch {
  $primaryFailure = $_
  try { $postRunArtifactRehash = @(Get-CcrAlpha6IdentitySmokeArtifactRecords $context) } catch {
    $cleanupFailures.Add("ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
} finally {
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) {
      $cleanupFailures.Add([string]$failure) | Out-Null
    }
  } catch {
    $cleanupFailures.Add("PACKAGE_CLEANUP:$($_.Exception.Message)") | Out-Null
  }
  try {
    $settingsAfter = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
    if (-not (Test-CcrAlpha6IdentitySmokeSettingsEqual $settingsBefore $settingsAfter)) {
      $cleanupFailures.Add("DEVICE_SETTINGS_MUTATED_DURING_IDENTITY_SMOKE") | Out-Null
    }
  } catch {
    $cleanupFailures.Add("DEVICE_SETTINGS_READBACK:$($_.Exception.Message)") | Out-Null
  }
  try { Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null } catch {
    $cleanupFailures.Add("FINAL_ARTIFACT_REHASH:$($_.Exception.Message)") | Out-Null
  }
  try {
    $postRunPublicSigningIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity
    if (($preRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress) -cne
        ($postRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress)) {
      $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_CHANGED_DURING_IDENTITY_SMOKE") | Out-Null
    }
  } catch {
    $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_REHASH:$($_.Exception.Message)") | Out-Null
  }
}

$settingsEvidence = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-identity-smoke-device-settings"
  status = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6IdentitySmokeSettingsEqual $settingsBefore $settingsAfter)) { "PASS" } else { "FAIL" })
  runId = $RunId
  before = $settingsBefore
  after = $settingsAfter
  deviceSettingsMutationCount = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6IdentitySmokeSettingsEqual $settingsBefore $settingsAfter)) { 0L } else { 1L })
}
Write-CcrAlpha6IdentitySmokeImmutableJson $settingsPath $settingsEvidence | Out-Null

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  $failurePath = Join-Path $context.OutputDirectory (
    "failure-alpha6-identity-smoke-$RunId-$([Guid]::NewGuid().ToString('N')).json"
  )
  $failure = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-candidate-identity-smoke-failure"
    status = "FAIL"
    runId = $RunId
    error = $(if ($null -ne $primaryFailure) {
        $primaryFailure.Exception.Message
      } else {
        "ALPHA6_IDENTITY_SMOKE_CLEANUP_FAILED"
      })
    cleanupFailures = $cleanupFailures.ToArray()
    settingsEvidencePath = $settingsPath
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    preRunPublicSigningIdentity = $preRunPublicSigningIdentity
    postRunPublicSigningIdentity = $postRunPublicSigningIdentity
    buildCommandCount = 0L
  }
  Write-CcrAlpha6IdentitySmokeImmutableJson $failurePath $failure | Out-Null
  if ($null -ne $primaryFailure) { throw $primaryFailure }
  throw "ALPHA6_IDENTITY_SMOKE_CLEANUP_FAILED:$($cleanupFailures -join '|')"
}

Assert-CcrAlpha6IdentitySmokeDeadline "complete"
$summary = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-candidate-identity-smoke"
  status = "PASS"
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
  smoke = $smokeResult
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
Write-CcrAlpha6IdentitySmokeImmutableJson $summaryPath $summary | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
