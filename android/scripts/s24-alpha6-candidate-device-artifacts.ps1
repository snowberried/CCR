$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Keep the historical revision 4 entry point intact. The active device bridge
# reuses only its audited Alpha 6 host/device primitives and then explicitly
# enters through the strict revision 5 candidate importer.
$script:CcrAlpha6HistoricalPinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$script:CcrAlpha6CandidateArtifactsPath = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
. $script:CcrAlpha6HistoricalPinnedPath
. $script:CcrAlpha6CandidateArtifactsPath

# The candidate importer rebinds runtime and signer values from validated
# inputs. Keep only the non-secret active harness constants explicit at load
# time so host-side contract functions cannot fall back to Alpha 4 defaults.
$script:CcrPinnedArtifactSetRevision = $script:CcrCandidateArtifactSetRevision
$script:CcrPinnedVersionName = "0.2.0-alpha.6"
$script:CcrPinnedVersionCode = 7
$script:CcrPinnedRuntimeSourceSha = $null
$script:CcrPinnedRuntimeInputsTreeSha256 = $null
$script:CcrPinnedDebugAppSha256 = $null

function Get-CcrAlpha6CandidatePublicFileRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_FILE_MISSING:$full"
  }
  $item = Get-Item -Force -LiteralPath $full
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_FILE_INVALID:$full"
  }
  $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $relative = if (Test-CcrPinnedPathWithin $full $repo) {
    $full.Substring($repo.Length).TrimStart([char[]]"\/").Replace('\', '/')
  } else {
    [System.IO.Path]::GetFileName($full)
  }
  return [PSCustomObject][ordered]@{
    repositoryRelativePath = $relative
    path = $full
    bytes = [long]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
  }
}

function Get-CcrAlpha6CandidatePublicSigningIdentity {
  param(
    [string]$RepoRoot = (Get-CcrCandidateRepoRoot),
    [string]$SigningDirectory = (Join-Path (Get-CcrCandidateRepoRoot) "android\signing")
  )
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  $signing = [System.IO.Path]::GetFullPath($SigningDirectory)
  $policyPath = Join-Path $signing "ccr-internal-pilot-v1-policy.json"
  $fingerprintPath = Join-Path $signing "ccr-internal-pilot-v1-cert.sha256"
  $certificatePath = Join-Path $signing "ccr-internal-pilot-v1-cert.pem"
  $policyRecord = Get-CcrAlpha6CandidatePublicFileRecord $policyPath $repo
  $fingerprintRecord = Get-CcrAlpha6CandidatePublicFileRecord $fingerprintPath $repo
  $certificateRecord = Get-CcrAlpha6CandidatePublicFileRecord $certificatePath $repo
  try {
    $policy = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_JSON_INVALID"
  }
  $fingerprint = Get-CcrCandidatePublicPolicyFingerprint $fingerprintPath
  foreach ($contract in @(
    @("schemaVersion", 1),
    @("status", "SIGNING_BASELINE_READY"),
    @("purpose", $script:CcrCandidateSigningPurpose),
    @("signingLineage", $script:CcrCandidateSigningLineage),
    @("signingMode", "SIGNED_CANDIDATE"),
    @("artifactSetRevision", $script:CcrCandidateArtifactSetRevision),
    @("alias", $script:CcrCandidateSigningAlias),
    @("certificateSha256", $fingerprint),
    @("expectedSigningCertificateSha256", $fingerprint),
    @("keyAlgorithm", "RSA-4096"),
    @("productionOrPlayKeyShared", $false),
    @("standardDebugKeyShared", $false)
  )) {
    $actual = Get-CcrPinnedRequiredProperty $policy ([string]$contract[0])
    if (($actual | ConvertTo-Json -Compress) -cne ($contract[1] | ConvertTo-Json -Compress)) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_CONTRACT_MISMATCH:$($contract[0])"
    }
  }
  $certificateFingerprint = Get-CcrCandidatePublicCertificateSha256 $certificatePath
  if ($certificateFingerprint -cne $fingerprint) {
    throw "ALPHA6_CANDIDATE_PUBLIC_CERTIFICATE_MISMATCH"
  }
  return [PSCustomObject][ordered]@{
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    signingLineage = $script:CcrCandidateSigningLineage
    expectedSigningCertificateSha256 = $fingerprint
    publicPolicy = $policyRecord
    publicFingerprint = $fingerprintRecord
    publicCertificate = $certificateRecord
  }
}

function Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged {
  param([Parameter(Mandatory = $true)][object]$Context)
  $identity = Get-CcrPinnedRequiredProperty $Context "PublicSigningIdentity"
  foreach ($name in @("publicPolicy", "publicFingerprint", "publicCertificate")) {
    $record = Get-CcrPinnedRequiredProperty $identity $name
    $path = [System.IO.Path]::GetFullPath([string](Get-CcrPinnedRequiredProperty $record "path"))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_MISSING_AFTER_PREFLIGHT:$name"
    }
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [long]$item.Length -ne [long](Get-CcrPinnedRequiredProperty $record "bytes") -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne
          [string](Get-CcrPinnedRequiredProperty $record "sha256")) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_CHANGED_AFTER_PREFLIGHT:$name"
    }
  }
  if ([string](Get-CcrPinnedRequiredProperty $identity "signingMode") -cne "SIGNED_CANDIDATE" -or
      (Get-CcrPinnedRequiredProperty $identity "candidateSigning") -ne $true -or
      [string](Get-CcrPinnedRequiredProperty $identity "signingLineage") -cne $script:CcrCandidateSigningLineage -or
      [string](Get-CcrPinnedRequiredProperty $identity "expectedSigningCertificateSha256") -cne
        $script:CcrPinnedSigningCertificateSha256) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_IDENTITY_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6CandidateDeviceIdentityUnchanged {
  param([Parameter(Mandatory = $true)][object]$Context)
  Assert-CcrAlpha6ArtifactSetUnchanged $Context | Out-Null
  Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged $Context | Out-Null
  return $true
}

