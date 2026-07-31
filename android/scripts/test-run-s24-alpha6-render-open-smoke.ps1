$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = Join-Path $PSScriptRoot "run-s24-alpha6-render-open-smoke.ps1"
$candidateBridge = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $candidateBridge

$passed = 0
function Assert-Alpha6RenderOpenTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_RENDER_OPEN_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-Alpha6RenderOpenThrowsLike {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_RENDER_OPEN_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function New-Alpha6RenderOpenAdbState {
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

function New-Alpha6RenderOpenAdbInvoker {
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
      throw "RENDER_OPEN_SETTINGS_WRITE_FORBIDDEN"
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "pm" -and $Arguments[4] -ceq "list") {
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }.GetNewClosure()
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  "ccr-alpha6-render-open-$PID-$([Guid]::NewGuid().ToString('N'))"
)
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$previousTestMode = $env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE
$env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE = "1"
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
      "render-open-$($role.role)",
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
    param($Context, $SmokeRunId, $EvidenceDirectory)
    return [PSCustomObject][ordered]@{
      status = "PASS"
      kind = "alpha6-candidate-render-open-smoke-instrumentation"
      runId = $SmokeRunId
      activityInstanceDriftCount = 0L
      surfaceGenerationDriftCount = 0L
      videoOpenFailedCount = 0L
      frameIndex = 0L
      hardwareDecoder = $true
      writeOpenCount = 0L
      performanceScenarioCount = 0L
      buildCommandCount = 0L
    }
  }

  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $runner,
    [ref]$null,
    [ref]$parseErrors
  ) | Out-Null
  Assert-Alpha6RenderOpenTest (@($parseErrors).Count -eq 0) "runner-parser"

  $state = New-Alpha6RenderOpenAdbState
  $output = Join-Path $root "success-output"
  $arguments = @{
    ArtifactManifest = $manifestPath
    ArtifactManifestSha256 = $manifestSha
    RuntimeSourceSha = $runtimeSource
    HarnessSourceSha = $harnessSource
    RuntimeInputsTreeSha256 = $runtimeTree
    ExpectedDebugAppSha256 = [string]$artifacts[0].sha256
    OutputDirectory = $output
    RunId = "alpha6-render-open-pass"
    MaxMinutes = 5
    TestOnlyAndroidTools = $tools
    TestOnlyIdentityReader = $identityReader
    TestOnlySourceIdentityVerifier = $sourceVerifier
    TestOnlyAdbInvoker = New-Alpha6RenderOpenAdbInvoker $state
    TestOnlyExecutor = $positiveExecutor
  }
  & $runner @arguments | Out-Null
  $summaryPath = Join-Path $output "alpha6-render-open-smoke-summary-alpha6-render-open-pass.json"
  $settingsPath = Join-Path $output "alpha6-render-open-smoke-settings-alpha6-render-open-pass.json"
  $summary = [System.IO.File]::ReadAllText(
    $summaryPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  $settings = [System.IO.File]::ReadAllText(
    $settingsPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6RenderOpenTest (
    [string]$summary.kind -ceq "alpha6-candidate-render-open-smoke" -and
      [string]$summary.status -ceq "PASS" -and
      [long]$summary.renderOpen.frameIndex -eq 0L -and
      [long]$summary.renderOpen.performanceScenarioCount -eq 0L -and
      [long]$summary.deviceSettingsMutationCount -eq 0L
  ) "positive-result"
  Assert-Alpha6RenderOpenTest (
    [string]$summary.identity.runtimeSourceSha -ceq $runtimeSource -and
      [string]$summary.identity.harnessSourceSha -ceq $harnessSource -and
      [int]$summary.identity.artifactSetRevision -eq 5 -and
      [string]$summary.identity.signingLineage -ceq "ccr-internal-pilot-v1" -and
      [string]$summary.identity.expectedSigningCertificateSha256 -ceq $certificate
  ) "revision5-candidate-preflight-signing-identity"
  Assert-Alpha6RenderOpenTest (
    [string]$settings.status -ceq "PASS" -and
      [long]$settings.deviceSettingsMutationCount -eq 0L -and
      [string]$settings.before.screenTimeout -ceq "120000" -and
      [string]$settings.after.screenTimeout -ceq "120000"
  ) "settings-evidence"
  Assert-Alpha6RenderOpenTest (
    (Get-Item -LiteralPath $summaryPath).IsReadOnly -and
      (Get-Item -LiteralPath $settingsPath).IsReadOnly
  ) "immutable-summary-settings"
  Assert-Alpha6RenderOpenTest (
    ($summary.preRunArtifactRehash | ConvertTo-Json -Compress) -ceq
      ($summary.postRunArtifactRehash | ConvertTo-Json -Compress) -and
      ($summary.preRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress) -ceq
        ($summary.postRunPublicSigningIdentity | ConvertTo-Json -Depth 20 -Compress)
  ) "artifact-unchanged"
  Assert-Alpha6RenderOpenTest (
    [long]$summary.buildCommandCount -eq 0L -and
      [long]$summary.renderOpen.buildCommandCount -eq 0L
  ) "build-command-count-zero"
  Assert-Alpha6RenderOpenTest (
    @($state.Commands | Where-Object { $_ -match 'pm list packages' }).Count -ge 2 -and
      @($state.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 1 -and
      @($state.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "cleanup"

  $failureState = New-Alpha6RenderOpenAdbState
  $failureArguments = @{} + $arguments
  $failureArguments.OutputDirectory = Join-Path $root "failure-output"
  $failureArguments.RunId = "alpha6-render-open-fail"
  $failureArguments.TestOnlyAdbInvoker = New-Alpha6RenderOpenAdbInvoker $failureState
  $failureArguments.TestOnlyExecutor = {
    param($Context, $SmokeRunId, $EvidenceDirectory)
    return [PSCustomObject][ordered]@{
      status = "FAIL"
      failure = [PSCustomObject][ordered]@{
        classification = "SURFACE_LOST_DURING_OPEN"
      }
      performanceScenarioCount = 0L
      buildCommandCount = 0L
    }
  }
  Assert-Alpha6RenderOpenThrowsLike {
    & $runner @failureArguments | Out-Null
  } "ALPHA6_RENDER_OPEN_SMOKE_FAILED:SURFACE_LOST_DURING_OPEN" "render-open-smoke-failure"
  $failureReports = @(
    Get-ChildItem -LiteralPath $failureArguments.OutputDirectory `
      -Filter "failure-alpha6-render-open-smoke-*.json" -File
  )
  $failureReport = [System.IO.File]::ReadAllText(
    $failureReports[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6RenderOpenTest (
    $failureReports.Count -eq 1 -and
      $failureReports[0].IsReadOnly -and
      [string]$failureReport.failure.classification -ceq
        "SURFACE_LOST_DURING_OPEN" -and
      [string]$failureReport.renderOpen.failure.classification -ceq
        "SURFACE_LOST_DURING_OPEN"
  ) "failure-classification-propagated"
  Assert-Alpha6RenderOpenTest (
    @($failureState.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 1
  ) "failure-cleanup"

  $mutationState = New-Alpha6RenderOpenAdbState
  $mutationArguments = @{} + $arguments
  $mutationArguments.OutputDirectory = Join-Path $root "mutation-output"
  $mutationArguments.RunId = "alpha6-render-open-mutation"
  $mutationArguments.TestOnlyAdbInvoker = New-Alpha6RenderOpenAdbInvoker $mutationState
  $mutationArguments.TestOnlyExecutor = {
    param($Context, $SmokeRunId, $EvidenceDirectory)
    $mutationState.Settings["system/screen_off_timeout"] = "999999"
    return [PSCustomObject]@{
      status = "PASS"
      performanceScenarioCount = 0L
      buildCommandCount = 0L
    }
  }.GetNewClosure()
  Assert-Alpha6RenderOpenThrowsLike {
    & $runner @mutationArguments | Out-Null
  } "ALPHA6_RENDER_OPEN_SMOKE_CLEANUP_FAILED:DEVICE_SETTINGS_MUTATED_DURING_RENDER_OPEN_SMOKE" `
    "settings-mutation-fail-closed"

  $debugAppPath = [string]$artifacts[0].path
  $debugAppContent = [System.IO.File]::ReadAllText($debugAppPath, [System.Text.Encoding]::UTF8)
  $driftArguments = @{} + $arguments
  $driftArguments.OutputDirectory = Join-Path $root "drift-output"
  $driftArguments.RunId = "alpha6-render-open-drift"
  $driftArguments.TestOnlyExecutor = {
    param($Context, $SmokeRunId, $EvidenceDirectory)
    [System.IO.File]::AppendAllText(
      $debugAppPath,
      "-drift",
      [System.Text.UTF8Encoding]::new($false)
    )
    return [PSCustomObject]@{
      status = "PASS"
      performanceScenarioCount = 0L
      buildCommandCount = 0L
    }
  }.GetNewClosure()
  try {
    Assert-Alpha6RenderOpenThrowsLike {
      & $runner @driftArguments | Out-Null
    } "*ALPHA6_ARTIFACT_CHANGED_AFTER_PREFLIGHT:debugApp*" "artifact-drift-fail-closed"
  } finally {
    [System.IO.File]::WriteAllText(
      $debugAppPath,
      $debugAppContent,
      [System.Text.UTF8Encoding]::new($false)
    )
  }

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
  $revision4Arguments.RunId = "alpha6-render-open-rev4"
  Assert-Alpha6RenderOpenThrowsLike {
    & $runner @revision4Arguments | Out-Null
  } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "revision4-candidate-rejected"

  $env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE = $null
  $forbiddenArguments = @{} + $arguments
  $forbiddenArguments.OutputDirectory = Join-Path $root "forbidden-output"
  $forbiddenArguments.RunId = "alpha6-render-open-hook"
  Assert-Alpha6RenderOpenThrowsLike {
    & $runner @forbiddenArguments | Out-Null
  } "ALPHA6_RENDER_OPEN_TEST_HOOK_FORBIDDEN" "production-test-hook-forbidden"
  $env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE = "1"

  Write-Output "Alpha 6 render-open smoke runner host tests passed: $passed"
} finally {
  if ($null -eq $previousTestMode) {
    Remove-Item Env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE -ErrorAction SilentlyContinue
  } else {
    $env:CCR_ALPHA6_RENDER_OPEN_TEST_MODE = $previousTestMode
  }
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
