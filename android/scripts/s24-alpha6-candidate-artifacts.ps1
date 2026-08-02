$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1")
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

$script:CcrCandidateBaseImportPinnedArtifactManifest = ${function:Import-CcrPinnedArtifactManifest}

function Import-CcrAlpha6CandidateArtifactManifest {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ExpectedHarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
    [string]$ExpectedRuntimeSourceSha = "c98264f2a10026a908e94c961bb13e4af2d59e60",
    [string]$ExpectedRuntimeInputsTreeSha256 = "3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468",
    [string]$ExpectedVersionName = "0.2.0-alpha.6",
    [int]$ExpectedVersionCode = 7,
    [string]$RepoRoot = (Get-CcrCandidateRepoRoot),
    [string]$FingerprintPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.sha256"),
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null
  )
  if (-not (Test-CcrPinnedAbsolutePath $ArtifactManifest)) {
    throw "CANDIDATE_MANIFEST_PATH_NOT_ABSOLUTE"
  }
  $manifestPath = [System.IO.Path]::GetFullPath($ArtifactManifest)
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "CANDIDATE_MANIFEST_NOT_FOUND"
  }
  try {
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "CANDIDATE_MANIFEST_JSON_INVALID"
  }
  if ([int](Get-CcrPinnedRequiredProperty $manifest "artifactSetRevision") -ne
      $script:CcrCandidateArtifactSetRevision) {
    throw "CANDIDATE_MANIFEST_REVISION_MISMATCH"
  }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "signingLineage") -cne
      $script:CcrCandidateSigningLineage) {
    throw "CANDIDATE_MANIFEST_LINEAGE_MISMATCH"
  }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "signingMode") -cne "SIGNED_CANDIDATE" -or
      (Get-CcrPinnedRequiredProperty $manifest "candidateSigning") -ne $true) {
    throw "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH"
  }
  if (-not (Test-CcrPinnedGitSha $ExpectedRuntimeSourceSha)) {
    throw "CANDIDATE_RUNTIME_SOURCE_SHA_INVALID"
  }
  if (-not (Test-CcrPinnedSha256 $ExpectedRuntimeInputsTreeSha256)) {
    throw "CANDIDATE_RUNTIME_INPUTS_TREE_SHA_INVALID"
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedVersionName) -or $ExpectedVersionCode -lt 1) {
    throw "CANDIDATE_VERSION_INVALID"
  }
  $embeddedRuntimeSourceSha = Get-CcrPinnedRequiredProperty $manifest "embeddedRuntimeSourceSha"
  foreach ($role in @("debugApp", "benchmarkApp")) {
    if ([string](Get-CcrPinnedRequiredProperty $embeddedRuntimeSourceSha $role) -cne
        $ExpectedRuntimeSourceSha) {
      throw "CANDIDATE_MANIFEST_EMBEDDED_RUNTIME_IDENTITY_MISMATCH:$role"
    }
  }
  $policyFingerprint = Get-CcrCandidatePublicPolicyFingerprint $FingerprintPath
  $declaredFingerprint = [string](Get-CcrPinnedRequiredProperty $manifest "expectedSigningCertificateSha256")
  if ($declaredFingerprint -cne $policyFingerprint) {
    throw "CANDIDATE_MANIFEST_PUBLIC_POLICY_MISMATCH"
  }

  $script:CcrPinnedArtifactSetRevision = $script:CcrCandidateArtifactSetRevision
  $script:CcrPinnedRuntimeSourceSha = $ExpectedRuntimeSourceSha
  $script:CcrPinnedRuntimeInputsTreeSha256 = $ExpectedRuntimeInputsTreeSha256
  $script:CcrPinnedVersionName = $ExpectedVersionName
  $script:CcrPinnedVersionCode = $ExpectedVersionCode
  $script:CcrPinnedDebugAppSha256 = $ExpectedDebugAppSha256
  $script:CcrPinnedSigningCertificateSha256 = $policyFingerprint
  return & $script:CcrCandidateBaseImportPinnedArtifactManifest `
    -ArtifactManifest $manifestPath `
    -RepoRoot $RepoRoot `
    -ExpectedHarnessSourceSha $ExpectedHarnessSourceSha `
    -AndroidTools $AndroidTools `
    -IdentityReader $IdentityReader `
    -TestOnlyExpectedDebugAppSha256 $ExpectedDebugAppSha256
}
