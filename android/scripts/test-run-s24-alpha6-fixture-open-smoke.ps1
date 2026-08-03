$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = Join-Path $PSScriptRoot "run-s24-alpha6-fixture-open-smoke.ps1"
$diagnosticRunner = Join-Path $PSScriptRoot "run-s24-alpha6-fixture-open-diagnostic.ps1"
$candidateBridge = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $candidateBridge

$passed = 0
function Assert-Alpha6FixtureOpenTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_FIXTURE_OPEN_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-Alpha6FixtureOpenThrowsLike {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_FIXTURE_OPEN_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function New-Alpha6FixtureOpenAdbState {
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

function New-Alpha6FixtureOpenAdbInvoker {
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
      throw "FIXTURE_OPEN_SETTINGS_WRITE_FORBIDDEN"
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "pm" -and $Arguments[4] -ceq "list") {
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }.GetNewClosure()
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  "ccr-alpha6-fixture-open-$PID-$([Guid]::NewGuid().ToString('N'))"
)
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$previousTestMode = $env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE
$env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE = "1"
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
      "fixture-open-$($role.role)",
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
  $positiveExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory, $FixtureMode)
    return [PSCustomObject][ordered]@{
      status = "PASS"
      mode = $FixtureMode
      runId = $FixtureRunId
      fixtureCount = 17
      assetHashPassCount = 17
      providerOpenPassCount = 17
      cacheVerificationPassCount = 17
      extractorOpenPassCount = 17
      videoTrackPassCount = 17
      sampleEnumerationPassCount = 17
      hardwareDecoderCandidatePassCount = 17
      writeOpenCount = 0
      deviceSettingsMutationCount = 0
      fullFrameDecodeCount = 0
      performanceScenarioCount = 0
      buildCommandCount = 0L
    }
  }

  foreach ($path in @($runner, $diagnosticRunner)) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $path,
      [ref]$null,
      [ref]$parseErrors
    ) | Out-Null
    Assert-Alpha6FixtureOpenTest (@($parseErrors).Count -eq 0) "parser-$([System.IO.Path]::GetFileName($path))"
  }
  $diagnosticSource = [System.IO.File]::ReadAllText($diagnosticRunner, [System.Text.Encoding]::UTF8)
  Assert-Alpha6FixtureOpenTest (
    $diagnosticSource.Contains('$parameters["Mode"] = "Diagnostic"')
  ) "diagnostic-wrapper-selects-diagnostic-mode"
  $runnerSource = [System.IO.File]::ReadAllText($runner, [System.Text.Encoding]::UTF8)
  Assert-Alpha6FixtureOpenTest (
    $runnerSource.Contains("New-CcrAlpha6TimedAdbInvoker") -and
      $runnerSource.Contains('$adbDeadlineState.CleanupMode = $true') -and
      $runnerSource.Contains('$adbDeadlineState.CleanupDeadlineUtc = [DateTime]::UtcNow.AddMinutes(2)')
  ) "fixture-open-adb-is-deadline-bounded"

  $state = New-Alpha6FixtureOpenAdbState
  $output = Join-Path $root "success-output"
  $arguments = @{
    ArtifactManifest = $manifestPath
    ArtifactManifestSha256 = $manifestSha
    RuntimeSourceSha = $runtimeSource
    HarnessSourceSha = $harnessSource
    RuntimeInputsTreeSha256 = $runtimeTree
    ExpectedDebugAppSha256 = [string]$artifacts[0].sha256
    OutputDirectory = $output
    RunId = "alpha6-fixture-open-pass"
    MaxMinutes = 5
    TestOnlyAndroidTools = $tools
    TestOnlyIdentityReader = $identityReader
    TestOnlySourceIdentityVerifier = $sourceVerifier
    TestOnlyAdbInvoker = New-Alpha6FixtureOpenAdbInvoker $state
    TestOnlyExecutor = $positiveExecutor
  }
  & $runner @arguments | Out-Null
  $summaryPath = Join-Path $output "alpha6-fixture-open-smoke-summary-alpha6-fixture-open-pass.json"
  $settingsPath = Join-Path $output "alpha6-fixture-open-smoke-settings-alpha6-fixture-open-pass.json"
  $summary = [System.IO.File]::ReadAllText(
    $summaryPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  $settings = [System.IO.File]::ReadAllText(
    $settingsPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6FixtureOpenTest (
    [string]$summary.status -ceq "PASS" -and
      [string]$summary.kind -ceq "alpha6-candidate-fixture-open-smoke" -and
      [string]$summary.mode -ceq "Smoke" -and
      [long]$summary.deviceSettingsMutationCount -eq 0L -and
      [long]$summary.buildCommandCount -eq 0L
  ) "smoke-pass-no-build-no-settings-mutation"
  Assert-Alpha6FixtureOpenTest (
    [int]$summary.fixtureOpen.fixtureCount -eq 17 -and
      [int]$summary.fixtureOpen.providerOpenPassCount -eq 17 -and
      [int]$summary.fixtureOpen.extractorOpenPassCount -eq 17 -and
      [int]$summary.fixtureOpen.hardwareDecoderCandidatePassCount -eq 17 -and
      [int]$summary.fixtureOpen.fullFrameDecodeCount -eq 0
  ) "fixture-open-smoke-17-of-17"
  Assert-Alpha6FixtureOpenTest (
    [string]$summary.identity.runtimeSourceSha -ceq $runtimeSource -and
      [string]$summary.identity.harnessSourceSha -ceq $harnessSource -and
      [int]$summary.identity.artifactSetRevision -eq 5 -and
      [string]$summary.identity.expectedSigningCertificateSha256 -ceq $certificate
  ) "fixture-open-smoke-identity"
  Assert-Alpha6FixtureOpenTest (
    [string]$settings.status -ceq "PASS" -and
      [long]$settings.deviceSettingsMutationCount -eq 0L -and
      [string]$settings.before.screenTimeout -ceq "120000" -and
      [string]$settings.after.screenTimeout -ceq "120000"
  ) "fixture-open-smoke-settings-preserved"
  Assert-Alpha6FixtureOpenTest (
    (Get-Item -LiteralPath $summaryPath).IsReadOnly -and
      (Get-Item -LiteralPath $settingsPath).IsReadOnly
  ) "fixture-open-smoke-evidence-read-only"
  Assert-Alpha6FixtureOpenTest (
    @($state.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "fixture-open-smoke-never-writes-settings"
  Assert-Alpha6FixtureOpenTest (
    @($state.Commands | Where-Object { $_ -match 'pm list packages' }).Count -ge 2 -and
      @($state.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 1
  ) "fixture-open-smoke-cleanup"

  $diagnosticState = New-Alpha6FixtureOpenAdbState
  $diagnosticArguments = @{} + $arguments
  $diagnosticArguments.OutputDirectory = Join-Path $root "diagnostic-output"
  $diagnosticArguments.RunId = "alpha6-fixture-open-diagnostic"
  $diagnosticArguments.Mode = "Diagnostic"
  $diagnosticArguments.TestOnlyAdbInvoker = New-Alpha6FixtureOpenAdbInvoker $diagnosticState
  $diagnosticArguments.TestOnlyExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory, $FixtureMode)
    return [PSCustomObject]@{
      status = "PASS"
      fixtureCount = 1L
      buildCommandCount = 0L
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
    }
  }
  & $runner @diagnosticArguments | Out-Null
  $diagnosticSummaryPath = Join-Path $diagnosticArguments.OutputDirectory (
    "alpha6-fixture-open-diagnostic-summary-alpha6-fixture-open-diagnostic.json"
  )
  $diagnosticSummary = [System.IO.File]::ReadAllText(
    $diagnosticSummaryPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6FixtureOpenTest (
    [string]$diagnosticSummary.status -ceq "PASS" -and
      [string]$diagnosticSummary.kind -ceq "alpha6-candidate-fixture-open-diagnostic" -and
      [string]$diagnosticSummary.mode -ceq "Diagnostic" -and
      [long]$diagnosticSummary.fixtureOpen.fixtureCount -eq 1L -and
      [long]$diagnosticSummary.deviceSettingsMutationCount -eq 0L
  ) "fixture-open-diagnostic-mode-pass"

  $failureState = New-Alpha6FixtureOpenAdbState
  $failureArguments = @{} + $arguments
  $failureArguments.OutputDirectory = Join-Path $root "failure-output"
  $failureArguments.RunId = "alpha6-fixture-open-fail"
  $failureArguments.TestOnlyAdbInvoker = New-Alpha6FixtureOpenAdbInvoker $failureState
  $failureArguments.TestOnlyExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory, $FixtureMode)
    throw "SYNTHETIC_FIXTURE_OPEN_FAILURE"
  }
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @failureArguments | Out-Null
  } "SYNTHETIC_FIXTURE_OPEN_FAILURE" "fixture-open-smoke-failure-propagates"
  Assert-Alpha6FixtureOpenTest (
    @($failureState.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "fixture-open-smoke-failure-before-settings-mutation"
  $failureReports = @(
    Get-ChildItem -LiteralPath $failureArguments.OutputDirectory `
      -Filter "failure-alpha6-fixture-open-smoke-*.json" -File
  )
  $failureReport = [System.IO.File]::ReadAllText(
    $failureReports[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6FixtureOpenTest (
    $failureReports.Count -eq 1 -and
      $failureReports[0].IsReadOnly -and
      [string]$failureReport.identity.runtimeSourceSha -ceq $runtimeSource -and
      [int]$failureReport.identity.artifactSetRevision -eq 5
  ) "fixture-open-smoke-failure-evidence-identity"

  $mutationState = New-Alpha6FixtureOpenAdbState
  $mutationArguments = @{} + $arguments
  $mutationArguments.OutputDirectory = Join-Path $root "mutation-output"
  $mutationArguments.RunId = "alpha6-fixture-open-mutation"
  $mutationArguments.TestOnlyAdbInvoker = New-Alpha6FixtureOpenAdbInvoker $mutationState
  $mutationArguments.TestOnlyExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory, $FixtureMode)
    $mutationState.Settings["system/screen_off_timeout"] = "999999"
    return [PSCustomObject]@{
      status = "PASS"
      fixtureCount = 17L
      buildCommandCount = 0L
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
    }
  }.GetNewClosure()
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @mutationArguments | Out-Null
  } "ALPHA6_FIXTURE_OPEN_SMOKE_CLEANUP_FAILED:DEVICE_SETTINGS_MUTATED_DURING_FIXTURE_OPEN_SMOKE" `
    "fixture-open-smoke-settings-mutation-fails-closed"

  $wrongAppArguments = @{} + $arguments
  $wrongAppArguments.OutputDirectory = Join-Path $root "wrong-app-output"
  $wrongAppArguments.RunId = "alpha6-fixture-open-wrong-app"
  $wrongAppArguments.ExpectedDebugAppSha256 = "f" * 64
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @wrongAppArguments | Out-Null
  } "PINNED_DEBUG_APP_SHA_MISMATCH" "fixture-open-smoke-wrong-app-identity-rejected"

  $wrongRuntimeArguments = @{} + $arguments
  $wrongRuntimeArguments.OutputDirectory = Join-Path $root "wrong-runtime-output"
  $wrongRuntimeArguments.RunId = "alpha6-fixture-open-runtime"
  $wrongRuntimeArguments.RuntimeSourceSha = $harnessSource
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @wrongRuntimeArguments | Out-Null
  } "CANDIDATE_MANIFEST_EMBEDDED_RUNTIME_IDENTITY_MISMATCH:debugApp" "fixture-open-smoke-wrong-runtime-identity-rejected"

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
  $revision4Arguments.RunId = "alpha6-fixture-open-rev4"
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @revision4Arguments | Out-Null
  } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "fixture-open-smoke-revision4-rejected"

  $env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE = $null
  $forbiddenArguments = @{} + $arguments
  $forbiddenArguments.OutputDirectory = Join-Path $root "forbidden-output"
  $forbiddenArguments.RunId = "alpha6-fixture-open-hook"
  Assert-Alpha6FixtureOpenThrowsLike {
    & $runner @forbiddenArguments | Out-Null
  } "ALPHA6_FIXTURE_OPEN_TEST_HOOK_FORBIDDEN" "fixture-open-smoke-production-hook-forbidden"
  $env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE = "1"

  Write-Output "Alpha 6 fixture-open smoke runner host tests passed: $passed"
} finally {
  if ($null -eq $previousTestMode) {
    Remove-Item Env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE -ErrorAction SilentlyContinue
  } else {
    $env:CCR_ALPHA6_FIXTURE_OPEN_TEST_MODE = $previousTestMode
  }
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
