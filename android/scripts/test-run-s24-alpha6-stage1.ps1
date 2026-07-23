$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = Join-Path $PSScriptRoot "run-s24-alpha6-stage1.ps1"
$alpha6Pinned = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinned = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
$tailContract = Join-Path $PSScriptRoot "alpha6-tail-contract.ps1"
$benchmarkActivity = Join-Path $PSScriptRoot "..\app\src\benchmark\java\com\snowberried\ctcinereviewer\benchmark\BenchmarkActivity.kt"
$macrobenchmark = Join-Path $PSScriptRoot "..\macrobenchmark\src\main\java\com\snowberried\ctcinereviewer\macrobenchmark\CcrProductMacrobenchmark.kt"
. $alpha6Pinned

$passed = 0
function Assert-Alpha6Stage1Test {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_STAGE1_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-Alpha6Stage1ThrowsLike {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_STAGE1_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function New-Alpha6FakeAdbState {
  param([string]$Fingerprint = "samsung/test/device:37/TEST/1:user/release-keys")
  return [PSCustomObject]@{
    Fingerprint = $Fingerprint
    Settings = @{
      "global/stay_on_while_plugged_in" = "0"
      "system/screen_brightness_mode" = "1"
      "system/screen_brightness" = "77"
      "system/screen_off_timeout" = "600000"
      "system/accelerometer_rotation" = "1"
      "system/user_rotation" = "2"
    }
    Commands = [System.Collections.Generic.List[string]]::new()
  }
}

function New-Alpha6FakeAdbInvoker {
  param([Parameter(Mandatory = $true)][object]$State)
  return {
    param($Arguments)
    $State.Commands.Add(($Arguments -join " ")) | Out-Null
    if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq "devices") {
      return [PSCustomObject]@{ exitCode = 0; output = "List of devices attached`nFAKE-S24`tdevice" }
    }
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and $Arguments[3] -ceq "getprop") {
      $value = switch ([string]$Arguments[4]) {
        "ro.product.model" { "SM-S928B" }
        "ro.product.manufacturer" { "samsung" }
        "ro.build.fingerprint" { $State.Fingerprint }
        "ro.build.version.security_patch" { "2026-06-01" }
        "ro.build.version.sdk" { "37" }
        default { "unknown" }
      }
      return [PSCustomObject]@{ exitCode = 0; output = $value }
    }
    if ($Arguments.Count -ge 7 -and $Arguments[2] -ceq "shell" -and $Arguments[3] -ceq "settings") {
      $operation = [string]$Arguments[4]
      $key = "$($Arguments[5])/$($Arguments[6])"
      if ($operation -ceq "get") {
        return [PSCustomObject]@{ exitCode = 0; output = [string]$State.Settings[$key] }
      }
      if ($operation -ceq "put") {
        $State.Settings[$key] = [string]$Arguments[7]
        return [PSCustomObject]@{ exitCode = 0; output = "" }
      }
      if ($operation -ceq "delete") {
        $State.Settings[$key] = "null"
        return [PSCustomObject]@{ exitCode = 0; output = "" }
      }
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and $Arguments[3] -ceq "pm" -and
        $Arguments[4] -ceq "list") {
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }.GetNewClosure()
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-stage1-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$previousTestMode = $env:CCR_ALPHA6_STAGE1_TEST_MODE
$env:CCR_ALPHA6_STAGE1_TEST_MODE = "1"
try {
  $runtimeSource = "1" * 40
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $certificate = $script:CcrPinnedSigningCertificateSha256
  $roles = @(
    [PSCustomObject]@{ role = "debugApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "debugTest"; package = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedAppPackage },
    [PSCustomObject]@{ role = "benchmarkApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "macrobenchmarkTest"; package = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedMacrobenchmarkPackage }
  )
  $artifacts = [System.Collections.Generic.List[object]]::new()
  $identities = @{}
  foreach ($role in $roles) {
    $path = Join-Path $root "$($role.role).apk"
    [System.IO.File]::WriteAllText($path, "stage1-$($role.role)", [System.Text.UTF8Encoding]::new($false))
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
    artifactSetRevision = 4
    runtimeSourceSha = $runtimeSource
    harnessSourceSha = $harnessSource
    runtimeInputsTreeSha256 = $runtimeTree
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $artifacts.ToArray()
  }
  $manifestPath = Join-Path $root "artifact-manifest-v4.json"
  [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
  $manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  $debugSha = [string]$artifacts[0].sha256
  $tools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }

  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$parseErrors) | Out-Null
  Assert-Alpha6Stage1Test (@($parseErrors).Count -eq 0) "runner-parser"
  $closed = @($runner, $alpha6Pinned, $basePinned, $tailContract | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
  $buildFree = @(Assert-CcrAlpha6ValidationScriptsBuildFree $closed)
  Assert-Alpha6Stage1Test ($buildFree.Count -eq 4) "closed-script-list-build-free"
  $source = [System.IO.File]::ReadAllText($runner, [System.Text.Encoding]::UTF8)
  Assert-Alpha6Stage1Test ($source.Contains("Invoke-CcrAlpha6PinnedHostPreflight")) "host-preflight-connected"
  Assert-Alpha6Stage1Test ($source.Contains("Assert-CcrAlpha6ArtifactSetUnchanged")) "artifact-rehash-connected"
  Assert-Alpha6Stage1Test ($source.Contains("Invoke-CcrPinnedCleanup")) "package-cleanup-finally"
  Assert-Alpha6Stage1Test ($source.Contains("Recover-CcrAlpha6Stage1Traces")) "trace-recovery-hook"
  Assert-Alpha6Stage1Test ($source -notmatch '(?m)^\s*\$\w*(?:Sha|Sha256)\w*\s*=\s*"[0-9a-f]{40,64}"') "no-final-hash-placeholder"
  Assert-Alpha6Stage1Test ($source -match 'scenarioCount\s*=\s*10' -and $source -match 'independentTraceCount\s*=\s*30') "ten-scenarios-thirty-traces"
  Assert-Alpha6Stage1Test ($source.Contains("ALPHA6_STAGE1_BENCHMARK_FIXTURE_IDENTITY_MISMATCH")) "fixture-identity-fail-closed"
  Assert-Alpha6Stage1Test ($source.Contains('"measuredWindowBuildAssociatedLongGapCount"') -and
    $source.Contains("ALPHA6_STAGE1_REVERSE_MECHANISM_NOT_EXERCISED")) "window-build-and-mechanism-gates"
  Assert-Alpha6Stage1Test ($source.Contains("directionReversalAndGenerationInvalidationRemainExactOnS24Ultra")) "direction-reversal-correctness-retained"
  $benchmarkSource = [System.IO.File]::ReadAllText($benchmarkActivity, [System.Text.Encoding]::UTF8)
  $macrobenchmarkSource = [System.IO.File]::ReadAllText($macrobenchmark, [System.Text.Encoding]::UTF8)
  foreach ($contract in @(
    [PSCustomObject]@{ id = "h264-bframes"; fixture = "1080p-h264-bframes.mp4"; minusOne = "hold1080MinusOne"; minusFive = "hold1080MinusFive"; scenario = "1080p-hold-minus" },
    [PSCustomObject]@{ id = "h264-long-gop"; fixture = "1080p-h264-long-gop.mp4"; minusOne = "hold1080H264LongGopMinusOne"; minusFive = "hold1080H264LongGopMinusFive"; scenario = "1080p-h264-long-gop-hold-minus" },
    [PSCustomObject]@{ id = "hevc-main8"; fixture = "1080p-hevc-main8.mp4"; minusOne = "hold1080HevcMain8MinusOne"; minusFive = "hold1080HevcMain8MinusFive"; scenario = "1080p-hevc-main8-hold-minus" },
    [PSCustomObject]@{ id = "vfr"; fixture = "1080p-vfr.mp4"; minusOne = "hold1080VfrMinusOne"; minusFive = "hold1080VfrMinusFive"; scenario = "1080p-vfr-hold-minus" }
  )) {
    Assert-Alpha6Stage1Test ($source.Contains($contract.id) -and $source.Contains($contract.fixture)) "runner-fixture-$($contract.id)"
    Assert-Alpha6Stage1Test ($source.Contains($contract.minusOne) -and $source.Contains($contract.minusFive)) "runner-strides-$($contract.id)"
    Assert-Alpha6Stage1Test ($benchmarkSource.Contains($contract.fixture) -and $benchmarkSource.Contains($contract.scenario)) "benchmark-fixture-$($contract.id)"
    Assert-Alpha6Stage1Test ($macrobenchmarkSource.Contains($contract.minusOne) -and $macrobenchmarkSource.Contains($contract.minusFive) -and $macrobenchmarkSource.Contains($contract.fixture)) "macrobenchmark-fixture-$($contract.id)"
  }
  Assert-Alpha6Stage1Test ($source.Contains('fixtureIdentity -ceq "h264-bframes"') -and $source.Contains('cappedForwardFps * 0.8')) "shared-capped-forward-baseline"
  Assert-Alpha6Stage1Test ($source.Contains('$absoluteMinimumFps = if ($stride -eq -1) { 12.0 } else { 10.0 }')) "absolute-forward-reverse-fps-floor"
  Assert-Alpha6Stage1Test (
    $source.Contains('@("h264-bframes.mp4", "long-gop.mp4", "hevc-main8.mp4", "vfr.mp4")')
  ) "completed-resume-revalidates-hevc-sequential-evidence"

  $preflightOutput = Join-Path $root "preflight-output"
  $adbWasCalled = [PSCustomObject]@{ Count = 0 }
  $forbiddenAdb = {
    param($Arguments)
    $adbWasCalled.Count += 1
    throw "ADB_MUST_NOT_RUN_DURING_PREFLIGHT"
  }.GetNewClosure()
  $preflightArgs = @{
    ArtifactManifest = $manifestPath
    ArtifactManifestSha256 = $manifestSha
    RuntimeSourceSha = $runtimeSource
    HarnessSourceSha = $harnessSource
    RuntimeInputsTreeSha256 = $runtimeTree
    ExpectedDebugAppSha256 = $debugSha
    OutputDirectory = $preflightOutput
    RunId = "alpha6-stage1-preflight"
    MaxMinutes = 25
    PreflightOnly = $true
    TestOnlyAndroidTools = $tools
    TestOnlyIdentityReader = $identityReader
    TestOnlySourceIdentityVerifier = $sourceVerifier
    TestOnlyAdbInvoker = $forbiddenAdb
  }
  & $runner @preflightArgs | Out-Null
  Assert-Alpha6Stage1Test ($adbWasCalled.Count -eq 0) "preflight-has-zero-adb"
  $preflightSummaryPath = Join-Path $preflightOutput "alpha6-stage1-summary-alpha6-stage1-preflight.json"
  $preflight = [System.IO.File]::ReadAllText($preflightSummaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ([string]$preflight.status -ceq "PREFLIGHT_PASS") "preflight-status"
  Assert-Alpha6Stage1Test ([long]$preflight.buildCommandCount -eq 0L -and [long]$preflight.deviceMutationCount -eq 0L) "preflight-no-build-no-mutation"
  $plannedPerformance = @($preflight.plannedPerformanceScenarios)
  Assert-Alpha6Stage1Test ($plannedPerformance.Count -eq 10 -and [long]$preflight.plannedIndependentTraceCount -eq 30L) "preflight-ten-scenarios-thirty-traces"
  $plannedTokens = @($plannedPerformance | ForEach-Object {
    "$($_.scenario)|$($_.fixtureIdentity)|$($_.fixture)|$($_.stride)"
  } | Sort-Object)
  $expectedPlannedTokens = @(
    "1080p-h264-long-gop-hold-minus-five|h264-long-gop|1080p-h264-long-gop.mp4|-5",
    "1080p-h264-long-gop-hold-minus-one|h264-long-gop|1080p-h264-long-gop.mp4|-1",
    "1080p-hevc-main8-hold-minus-five|hevc-main8|1080p-hevc-main8.mp4|-5",
    "1080p-hevc-main8-hold-minus-one|hevc-main8|1080p-hevc-main8.mp4|-1",
    "1080p-hold-minus-five|h264-bframes|1080p-h264-bframes.mp4|-5",
    "1080p-hold-minus-one|h264-bframes|1080p-h264-bframes.mp4|-1",
    "1080p-hold-plus-five|h264-bframes|1080p-h264-bframes.mp4|5",
    "1080p-hold-plus-one|h264-bframes|1080p-h264-bframes.mp4|1",
    "1080p-vfr-hold-minus-five|vfr|1080p-vfr.mp4|-5",
    "1080p-vfr-hold-minus-one|vfr|1080p-vfr.mp4|-1"
  ) | Sort-Object
  Assert-Alpha6Stage1Test (($plannedTokens -join "`n") -ceq ($expectedPlannedTokens -join "`n")) "preflight-fixture-scenario-plan-exact"
  Assert-Alpha6Stage1Test (@($preflight.identity.closedValidationScripts).Count -eq 4) "closed-script-hashes-recorded"
  Assert-Alpha6Stage1Test (@($preflight.preRunArtifactRehash).Count -eq 4 -and @($preflight.postRunArtifactRehash).Count -eq 4) "pre-post-rehash-recorded"
  $preflightResume = @{} + $preflightArgs
  $preflightResume.Resume = $true
  & $runner @preflightResume | Out-Null
  Assert-Alpha6Stage1Test ($adbWasCalled.Count -eq 0) "preflight-resume-has-zero-adb"
  $preflightSummaryRaw = [System.IO.File]::ReadAllText($preflightSummaryPath, [System.Text.Encoding]::UTF8)
  (Get-Item -LiteralPath $preflightSummaryPath).IsReadOnly = $false
  $mutatedPreflight = $preflightSummaryRaw | ConvertFrom-Json
  $mutatedPreflight.deviceMutationCount = 1L
  [System.IO.File]::WriteAllText($preflightSummaryPath, ($mutatedPreflight | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH" "preflight-resume-rejects-summary-drift"
  [System.IO.File]::WriteAllText($preflightSummaryPath, $preflightSummaryRaw, [System.Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $preflightSummaryPath).IsReadOnly = $true
  (Get-Item -LiteralPath $preflightSummaryPath).IsReadOnly = $false
  $mutatedPlan = $preflightSummaryRaw | ConvertFrom-Json
  $mutatedPlan.plannedPerformanceScenarios[0].fixture = "tampered.mp4"
  [System.IO.File]::WriteAllText($preflightSummaryPath, ($mutatedPlan | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH" "preflight-resume-rejects-scenario-plan-drift"
  [System.IO.File]::WriteAllText($preflightSummaryPath, $preflightSummaryRaw, [System.Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $preflightSummaryPath).IsReadOnly = $true

  $badResume = @{} + $preflightResume
  $badResume.MaxMinutes = 26
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @badResume | Out-Null
  } "ALPHA6_STAGE1_SESSION_CONTRACT_MISMATCH" "resume-max-minutes-mismatch"

  $insideOutput = Join-Path (Get-CcrPinnedRepoRoot) "android\build\alpha6-stage1-forbidden-output"
  $insideArgs = @{} + $preflightArgs
  $insideArgs.OutputDirectory = $insideOutput
  $insideArgs.RunId = "alpha6-stage1-inside"
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @insideArgs | Out-Null
  } "ALPHA6_OUTPUT_INSIDE_WORKTREE" "external-output-required"

  $zeroRuntime = @{} + $preflightArgs
  $zeroRuntime.OutputDirectory = Join-Path $root "zero-runtime-output"
  $zeroRuntime.RunId = "alpha6-stage1-zero-runtime"
  $zeroRuntime.RuntimeSourceSha = "0" * 40
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @zeroRuntime | Out-Null
  } "ALPHA6_RUNTIME_SOURCE_SHA_INVALID" "zero-runtime-placeholder-rejected"

  $failureOutput = Join-Path $root "correctness-failure-output"
  $failureLog = Join-Path $root "correctness-failure-stage-log.txt"
  $failureState = New-Alpha6FakeAdbState
  $failureAdb = New-Alpha6FakeAdbInvoker $failureState
  $failureExecutor = {
    param($Stage, $Context, $StageDirectory)
    [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
    [System.IO.File]::AppendAllText($failureLog, "$Stage`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $StageDirectory "host-only-$Stage.txt"), "synthetic", [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ status = if ($Stage -ceq "Correctness") { "FAIL" } else { "PASS" } }
  }.GetNewClosure()
  $failureArgs = @{} + $preflightArgs
  $failureArgs.Remove("PreflightOnly")
  $failureArgs.OutputDirectory = $failureOutput
  $failureArgs.RunId = "alpha6-stage1-correctness-fail"
  $failureArgs.OriginalScreenTimeoutSetting = "120000"
  $failureArgs.TestOnlyAdbInvoker = $failureAdb
  $failureArgs.TestOnlyStageExecutor = $failureExecutor
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @failureArgs | Out-Null
  } "ALPHA6_STAGE1_CORRECTNESS_FAILED" "correctness-failure-propagates"
  $failureStages = @(Get-Content -Encoding UTF8 -LiteralPath $failureLog)
  Assert-Alpha6Stage1Test (($failureStages -join ",") -ceq "Correctness") "correctness-failure-blocks-performance"
  Assert-Alpha6Stage1Test (-not (Test-Path -LiteralPath (Join-Path $failureOutput "checkpoint-alpha6-stage1-performance-alpha6-stage1-correctness-fail.json"))) "no-performance-checkpoint-after-correctness-fail"
  $failureReports = @(Get-ChildItem -LiteralPath $failureOutput -Filter "failure-alpha6-stage1-*.json" -File)
  Assert-Alpha6Stage1Test ($failureReports.Count -eq 1) "failure-report-written"
  $failureReport = [System.IO.File]::ReadAllText($failureReports[0].FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ([string]$failureReport.phase -ceq "correctness" -and [long]$failureReport.buildCommandCount -eq 0L) "failure-report-phase-and-build-count"
  foreach ($entry in @{
    "global/stay_on_while_plugged_in" = "0"
    "system/screen_brightness_mode" = "1"
    "system/screen_brightness" = "77"
    "system/screen_off_timeout" = "120000"
    "system/accelerometer_rotation" = "1"
    "system/user_rotation" = "2"
  }.GetEnumerator()) {
    Assert-Alpha6Stage1Test ([string]$failureState.Settings[$entry.Key] -ceq [string]$entry.Value) "setting-restored-$($entry.Key)"
  }
  Assert-Alpha6Stage1Test (@($failureState.Commands | Where-Object { $_ -match 'pm list packages' }).Count -ge 2) "test-package-cleanup-queried"
  Assert-Alpha6Stage1Test (@($failureState.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 1) "app-force-stopped"
  $settingsRecordPath = Join-Path $failureOutput "checkpoint-alpha6-stage1-device-settings-alpha6-stage1-correctness-fail.json"
  $settingsRecord = [System.IO.File]::ReadAllText($settingsRecordPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ($settingsRecord.staleScreenTimeoutDetected -eq $true -and
    $settingsRecord.restoredBeforeValidation -eq $true -and
    [string]$settingsRecord.effectiveRestoreBaseline.screenTimeout -ceq "120000") "stale-device-setting-restored-and-recorded"

  foreach ($entry in @{
    "global/stay_on_while_plugged_in" = "7"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "128"
    "system/screen_off_timeout" = "1800000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }.GetEnumerator()) { $failureState.Settings[$entry.Key] = $entry.Value }
  $partialResumeLog = Join-Path $root "partial-resume-stage-log.txt"
  $partialResumeExecutor = {
    param($Stage, $Context, $StageDirectory)
    [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
    [System.IO.File]::AppendAllText($partialResumeLog, "$Stage`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $StageDirectory "host-only-$Stage.txt"), "resumed-$Stage", [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ status = "PASS"; buildCommandCount = 0L }
  }.GetNewClosure()
  $partialResumeArgs = @{} + $failureArgs
  $partialResumeArgs.Resume = $true
  $partialResumeArgs.TestOnlyStageExecutor = $partialResumeExecutor
  & $runner @partialResumeArgs | Out-Null
  Assert-Alpha6Stage1Test (
    (@(Get-Content -Encoding UTF8 -LiteralPath $partialResumeLog) -join ",") -ceq "Correctness,Performance"
  ) "partial-resume-retries-unfinished-stages"
  $settingsAttempts = @(Get-ChildItem -LiteralPath $failureOutput -Filter "checkpoint-alpha6-stage1-device-settings-*.json" -File)
  Assert-Alpha6Stage1Test ($settingsAttempts.Count -eq 2) "partial-resume-keeps-unique-settings-evidence"
  $resumeSettingsRecord = @($settingsAttempts | Where-Object { $_.Name -cne "checkpoint-alpha6-stage1-device-settings-alpha6-stage1-correctness-fail.json" })[0]
  $resumeSettings = [System.IO.File]::ReadAllText($resumeSettingsRecord.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ($resumeSettings.interruptedAttemptStateDetected -eq $true -and
    $resumeSettings.restoredInterruptedAttemptBeforeValidation -eq $true -and
    [string]$failureState.Settings["system/screen_off_timeout"] -ceq "120000") "partial-resume-restores-pinned-user-settings"

  $successOutput = Join-Path $root "success-output"
  $successLog = Join-Path $root "success-stage-log.txt"
  $successState = New-Alpha6FakeAdbState
  $successAdb = New-Alpha6FakeAdbInvoker $successState
  $successExecutor = {
    param($Stage, $Context, $StageDirectory)
    [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
    [System.IO.File]::AppendAllText($successLog, "$Stage`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $StageDirectory "host-only-$Stage.txt"), "synthetic-$Stage", [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ status = "PASS"; buildCommandCount = 0L }
  }.GetNewClosure()
  $successArgs = @{} + $failureArgs
  $successArgs.OutputDirectory = $successOutput
  $successArgs.RunId = "alpha6-stage1-success"
  $successArgs.TestOnlyAdbInvoker = $successAdb
  $successArgs.TestOnlyStageExecutor = $successExecutor
  & $runner @successArgs | Out-Null
  $successStages = @(Get-Content -Encoding UTF8 -LiteralPath $successLog)
  Assert-Alpha6Stage1Test (($successStages -join ",") -ceq "Correctness,Performance") "stage-order"
  $successSummaryPath = Join-Path $successOutput "alpha6-stage1-summary-alpha6-stage1-success.json"
  $successSummary = [System.IO.File]::ReadAllText($successSummaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ([string]$successSummary.status -ceq "PENDING_USER" -and
      [string]$successSummary.technicalGateStatus -ceq "PASS" -and $successSummary.releaseEligible -eq $false) "success-status"
  Assert-Alpha6Stage1Test ($successSummary.auxiliaryDecoderUsed -eq $false -and [string]$successSummary.userReverseSmoothness -ceq "PENDING_USER") "stage1-single-decoder-user-pending"
  Assert-Alpha6Stage1Test ([long]$successSummary.buildCommandCount -eq 0L) "success-build-count-zero"
  $successResume = @{} + $successArgs
  $successResume.Resume = $true
  & $runner @successResume | Out-Null
  Assert-Alpha6Stage1Test (@(Get-Content -Encoding UTF8 -LiteralPath $successLog).Count -eq 2) "resume-skips-completed-stages"

  $successSummaryRaw = [System.IO.File]::ReadAllText($successSummaryPath, [System.Text.Encoding]::UTF8)
  $successSummaryItem = Get-Item -LiteralPath $successSummaryPath
  $successSummaryItem.IsReadOnly = $false
  $mutatedSummary = $successSummaryRaw | ConvertFrom-Json
  $mutatedSummary.releaseEligible = $true
  [System.IO.File]::WriteAllText($successSummaryPath, ($mutatedSummary | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @successResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_SUMMARY_CONTRACT_MISMATCH" "resume-rejects-summary-fixed-field-drift"
  [System.IO.File]::WriteAllText($successSummaryPath, $successSummaryRaw, [System.Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $successSummaryPath).IsReadOnly = $true

  $differentDeviceState = New-Alpha6FakeAdbState "samsung/test/device:37/DIFFERENT/1:user/release-keys"
  $differentDeviceResume = @{} + $successResume
  $differentDeviceResume.TestOnlyAdbInvoker = New-Alpha6FakeAdbInvoker $differentDeviceState
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @differentDeviceResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH" "resume-device-identity-preserved"

  $performanceEvidencePath = Join-Path $successOutput "attempt-alpha6-stage1-success-stage-performance\host-only-Performance.txt"
  (Get-Item -LiteralPath $performanceEvidencePath).IsReadOnly = $false
  [System.IO.File]::AppendAllText($performanceEvidencePath, "-tampered", [System.Text.UTF8Encoding]::new($false))
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @successResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_EVIDENCE_HASH_MISMATCH" "resume-rehashes-completed-evidence"

  foreach ($artifact in $artifacts) {
    Assert-Alpha6Stage1Test (
      (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact.path).Hash.ToLowerInvariant() -ceq [string]$artifact.sha256
    ) "artifact-unchanged-$($artifact.role)"
  }
} finally {
  $env:CCR_ALPHA6_STAGE1_TEST_MODE = $previousTestMode
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "Alpha 6 Stage 1 host-only tests passed: $passed"