function Invoke-CcrAlpha6CandidateDeviceHostPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
    [Parameter(Mandatory = $true)][bool]$PreflightOnly,
    [Parameter(Mandatory = $true)][long]$BuildCommandCount,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ValidationScriptPaths,
    [string]$RepoRoot = (Get-CcrCandidateRepoRoot),
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null,
    [scriptblock]$SourceIdentityVerifier = $null
  )
  if (-not (Test-CcrAlpha6NonZeroGitSha $RuntimeSourceSha)) { throw "ALPHA6_RUNTIME_SOURCE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroGitSha $HarnessSourceSha)) { throw "ALPHA6_HARNESS_SOURCE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroSha256 $RuntimeInputsTreeSha256)) { throw "ALPHA6_RUNTIME_INPUTS_TREE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroSha256 $ExpectedDebugAppSha256)) { throw "ALPHA6_DEBUG_APP_SHA_INVALID" }
  if ($BuildCommandCount -ne 0L) { throw "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO" }
  Assert-CcrPinnedRunId $RunId | Out-Null
  $manifestSha = Assert-CcrAlpha6ManifestSha256 $ArtifactManifest $ArtifactManifestSha256
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  foreach ($path in $ValidationScriptPaths) {
    $full = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-CcrPinnedPathWithin $full $repo)) {
      throw "ALPHA6_CANDIDATE_VALIDATION_SCRIPT_OUTSIDE_REPOSITORY:$full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw "ALPHA6_VALIDATION_SCRIPT_INVALID:$full"
    }
    $item = Get-Item -Force -LiteralPath $full
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "ALPHA6_CANDIDATE_VALIDATION_SCRIPT_REPARSE_POINT:$full"
    }
  }
  $scripts = @(Assert-CcrAlpha6ValidationScriptsBuildFree $ValidationScriptPaths)
  if ($null -eq $SourceIdentityVerifier) {
    Assert-CcrAlpha6SourceIdentity $repo $RuntimeSourceSha $HarnessSourceSha | Out-Null
  } elseif ((& $SourceIdentityVerifier $repo $RuntimeSourceSha $HarnessSourceSha) -ne $true) {
    throw "ALPHA6_SOURCE_IDENTITY_VERIFIER_REJECTED"
  }
  $output = Assert-CcrAlpha6ExternalOutputDirectory $OutputDirectory $repo
  $publicIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity -RepoRoot $repo `
    -SigningDirectory (Join-Path $repo "android\signing")
  $set = Import-CcrAlpha6CandidateArtifactManifest `
    -ArtifactManifest $ArtifactManifest `
    -ExpectedHarnessSourceSha $HarnessSourceSha.ToLowerInvariant() `
    -ExpectedDebugAppSha256 $ExpectedDebugAppSha256.ToLowerInvariant() `
    -ExpectedRuntimeSourceSha $RuntimeSourceSha.ToLowerInvariant() `
    -ExpectedRuntimeInputsTreeSha256 $RuntimeInputsTreeSha256.ToLowerInvariant() `
    -RepoRoot $repo `
    -FingerprintPath ([string]$publicIdentity.publicFingerprint.path) `
    -AndroidTools $AndroidTools `
    -IdentityReader $IdentityReader
  if ($set.ManifestSha256 -cne $manifestSha) { throw "ALPHA6_PREFLIGHT_MANIFEST_SHA_MISMATCH" }
  if ([int](Get-CcrPinnedRequiredProperty $set.Manifest "artifactSetRevision") -ne 5 -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "signingMode") -cne "SIGNED_CANDIDATE" -or
      (Get-CcrPinnedRequiredProperty $set.Manifest "candidateSigning") -ne $true -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "signingLineage") -cne
        [string]$publicIdentity.signingLineage -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "expectedSigningCertificateSha256") -cne
        [string]$publicIdentity.expectedSigningCertificateSha256) {
    throw "ALPHA6_CANDIDATE_IMPORTED_IDENTITY_MISMATCH"
  }
  Reserve-CcrPinnedRunId $output $RunId | Out-Null
  $context = [PSCustomObject][ordered]@{
    ArtifactSet = $set
    PublicSigningIdentity = $publicIdentity
    OutputDirectory = $output
    RunId = $RunId
    PreflightOnly = $PreflightOnly
    BuildCommandCount = 0L
    RuntimeSourceSha = $RuntimeSourceSha.ToLowerInvariant()
    HarnessSourceSha = $HarnessSourceSha.ToLowerInvariant()
    RuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256.ToLowerInvariant()
    ArtifactManifestSha256 = $manifestSha
    DebugAppSha256 = $ExpectedDebugAppSha256.ToLowerInvariant()
    ValidationScripts = $scripts
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  return $context
}
