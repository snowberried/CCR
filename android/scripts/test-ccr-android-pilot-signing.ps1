$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "verify-ccr-android-pilot-signing.ps1")
. (Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1")
. (Join-Path $PSScriptRoot "build-s24-alpha6-candidate.ps1")

$passed = 0
function Assert-CcrCandidateTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "CANDIDATE_HOST_TEST_FAILED:$Name" }
  $script:passed += 1
}
function Assert-CcrCandidateThrows {
  param([scriptblock]$Action, [string]$Expected, [string]$Name, [string]$ForbiddenText = "")
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ([string]$message -cne $Expected) {
    throw "CANDIDATE_HOST_EXPECTED_THROW_FAILED:$Name/$message/$Expected"
  }
  if ($ForbiddenText -and ([string]$message).Contains($ForbiddenText)) {
    throw "CANDIDATE_HOST_SECRET_LEAK:$Name"
  }
  $script:passed += 1
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-candidate-signing-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$savedEnvironment = @{}
foreach ($name in $script:CcrCandidateEnvironmentNames) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
try {
  $certificate = "a" * 64
  $otherCertificate = "b" * 64
  $secretSentinel = "SENTINEL_PASSWORD_MUST_NOT_APPEAR"
  $primary = Join-Path $root "ccr-internal-pilot-v1.jks"
  $backup1 = Join-Path $root "backup-1"
  $backup2 = Join-Path $root "backup-2"
  [System.IO.Directory]::CreateDirectory($backup1) | Out-Null
  [System.IO.Directory]::CreateDirectory($backup2) | Out-Null
  [System.IO.File]::WriteAllText($primary, "fake-candidate-jks", [System.Text.UTF8Encoding]::new($false))
  foreach ($directory in @($backup1, $backup2)) {
    [System.IO.File]::Copy($primary, (Join-Path $directory "ccr-internal-pilot-v1.jks"), $false)
  }
  $fingerprintPath = Join-Path $root "ccr-internal-pilot-v1-cert.sha256"
  $certificatePath = Join-Path $root "ccr-internal-pilot-v1-cert.pem"
  $policyPath = Join-Path $root "ccr-internal-pilot-v1-policy.json"
  [System.IO.File]::WriteAllText(
    $fingerprintPath,
    "$certificate  ccr-internal-pilot-v1-cert.pem`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText($certificatePath, "fake-public-cert", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText(
    $policyPath,
    (([PSCustomObject][ordered]@{
      schemaVersion = 1
      status = "SIGNING_BASELINE_READY"
      purpose = $script:CcrCandidateSigningPurpose
      signingLineage = $script:CcrCandidateSigningLineage
      signingMode = "SIGNED_CANDIDATE"
      artifactSetRevision = 5
      alias = $script:CcrCandidateSigningAlias
      certificateSha256 = $certificate
      expectedSigningCertificateSha256 = $certificate
      subject = "CN=CCR Android Internal Pilot v1"
      keyAlgorithm = "RSA-4096"
    } | ConvertTo-Json) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $inputs = [PSCustomObject][ordered]@{
    KeyStorePath = $primary
    StorePassword = $secretSentinel
    Alias = $script:CcrCandidateSigningAlias
    KeyPassword = $secretSentinel
    ExpectedCertificateSha256 = $certificate
  }
  $inspector = {
    param($Path, $Alias, $StorePassword, $KeyPassword)
    if ($Alias -cne $script:CcrCandidateSigningAlias) {
      return [PSCustomObject]@{
        aliasPresent = $false
        privateKeyAccessible = $false
        certificateSha256 = $null
      }
    }
    return [PSCustomObject]@{
      aliasPresent = $true
      privateKeyAccessible = $true
      certificateSha256 = $certificate
    }
  }.GetNewClosure()
  $publicInspector = { param($Path) return $certificate }.GetNewClosure()

  foreach ($name in $script:CcrCandidateEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }
  Assert-CcrCandidateThrows {
    Get-CcrCandidateEnvironmentInputs | Out-Null
  } "CANDIDATE_SIGNING_NOT_READY" "candidate-mode-missing"

  [Environment]::SetEnvironmentVariable(
    "CCR_ANDROID_CANDIDATE_KEYSTORE_PASSWORD",
    $secretSentinel,
    "Process"
  )
  Assert-CcrCandidateThrows {
    Get-CcrCandidateEnvironmentInputs | Out-Null
  } "CANDIDATE_SIGNING_INPUT_INCOMPLETE" "candidate-mode-partial" $secretSentinel
  foreach ($name in $script:CcrCandidateEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }

  $ready = Invoke-CcrAndroidPilotSigningPreflight `
    -Inputs $inputs `
    -BackupDirectory1 $backup1 `
    -BackupDirectory2 $backup2 `
    -FingerprintPath $fingerprintPath `
    -CertificatePath $certificatePath `
    -PolicyPath $policyPath `
    -KeyStoreInspector $inspector `
    -PublicCertificateInspector $publicInspector
  Assert-CcrCandidateTest ($ready.status -ceq "SIGNING_BASELINE_READY" -and
      $ready.verifiedBackupCount -eq 2 -and
      $ready.certificateSha256 -ceq $certificate) "preflight-valid"

  $badAlias = [PSCustomObject][ordered]@{
    KeyStorePath = $primary
    StorePassword = $secretSentinel
    Alias = "wrong-alias"
    KeyPassword = $secretSentinel
    ExpectedCertificateSha256 = $certificate
  }
  Assert-CcrCandidateThrows {
    Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $badAlias `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 $backup2 `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $publicInspector | Out-Null
  } "CANDIDATE_ALIAS_MISSING" "wrong-alias" $secretSentinel

  $badExpected = [PSCustomObject][ordered]@{
    KeyStorePath = $primary
    StorePassword = $secretSentinel
    Alias = $script:CcrCandidateSigningAlias
    KeyPassword = $secretSentinel
    ExpectedCertificateSha256 = $otherCertificate
  }
  Assert-CcrCandidateThrows {
    Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $badExpected `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 $backup2 `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $publicInspector | Out-Null
  } "CANDIDATE_CERT_MISMATCH" "wrong-expected-fingerprint" $secretSentinel

  $wrongPublicInspector = { param($Path) return $otherCertificate }.GetNewClosure()
  Assert-CcrCandidateThrows {
    Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $inputs `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 $backup2 `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $wrongPublicInspector | Out-Null
  } "CANDIDATE_PUBLIC_CERT_MISMATCH" "wrong-public-certificate"

  Assert-CcrCandidateThrows {
    Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $inputs `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 (Join-Path $root "missing-backup") `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $publicInspector | Out-Null
  } "CANDIDATE_BACKUP_MISSING" "backup-missing"

  $backup2Path = Join-Path $backup2 "ccr-internal-pilot-v1.jks"
  [System.IO.File]::AppendAllText($backup2Path, "tamper")
  Assert-CcrCandidateThrows {
    Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $inputs `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 $backup2 `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $publicInspector | Out-Null
  } "CANDIDATE_BACKUP_HASH_MISMATCH" "backup-hash-mismatch"
  [System.IO.File]::Delete($backup2Path)
  [System.IO.File]::Copy($primary, $backup2Path, $false)

  $runtimeSource = "1" * 40
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $roles = @(
    [PSCustomObject]@{ role = "debugApp"; packageName = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; targetPackage = $null },
    [PSCustomObject]@{ role = "debugTest"; packageName = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedAppPackage },
    [PSCustomObject]@{ role = "benchmarkApp"; packageName = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; targetPackage = $null },
    [PSCustomObject]@{ role = "macrobenchmarkTest"; packageName = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedMacrobenchmarkPackage }
  )
  $artifacts = [System.Collections.Generic.List[object]]::new()
  $identities = @{}
  foreach ($role in $roles) {
    $path = Join-Path $root "$($role.role).apk"
    [System.IO.File]::WriteAllText($path, "fake-$($role.role)", [System.Text.UTF8Encoding]::new($false))
    $artifact = [PSCustomObject][ordered]@{
      role = $role.role
      path = $path
      bytes = (Get-Item -LiteralPath $path).Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
      packageName = $role.packageName
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $certificate
      runner = $role.runner
      targetPackage = $role.targetPackage
    }
    $artifacts.Add($artifact) | Out-Null
    $identities[$role.role] = [PSCustomObject]@{
      packageName = $role.packageName
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $certificate
      runner = $role.runner
      targetPackage = $role.targetPackage
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
  function Write-CcrCandidateManifest {
    [System.IO.File]::WriteAllText(
      $manifestPath,
      (($manifest | ConvertTo-Json -Depth 12) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
  }
  Write-CcrCandidateManifest
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $fakeTools = [PSCustomObject]@{ ApkAnalyzer = "fake"; ApkSigner = "fake"; Adb = "fake" }
  $debugSha = [string]$artifacts[0].sha256
  $set = Import-CcrAlpha6CandidateArtifactManifest `
    -ArtifactManifest $manifestPath `
    -ExpectedHarnessSourceSha $harnessSource `
    -ExpectedDebugAppSha256 $debugSha `
    -ExpectedRuntimeSourceSha $runtimeSource `
    -ExpectedRuntimeInputsTreeSha256 $runtimeTree `
    -FingerprintPath $fingerprintPath `
    -AndroidTools $fakeTools `
    -IdentityReader $identityReader
  Assert-CcrCandidateTest ($set.Manifest.artifactSetRevision -eq 5 -and
      $set.Manifest.signingLineage -ceq $script:CcrCandidateSigningLineage) "revision-5-valid"

  $manifest.signingMode = "CI_EPHEMERAL_DEBUG"
  Write-CcrCandidateManifest
  Assert-CcrCandidateThrows {
    Import-CcrAlpha6CandidateArtifactManifest `
      -ArtifactManifest $manifestPath `
      -ExpectedHarnessSourceSha $harnessSource `
      -ExpectedDebugAppSha256 $debugSha `
      -ExpectedRuntimeSourceSha $runtimeSource `
      -ExpectedRuntimeInputsTreeSha256 $runtimeTree `
      -FingerprintPath $fingerprintPath `
      -AndroidTools $fakeTools `
      -IdentityReader $identityReader | Out-Null
  } "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" "ephemeral-debug-rejected"
  $manifest.signingMode = "SIGNED_CANDIDATE"

  $manifest.artifactSetRevision = 4
  Write-CcrCandidateManifest
  Assert-CcrCandidateThrows {
    Import-CcrAlpha6CandidateArtifactManifest `
      -ArtifactManifest $manifestPath `
      -ExpectedHarnessSourceSha $harnessSource `
      -ExpectedDebugAppSha256 $debugSha `
      -ExpectedRuntimeSourceSha $runtimeSource `
      -ExpectedRuntimeInputsTreeSha256 $runtimeTree `
      -FingerprintPath $fingerprintPath `
      -AndroidTools $fakeTools `
      -IdentityReader $identityReader | Out-Null
  } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "historical-revision-rejected-as-candidate"
  $manifest.artifactSetRevision = 5

  $identities["macrobenchmarkTest"].signingCertificateSha256 = $otherCertificate
  Write-CcrCandidateManifest
  Assert-CcrCandidateThrows {
    Import-CcrAlpha6CandidateArtifactManifest `
      -ArtifactManifest $manifestPath `
      -ExpectedHarnessSourceSha $harnessSource `
      -ExpectedDebugAppSha256 $debugSha `
      -ExpectedRuntimeSourceSha $runtimeSource `
      -ExpectedRuntimeInputsTreeSha256 $runtimeTree `
      -FingerprintPath $fingerprintPath `
      -AndroidTools $fakeTools `
      -IdentityReader $identityReader | Out-Null
  } "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:macrobenchmarkTest" "mixed-signer-rejected"
  $identities["macrobenchmarkTest"].signingCertificateSha256 = $certificate

  $legacySource = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"),
    [System.Text.Encoding]::UTF8
  )
  $alpha6HistoricalSource = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    [System.Text.Encoding]::UTF8
  )
  Assert-CcrCandidateTest ($legacySource.Contains("49379c1b2a2fec8a50c320955a7027c515aff10f28483b08ae9c27b3ffcfbef0")) "alpha4-legacy-signer-preserved"
  Assert-CcrCandidateTest ($alpha6HistoricalSource.Contains('$script:CcrPinnedArtifactSetRevision = 4')) "alpha6-revision4-preserved"

  $initSource = [System.IO.File]::ReadAllText(
    (Join-Path (Get-CcrCandidateRepoRoot) "android\gradle\candidate-signing.init.gradle"),
    [System.Text.Encoding]::UTF8
  )
  Assert-CcrCandidateTest ($initSource.Contains('candidateMode != "1"') -and
      $initSource.Contains('"debug", "benchmark"') -and
      $initSource.Contains("ccrCandidate")) "gradle-opt-in-and-four-apk-signing-boundary"

  Assert-CcrCandidateThrows {
    Assert-CcrCandidateBuildSigningReady `
      -BackupDirectory1 $backup1 `
      -BackupDirectory2 $backup2 `
      -FingerprintPath $fingerprintPath `
      -CertificatePath $certificatePath `
      -PolicyPath $policyPath `
      -KeyStoreInspector $inspector `
      -PublicCertificateInspector $publicInspector | Out-Null
  } "CANDIDATE_SIGNING_NOT_READY" "wrapper-fails-before-build-without-key"
} finally {
  foreach ($name in $script:CcrCandidateEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], "Process")
  }
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "CCR Android pilot signing host tests passed: $passed"
