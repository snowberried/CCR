param(
  [string]$OutputRoot = "",
  [string]$BackupDirectory1 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_1,
  [string]$BackupDirectory2 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_2
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1")
. (Join-Path $PSScriptRoot "verify-ccr-android-pilot-signing.ps1")
. (Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1")

$script:CcrAlpha6RuntimeSourceSha = "c98264f2a10026a908e94c961bb13e4af2d59e60"
$script:CcrAlpha6RuntimeInputsTreeSha256 = "3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468"

function Assert-CcrCandidateRuntimeSourceSha {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value -cnotmatch "^[a-f0-9]{40}$") { throw "CANDIDATE_RUNTIME_SOURCE_SHA_INVALID" }
  if ($Value -cne $script:CcrAlpha6RuntimeSourceSha) { throw "CANDIDATE_RUNTIME_SOURCE_SHA_MISMATCH" }
  return $Value
}

function Invoke-CcrCandidateGradle {
  param(
    [Parameter(Mandatory = $true)][string]$AndroidRoot,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [scriptblock]$TestOnlyProcessInvoker = $null
  )
  Assert-CcrCandidateRuntimeSourceSha $script:CcrAlpha6RuntimeSourceSha | Out-Null
  if ($null -ne $TestOnlyProcessInvoker -and $env:CCR_CANDIDATE_BUILD_TEST_MODE -cne "1") {
    throw "CANDIDATE_GRADLE_TEST_HOOK_FORBIDDEN"
  }
  $environmentNames = @(
    "CCR_ANDROID_CANDIDATE_MODE",
    "CCR_ANDROID_COMMIT_SHA",
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
    [Environment]::SetEnvironmentVariable(
      "CCR_ANDROID_COMMIT_SHA",
      $script:CcrAlpha6RuntimeSourceSha,
      "Process"
    )
    foreach ($name in $environmentNames | Where-Object { $_ -like "CCR_ANDROID_INTERNAL_*" }) {
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    if ($null -ne $TestOnlyProcessInvoker) {
      $result = & $TestOnlyProcessInvoker $AndroidRoot $Arguments
      if ($null -eq $result -or
          -not $result.PSObject.Properties["exitCode"] -or
          -not $result.PSObject.Properties["output"]) {
        throw "CANDIDATE_GRADLE_TEST_RESULT_INVALID"
      }
      return [PSCustomObject]@{ exitCode = [int]$result.exitCode; output = [string]$result.output }
    }
    Push-Location $AndroidRoot
    try {
      $lines = @(& (Join-Path $AndroidRoot "gradlew.bat") @Arguments 2>&1)
      $exitCode = [int]$LASTEXITCODE
    } finally { Pop-Location }
    return [PSCustomObject]@{ exitCode = $exitCode; output = ($lines -join "`n") }
  } finally {
    foreach ($name in $environmentNames) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Get-CcrCandidateEmbeddedRuntimeSourceSha {
  param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ApkAnalyzer,
    [scriptblock]$TestOnlyAnalyzerInvoker = $null
  )
  if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw "CANDIDATE_APK_MISSING"
  }
  if ($null -ne $TestOnlyAnalyzerInvoker -and $env:CCR_CANDIDATE_BUILD_TEST_MODE -cne "1") {
    throw "CANDIDATE_APK_ANALYZER_TEST_HOOK_FORBIDDEN"
  }
  $arguments = @(
    "dex", "code",
    "--class", "com.snowberried.ctcinereviewer.BuildConfig",
    [System.IO.Path]::GetFullPath($ApkPath)
  )
  if ($null -ne $TestOnlyAnalyzerInvoker) {
    $result = & $TestOnlyAnalyzerInvoker $ApkAnalyzer $arguments
  } else {
    $lines = @(& $ApkAnalyzer @arguments 2>&1)
    $result = [PSCustomObject]@{ exitCode = [int]$LASTEXITCODE; output = ($lines -join "`n") }
  }
  if ($null -eq $result -or [int]$result.exitCode -ne 0) {
    throw "CANDIDATE_APK_RUNTIME_IDENTITY_INSPECTION_FAILED"
  }
  $matches = @([regex]::Matches(
      [string]$result.output,
      '(?m)^\.field public static final COMMIT_SHA:Ljava/lang/String; = "([a-f0-9]{40})"\s*$'
    ))
  if ($matches.Count -ne 1) { throw "CANDIDATE_APK_RUNTIME_IDENTITY_PARSE_FAILED" }
  $runtimeSourceSha = $matches[0].Groups[1].Value
  if ($runtimeSourceSha -cne $script:CcrAlpha6RuntimeSourceSha) {
    throw "CANDIDATE_APK_RUNTIME_IDENTITY_MISMATCH"
  }
  return $runtimeSourceSha
}

function Assert-CcrCandidateBuildSigningReady {
  param(
    [string]$BackupDirectory1,
    [string]$BackupDirectory2,
    [scriptblock]$KeyStoreInspector = $null,
    [scriptblock]$PublicCertificateInspector = $null,
    [string]$FingerprintPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.sha256"),
    [string]$CertificatePath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.pem"),
    [string]$PolicyPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-policy.json")
  )
  $inputs = Get-CcrCandidateEnvironmentInputs
  return Invoke-CcrAndroidPilotSigningPreflight `
    -Inputs $inputs `
    -BackupDirectory1 $BackupDirectory1 `
    -BackupDirectory2 $BackupDirectory2 `
    -FingerprintPath $FingerprintPath `
    -CertificatePath $CertificatePath `
    -PolicyPath $PolicyPath `
    -KeyStoreInspector $KeyStoreInspector `
    -PublicCertificateInspector $PublicCertificateInspector
}

function Assert-CcrCandidateExternalOutputRoot {
  param([Parameter(Mandatory = $true)][string]$OutputRoot)
  if (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
    throw "CANDIDATE_OUTPUT_PATH_NOT_ABSOLUTE"
  }
  $full = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
  $repo = (Get-CcrCandidateRepoRoot).TrimEnd('\', '/')
  if ($full.Equals("C:\tmp", [System.StringComparison]::OrdinalIgnoreCase) -or
      $full.StartsWith("C:\tmp\", [System.StringComparison]::OrdinalIgnoreCase) -or
      $full.Equals($repo, [System.StringComparison]::OrdinalIgnoreCase) -or
      $full.StartsWith($repo + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "CANDIDATE_OUTPUT_STORAGE_POLICY_VIOLATION"
  }
  return $full
}

function Invoke-CcrS24Alpha6CandidateBuild {
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
    throw "CANDIDATE_SOURCE_HEAD_UNAVAILABLE"
  }
  if (@(& git -C $repo status --porcelain=v1 --untracked-files=all 2>$null).Count -ne 0) {
    throw "CANDIDATE_SOURCE_WORKTREE_NOT_CLEAN"
  }
  $runtime = @(& node (Join-Path $androidRoot "tools\verify-runtime-inputs-alpha6.mjs") 2>&1)
  if ($LASTEXITCODE -ne 0 -or ($runtime -join "`n") -notmatch "verified 40 frozen Alpha 6 runtime inputs") {
    throw "CANDIDATE_RUNTIME_FREEZE_FAILED"
  }

  $preflight = Assert-CcrCandidateBuildSigningReady `
    -BackupDirectory1 $BackupDirectory1 `
    -BackupDirectory2 $BackupDirectory2
  $candidateInputs = Get-CcrCandidateEnvironmentInputs
  $initScript = Join-Path $androidRoot "gradle\candidate-signing.init.gradle"
  $signingReport = Invoke-CcrCandidateGradle -AndroidRoot $androidRoot -Arguments @(
    "--no-daemon", "-I", $initScript, "signingReport"
  )
  if ($signingReport.exitCode -ne 0) { throw "CANDIDATE_SIGNING_REPORT_FAILED" }
  $normalizedReport = $signingReport.output.Replace(":", "").ToLowerInvariant()
  $normalizedReportPath = $signingReport.output.Replace("/", "\").ToLowerInvariant()
  $expectedStorePath = ([string]$candidateInputs.KeyStorePath).Replace("/", "\").ToLowerInvariant()
  if ($normalizedReport -notmatch [regex]::Escape(([string]$preflight.certificateSha256).ToLowerInvariant()) -or
      -not $normalizedReportPath.Contains($expectedStorePath) -or
      ([regex]::Matches($signingReport.output, "(?im)^\s*Config:\s*ccrCandidate\s*$")).Count -lt 4) {
    throw "CANDIDATE_SIGNING_REPORT_MISMATCH"
  }

  $build = Invoke-CcrCandidateGradle -AndroidRoot $androidRoot -Arguments @(
    "--no-daemon",
    "-I", $initScript,
    "assembleInternalDebug",
    "assembleInternalDebugAndroidTest",
    "assembleInternalBenchmark",
    ":macrobenchmark:assembleInternalBenchmark",
    "--stacktrace"
  )
  if ($build.exitCode -ne 0) { throw "CANDIDATE_APK_BUILD_FAILED" }

  if (-not $OutputRoot) {
    $OutputRoot = Join-Path $env:USERPROFILE "Documents\CCR-Artifacts"
  }
  $root = Assert-CcrCandidateExternalOutputRoot $OutputRoot
  $setDirectory = Join-Path $root (
    "CCR-Android-0.2.0-alpha.6-{0}-{1}" -f
      $head[0].Substring(0, 7),
      (Get-Date -Format "yyyyMMdd-HHmmss")
  )
  if (Test-Path -LiteralPath $setDirectory) { throw "CANDIDATE_OUTPUT_ALREADY_EXISTS" }

  $sourceArtifacts = [ordered]@{
    debugApp = Join-Path $androidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
    debugTest = Join-Path $androidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"
    benchmarkApp = Join-Path $androidRoot "app\build\outputs\apk\internal\benchmark\app-internal-benchmark.apk"
    macrobenchmarkTest = Join-Path $androidRoot "macrobenchmark\build\outputs\apk\internal\benchmark\macrobenchmark-internal-benchmark.apk"
  }
  $tools = Get-CcrPinnedAndroidSdkTools
  $embeddedRuntimeSourceSha = [ordered]@{}
  foreach ($role in @("debugApp", "benchmarkApp")) {
    $embeddedRuntimeSourceSha[$role] = Get-CcrCandidateEmbeddedRuntimeSourceSha `
      -ApkPath $sourceArtifacts[$role] `
      -ApkAnalyzer $tools.ApkAnalyzer
  }
  [System.IO.Directory]::CreateDirectory($setDirectory) | Out-Null
  $records = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in $sourceArtifacts.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
      throw "CANDIDATE_APK_MISSING:$($entry.Key)"
    }
    $destination = Join-Path $setDirectory ([System.IO.Path]::GetFileName($entry.Value))
    [System.IO.File]::Copy($entry.Value, $destination, $false)
    $artifact = [PSCustomObject]@{ role = [string]$entry.Key; path = $destination }
    $identity = Get-CcrPinnedApkIdentity $artifact $tools
    if ([string]$identity.signingCertificateSha256 -cne [string]$preflight.certificateSha256) {
      throw "CANDIDATE_APK_SIGNER_MISMATCH:$($entry.Key)"
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
    artifactSetRevision = 5
    signingLineage = $script:CcrCandidateSigningLineage
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    expectedSigningCertificateSha256 = [string]$preflight.certificateSha256
    runtimeSourceSha = $script:CcrAlpha6RuntimeSourceSha
    harnessSourceSha = $head[0]
    runtimeInputsTreeSha256 = $script:CcrAlpha6RuntimeInputsTreeSha256
    embeddedRuntimeSourceSha = [PSCustomObject]$embeddedRuntimeSourceSha
    versionName = "0.2.0-alpha.6"
    versionCode = 7
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
    -ExpectedHarnessSourceSha $head[0] `
    -ExpectedDebugAppSha256 $debugSha | Out-Null

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
signingMode=SIGNED_CANDIDATE
signingLineage=$($script:CcrCandidateSigningLineage)
artifactSetRevision=5
runtimeSourceSha=$($script:CcrAlpha6RuntimeSourceSha)
harnessSourceSha=$($head[0])
embeddedDebugAppRuntimeSourceSha=$($embeddedRuntimeSourceSha.debugApp)
embeddedBenchmarkAppRuntimeSourceSha=$($embeddedRuntimeSourceSha.benchmarkApp)
ciEphemeralDebug=false
"@,
    [System.Text.UTF8Encoding]::new($false)
  )
  Get-ChildItem -LiteralPath $setDirectory -File | ForEach-Object { $_.IsReadOnly = $true }
  Write-Output "PASS - ALPHA6_SIGNED_CANDIDATE_ARTIFACT_SET_V5_CREATED"
  Write-Output "artifactSet=$setDirectory"
}

if ($MyInvocation.InvocationName -ne ".") {
  try {
    Invoke-CcrS24Alpha6CandidateBuild `
      -OutputRoot $OutputRoot `
      -BackupDirectory1 $BackupDirectory1 `
      -BackupDirectory2 $BackupDirectory2
  } catch {
    Write-Error $_.Exception.Message
    exit 1
  }
}
