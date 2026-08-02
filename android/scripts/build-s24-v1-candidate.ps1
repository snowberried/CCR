param(
  [string]$OutputRoot = "",
  [string]$BackupDirectory1 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_1,
  [string]$BackupDirectory2 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_2
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "build-s24-alpha6-candidate.ps1") `
  -OutputRoot $OutputRoot `
  -BackupDirectory1 $BackupDirectory1 `
  -BackupDirectory2 $BackupDirectory2

$script:CcrV1VersionName = "1.0.0"
$script:CcrV1VersionCode = 8

function Invoke-CcrV1CandidateGradle {
  param(
    [Parameter(Mandatory = $true)][string]$AndroidRoot,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256
  )
  if ($RuntimeSourceSha -cnotmatch "^[a-f0-9]{40}$") {
    throw "V1_CANDIDATE_RUNTIME_SOURCE_SHA_INVALID"
  }
  if ($RuntimeInputsTreeSha256 -cnotmatch "^[a-f0-9]{64}$") {
    throw "V1_CANDIDATE_RUNTIME_INPUTS_TREE_SHA_INVALID"
  }
  $environmentNames = @(
    "CCR_ANDROID_CANDIDATE_MODE",
    "CCR_ANDROID_COMMIT_SHA",
    "CCR_ANDROID_RUNTIME_INPUTS_TREE_SHA256",
    "CCR_ANDROID_INTERNAL_KEYSTORE_PATH",
    "CCR_ANDROID_INTERNAL_KEYSTORE_PASSWORD",
    "CCR_ANDROID_INTERNAL_KEY_ALIAS",
    "CCR_ANDROID_INTERNAL_KEY_PASSWORD"
  )
  $previous = @{}
  foreach ($name in $environmentNames) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  }
  try {
    [Environment]::SetEnvironmentVariable("CCR_ANDROID_CANDIDATE_MODE", "1", "Process")
    [Environment]::SetEnvironmentVariable("CCR_ANDROID_COMMIT_SHA", $RuntimeSourceSha, "Process")
    [Environment]::SetEnvironmentVariable(
      "CCR_ANDROID_RUNTIME_INPUTS_TREE_SHA256",
      $RuntimeInputsTreeSha256,
      "Process"
    )
    foreach ($name in $environmentNames | Where-Object { $_ -like "CCR_ANDROID_INTERNAL_*" }) {
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    Push-Location $AndroidRoot
    try {
      $lines = @(& (Join-Path $AndroidRoot "gradlew.bat") @Arguments 2>&1)
      $exitCode = [int]$LASTEXITCODE
    } finally {
      Pop-Location
    }
    return [PSCustomObject]@{ exitCode = $exitCode; output = ($lines -join "`n") }
  } finally {
    foreach ($name in $environmentNames) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Get-CcrV1RuntimeInputs {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha
  )
  $tool = Join-Path $RepoRoot "android\tools\compute-runtime-inputs-v1.mjs"
  $lines = @(& node $tool $RuntimeSourceSha 2>&1)
  if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) {
    throw "V1_CANDIDATE_RUNTIME_INPUTS_FAILED"
  }
  try {
    $runtime = [string]$lines[0] | ConvertFrom-Json
  } catch {
    throw "V1_CANDIDATE_RUNTIME_INPUTS_JSON_INVALID"
  }
  if ([string]$runtime.runtimeSourceSha -cne $RuntimeSourceSha -or
      [int]$runtime.fileCount -lt 1 -or
      [string]$runtime.runtimeInputsTreeSha256 -cnotmatch "^[a-f0-9]{64}$") {
    throw "V1_CANDIDATE_RUNTIME_INPUTS_IDENTITY_MISMATCH"
  }
  return $runtime
}

