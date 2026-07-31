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
  [Parameter(DontShow = $true)][scriptblock]$TestOnlyExecutor = $null
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
  $null -ne $TestOnlyExecutor
if ($testHookUsed -and $env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE -cne "1") {
  throw "ALPHA6_RENDER_OPEN_TEST_HOOK_FORBIDDEN"
}

Assert-CcrPinnedRunId $RunId | Out-Null
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
$adbDeadlineState = [PSCustomObject]@{
  ValidationDeadlineUtc = $deadlineUtc
  CleanupMode = $false
  CleanupDeadlineUtc = $deadlineUtc
}

function Assert-CcrAlpha6RenderOpenDeadline {
  param([Parameter(Mandatory = $true)][string]$Phase)
  if ([DateTime]::UtcNow -ge $deadlineUtc) {
    throw "ALPHA6_RENDER_OPEN_MAX_MINUTES_EXCEEDED:$Phase"
  }
}

function Write-CcrAlpha6RenderOpenImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $full) { throw "ALPHA6_RENDER_OPEN_EVIDENCE_ALREADY_EXISTS:$full" }
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

function Get-CcrAlpha6RenderOpenArtifactRecords {
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

function Test-CcrAlpha6RenderOpenSettingsEqual {
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

$summaryPath = Join-Path $context.OutputDirectory "alpha6-render-open-smoke-summary-$RunId.json"
$settingsPath = Join-Path $context.OutputDirectory "alpha6-render-open-smoke-settings-$RunId.json"
$attemptDirectory = Join-Path $context.OutputDirectory "attempt-$RunId-render-open-smoke"
$preRunArtifactRehash = @(Get-CcrAlpha6RenderOpenArtifactRecords $context)
$preRunPublicSigningIdentity = $context.PublicSigningIdentity
$settingsBefore = Get-CcrAlpha6CandidateDeviceSettingsSnapshot $context
$renderOpenResult = $null
$settingsAfter = $null
$postRunArtifactRehash = $null
$postRunPublicSigningIdentity = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null
$primaryFailureClassification = $null
$allowedFailureClassifications = @(
  "SURFACE_NOT_STABLE_BEFORE_OPEN",
  "SURFACE_LOST_DURING_OPEN",
  "STALE_ACTIVITY_INSTANCE",
  "PROVIDER_OR_EXTRACTOR_OPEN_FAILURE",
  "DECODER_SURFACE_UNAVAILABLE",
  "UNCLASSIFIED_AFTER_STABLE_SURFACE"
)

try {
  Assert-CcrAlpha6RenderOpenDeadline "instrumentation"
  if ($null -ne $TestOnlyExecutor) {
    $renderOpenResult = & $TestOnlyExecutor $context $RunId $attemptDirectory
  } else {
    $renderOpenResult = Invoke-CcrAlpha6CandidateRenderOpenInstrumentation `
      -Context $context -RunId $RunId -EvidenceDirectory $attemptDirectory
  }
  if ($null -eq $renderOpenResult -or [string]$renderOpenResult.status -cne "PASS") {
    $classification = if ($null -ne $renderOpenResult -and
        (Test-CcrPinnedProperty $renderOpenResult "failure")) {
      [string](Get-CcrPinnedRequiredProperty $renderOpenResult.failure "classification")
    } else {
      "UNCLASSIFIED_AFTER_STABLE_SURFACE"
    }
    if ($classification -notin $allowedFailureClassifications) {
      $classification = "UNCLASSIFIED_AFTER_STABLE_SURFACE"
    }
    $primaryFailureClassification = $classification
    throw "ALPHA6_RENDER_OPEN_SMOKE_FAILED:$classification"
  }
  if ([long](Get-CcrPinnedRequiredProperty $renderOpenResult "buildCommandCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $renderOpenResult "performanceScenarioCount") -ne 0L) {
    throw "ALPHA6_RENDER_OPEN_SMOKE_RESULT_CONTRACT_MISMATCH"
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  $postRunArtifactRehash = @(Get-CcrAlpha6RenderOpenArtifactRecords $context)
  Assert-CcrAlpha6RenderOpenDeadline "complete"
} catch {
  $primaryFailure = $_
  if ([string]::IsNullOrWhiteSpace($primaryFailureClassification)) {
    $primaryFailureClassification = "UNCLASSIFIED_AFTER_STABLE_SURFACE"
  }
  try {
    $postRunArtifactRehash = @(Get-CcrAlpha6RenderOpenArtifactRecords $context)
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
    if (-not (Test-CcrAlpha6RenderOpenSettingsEqual $settingsBefore $settingsAfter)) {
      $cleanupFailures.Add("DEVICE_SETTINGS_MUTATED_DURING_RENDER_OPEN_SMOKE") | Out-Null
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
      $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_CHANGED_DURING_RENDER_OPEN_SMOKE") | Out-Null
    }
  } catch {
    $cleanupFailures.Add("PUBLIC_SIGNING_IDENTITY_REHASH:$($_.Exception.Message)") | Out-Null
  }
}

$settingsEvidence = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-render-open-smoke-device-settings"
  status = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6RenderOpenSettingsEqual $settingsBefore $settingsAfter)) { "PASS" } else { "FAIL" })
  runId = $RunId
  before = $settingsBefore
  after = $settingsAfter
  deviceSettingsMutationCount = $(if ($null -ne $settingsAfter -and
      (Test-CcrAlpha6RenderOpenSettingsEqual $settingsBefore $settingsAfter)) { 0L } else { 1L })
}
Write-CcrAlpha6RenderOpenImmutableJson $settingsPath $settingsEvidence | Out-Null

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  $failurePath = Join-Path $context.OutputDirectory (
    "failure-alpha6-render-open-smoke-$RunId-$([Guid]::NewGuid().ToString('N')).json"
  )
  $failure = [ordered]@{
    schemaVersion = 1
    kind = "alpha6-candidate-render-open-smoke-failure"
    status = "FAIL"
    runId = $RunId
    error = $(if ($null -ne $primaryFailure) {
        $primaryFailure.Exception.Message
      } else {
        "ALPHA6_RENDER_OPEN_SMOKE_CLEANUP_FAILED"
      })
    failure = $(if ($null -ne $renderOpenResult -and
        (Test-CcrPinnedProperty $renderOpenResult "failure")) {
        $renderOpenResult.failure
      } else {
        [ordered]@{
          classification = $(if ([string]::IsNullOrWhiteSpace($primaryFailureClassification)) {
              "UNCLASSIFIED_AFTER_STABLE_SURFACE"
            } else {
              $primaryFailureClassification
            })
          stageCode = "HOST_RENDER_OPEN_GATE"
          exceptionClass = $(if ($null -ne $primaryFailure) {
              [string]$primaryFailure.Exception.GetType().Name
            } else {
              "CleanupFailure"
            })
          sanitizedDetail = "SEE_ERROR_AND_IMMUTABLE_RENDER_EVIDENCE"
        }
      })
    renderOpen = $renderOpenResult
    cleanupFailures = $cleanupFailures.ToArray()
    settingsEvidencePath = $settingsPath
    preRunArtifactRehash = $preRunArtifactRehash
    postRunArtifactRehash = $postRunArtifactRehash
    preRunPublicSigningIdentity = $preRunPublicSigningIdentity
    postRunPublicSigningIdentity = $postRunPublicSigningIdentity
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrAlpha6RenderOpenImmutableJson $failurePath $failure | Out-Null
  if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
    throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
  }
  if ($null -ne $primaryFailure) { throw $primaryFailure }
  throw "ALPHA6_RENDER_OPEN_SMOKE_CLEANUP_FAILED:$($cleanupFailures -join '|')"
}

$summary = [ordered]@{
  schemaVersion = 1
  kind = "alpha6-candidate-render-open-smoke"
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
  renderOpen = $renderOpenResult
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
Write-CcrAlpha6RenderOpenImmutableJson $summaryPath $summary | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
