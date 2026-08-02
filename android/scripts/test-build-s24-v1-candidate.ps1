$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$builderPath = Join-Path $PSScriptRoot "build-s24-v1-candidate.ps1"
. $builderPath

$passed = 0
function Assert-CcrV1BuilderTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "V1_CANDIDATE_BUILDER_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-CcrV1BuilderThrows {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "V1_CANDIDATE_BUILDER_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

$repo = Get-CcrCandidateRepoRoot
$source = [System.IO.File]::ReadAllText($builderPath, [System.Text.Encoding]::UTF8)
$gradleSource = [System.IO.File]::ReadAllText(
  (Join-Path $repo "android\app\build.gradle.kts"),
  [System.Text.Encoding]::UTF8
)

Assert-CcrV1BuilderTest (
  $script:CcrV1VersionName -ceq "1.0.0" -and
    $script:CcrV1VersionCode -eq 8 -and
    $gradleSource -match 'versionName\s*=\s*"1\.0\.0"' -and
    $gradleSource -match 'versionCode\s*=\s*8\b'
) "version-contract"

Assert-CcrV1BuilderTest (
  $gradleSource.Contains("CCR_ANDROID_RUNTIME_INPUTS_TREE_SHA256") -and
    $gradleSource.Contains("RUNTIME_INPUTS_TREE_SHA256")
) "runtime-tree-build-config-contract"

foreach ($required in @(
  "Assert-CcrCandidateBuildSigningReady",
  "candidate-signing.init.gradle",
  "signingReport",
  "assembleInternalDebugAndroidTest",
  ":macrobenchmark:assembleInternalBenchmark",
  "Import-CcrAlpha6CandidateArtifactManifest",
  "ExpectedVersionName",
  "ExpectedVersionCode",
  "CCR_ANDROID_RUNTIME_INPUTS_TREE_SHA256",
  "Assert-CcrV1EmbeddedRuntimeInputsTreeSha256",
  "Assert-CcrCandidateExternalOutputRoot"
)) {
  Assert-CcrV1BuilderTest ($source.Contains($required)) "source-contract-$required"
}

Assert-CcrV1BuilderTest (
  $source -notmatch '(?im)Write-Output.*(?:StorePassword|KeyPassword|candidateInputs)'
) "secret-values-not-written"

Assert-CcrV1BuilderThrows {
  Invoke-CcrV1CandidateGradle `
    -AndroidRoot (Join-Path $repo "android") `
    -Arguments @("help") `
    -RuntimeSourceSha "invalid" -RuntimeInputsTreeSha256 ("a" * 64) | Out-Null
} "*V1_CANDIDATE_RUNTIME_SOURCE_SHA_INVALID*" "invalid-runtime-source-rejected-before-gradle"

Assert-CcrV1BuilderThrows {
  Invoke-CcrV1CandidateGradle -AndroidRoot (Join-Path $repo "android") -Arguments @("help") -RuntimeSourceSha ("a" * 40) -RuntimeInputsTreeSha256 "invalid" | Out-Null
} "*V1_CANDIDATE_RUNTIME_INPUTS_TREE_SHA_INVALID*" "invalid-runtime-tree-rejected-before-gradle"

$historicalSource = @(& git -C $repo rev-parse "HEAD^" 2>$null)
if ($LASTEXITCODE -ne 0 -or $historicalSource.Count -ne 1) {
  throw "V1_CANDIDATE_BUILDER_HISTORICAL_SOURCE_UNAVAILABLE"
}
$firstRuntime = Get-CcrV1RuntimeInputs -RepoRoot $repo -RuntimeSourceSha $historicalSource[0]
$secondRuntime = Get-CcrV1RuntimeInputs -RepoRoot $repo -RuntimeSourceSha $historicalSource[0]
Assert-CcrV1BuilderTest (
  [string]$firstRuntime.runtimeInputsTreeSha256 -cmatch "^[a-f0-9]{64}$" -and
    [string]$firstRuntime.runtimeInputsTreeSha256 -ceq
      [string]$secondRuntime.runtimeInputsTreeSha256 -and
    [int]$firstRuntime.fileCount -gt 0
) "runtime-tree-deterministic"

Write-Output "S24 v1 candidate builder host tests passed: $passed"