function Get-CcrV1EmbeddedRuntimeSourceSha {
  param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ApkAnalyzer,
    [Parameter(Mandatory = $true)][string]$ExpectedRuntimeSourceSha
  )
  if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw "V1_CANDIDATE_APK_MISSING"
  }
  $lines = @(& $ApkAnalyzer "dex" "code" `
    "--class" "com.snowberried.ctcinereviewer.BuildConfig" $ApkPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "V1_CANDIDATE_APK_RUNTIME_IDENTITY_INSPECTION_FAILED"
  }
  $matches = @([regex]::Matches(
      ($lines -join "`n"),
      '(?m)^\.field public static final COMMIT_SHA:Ljava/lang/String; = "([a-f0-9]{40})"\s*$'
    ))
  if ($matches.Count -ne 1) {
    throw "V1_CANDIDATE_APK_RUNTIME_IDENTITY_PARSE_FAILED"
  }
  $runtimeSourceSha = $matches[0].Groups[1].Value
  if ($runtimeSourceSha -cne $ExpectedRuntimeSourceSha) {
    throw "V1_CANDIDATE_APK_RUNTIME_IDENTITY_MISMATCH"
  }
  return $runtimeSourceSha
}

function Assert-CcrV1EmbeddedRuntimeInputsTreeSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ApkAnalyzer,
    [Parameter(Mandatory = $true)][string]$ExpectedRuntimeInputsTreeSha256
  )
  if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw "V1_CANDIDATE_APK_MISSING"
  }
  $lines = @(& $ApkAnalyzer "dex" "code" "--class" "com.snowberried.ctcinereviewer.BuildConfig" $ApkPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "V1_CANDIDATE_APK_RUNTIME_TREE_INSPECTION_FAILED"
  }
  $matches = @([regex]::Matches(
      ($lines -join [Environment]::NewLine),
      '(?m)^\.field public static final RUNTIME_INPUTS_TREE_SHA256:Ljava/lang/String; = "([a-f0-9]{64})"\s*$'
    ))
  if ($matches.Count -ne 1) {
    throw "V1_CANDIDATE_APK_RUNTIME_TREE_PARSE_FAILED"
  }
  if ($matches[0].Groups[1].Value -cne $ExpectedRuntimeInputsTreeSha256) {
    throw "V1_CANDIDATE_APK_RUNTIME_TREE_MISMATCH"
  }
}

