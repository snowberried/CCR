$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$bridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $bridgePath

$passed = 0
function Assert-CcrAlpha6CandidateBridgeTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_CANDIDATE_BRIDGE_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-CcrAlpha6CandidateBridgeThrows {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_CANDIDATE_BRIDGE_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function Copy-CcrAlpha6CandidateBridgeValue {
  param([Parameter(Mandatory = $true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-candidate-bridge-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
  $repo = Get-CcrCandidateRepoRoot
  $runtimeSource = "1" * 40
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $certificate = Get-CcrCandidatePublicPolicyFingerprint
  $otherCertificate = "4" * 64
  $roles = @(
    [PSCustomObject]@{ role = "debugApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "debugTest"; package = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedAppPackage },
    [PSCustomObject]@{ role = "benchmarkApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "macrobenchmarkTest"; package = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedMacrobenchmarkPackage }
  )
  $artifacts = [System.Collections.Generic.List[object]]::new()
  $identities = @{}
  $originalArtifactText = @{}
  foreach ($role in $roles) {
    $path = Join-Path $root "$($role.role).apk"
    $text = "candidate-bridge-$($role.role)"
    $originalArtifactText[$role.role] = $text
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    $artifacts.Add([PSCustomObject][ordered]@{
      role = $role.role
      path = $path
      bytes = (Get-Item -LiteralPath $path).Length
      sha256 = $sha
      packageName = $role.package
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $certificate
      runner = $role.runner
      targetPackage = $role.target
    }) | Out-Null
    $identities[$role.role] = [PSCustomObject]@{
      packageName = $role.package
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $certificate
      runner = $role.runner
      targetPackage = $role.target
    }
  }
  $manifest = [PSCustomObject][ordered]@{
    schemaVersion = 1
    artifactSetRevision = 5
    signingLineage = $script:CcrCandidateSigningLineage
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    expectedSigningCertificateSha256 = $certificate
    runtimeSourceSha = $runtimeSource
    harnessSourceSha = $harnessSource
    runtimeInputsTreeSha256 = $runtimeTree
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $artifacts.ToArray()
  }
  $manifestPath = Join-Path $root "artifact-manifest-v5.json"
  function Write-CcrAlpha6CandidateBridgeManifest {
    param([object]$Value = $manifest, [string]$Path = $manifestPath)
    [System.IO.File]::WriteAllText(
      $Path,
      (($Value | ConvertTo-Json -Depth 15) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
  $manifestSha = Write-CcrAlpha6CandidateBridgeManifest
  $debugSha = [string]$artifacts[0].sha256
  $tools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $closedScripts = @(
    (Join-Path $PSScriptRoot "run-s24-alpha6-stage1.ps1"),
    $bridgePath,
    (Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"),
    (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"),
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"),
    (Join-Path $PSScriptRoot "alpha6-tail-contract.ps1")
  ) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
  $script:nextRun = 0
  function Invoke-CcrAlpha6CandidateBridgeTestPreflight {
    param(
      [object]$Manifest = $manifest,
      [scriptblock]$Reader = $identityReader,
      [string]$ExpectedDebugSha = $debugSha,
      [long]$BuildCommandCount = 0L,
      [string[]]$Scripts = $closedScripts,
      [string]$ExpectedManifestSha = $null,
      [string]$RunId = $null
    )
    $path = Join-Path $root "manifest-$([Guid]::NewGuid().ToString('N')).json"
    $sha = Write-CcrAlpha6CandidateBridgeManifest $Manifest $path
    if ([string]::IsNullOrEmpty($ExpectedManifestSha)) { $ExpectedManifestSha = $sha }
    if ([string]::IsNullOrEmpty($RunId)) {
      $script:nextRun += 1
      $RunId = "bridge-$($script:nextRun)"
    }
    return Invoke-CcrAlpha6CandidateDeviceHostPreflight `
      -ArtifactManifest $path `
      -ArtifactManifestSha256 $ExpectedManifestSha `
      -OutputDirectory (Join-Path $root "output") `
      -RunId $RunId `
      -RuntimeSourceSha $runtimeSource `
      -HarnessSourceSha $harnessSource `
      -RuntimeInputsTreeSha256 $runtimeTree `
      -ExpectedDebugAppSha256 $ExpectedDebugSha `
      -PreflightOnly $true `
      -BuildCommandCount $BuildCommandCount `
      -ValidationScriptPaths $Scripts `
      -RepoRoot $repo `
      -AndroidTools $tools `
      -IdentityReader $Reader `
      -SourceIdentityVerifier $sourceVerifier
  }

  $context = Invoke-CcrAlpha6CandidateBridgeTestPreflight -RunId "bridge-positive"
  Assert-CcrAlpha6CandidateBridgeTest (
    [int]$context.ArtifactSet.Manifest.artifactSetRevision -eq 5 -and
      [string]$context.PublicSigningIdentity.signingMode -ceq "SIGNED_CANDIDATE" -and
      $context.PublicSigningIdentity.candidateSigning -eq $true -and
      [string]$context.PublicSigningIdentity.signingLineage -ceq "ccr-internal-pilot-v1" -and
      [string]$context.PublicSigningIdentity.expectedSigningCertificateSha256 -ceq $certificate
  ) "positive-candidate-identity"
  Assert-CcrAlpha6CandidateBridgeTest (
    @($context.ValidationScripts).Count -eq 7 -and
      @($context.PublicSigningIdentity.publicPolicy, $context.PublicSigningIdentity.publicFingerprint,
        $context.PublicSigningIdentity.publicCertificate | Where-Object {
          [string]$_.sha256 -cmatch "^[a-f0-9]{64}$" -and [long]$_.bytes -gt 0L
        }).Count -eq 3
  ) "closed-scripts-and-public-policy-records"
  Assert-CcrAlpha6CandidateBridgeTest (
    $context.BuildCommandCount -eq 0L -and (Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context)
  ) "zero-build-and-post-import-rehash"

  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateDeviceHostPreflight `
      -ArtifactManifest $context.ArtifactSet.ManifestPath `
      -ArtifactManifestSha256 $context.ArtifactSet.ManifestSha256 `
      -OutputDirectory $context.OutputDirectory `
      -RunId "bridge-positive" `
      -RuntimeSourceSha $runtimeSource `
      -HarnessSourceSha $harnessSource `
      -RuntimeInputsTreeSha256 $runtimeTree `
      -ExpectedDebugAppSha256 $debugSha `
      -PreflightOnly $true `
      -BuildCommandCount 0L `
      -ValidationScriptPaths $closedScripts `
      -RepoRoot $repo `
      -AndroidTools $tools `
      -IdentityReader $identityReader `
      -SourceIdentityVerifier $sourceVerifier | Out-Null
  } "PINNED_RUN_ID_DUPLICATE:*" "duplicate-run-id"

  foreach ($revision in @(4, 6)) {
    $bad = Copy-CcrAlpha6CandidateBridgeValue $manifest
    $bad.artifactSetRevision = $revision
    Assert-CcrAlpha6CandidateBridgeThrows {
      Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $bad | Out-Null
    } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "revision-$revision-rejected"
  }
  foreach ($case in @(
    [PSCustomObject]@{ name = "mode"; property = "signingMode"; value = "CI_EPHEMERAL_DEBUG"; error = "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" },
    [PSCustomObject]@{ name = "candidate-false"; property = "candidateSigning"; value = $false; error = "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" },
    [PSCustomObject]@{ name = "lineage"; property = "signingLineage"; value = "other-lineage"; error = "CANDIDATE_MANIFEST_LINEAGE_MISMATCH" },
    [PSCustomObject]@{ name = "fingerprint"; property = "expectedSigningCertificateSha256"; value = $otherCertificate; error = "CANDIDATE_MANIFEST_PUBLIC_POLICY_MISMATCH" }
  )) {
    $bad = Copy-CcrAlpha6CandidateBridgeValue $manifest
    $bad.($case.property) = $case.value
    Assert-CcrAlpha6CandidateBridgeThrows {
      Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $bad | Out-Null
    } $case.error "$($case.name)-rejected"
  }
  $missingMode = Copy-CcrAlpha6CandidateBridgeValue $manifest
  $missingMode.PSObject.Properties.Remove("signingMode")
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $missingMode | Out-Null
  } "PINNED_MANIFEST_PROPERTY_MISSING:signingMode" "missing-signing-mode-rejected"

  $identityCases = @(
    [PSCustomObject]@{ name = "actual-signer"; role = "debugApp"; property = "signingCertificateSha256"; value = $otherCertificate; error = "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:debugApp" },
    [PSCustomObject]@{ name = "mixed-signer"; role = "macrobenchmarkTest"; property = "signingCertificateSha256"; value = $otherCertificate; error = "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:macrobenchmarkTest" },
    [PSCustomObject]@{ name = "wrong-package"; role = "debugApp"; property = "packageName"; value = "invalid.package"; error = "PINNED_ARTIFACT_PACKAGE_MISMATCH:debugApp" },
    [PSCustomObject]@{ name = "wrong-version"; role = "benchmarkApp"; property = "versionCode"; value = 8; error = "PINNED_ARTIFACT_VERSION_CODE_INSPECTION_MISMATCH:benchmarkApp" },
    [PSCustomObject]@{ name = "wrong-runner"; role = "debugTest"; property = "runner"; value = "invalid.Runner"; error = "PINNED_ARTIFACT_RUNNER_INSPECTION_MISMATCH:debugTest" },
    [PSCustomObject]@{ name = "wrong-target"; role = "macrobenchmarkTest"; property = "targetPackage"; value = "invalid.target"; error = "PINNED_ARTIFACT_TARGET_INSPECTION_MISMATCH:macrobenchmarkTest" }
  )
  foreach ($case in $identityCases) {
    $original = $identities[$case.role].($case.property)
    $identities[$case.role].($case.property) = $case.value
    try {
      Assert-CcrAlpha6CandidateBridgeThrows {
        Invoke-CcrAlpha6CandidateBridgeTestPreflight | Out-Null
      } $case.error "$($case.name)-rejected"
    } finally {
      $identities[$case.role].($case.property) = $original
    }
  }
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -ExpectedDebugSha ("5" * 64) | Out-Null
  } "PINNED_DEBUG_APP_SHA_MISMATCH" "debug-app-expected-sha-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -ExpectedManifestSha ("6" * 64) | Out-Null
  } "ALPHA6_MANIFEST_SHA_MISMATCH" "manifest-sha-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -BuildCommandCount 1L | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO" "build-count-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @() | Out-Null
  } "ALPHA6_VALIDATION_SCRIPT_SET_EMPTY" "closed-script-missing-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @($closedScripts[0], $closedScripts[0]) | Out-Null
  } "ALPHA6_VALIDATION_SCRIPT_DUPLICATE:*" "closed-script-duplicate-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @(
      [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "run-s24-battery-validation.ps1"))
    ) | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COMMAND_FORBIDDEN:*" "validation-build-command-rejected"

  [System.IO.File]::AppendAllText($context.ArtifactSet.ManifestPath, "tamper", [System.Text.UTF8Encoding]::new($false))
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  } "ALPHA6_ARTIFACT_MANIFEST_CHANGED_AFTER_PREFLIGHT" "manifest-tamper-after-preflight"
  Write-CcrAlpha6CandidateBridgeManifest $manifest $context.ArtifactSet.ManifestPath | Out-Null
  [System.IO.File]::AppendAllText($artifacts[0].path, "tamper", [System.Text.UTF8Encoding]::new($false))
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  } "ALPHA6_ARTIFACT_CHANGED_AFTER_PREFLIGHT:debugApp" "artifact-tamper-after-preflight"
  [System.IO.File]::WriteAllText(
    $artifacts[0].path,
    [string]$originalArtifactText["debugApp"],
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-CcrAlpha6CandidateBridgeTest (Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context) "artifact-restored"

  $publicCopy = Join-Path $root "public-policy"
  [System.IO.Directory]::CreateDirectory($publicCopy) | Out-Null
  foreach ($name in @(
    "ccr-internal-pilot-v1-policy.json",
    "ccr-internal-pilot-v1-cert.sha256",
    "ccr-internal-pilot-v1-cert.pem"
  )) {
    [System.IO.File]::Copy((Join-Path $repo "android\signing\$name"), (Join-Path $publicCopy $name), $false)
  }
  $copiedIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity -RepoRoot $repo -SigningDirectory $publicCopy
  $publicContext = [PSCustomObject]@{ PublicSigningIdentity = $copiedIdentity }
  [System.IO.File]::AppendAllText(
    (Join-Path $publicCopy "ccr-internal-pilot-v1-policy.json"),
    " ",
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged $publicContext | Out-Null
  } "ALPHA6_CANDIDATE_PUBLIC_POLICY_CHANGED_AFTER_PREFLIGHT:publicPolicy" "public-policy-drift-rejected"

  $historicalSource = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    [System.Text.Encoding]::UTF8
  )
  $bridgeSource = [System.IO.File]::ReadAllText($bridgePath, [System.Text.Encoding]::UTF8)
  Assert-CcrAlpha6CandidateBridgeTest (
    $historicalSource.Contains('$script:CcrPinnedArtifactSetRevision = 4') -and
      $historicalSource.Contains("Invoke-CcrAlpha6PinnedHostPreflight") -and
      $bridgeSource.Contains("Import-CcrAlpha6CandidateArtifactManifest")
  ) "historical-v4-preserved-active-v5-explicit"
} finally {
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "Alpha 6 candidate device bridge host tests passed: $passed"
