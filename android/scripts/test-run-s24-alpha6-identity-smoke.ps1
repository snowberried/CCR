$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = Join-Path $PSScriptRoot "run-s24-alpha6-identity-smoke.ps1"
$candidateBridge = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $candidateBridge

$passed = 0
function Assert-Alpha6IdentitySmokeTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_IDENTITY_SMOKE_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-Alpha6IdentitySmokeThrowsLike {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_IDENTITY_SMOKE_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function New-Alpha6IdentitySmokeAdbState {
  return [PSCustomObject]@{
    Settings = @{
      "global/stay_on_while_plugged_in" = "0"
      "system/screen_brightness_mode" = "1"
      "system/screen_brightness" = "77"
      "system/screen_off_timeout" = "120000"
      "system/accelerometer_rotation" = "1"
      "system/user_rotation" = "2"
    }
    Commands = [System.Collections.Generic.List[string]]::new()
  }
}

function New-Alpha6IdentitySmokeAdbInvoker {
  param([Parameter(Mandatory = $true)][object]$State)
  return {
    param($Arguments)
    $State.Commands.Add(($Arguments -join " ")) | Out-Null
    if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq "devices") {
      return [PSCustomObject]@{
        exitCode = 0
        output = "List of devices attached`nFAKE-S24`tdevice"
      }
    }
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "getprop") {
      $value = switch ([string]$Arguments[4]) {
        "ro.product.model" { "SM-S928N" }
        "ro.product.manufacturer" { "samsung" }
        "ro.build.fingerprint" { "samsung/test/device:37/TEST/1:user/release-keys" }
        "ro.build.version.security_patch" { "2026-06-01" }
        "ro.build.version.sdk" { "37" }
        default { "unknown" }
      }
      return [PSCustomObject]@{ exitCode = 0; output = $value }
    }
    if ($Arguments.Count -ge 7 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "settings") {
      $key = "$($Arguments[5])/$($Arguments[6])"
      if ($Arguments[4] -ceq "get") {
        return [PSCustomObject]@{ exitCode = 0; output = [string]$State.Settings[$key] }
      }
      throw "IDENTITY_SMOKE_SETTINGS_WRITE_FORBIDDEN"
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "pm" -and $Arguments[4] -ceq "list") {
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }.GetNewClosure()
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  "ccr-alpha6-identity-smoke-$PID-$([Guid]::NewGuid().ToString('N'))"
)
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$previousTestMode = $env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE
$env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE = "1"
try {
  $runtimeSource = "c98264f2a10026a908e94c961bb13e4af2d59e60"
  $harnessSource = "2" * 40
  $runtimeTree = "3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468"
  $certificate = Get-CcrCandidatePublicPolicyFingerprint
  $roles = @(
    [PSCustomObject]@{
      role = "debugApp"
      package = $script:CcrPinnedAppPackage
      versionName = "0.2.0-alpha.6"
      versionCode = 7
      runner = $null
      target = $null
    },
    [PSCustomObject]@{
      role = "debugTest"
      package = $script:CcrPinnedDebugTestPackage
      versionName = $null
      versionCode = $null
      runner = $script:CcrPinnedRunner
      target = $script:CcrPinnedAppPackage
    },
    [PSCustomObject]@{
      role = "benchmarkApp"
      package = $script:CcrPinnedAppPackage
      versionName = "0.2.0-alpha.6"
      versionCode = 7
      runner = $null
      target = $null
    },
    [PSCustomObject]@{
      role = "macrobenchmarkTest"
      package = $script:CcrPinnedMacrobenchmarkPackage
      versionName = $null
      versionCode = $null
      runner = $script:CcrPinnedRunner
      target = $script:CcrPinnedMacrobenchmarkPackage
    }
  )
  $artifacts = [System.Collections.Generic.List[object]]::new()
  $identities = @{}
  foreach ($role in $roles) {
    $path = Join-Path $root "$($role.role).apk"
    [System.IO.File]::WriteAllText(
      $path,
      "identity-smoke-$($role.role)",
      [System.Text.UTF8Encoding]::new($false)
    )
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
    embeddedRuntimeSourceSha = [PSCustomObject]@{
      debugApp = $runtimeSource
      benchmarkApp = $runtimeSource
    }
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $artifacts.ToArray()
  }
  $manifestPath = Join-Path $root "artifact-manifest-v5.json"
  [System.IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 15) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  $tools = [PSCustomObject]@{
    Adb = "fake-adb"
    ApkAnalyzer = "fake-apkanalyzer"
    ApkSigner = "fake-apksigner"
  }
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $smokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    return [PSCustomObject]@{
      status = "PASS"
      runId = $IdentityRunId
      runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
      harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
      artifactSetRevision = 5
      buildCommandCount = 0L
    }
  }

  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $runner,
    [ref]$null,
    [ref]$parseErrors
  ) | Out-Null
  Assert-Alpha6IdentitySmokeTest (@($parseErrors).Count -eq 0) "runner-parser"

  $state = New-Alpha6IdentitySmokeAdbState
  $adbInvoker = New-Alpha6IdentitySmokeAdbInvoker $state
  $output = Join-Path $root "success-output"
  $arguments = @{
    ArtifactManifest = $manifestPath
    ArtifactManifestSha256 = $manifestSha
    RuntimeSourceSha = $runtimeSource
    HarnessSourceSha = $harnessSource
    RuntimeInputsTreeSha256 = $runtimeTree
    ExpectedDebugAppSha256 = [string]$artifacts[0].sha256
    OutputDirectory = $output
    RunId = "alpha6-identity-smoke-pass"
    MaxMinutes = 5
    TestOnlyAndroidTools = $tools
    TestOnlyIdentityReader = $identityReader
    TestOnlySourceIdentityVerifier = $sourceVerifier
    TestOnlyAdbInvoker = $adbInvoker
    TestOnlySmokeExecutor = $smokeExecutor
  }
  & $runner @arguments | Out-Null
  $summaryPath = Join-Path $output "alpha6-identity-smoke-summary-alpha6-identity-smoke-pass.json"
  $settingsPath = Join-Path $output "alpha6-identity-smoke-settings-alpha6-identity-smoke-pass.json"
  $summary = [System.IO.File]::ReadAllText(
    $summaryPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  $settings = [System.IO.File]::ReadAllText(
    $settingsPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6IdentitySmokeTest (
    [string]$summary.status -ceq "PASS" -and
      [long]$summary.deviceSettingsMutationCount -eq 0L -and
      [long]$summary.buildCommandCount -eq 0L
  ) "success-no-build-no-settings-mutation"
  Assert-Alpha6IdentitySmokeTest (
    [string]$summary.identity.runtimeSourceSha -ceq $runtimeSource -and
      [string]$summary.identity.harnessSourceSha -ceq $harnessSource -and
      [int]$summary.identity.artifactSetRevision -eq 5 -and
      [string]$summary.identity.signingLineage -ceq "ccr-internal-pilot-v1" -and
      [string]$summary.identity.expectedSigningCertificateSha256 -ceq $certificate
  ) "success-identity-recorded"
  Assert-Alpha6IdentitySmokeTest (
    ($summary.preRunArtifactRehash | ConvertTo-Json -Compress) -ceq
      ($summary.postRunArtifactRehash | ConvertTo-Json -Compress)
  ) "artifact-pre-post-rehash-identical"
  Assert-Alpha6IdentitySmokeTest (
    ($summary.preRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress) -ceq
      ($summary.postRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress)
  ) "public-signing-identity-pre-post-identical"
  Assert-Alpha6IdentitySmokeTest (
    [string]$settings.status -ceq "PASS" -and
      [long]$settings.deviceSettingsMutationCount -eq 0L -and
      [string]$settings.before.screenTimeout -ceq "120000" -and
      [string]$settings.after.screenTimeout -ceq "120000"
  ) "settings-baseline-preserved"
  Assert-Alpha6IdentitySmokeTest (
    (Get-Item -LiteralPath $summaryPath).IsReadOnly -and
      (Get-Item -LiteralPath $settingsPath).IsReadOnly
  ) "success-evidence-read-only"
  Assert-Alpha6IdentitySmokeTest (
    @($state.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "runner-never-writes-settings"
  Assert-Alpha6IdentitySmokeTest (
    @($state.Commands | Where-Object { $_ -match 'pm list packages' }).Count -ge 2 -and
      @($state.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 1
  ) "cleanup-test-packages-and-force-stop"

  $failureState = New-Alpha6IdentitySmokeAdbState
  $failureArguments = @{} + $arguments
  $failureArguments.OutputDirectory = Join-Path $root "failure-output"
  $failureArguments.RunId = "alpha6-identity-smoke-fail"
  $failureArguments.TestOnlyAdbInvoker = New-Alpha6IdentitySmokeAdbInvoker $failureState
  $failureArguments.TestOnlySmokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    throw "SYNTHETIC_IDENTITY_SMOKE_FAILURE"
  }
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @failureArguments | Out-Null
  } "SYNTHETIC_IDENTITY_SMOKE_FAILURE" "instrumentation-failure-propagates"
  Assert-Alpha6IdentitySmokeTest (
    @($failureState.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "failure-before-settings-mutation"
  $failureReports = @(
    Get-ChildItem -LiteralPath $failureArguments.OutputDirectory `
      -Filter "failure-alpha6-identity-smoke-*.json" -File
  )
  Assert-Alpha6IdentitySmokeTest (
    $failureReports.Count -eq 1 -and $failureReports[0].IsReadOnly
  ) "failure-evidence-read-only"

  $mutationState = New-Alpha6IdentitySmokeAdbState
  $mutationArguments = @{} + $arguments
  $mutationArguments.OutputDirectory = Join-Path $root "mutation-output"
  $mutationArguments.RunId = "alpha6-identity-smoke-mutation"
  $mutationArguments.TestOnlyAdbInvoker = New-Alpha6IdentitySmokeAdbInvoker $mutationState
  $mutationArguments.TestOnlySmokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    $mutationState.Settings["system/screen_off_timeout"] = "999999"
    return [PSCustomObject]@{ status = "PASS" }
  }.GetNewClosure()
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @mutationArguments | Out-Null
  } "ALPHA6_IDENTITY_SMOKE_CLEANUP_FAILED:DEVICE_SETTINGS_MUTATED_DURING_IDENTITY_SMOKE" `
    "settings-mutation-fails-closed"

  $wrongAppArguments = @{} + $arguments
  $wrongAppArguments.OutputDirectory = Join-Path $root "wrong-app-output"
  $wrongAppArguments.RunId = "alpha6-identity-smoke-wrong-app"
  $wrongAppArguments.ExpectedDebugAppSha256 = "f" * 64
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @wrongAppArguments | Out-Null
  } "PINNED_DEBUG_APP_SHA_MISMATCH" "wrong-app-sha-rejected"

  $wrongRuntimeArguments = @{} + $arguments
  $wrongRuntimeArguments.OutputDirectory = Join-Path $root "wrong-runtime-output"
  $wrongRuntimeArguments.RunId = "alpha6-identity-smoke-runtime"
  $wrongRuntimeArguments.RuntimeSourceSha = $harnessSource
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @wrongRuntimeArguments | Out-Null
  } "CANDIDATE_RUNTIME_SOURCE_SHA_MISMATCH" "wrong-runtime-sha-rejected"

  $wrongHarnessArguments = @{} + $arguments
  $wrongHarnessArguments.OutputDirectory = Join-Path $root "wrong-harness-output"
  $wrongHarnessArguments.RunId = "alpha6-identity-smoke-harness"
  $wrongHarnessArguments.HarnessSourceSha = "4" * 40
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @wrongHarnessArguments | Out-Null
  } "PINNED_MANIFEST_HARNESS_SOURCE_MISMATCH" "wrong-harness-sha-rejected"

  $revision4 = ($manifest | ConvertTo-Json -Depth 15 -Compress) | ConvertFrom-Json
  $revision4.artifactSetRevision = 4
  $revision4Path = Join-Path $root "artifact-manifest-v4.json"
  [System.IO.File]::WriteAllText(
    $revision4Path,
    (($revision4 | ConvertTo-Json -Depth 15) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $revision4Arguments = @{} + $arguments
  $revision4Arguments.ArtifactManifest = $revision4Path
  $revision4Arguments.ArtifactManifestSha256 = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $revision4Path
  ).Hash.ToLowerInvariant()
  $revision4Arguments.OutputDirectory = Join-Path $root "revision4-output"
  $revision4Arguments.RunId = "alpha6-identity-smoke-rev4"
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @revision4Arguments | Out-Null
  } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "revision4-rejected"

  $wrongTest = ($manifest | ConvertTo-Json -Depth 15 -Compress) | ConvertFrom-Json
  @($wrongTest.artifacts | Where-Object { $_.role -ceq "debugTest" })[0].sha256 = "f" * 64
  $wrongTestPath = Join-Path $root "artifact-manifest-wrong-test.json"
  [System.IO.File]::WriteAllText(
    $wrongTestPath,
    (($wrongTest | ConvertTo-Json -Depth 15) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $wrongTestArguments = @{} + $arguments
  $wrongTestArguments.ArtifactManifest = $wrongTestPath
  $wrongTestArguments.ArtifactManifestSha256 = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $wrongTestPath
  ).Hash.ToLowerInvariant()
  $wrongTestArguments.OutputDirectory = Join-Path $root "wrong-test-output"
  $wrongTestArguments.RunId = "alpha6-identity-smoke-test"
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @wrongTestArguments | Out-Null
  } "PINNED_ARTIFACT_SHA_MISMATCH:debugTest" "wrong-test-sha-rejected"

  $env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE = $null
  $forbiddenArguments = @{} + $arguments
  $forbiddenArguments.OutputDirectory = Join-Path $root "forbidden-hook-output"
  $forbiddenArguments.RunId = "alpha6-identity-smoke-hook"
  Assert-Alpha6IdentitySmokeThrowsLike {
    & $runner @forbiddenArguments | Out-Null
  } "ALPHA6_IDENTITY_SMOKE_TEST_HOOK_FORBIDDEN" "production-test-hook-forbidden"
  $env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE = "1"

  Write-Output "Alpha 6 identity smoke runner host tests passed: $passed"
} finally {
  if ($null -eq $previousTestMode) {
    Remove-Item Env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE -ErrorAction SilentlyContinue
  } else {
    $env:CCR_ALPHA6_IDENTITY_SMOKE_TEST_MODE = $previousTestMode
  }
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