function Invoke-CcrS24V1CandidateBuild {
  param(
    [string]$OutputRoot,
    [string]$BackupDirectory1,
    [string]$BackupDirectory2
  )
  $repo = Get-CcrCandidateRepoRoot
  $androidRoot = Join-Path $repo "android"
  $head = @(& git -C $repo rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or
      $head[0] -cnotmatch "^[a-f0-9]{40}$") {
    throw "V1_CANDIDATE_SOURCE_HEAD_UNAVAILABLE"
  }
  $headSha = $head[0].ToLowerInvariant()
  if (@(& git -C $repo status --porcelain=v1 --untracked-files=all 2>$null).Count -ne 0) {
    throw "V1_CANDIDATE_SOURCE_WORKTREE_NOT_CLEAN"
  }
  $appGradle = [System.IO.File]::ReadAllText(
    (Join-Path $androidRoot "app\build.gradle.kts"),
    [System.Text.Encoding]::UTF8
  )
  if (($appGradle -notmatch 'versionName\s*=\s*"1\.0\.0"') -or
      ($appGradle -notmatch 'versionCode\s*=\s*8\b')) {
    throw "V1_CANDIDATE_VERSION_CONTRACT_MISMATCH"
  }
  $runtime = Get-CcrV1RuntimeInputs -RepoRoot $repo -RuntimeSourceSha $headSha

  $preflight = Assert-CcrCandidateBuildSigningReady `
    -BackupDirectory1 $BackupDirectory1 `
    -BackupDirectory2 $BackupDirectory2
  $candidateInputs = Get-CcrCandidateEnvironmentInputs
  $initScript = Join-Path $androidRoot "gradle\candidate-signing.init.gradle"
  $signingReport = Invoke-CcrV1CandidateGradle -AndroidRoot $androidRoot `
    -RuntimeSourceSha $headSha -RuntimeInputsTreeSha256 ([string]$runtime.runtimeInputsTreeSha256) -Arguments @(
      "--no-daemon", "--offline", "-I", $initScript, "signingReport"
    )
  if ($signingReport.exitCode -ne 0) {
    throw "V1_CANDIDATE_SIGNING_REPORT_FAILED"
  }
  $normalizedReport = $signingReport.output.Replace(":", "").ToLowerInvariant()
  $normalizedReportPath = $signingReport.output.Replace('/', '\').ToLowerInvariant()
  $expectedStorePath = ([string]$candidateInputs.KeyStorePath).Replace('/', '\').ToLowerInvariant()
  if ($normalizedReport -notmatch [regex]::Escape(([string]$preflight.certificateSha256).ToLowerInvariant()) -or
      -not $normalizedReportPath.Contains($expectedStorePath) -or
      ([regex]::Matches($signingReport.output, "(?im)^\s*Config:\s*ccrCandidate\s*$")).Count -lt 4) {
    throw "V1_CANDIDATE_SIGNING_REPORT_MISMATCH"
  }

  $build = Invoke-CcrV1CandidateGradle -AndroidRoot $androidRoot `
    -RuntimeSourceSha $headSha -RuntimeInputsTreeSha256 ([string]$runtime.runtimeInputsTreeSha256) -Arguments @(
      "--no-daemon", "--offline", "-I", $initScript,
      "assembleInternalDebug",
      "assembleInternalDebugAndroidTest",
      "assembleInternalBenchmark",
      ":macrobenchmark:assembleInternalBenchmark",
      "--stacktrace"
    )
  if ($build.exitCode -ne 0) {
    throw "V1_CANDIDATE_APK_BUILD_FAILED`n$($build.output)"
  }

  if (-not $OutputRoot) {
    $OutputRoot = Join-Path $env:USERPROFILE "Documents\CCR-Artifacts"
  }
  $root = Assert-CcrCandidateExternalOutputRoot $OutputRoot
  $setDirectory = Join-Path $root (
    "CCR-Android-1.0.0-{0}-{1}" -f
      $headSha.Substring(0, 7),
      (Get-Date -Format "yyyyMMdd-HHmmss")
  )
  if (Test-Path -LiteralPath $setDirectory) {
    throw "V1_CANDIDATE_OUTPUT_ALREADY_EXISTS"
  }

  $sourceArtifacts = [ordered]@{
    debugApp = Join-Path $androidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
    debugTest = Join-Path $androidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"
    benchmarkApp = Join-Path $androidRoot "app\build\outputs\apk\internal\benchmark\app-internal-benchmark.apk"
    macrobenchmarkTest = Join-Path $androidRoot "macrobenchmark\build\outputs\apk\internal\benchmark\macrobenchmark-internal-benchmark.apk"
  }
  $tools = Get-CcrPinnedAndroidSdkTools
  $embeddedRuntimeSourceSha = [ordered]@{}
  foreach ($role in @("debugApp", "benchmarkApp")) {
    $embeddedRuntimeSourceSha[$role] = Get-CcrV1EmbeddedRuntimeSourceSha `
      -ApkPath $sourceArtifacts[$role] `
      -ApkAnalyzer $tools.ApkAnalyzer `
      -ExpectedRuntimeSourceSha $headSha
    Assert-CcrV1EmbeddedRuntimeInputsTreeSha256 `
      -ApkPath $sourceArtifacts[$role] `
      -ApkAnalyzer $tools.ApkAnalyzer `
      -ExpectedRuntimeInputsTreeSha256 ([string]$runtime.runtimeInputsTreeSha256)
  }

  [System.IO.Directory]::CreateDirectory($setDirectory) | Out-Null
  $records = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in $sourceArtifacts.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
      throw "V1_CANDIDATE_APK_MISSING:$($entry.Key)"
    }
    $destination = Join-Path $setDirectory ([System.IO.Path]::GetFileName($entry.Value))
    [System.IO.File]::Copy($entry.Value, $destination, $false)
    $artifact = [PSCustomObject]@{ role = [string]$entry.Key; path = $destination }
    $identity = Get-CcrPinnedApkIdentity $artifact $tools
    if ([string]$identity.signingCertificateSha256 -cne [string]$preflight.certificateSha256) {
      throw "V1_CANDIDATE_APK_SIGNER_MISMATCH:$($entry.Key)"
    }
    $item = Get-Item -LiteralPath $destination
    $records.Add([PSCustomObject][ordered]@{
      role = [string]$entry.Key
      path = $item.FullName
      bytes = [long]$item.Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
      packageName = $identity.packageName
      versionName = $identity.versionName
      versionCode = $identity.versionCode
      signingCertificateSha256 = $identity.signingCertificateSha256
      runner = $identity.runner
      targetPackage = $identity.targetPackage
    }) | Out-Null
  }

  $manifest = [PSCustomObject][ordered]@{
    schemaVersion = 1
    artifactSetRevision = $script:CcrCandidateArtifactSetRevision
    signingLineage = $script:CcrCandidateSigningLineage
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    expectedSigningCertificateSha256 = [string]$preflight.certificateSha256
    runtimeSourceSha = $headSha
    harnessSourceSha = $headSha
    runtimeInputsTreeSha256 = [string]$runtime.runtimeInputsTreeSha256
    embeddedRuntimeSourceSha = [PSCustomObject]$embeddedRuntimeSourceSha
    versionName = $script:CcrV1VersionName
    versionCode = $script:CcrV1VersionCode
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $records.ToArray()
  }
  $manifestPath = Join-Path $setDirectory "artifact-manifest-v5.json"
  [System.IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 12) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $debugSha = [string]($records | Where-Object role -ceq "debugApp").sha256
  Import-CcrAlpha6CandidateArtifactManifest `
    -ArtifactManifest $manifestPath `
    -ExpectedHarnessSourceSha $headSha `
    -ExpectedDebugAppSha256 $debugSha `
    -ExpectedRuntimeSourceSha $headSha `
    -ExpectedRuntimeInputsTreeSha256 ([string]$runtime.runtimeInputsTreeSha256) `
    -ExpectedVersionName $script:CcrV1VersionName `
    -ExpectedVersionCode $script:CcrV1VersionCode | Out-Null

  $checksums = @($records | ForEach-Object {
    "$($_.sha256)  $([System.IO.Path]::GetFileName([string]$_.path))"
  })
  $checksums += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant())  artifact-manifest-v5.json"
  [System.IO.File]::WriteAllLines(
    (Join-Path $setDirectory "SHA256SUMS.txt"),
    $checksums,
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $setDirectory "PROVENANCE.txt"),
    @"
versionName=$($script:CcrV1VersionName)
versionCode=$($script:CcrV1VersionCode)
signingMode=SIGNED_CANDIDATE
signingLineage=$($script:CcrCandidateSigningLineage)
artifactSetRevision=$($script:CcrCandidateArtifactSetRevision)
runtimeSourceSha=$headSha
harnessSourceSha=$headSha
runtimeInputsTreeSha256=$([string]$runtime.runtimeInputsTreeSha256)
embeddedDebugAppRuntimeSourceSha=$($embeddedRuntimeSourceSha.debugApp)
embeddedBenchmarkAppRuntimeSourceSha=$($embeddedRuntimeSourceSha.benchmarkApp)
ciEphemeralDebug=false
"@,
    [System.Text.UTF8Encoding]::new($false)
  )
  Get-ChildItem -LiteralPath $setDirectory -File | ForEach-Object { $_.IsReadOnly = $true }
  Write-Output "PASS - V1_SIGNED_CANDIDATE_ARTIFACT_SET_V5_CREATED"
  Write-Output "artifactSet=$setDirectory"
  Write-Output "manifest=$manifestPath"
  Write-Output "runtimeSourceSha=$headSha"
  Write-Output "runtimeInputsTreeSha256=$([string]$runtime.runtimeInputsTreeSha256)"
  Write-Output "debugAppSha256=$debugSha"
}

if ($MyInvocation.InvocationName -ne ".") {
  try {
    Invoke-CcrS24V1CandidateBuild `
      -OutputRoot $OutputRoot `
      -BackupDirectory1 $BackupDirectory1 `
      -BackupDirectory2 $BackupDirectory2
  } catch {
    Write-Error $_.Exception.Message
    exit 1
  }
}
