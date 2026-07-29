$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = Join-Path $PSScriptRoot "run-s24-alpha6-stage1.ps1"
$candidateBridge = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
$candidateArtifacts = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
$candidateSigningCommon = Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"
$alpha6HistoricalPinned = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$basePinned = Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"
$tailContract = Join-Path $PSScriptRoot "alpha6-tail-contract.ps1"
$benchmarkActivity = Join-Path $PSScriptRoot "..\app\src\benchmark\java\com\snowberried\ctcinereviewer\benchmark\BenchmarkActivity.kt"
$macrobenchmark = Join-Path $PSScriptRoot "..\macrobenchmark\src\main\java\com\snowberried\ctcinereviewer\macrobenchmark\CcrProductMacrobenchmark.kt"
. $candidateBridge

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
    Wakefulness = "Awake"
    DisplayState = "ON"
    SurfaceOrientation = 0L
    InputStateOutput = $null
    Configuration = "mcc310-mnc260-en-rUS-sw411dp-w891dp-h411dp-normal-long-port"
    ProcessIds = @{}
    SettleSampleReadCount = 0L
    SettleSampleMutator = $null
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
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "dumpsys" -and $Arguments[4] -ceq "power") {
      $State.SettleSampleReadCount += 1L
      if ($null -ne $State.SettleSampleMutator) {
        & $State.SettleSampleMutator $State ([long]$State.SettleSampleReadCount)
      }
      return [PSCustomObject]@{
        exitCode = 0
        output = "mWakefulness=$([string]$State.Wakefulness)"
      }
    }
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "dumpsys" -and $Arguments[4] -ceq "display") {
      return [PSCustomObject]@{
        exitCode = 0
        output = "mDisplayState=$([string]$State.DisplayState)"
      }
    }
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "dumpsys" -and $Arguments[4] -ceq "input") {
      $inputStateOutput = if ($null -eq $State.InputStateOutput) {
        "SurfaceOrientation: $([long]$State.SurfaceOrientation)"
      } else {
        [string]$State.InputStateOutput
      }
      return [PSCustomObject]@{
        exitCode = 0
        output = $inputStateOutput
      }
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "cmd" -and $Arguments[4] -ceq "activity" -and
        $Arguments[5] -ceq "get-config") {
      return [PSCustomObject]@{ exitCode = 0; output = [string]$State.Configuration }
    }
    if ($Arguments.Count -ge 5 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "pidof") {
      $packageName = [string]$Arguments[4]
      $processIdText = if ($State.ProcessIds.ContainsKey($packageName)) {
        [string]$State.ProcessIds[$packageName]
      } else {
        ""
      }
      return [PSCustomObject]@{
        exitCode = if ([string]::IsNullOrWhiteSpace($processIdText)) { 1 } else { 0 }
        output = $processIdText
      }
    }
    if ($Arguments.Count -ge 6 -and $Arguments[2] -ceq "shell" -and
        $Arguments[3] -ceq "am" -and $Arguments[4] -ceq "force-stop") {
      $State.ProcessIds[[string]$Arguments[5]] = ""
      return [PSCustomObject]@{ exitCode = 0; output = "" }
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
  $runtimeSource = "c98264f2a10026a908e94c961bb13e4af2d59e60"
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $certificate = Get-CcrCandidatePublicPolicyFingerprint
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
  [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
  $manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  $debugSha = [string]$artifacts[0].sha256
  $tools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $identitySmokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    return [PSCustomObject]@{
      status = "PASS"
      runId = $IdentityRunId
      artifactSetRevision = 5
      debugArtifactInstallSetCount = 1L
      debugArtifactInstallCommandCount = 2L
      buildCommandCount = 0L
    }
  }
  $fixtureOpenSmokeExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory)
    [System.IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
    $reportPath = Join-Path $EvidenceDirectory "fixture.json"
    [System.IO.File]::WriteAllText(
      $reportPath,
      '{"kind":"host-only-fixture-open-smoke","status":"PASS"}',
      [System.Text.UTF8Encoding]::new($false)
    )
    $reportItem = Get-Item -LiteralPath $reportPath
    return [PSCustomObject]@{
      status = "PASS"
      runId = $FixtureRunId
      fixtureCount = 17L
      reportPath = $reportItem.FullName
      reportBytes = [long]$reportItem.Length
      reportSha256 =
        (Get-FileHash -Algorithm SHA256 -LiteralPath $reportItem.FullName).Hash.ToLowerInvariant()
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
      buildCommandCount = 0L
    }
  }
  $settingsSettleExecutor = {
    param($Context, $AttemptRunId)
    $targetSettings = [PSCustomObject][ordered]@{
      stayAwake = "7"
      brightnessMode = "0"
      brightness = "128"
      screenTimeout = "1800000"
      accelerometerRotation = "0"
      userRotation = "0"
    }
    $samples = @(0..2 | ForEach-Object {
      [PSCustomObject][ordered]@{
        sampledAtUtc = [DateTime]::UtcNow.ToString("o")
        settings = $targetSettings
        wakefulnessAwake = $true
        displayOn = $true
        surfaceOrientation = 0L
        configurationSignatureSha256 = "4" * 64
        priorValidationProcessCount = 0L
        ready = $true
        stabilityKeySha256 = "5" * 64
      }
    })
    return [PSCustomObject][ordered]@{
      kind = "alpha6-stage1-device-settings-settle"
      status = "PASS"
      targetSettings = $targetSettings
      pollIntervalMs = 250L
      requiredConsecutiveSamples = 3L
      stableIntervalMs = 500L
      timeoutMs = 10000L
      observedConsecutiveSamples = 3L
      preparationFailures = @()
      lastReadFailure = $null
      samples = $samples
      buildCommandCount = 0L
    }
  }
  $renderOpenSmokeExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    [System.IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
    $reportPath = Join-Path $EvidenceDirectory "render-open-smoke.json"
    [System.IO.File]::WriteAllText(
      $reportPath,
      '{"kind":"host-only-render-open-smoke","status":"PASS"}',
      [System.Text.UTF8Encoding]::new($false)
    )
    $reportItem = Get-Item -LiteralPath $reportPath
    return [PSCustomObject][ordered]@{
      status = "PASS"
      runId = $RenderRunId
      reportPath = $reportItem.FullName
      reportBytes = [long]$reportItem.Length
      reportSha256 =
        (Get-FileHash -Algorithm SHA256 -LiteralPath $reportItem.FullName).Hash.ToLowerInvariant()
      stableIntervalMs = 300L
      activityInstanceDriftCount = 0L
      surfaceGenerationDriftCount = 0L
      surfaceLossCount = 0L
      videoOpenFailedCount = 0L
      buildCommandCount = 0L
    }
  }

  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$parseErrors) | Out-Null
  Assert-Alpha6Stage1Test (@($parseErrors).Count -eq 0) "runner-parser"
  $closed = @(
    $runner,
    $candidateBridge,
    $candidateArtifacts,
    $candidateSigningCommon,
    $alpha6HistoricalPinned,
    $basePinned,
    $tailContract
  ) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
  $buildFree = @(Assert-CcrAlpha6ValidationScriptsBuildFree $closed)
  Assert-Alpha6Stage1Test ($buildFree.Count -eq 7) "closed-script-list-build-free"
  $source = [System.IO.File]::ReadAllText($runner, [System.Text.Encoding]::UTF8)
  $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$null)
  $resolverAst = @($runnerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq "Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract"
  }, $true))
  Assert-Alpha6Stage1Test ($resolverAst.Count -eq 1) "correctness-evidence-resolver-defined-once"
  Invoke-Expression $resolverAst[0].Extent.Text
  $settingsAssertionAst = @($runnerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq "Assert-CcrAlpha6Stage1SettingsRestored"
  }, $true))
  Assert-Alpha6Stage1Test ($settingsAssertionAst.Count -eq 1) "settings-restore-assertion-defined-once"
  Invoke-Expression $settingsAssertionAst[0].Extent.Text
  foreach ($functionName in @(
    "Get-CcrAlpha6Stage1Sha256Text",
    "Get-CcrAlpha6Stage1TargetSettings",
    "Get-CcrAlpha6Stage1DeviceSettleSample",
    "Wait-CcrAlpha6Stage1DeviceSettingsSettled",
    "Get-CcrAlpha6Stage1CleanupVerification"
  )) {
    $functionAst = @($runnerAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
    }.GetNewClosure(), $true))
    Assert-Alpha6Stage1Test ($functionAst.Count -eq 1) "actual-settle-function-defined-once-$functionName"
    Invoke-Expression $functionAst[0].Extent.Text
  }
  $actualSettleState = New-Alpha6FakeAdbState
  foreach ($entry in @{
    "global/stay_on_while_plugged_in" = "7"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "128"
    "system/screen_off_timeout" = "1800000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }.GetEnumerator()) {
    $actualSettleState.Settings[$entry.Key] = [string]$entry.Value
  }
  $actualSettleState.InputStateOutput =
    "Viewport INTERNAL: displayId=0, uniqueId=local:primary, orientation=0, densityDpi=600, isActive=[1]`r`n" +
    "Viewport INTERNAL: displayId=0, uniqueId=local:primary, orientation=0, densityDpi=600, isActive=[1]`r`n" +
    "Viewport INTERNAL: displayId=0, uniqueId=local:inactive, orientation=2, densityDpi=600, isActive=[0]`r`n"
  $actualSettleState.SettleSampleMutator = {
    param($State, $SampleIndex)
    if ($SampleIndex -eq 1L) {
      $State.Configuration = "stable-config-a"
      $State.ProcessIds[$script:CcrPinnedAppPackage] = ""
      $State.ProcessIds[$script:CcrPinnedMacrobenchmarkPackage] = ""
    } elseif ($SampleIndex -eq 2L) {
      $State.Configuration = "stable-config-b"
      $State.ProcessIds[$script:CcrPinnedAppPackage] = ""
      $State.ProcessIds[$script:CcrPinnedMacrobenchmarkPackage] = ""
    } elseif ($SampleIndex -eq 3L) {
      $State.Configuration = "stable-config-b"
      $State.ProcessIds[$script:CcrPinnedAppPackage] = ""
      $State.ProcessIds[$script:CcrPinnedMacrobenchmarkPackage] = "9301"
    } else {
      $State.Configuration = "stable-config-b"
      $State.ProcessIds[$script:CcrPinnedAppPackage] = ""
      $State.ProcessIds[$script:CcrPinnedMacrobenchmarkPackage] = ""
    }
  }.GetNewClosure()
  $actualSettleContext = [PSCustomObject]@{
    Adb = "fake-adb"
    AdbInvoker = New-Alpha6FakeAdbInvoker $actualSettleState
    Serial = "FAKE-S24"
  }
  $deadlineUtc = [DateTime]::UtcNow.AddSeconds(5)
  $adbDeadlineState = [PSCustomObject]@{
    ValidationDeadlineUtc = $deadlineUtc
    CleanupMode = $false
    CleanupDeadlineUtc = $deadlineUtc
  }
  $actualSettleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $actualSettle = Wait-CcrAlpha6Stage1DeviceSettingsSettled $actualSettleContext
  $actualSettleStopwatch.Stop()
  Assert-Alpha6Stage1Test (
    [string]$actualSettle.status -ceq "PASS" -and
      [long]$actualSettle.observedConsecutiveSamples -eq 3L -and
      @($actualSettle.samples).Count -eq 6 -and
      [string]$actualSettle.lastReadFailure -ceq ""
  ) "actual-settings-settle-positive"
  Assert-Alpha6Stage1Test (
    $actualSettle.samples[0].ready -eq $true -and
      $actualSettle.samples[1].ready -eq $true -and
      [string]$actualSettle.samples[0].configurationSignatureSha256 -cne
        [string]$actualSettle.samples[1].configurationSignatureSha256 -and
      $actualSettle.samples[2].ready -eq $false -and
      [long]$actualSettle.samples[2].priorValidationProcessCount -eq 1L -and
      [long]$actualSettle.samples[2].priorValidationProcessCounts.PSObject.Properties[
        $script:CcrPinnedMacrobenchmarkPackage
      ].Value -eq 1L -and
      (@($actualSettle.samples[3..5] | ForEach-Object {
        [string]$_.stabilityKeySha256
      } | Select-Object -Unique)).Count -eq 1
  ) "actual-settings-settle-resets-on-config-and-process-drift"
  Assert-Alpha6Stage1Test (
    $actualSettleStopwatch.ElapsedMilliseconds -ge 1000L -and
      $actualSettleStopwatch.ElapsedMilliseconds -lt 3500L -and
      [long]$actualSettle.pollIntervalMs -eq 250L -and
      [long]$actualSettle.stableIntervalMs -eq 500L -and
      [long]$actualSettle.timeoutMs -eq 10000L
  ) "actual-settings-settle-stable-window-and-bounds"
  Assert-Alpha6Stage1Test (
    @($actualSettleState.Commands | Where-Object { $_ -match 'dumpsys power$' }).Count -eq 6 -and
      @($actualSettleState.Commands | Where-Object { $_ -match 'cmd activity get-config$' }).Count -eq 6 -and
      @($actualSettleState.Commands | Where-Object { $_ -match 'shell pidof ' }).Count -eq 18 -and
      @($actualSettleState.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 3
  ) "actual-settings-settle-reads-device-config-and-processes"
  $targetSettings = Get-CcrAlpha6Stage1TargetSettings
  $actualSettleState.InputStateOutput = "SurfaceOrientation: 0`r`n"
  $legacyOrientationSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$legacyOrientationSample.surfaceOrientation -eq 0L -and
      $legacyOrientationSample.ready -eq $true
  ) "settings-settle-keeps-legacy-surface-orientation"
  $actualSettleState.InputStateOutput =
    "Viewport INTERNAL: isActive=[1], orientation=0, uniqueId=local:primary, displayId=0"
  $reorderedViewportSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$reorderedViewportSample.surfaceOrientation -eq 0L -and
      $reorderedViewportSample.ready -eq $true
  ) "settings-settle-accepts-reordered-active-primary-viewport"
  $actualSettleState.InputStateOutput =
    "Viewport INTERNAL: displayId=0, orientation=1, isActive=[1]"
  $landscapeViewportSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$landscapeViewportSample.surfaceOrientation -eq 1L -and
      $landscapeViewportSample.ready -eq $false
  ) "settings-settle-rejects-active-landscape-viewport"
  $actualSettleState.InputStateOutput = @"
      Viewport INTERNAL: displayId=0, orientation=0, isActive=[0]
      Viewport EXTERNAL: displayId=0, orientation=0, isActive=[1]
      Viewport INTERNAL: displayId=1, orientation=0, isActive=[1]
"@
  $nonPrimaryViewportSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$nonPrimaryViewportSample.surfaceOrientation -eq -1L -and
      $nonPrimaryViewportSample.ready -eq $false
  ) "settings-settle-ignores-inactive-external-and-secondary-viewports"
  $actualSettleState.InputStateOutput = @"
      Viewport INTERNAL: displayId=0, orientation=0, isActive=[1]
      Viewport INTERNAL: displayId=0, orientation=1, isActive=[1]
"@
  $conflictingViewportSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$conflictingViewportSample.surfaceOrientation -eq -1L -and
      $conflictingViewportSample.ready -eq $false
  ) "settings-settle-rejects-conflicting-active-primary-viewports"
  $actualSettleState.InputStateOutput = @"
      Viewport INTERNAL: displayId=0, orientation=0, isActive=[1]
      Viewport INTERNAL: displayId=0, isActive=[1]
"@
  $malformedViewportSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$malformedViewportSample.surfaceOrientation -eq -1L -and
      $malformedViewportSample.ready -eq $false
  ) "settings-settle-rejects-partially-malformed-active-primary-viewports"
  $actualSettleState.InputStateOutput =
    "SurfaceOrientation: 9`r`n" +
    "Viewport INTERNAL: displayId=0, orientation=0, isActive=[1]`r`n"
  $malformedLegacySample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$malformedLegacySample.surfaceOrientation -eq -1L -and
      $malformedLegacySample.ready -eq $false
  ) "settings-settle-rejects-malformed-legacy-before-viewport-fallback"
  $actualSettleState.InputStateOutput = @"
      SurfaceOrientation: 0
      Viewport INTERNAL: displayId=0, orientation=0, isActive=[1]
"@
  $matchingHybridSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$matchingHybridSample.surfaceOrientation -eq 0L -and
      $matchingHybridSample.ready -eq $true
  ) "settings-settle-accepts-matching-legacy-and-viewport"
  $actualSettleState.InputStateOutput = @"
      SurfaceOrientation: 0
      Viewport INTERNAL: displayId=0, orientation=1, isActive=[1]
"@
  $conflictingHybridSample = Get-CcrAlpha6Stage1DeviceSettleSample `
    $actualSettleContext $targetSettings
  Assert-Alpha6Stage1Test (
    [long]$conflictingHybridSample.surfaceOrientation -eq -1L -and
      $conflictingHybridSample.ready -eq $false
  ) "settings-settle-rejects-conflicting-legacy-and-viewport"

  $boundedSettleState = New-Alpha6FakeAdbState
  foreach ($entry in @{
    "global/stay_on_while_plugged_in" = "7"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "128"
    "system/screen_off_timeout" = "1800000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }.GetEnumerator()) {
    $boundedSettleState.Settings[$entry.Key] = [string]$entry.Value
  }
  $boundedSettleState.DisplayState = "OFF"
  $boundedSettleContext = [PSCustomObject]@{
    Adb = "fake-adb"
    AdbInvoker = New-Alpha6FakeAdbInvoker $boundedSettleState
    Serial = "FAKE-S24"
  }
  $deadlineUtc = [DateTime]::UtcNow.AddMilliseconds(900)
  $adbDeadlineState = [PSCustomObject]@{
    ValidationDeadlineUtc = $deadlineUtc
    CleanupMode = $false
    CleanupDeadlineUtc = $deadlineUtc
  }
  $boundedSettleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $boundedSettle = Wait-CcrAlpha6Stage1DeviceSettingsSettled $boundedSettleContext
  $boundedSettleStopwatch.Stop()
  Assert-Alpha6Stage1Test (
    [string]$boundedSettle.status -ceq "FAIL" -and
      [long]$boundedSettle.observedConsecutiveSamples -eq 0L -and
      @($boundedSettle.samples).Count -ge 1 -and
      @($boundedSettle.samples | Where-Object { $_.ready -eq $true }).Count -eq 0 -and
      @($boundedSettle.samples | Where-Object { $_.displayOn -eq $true }).Count -eq 0
  ) "actual-settings-settle-rejects-display-off"
  Assert-Alpha6Stage1Test (
    $boundedSettleStopwatch.ElapsedMilliseconds -lt 2500L
  ) "actual-settings-settle-timeout-bounded"
  $autoBrightnessState = New-Alpha6FakeAdbState
  $autoBrightnessState.Settings["system/screen_off_timeout"] = "120000"
  $autoBrightnessState.Settings["system/screen_brightness"] = "99"
  $autoBrightnessContext = [PSCustomObject]@{
    Adb = "fake-adb"
    AdbInvoker = New-Alpha6FakeAdbInvoker $autoBrightnessState
    Serial = "FAKE-S24"
    SavedSettings = [PSCustomObject]@{
      stayAwake = "0"
      brightnessMode = "1"
      brightness = "77"
      screenTimeout = "120000"
      accelerometerRotation = "1"
      userRotation = "2"
    }
  }
  $autoBrightnessCleanup =
    Get-CcrAlpha6Stage1CleanupVerification $autoBrightnessContext
  Assert-Alpha6Stage1Test (
    [string]$autoBrightnessCleanup.status -ceq "PASS" -and
      $autoBrightnessCleanup.settingsRestored -eq $true -and
      $autoBrightnessCleanup.rawBrightnessExactRequired -eq $false
  ) "cleanup-verification-allows-auto-brightness-recalculation"
  $manualBrightnessState = New-Alpha6FakeAdbState
  $manualBrightnessState.Settings["system/screen_brightness_mode"] = "0"
  $manualBrightnessState.Settings["system/screen_off_timeout"] = "120000"
  $manualBrightnessState.Settings["system/screen_brightness"] = "99"
  $manualBrightnessContext = [PSCustomObject]@{
    Adb = "fake-adb"
    AdbInvoker = New-Alpha6FakeAdbInvoker $manualBrightnessState
    Serial = "FAKE-S24"
    SavedSettings = [PSCustomObject]@{
      stayAwake = "0"
      brightnessMode = "0"
      brightness = "77"
      screenTimeout = "120000"
      accelerometerRotation = "1"
      userRotation = "2"
    }
  }
  $manualBrightnessCleanup =
    Get-CcrAlpha6Stage1CleanupVerification $manualBrightnessContext
  Assert-Alpha6Stage1Test (
    [string]$manualBrightnessCleanup.status -ceq "FAIL" -and
      $manualBrightnessCleanup.settingsRestored -eq $false -and
      $manualBrightnessCleanup.rawBrightnessExactRequired -eq $true
  ) "cleanup-verification-requires-manual-brightness-exact"
  Assert-Alpha6Stage1Test ($source.Contains("Invoke-CcrAlpha6CandidateDeviceHostPreflight")) "candidate-host-preflight-connected"
  Assert-Alpha6Stage1Test ($source.Contains("Assert-CcrAlpha6CandidateDeviceIdentityUnchanged")) "candidate-identity-rehash-connected"
  Assert-Alpha6Stage1Test (-not $source.Contains("artifactSetRevision = 4")) "active-revision4-hardcode-removed"
  Assert-Alpha6Stage1Test ($source.Contains("Invoke-CcrPinnedCleanup")) "package-cleanup-finally"
  Assert-Alpha6Stage1Test ($source.Contains("Recover-CcrAlpha6Stage1Traces")) "trace-recovery-hook"
  Assert-Alpha6Stage1Test ($source -notmatch '(?m)^\s*\$\w*(?:Sha|Sha256)\w*\s*=\s*"[0-9a-f]{40,64}"') "no-final-hash-placeholder"
  Assert-Alpha6Stage1Test (
    $source.Contains("Wait-CcrAlpha6Stage1DeviceSettingsSettled") -and
      $source.Contains("Invoke-CcrAlpha6Stage1RenderOpenSmoke") -and
      $source.Contains("ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED") -and
      $source.Contains("ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED") -and
      $source.Contains("Invoke-CcrAlpha6CandidateRenderOpenInstrumentation") -and
      $source.Contains("-SkipInstall")
  ) "settings-settle-render-open-smoke-wired"
  Assert-Alpha6Stage1Test (
    $source.Contains("Viewport\s+INTERNAL") -and
      $source.Contains("displayId=0") -and
      $source.Contains("isActive=\[1\]")
  ) "settings-settle-android16-active-primary-viewport-fallback-wired"
  $correctnessAst = @($runnerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq "Invoke-CcrAlpha6Stage1Correctness"
  }, $true))
  Assert-Alpha6Stage1Test ($correctnessAst.Count -eq 1) "correctness-defined-once"
  $correctnessSource = $correctnessAst[0].Extent.Text
  Assert-Alpha6Stage1Test (
    -not $correctnessSource.Contains("Install-CcrPinnedArtifactSet") -and
      $correctnessSource.Contains(
        'Assert-CcrPinnedInstalledArtifact $Context "debugApp"'
      ) -and
      $correctnessSource.Contains(
        'Assert-CcrPinnedInstalledArtifact $Context "debugTest"'
      )
  ) "correctness-reverifies-debug-set-without-reinstall"
  Invoke-Expression $correctnessAst[0].Extent.Text
  $originalInstalledArtifactAssertion =
    (Get-Command Assert-CcrPinnedInstalledArtifact -CommandType Function).ScriptBlock
  $originalInstrumentationInvocation =
    (Get-Command Invoke-CcrPinnedInstrumentation -CommandType Function).ScriptBlock
  $installedArtifactRoles = [System.Collections.Generic.List[string]]::new()
  $instrumentationInvocationCount = 0L
  try {
    Set-Item -LiteralPath Function:\Assert-CcrPinnedInstalledArtifact -Value {
      param($Context, $Role)
      $installedArtifactRoles.Add([string]$Role) | Out-Null
      if ([string]$Role -ceq "debugTest") {
        throw "PINNED_INSTALLED_ARTIFACT_SHA_MISMATCH:debugTest"
      }
      return $true
    }.GetNewClosure()
    Set-Item -LiteralPath Function:\Invoke-CcrPinnedInstrumentation -Value {
      $instrumentationInvocationCount += 1L
      throw "UNEXPECTED_CORRECTNESS_INSTRUMENTATION_ENTRY"
    }.GetNewClosure()
    $TestOnlyStageExecutor = $null
    $installedDriftStageDirectory = Join-Path $root "installed-sha-drift-correctness"
    Assert-Alpha6Stage1ThrowsLike {
      Invoke-CcrAlpha6Stage1Correctness `
        ([PSCustomObject]@{}) $installedDriftStageDirectory | Out-Null
    } "PINNED_INSTALLED_ARTIFACT_SHA_MISMATCH:debugTest" `
      "installed-sha-drift-blocks-correctness-instrumentation"
    Assert-Alpha6Stage1Test (
      ($installedArtifactRoles -join ",") -ceq "debugApp,debugTest" -and
        $instrumentationInvocationCount -eq 0L
    ) "installed-sha-drift-correctness-instrumentation-count-zero"
  } finally {
    Set-Item -LiteralPath Function:\Assert-CcrPinnedInstalledArtifact `
      -Value $originalInstalledArtifactAssertion
    Set-Item -LiteralPath Function:\Invoke-CcrPinnedInstrumentation `
      -Value $originalInstrumentationInvocation
  }
  $candidateBridgeSource = [System.IO.File]::ReadAllText(
    $candidateBridge,
    [System.Text.Encoding]::UTF8
  )
  $candidateBridgeAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $candidateBridge,
    [ref]$null,
    [ref]$null
  )
  $identityInstrumentationAst = @($candidateBridgeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq "Invoke-CcrAlpha6CandidateIdentitySmokeInstrumentation"
  }, $true))
  Assert-Alpha6Stage1Test (
    $identityInstrumentationAst.Count -eq 1
  ) "candidate-identity-smoke-defined-once"
  $identityInstrumentationSource = $identityInstrumentationAst[0].Extent.Text
  Assert-Alpha6Stage1Test (
    ([regex]::Matches(
      $identityInstrumentationSource,
      'Install-CcrPinnedArtifactSet\s+\$Context\s+"Debug"'
    )).Count -eq 1 -and
      $identityInstrumentationSource.Contains("debugArtifactInstallSetCount = 1L") -and
      $identityInstrumentationSource.Contains("debugArtifactInstallCommandCount = 2L")
  ) "identity-smoke-installs-debug-set-exactly-once"
  Assert-Alpha6Stage1Test ($source -match 'scenarioCount\s*=\s*10' -and $source -match 'independentTraceCount\s*=\s*30') "ten-scenarios-thirty-traces"
  Assert-Alpha6Stage1Test ($source.Contains("ALPHA6_STAGE1_BENCHMARK_FIXTURE_IDENTITY_MISMATCH")) "fixture-identity-fail-closed"
  Assert-Alpha6Stage1Test (
    $source.IndexOf("Invoke-CcrAlpha6CandidateIdentitySmokeInstrumentation") -lt
      $source.IndexOf("Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation") -and
      $source.IndexOf("Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation") -lt
        $source.IndexOf("Initialize-CcrAlpha6PinnedDeviceSettings")
  ) "identity-fixture-settings-order"
  $resolverContracts = @(
    [PSCustomObject]@{ stage = "Full"; reportName = "s24-frame-accuracy-report.json"; kind = "frame-accuracy-exact" },
    [PSCustomObject]@{ stage = "Representative"; reportName = "representative-resolution-exact-report.json"; kind = "representative-resolution-exact-subset" },
    [PSCustomObject]@{ stage = "Forward"; reportName = "s24-forward-sequential-report.json"; kind = "forward-sequential-exact" },
    [PSCustomObject]@{ stage = "Reverse"; reportName = "s24-reverse-window-report.json"; kind = "reverse-window-exact" },
    [PSCustomObject]@{ stage = "ReleaseCancel"; reportName = "s24-release-cancel-grace-report.json"; kind = "release-cancel-grace" },
    [PSCustomObject]@{ stage = "Direction"; reportName = "s24-alpha5-direction-reversal-report.json"; kind = "bidirectional-transition-exact" },
    [PSCustomObject]@{ stage = "ReverseLifecycle"; reportName = "s24-alpha5-reverse-lifecycle-report.json"; kind = "alpha5-reverse-lifecycle-exact" }
  )
  foreach ($contract in $resolverContracts) {
    $suffix = ([string]$contract.stage).ToLowerInvariant()
    $resolvedContract = Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract `
      "trusted-run-c-$suffix-$([string]$contract.reportName)" $resolverContracts "trusted-run"
    Assert-Alpha6Stage1Test (
      [string]$resolvedContract.expectedChildRunId -ceq "trusted-run-c-$suffix" -and
        [string]$resolvedContract.contract.stage -ceq [string]$contract.stage
    ) "correctness-evidence-binds-trusted-parent-run-id-$suffix"
    Assert-Alpha6Stage1ThrowsLike {
      Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract `
        "stale-run-c-$suffix-$([string]$contract.reportName)" $resolverContracts "trusted-run" | Out-Null
    } "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_IDENTITY_MISMATCH:*" "correctness-evidence-rejects-stale-self-consistent-run-id-$suffix"
  }
  Assert-Alpha6Stage1ThrowsLike {
    Resolve-CcrAlpha6Stage1CorrectnessEvidenceContract `
      "trusted-run-c-reverselifecycle-s24-frame-accuracy-report.json" $resolverContracts "trusted-run" | Out-Null
  } "ALPHA6_STAGE1_CORRECTNESS_RESULT_EVIDENCE_IDENTITY_MISMATCH:*" "correctness-evidence-rejects-wrong-stage-prefix"
  $correctnessCheckpointValidation = 'Assert-CcrAlpha6Stage1Checkpoint $correctnessCheckpoint "Correctness" $context | Out-Null'
  $correctnessCheckpointWrite = 'Write-CcrAlpha6Stage1ImmutableJson $correctnessCheckpointPath $correctnessCheckpoint | Out-Null'
  $correctnessWriteIndex = $source.IndexOf($correctnessCheckpointWrite, [System.StringComparison]::Ordinal)
  $correctnessValidationIndex = $source.LastIndexOf(
    $correctnessCheckpointValidation,
    $correctnessWriteIndex,
    [System.StringComparison]::Ordinal
  )
  $performanceCheckpointValidation = 'Assert-CcrAlpha6Stage1Checkpoint $performanceCheckpoint "Performance" $context | Out-Null'
  $performanceCheckpointWrite = 'Write-CcrAlpha6Stage1ImmutableJson $performanceCheckpointPath $performanceCheckpoint | Out-Null'
  $performanceWriteIndex = $source.IndexOf($performanceCheckpointWrite, [System.StringComparison]::Ordinal)
  $performanceValidationIndex = $source.LastIndexOf(
    $performanceCheckpointValidation,
    $performanceWriteIndex,
    [System.StringComparison]::Ordinal
  )
  Assert-Alpha6Stage1Test (
    $correctnessValidationIndex -ge 0 -and $correctnessValidationIndex -lt $correctnessWriteIndex -and
      $performanceValidationIndex -ge 0 -and $performanceValidationIndex -lt $performanceWriteIndex
  ) "stage-checkpoints-validated-before-write"
  Assert-Alpha6Stage1Test (
    ([regex]::Matches(
      $source,
      '\$requireRequestStageMetrics = \[string\]\$scenario\.direction -ceq "reverse"'
    )).Count -eq 1 -and
      ([regex]::Matches(
        $source,
        '\$requireRequestStageMetrics = \[string\]\$contract\.direction -ceq "reverse"'
      )).Count -eq 1 -and
      ([regex]::Matches($source, '-RequireRequestStageMetrics:\$requireRequestStageMetrics')).Count -eq 2
  ) "request-stage-metrics-bind-execution-and-canonical-result-directions"
  Assert-Alpha6Stage1Test (
    $source.Contains('$strideValue -isnot [int] -and $strideValue -isnot [long]') -and
      $source.Contains('[long]$strideValue -ne [long]$contract.stride')
  ) "performance-result-stride-requires-exact-json-integer"
  Assert-Alpha6Stage1Test (
    $source.Contains('$seenTracePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)') -and
      $source.Contains('$seenTraceHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)') -and
      $source.Contains('$traceOrdinals = [System.Collections.Generic.HashSet[int]]::new()') -and
      $source.Contains('iter00(?<ordinal>[0-2])_.+\.perfetto-trace$') -and
      $source.Contains('ALPHA6_STAGE1_PERFORMANCE_RESULT_TRACE_IDENTITY_MISMATCH')
  ) "performance-result-traces-bind-method-ordinal-path-and-hash"
  $brightnessDriftState = New-Alpha6FakeAdbState
  $brightnessDriftState.Settings["system/screen_brightness"] = "40"
  $brightnessDriftContext = [PSCustomObject]@{
    Adb = "fake-adb"
    AdbInvoker = New-Alpha6FakeAdbInvoker $brightnessDriftState
    Serial = "FAKE-S24"
    SavedSettings = [PSCustomObject]@{
      stayAwake = "0"
      brightnessMode = "1"
      brightness = "29"
      screenTimeout = "600000"
      accelerometerRotation = "1"
      userRotation = "2"
    }
  }
  Assert-Alpha6Stage1Test (
    (Assert-CcrAlpha6Stage1SettingsRestored $brightnessDriftContext) -eq $true
  ) "automatic-brightness-raw-value-may-drift-after-restore"
  $brightnessDriftState.Settings["system/screen_brightness_mode"] = "0"
  $brightnessDriftContext.SavedSettings.brightnessMode = "0"
  Assert-Alpha6Stage1ThrowsLike {
    Assert-CcrAlpha6Stage1SettingsRestored $brightnessDriftContext | Out-Null
  } "ALPHA6_STAGE1_SETTING_RESTORE_MISMATCH:system/screen_brightness" "manual-brightness-remains-exact"
  Assert-Alpha6Stage1Test ($source.Contains('"measuredWindowBuildAssociatedLongGapCount"') -and
    $source.Contains("ALPHA6_STAGE1_REVERSE_MECHANISM_NOT_EXERCISED")) "window-build-and-mechanism-gates"
  Assert-Alpha6Stage1Test ($source.Contains("directionReversalAndGenerationInvalidationRemainExactOnS24Ultra")) "direction-reversal-correctness-retained"
  $benchmarkSource = [System.IO.File]::ReadAllText($benchmarkActivity, [System.Text.Encoding]::UTF8)
  $macrobenchmarkSource = [System.IO.File]::ReadAllText($macrobenchmark, [System.Text.Encoding]::UTF8)
  Assert-Alpha6Stage1Test `
    ($macrobenchmarkSource.Contains(
      "row.actorStartedNs != null || row.cachedNavigationStartedNs != null"
    )) `
    "macrobenchmark-request-path-at-least-one"
  Assert-Alpha6Stage1Test `
    (-not $macrobenchmarkSource.Contains(
      "CCR publication must have exactly one actor or cached-navigation start"
    )) `
    "macrobenchmark-request-path-xor-removed"
  Assert-Alpha6Stage1Test `
    ($macrobenchmarkSource.Contains(
      "it.cachedNavigationStartedNs != null && it.actorStartedNs == null"
    )) `
    "macrobenchmark-cache-only-excludes-fallback"
  Assert-Alpha6Stage1Test `
    ($macrobenchmarkSource.Contains("cachedStarted <= actorStarted") -and
      $macrobenchmarkSource.Contains(
        "CCR media actor started before cached-navigation fallback"
      )) `
    "macrobenchmark-fallback-ordering"
  Assert-Alpha6Stage1Test `
    ($macrobenchmarkSource.Contains(
      "CCR cache-only publication touched decoder output"
    )) `
    "macrobenchmark-cache-only-decoder-isolation"
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
  Assert-Alpha6Stage1Test (
    (@($preflight.stageOrder) -join "|") -ceq
      "IdentitySmoke|FixtureOpenSmoke|DeviceSettings|SettingsSettle|RenderOpenSmoke|Correctness|Performance"
  ) "preflight-stage-order"
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
  Assert-Alpha6Stage1Test (@($preflight.identity.closedValidationScripts).Count -eq 7) "closed-script-hashes-recorded"
  Assert-Alpha6Stage1Test (
    [int]$preflight.identity.artifactSetRevision -eq 5 -and
      [string]$preflight.identity.signingMode -ceq "SIGNED_CANDIDATE" -and
      $preflight.identity.candidateSigning -eq $true -and
      [string]$preflight.identity.signingLineage -ceq "ccr-internal-pilot-v1" -and
      [string]$preflight.identity.expectedSigningCertificateSha256 -ceq $certificate -and
      [string]$preflight.identity.publicSigningPolicySha256 -cmatch "^[a-f0-9]{64}$" -and
      [string]$preflight.identity.publicSigningFingerprint.sha256 -cmatch "^[a-f0-9]{64}$" -and
      [string]$preflight.identity.publicSigningCertificate.sha256 -cmatch "^[a-f0-9]{64}$"
  ) "revision5-signing-identity-recorded"
  Assert-Alpha6Stage1Test (@($preflight.preRunArtifactRehash).Count -eq 4 -and @($preflight.postRunArtifactRehash).Count -eq 4) "pre-post-rehash-recorded"
  $preflightResume = @{} + $preflightArgs
  $preflightResume.Resume = $true
  & $runner @preflightResume | Out-Null
  Assert-Alpha6Stage1Test ($adbWasCalled.Count -eq 0) "preflight-resume-has-zero-adb"
  $preflightSessionPath = Join-Path $preflightOutput "checkpoint-alpha6-stage1-session-alpha6-stage1-preflight.json"
  $preflightSessionRaw = [System.IO.File]::ReadAllText($preflightSessionPath, [System.Text.Encoding]::UTF8)
  (Get-Item -LiteralPath $preflightSessionPath).IsReadOnly = $false
  $revision4Session = $preflightSessionRaw | ConvertFrom-Json
  $revision4Session.identity.artifactSetRevision = 4
  [System.IO.File]::WriteAllText(
    $preflightSessionPath,
    ($revision4Session | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH" "revision4-resume-identity-rejected"
  [System.IO.File]::WriteAllText($preflightSessionPath, $preflightSessionRaw, [System.Text.UTF8Encoding]::new($false))
  $policyDriftSession = $preflightSessionRaw | ConvertFrom-Json
  $policyDriftSession.identity.publicSigningPolicySha256 = "0" * 64
  [System.IO.File]::WriteAllText(
    $preflightSessionPath,
    ($policyDriftSession | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH" "policy-identity-drift-rejected"
  [System.IO.File]::WriteAllText($preflightSessionPath, $preflightSessionRaw, [System.Text.UTF8Encoding]::new($false))
  $oldStageOrderSession = $preflightSessionRaw | ConvertFrom-Json
  $oldStageOrderSession.stageOrder = @(
    "IdentitySmoke", "FixtureOpenSmoke", "Correctness", "Performance"
  )
  [System.IO.File]::WriteAllText(
    $preflightSessionPath,
    ($oldStageOrderSession | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_SESSION_CONTRACT_MISMATCH" "legacy-four-stage-session-rejected"
  [System.IO.File]::WriteAllText($preflightSessionPath, $preflightSessionRaw, [System.Text.UTF8Encoding]::new($false))
  $oldIdentityStageOrderSession = $preflightSessionRaw | ConvertFrom-Json
  $oldIdentityStageOrderSession.identity.stageOrder = @(
    "IdentitySmoke", "FixtureOpenSmoke", "Correctness", "Performance"
  )
  [System.IO.File]::WriteAllText(
    $preflightSessionPath,
    ($oldIdentityStageOrderSession | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @preflightResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH" "legacy-four-stage-identity-rejected"
  [System.IO.File]::WriteAllText($preflightSessionPath, $preflightSessionRaw, [System.Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $preflightSessionPath).IsReadOnly = $true
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

  $revision4Manifest = ($manifest | ConvertTo-Json -Depth 15 -Compress) | ConvertFrom-Json
  $revision4Manifest.artifactSetRevision = 4
  $revision4ManifestPath = Join-Path $root "artifact-manifest-v4.json"
  [System.IO.File]::WriteAllText(
    $revision4ManifestPath,
    (($revision4Manifest | ConvertTo-Json -Depth 15) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  $revision4Args = @{} + $preflightArgs
  $revision4Args.ArtifactManifest = $revision4ManifestPath
  $revision4Args.ArtifactManifestSha256 = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $revision4ManifestPath
  ).Hash.ToLowerInvariant()
  $revision4Args.OutputDirectory = Join-Path $root "revision4-output"
  $revision4Args.RunId = "alpha6-stage1-revision4"
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @revision4Args | Out-Null
  } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "historical-revision4-active-runner-rejected"

  $longRunId = @{} + $preflightArgs
  $longRunId.OutputDirectory = Join-Path $root "long-run-id-output"
  $longRunId.RunId = "r" * 38
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @longRunId | Out-Null
  } "ALPHA6_STAGE1_RUN_ID_TOO_LONG" "performance-child-run-id-length-fails-fast"

  $gatePreflightConflict = @{} + $preflightArgs
  $gatePreflightConflict.SurfaceTransitionGateOnly = $true
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @gatePreflightConflict | Out-Null
  } "ALPHA6_STAGE1_SURFACE_TRANSITION_MODE_CONFLICT" `
    "surface-transition-gate-rejects-preflight-combination"
  $gateResumeConflict = @{} + $preflightArgs
  $gateResumeConflict.Remove("PreflightOnly")
  $gateResumeConflict.Resume = $true
  $gateResumeConflict.SurfaceTransitionGateOnly = $true
  $gateResumeConflict.OutputDirectory = Join-Path $root "gate-resume-conflict"
  $gateResumeConflict.RunId = "alpha6-gate-resume-conflict"
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @gateResumeConflict | Out-Null
  } "ALPHA6_STAGE1_SURFACE_TRANSITION_MODE_CONFLICT" `
    "surface-transition-gate-rejects-resume-combination"
  Assert-Alpha6Stage1Test ($adbWasCalled.Count -eq 0) `
    "surface-transition-mode-conflicts-before-adb"

  $gateSuccessOutput = Join-Path $root "surface-transition-gate-success"
  $gateSuccessState = New-Alpha6FakeAdbState
  $gateSuccessRunIds = [System.Collections.Generic.List[string]]::new()
  $gateSuccessDownstreamCount = 0L
  $gateSuccessRenderExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    $gateSuccessRunIds.Add([string]$RenderRunId) | Out-Null
    $gateSuccessState.ProcessIds[$script:CcrPinnedAppPackage] = "9401"
    $gateSuccessState.ProcessIds[$script:CcrPinnedDebugTestPackage] = "9402"
    $gateSuccessState.ProcessIds[$script:CcrPinnedMacrobenchmarkPackage] = "9403"
    [System.IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
    $reportPath = Join-Path $EvidenceDirectory "render-$RenderRunId.json"
    [System.IO.File]::WriteAllText(
      $reportPath,
      '{"kind":"host-only-render-open-smoke","status":"PASS"}',
      [System.Text.UTF8Encoding]::new($false)
    )
    (Get-Item -LiteralPath $reportPath).IsReadOnly = $true
    $reportItem = Get-Item -LiteralPath $reportPath
    return [PSCustomObject]@{
      status = "PASS"
      runId = $RenderRunId
      reportPath = $reportItem.FullName
      reportBytes = [long]$reportItem.Length
      reportSha256 =
        (Get-FileHash -Algorithm SHA256 -LiteralPath $reportItem.FullName).Hash.ToLowerInvariant()
      stableIntervalMs = 300L
      activityInstanceDriftCount = 0L
      surfaceGenerationDriftCount = 0L
      surfaceLossCount = 0L
      videoOpenFailedCount = 0L
      buildCommandCount = 0L
    }
  }.GetNewClosure()
  $gateSuccessArgs = @{} + $preflightArgs
  $gateSuccessArgs.Remove("PreflightOnly")
  $gateSuccessArgs.OutputDirectory = $gateSuccessOutput
  $gateSuccessArgs.RunId = "alpha6-surface-gate"
  $gateSuccessArgs.OriginalScreenTimeoutSetting = "120000"
  $gateSuccessArgs.SurfaceTransitionGateOnly = $true
  $gateSuccessArgs.TestOnlyAdbInvoker = New-Alpha6FakeAdbInvoker $gateSuccessState
  $gateSuccessArgs.TestOnlyIdentitySmokeExecutor = $identitySmokeExecutor
  $gateSuccessArgs.TestOnlyFixtureOpenSmokeExecutor = $fixtureOpenSmokeExecutor
  $gateSuccessArgs.TestOnlySettingsSettleExecutor = $settingsSettleExecutor
  $gateSuccessArgs.TestOnlyRenderOpenSmokeExecutor = $gateSuccessRenderExecutor
  $gateSuccessArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $gateSuccessDownstreamCount += 1L
    throw "SURFACE_TRANSITION_GATE_DOWNSTREAM_STAGE_FORBIDDEN:$Stage"
  }.GetNewClosure()
  & $runner @gateSuccessArgs | Out-Null
  $expectedGateRunIds = @(1..10 | ForEach-Object {
    "alpha6-surface-gate-g{0:D2}-ro" -f $_
  })
  Assert-Alpha6Stage1Test (
    ($gateSuccessRunIds -join "|") -ceq ($expectedGateRunIds -join "|") -and
      @($gateSuccessRunIds | Select-Object -Unique).Count -eq 10 -and
      $gateSuccessDownstreamCount -eq 0L
  ) "surface-transition-gate-ten-unique-render-runs-no-downstream"
  $gateSuccessSummaryPath = Join-Path $gateSuccessOutput (
    "alpha6-stage1-summary-alpha6-surface-gate.json"
  )
  $gateSuccessSummary = [System.IO.File]::ReadAllText(
    $gateSuccessSummaryPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$gateSuccessSummary.kind -ceq
      "alpha6-stage1-surface-transition-gate" -and
      [string]$gateSuccessSummary.status -ceq "PASS" -and
      [long]$gateSuccessSummary.renderOpenSmokeRequiredCount -eq 10L -and
      [long]$gateSuccessSummary.renderOpenSmokePassCount -eq 10L -and
      [long]$gateSuccessSummary.renderOpenAttemptCleanupPassCount -eq 10L -and
      [long]$gateSuccessSummary.correctnessExecutedTestCount -eq 0L -and
      [long]$gateSuccessSummary.performanceScenarioCount -eq 0L -and
      $gateSuccessSummary.fullStage1Executed -eq $false
  ) "surface-transition-gate-summary-counts"
  Assert-Alpha6Stage1Test (
    (@($gateSuccessSummary.executedStageOrder) -join "|") -ceq
      "IdentitySmoke|FixtureOpenSmoke|DeviceSettings|SettingsSettle|RenderOpenSmoke" -and
      (@($gateSuccessSummary.skippedStageOrder) -join "|") -ceq
      "Correctness|Performance" -and
      [string]$gateSuccessSummary.s24GateStatus -ceq
      "SURFACE_TRANSITION_GATE_PASS_STAGE1_PENDING" -and
      [string]$gateSuccessSummary.nextRequiredAction -ceq
      "RUN_FRESH_FULL_STAGE1_WITH_THE_SURFACE_STABLE_REV5_ARTIFACT_SET"
  ) "surface-transition-gate-stage-and-next-action"
  $gateSuccessCheckpoints = @(
    Get-ChildItem -LiteralPath $gateSuccessOutput `
      -Filter "checkpoint-alpha6-stage1-render-open-smoke-alpha6-surface-gate-g*.json" `
      -File
  )
  Assert-Alpha6Stage1Test (
    $gateSuccessCheckpoints.Count -eq 10 -and
      @($gateSuccessCheckpoints | Where-Object { -not $_.IsReadOnly }).Count -eq 0 -and
      @($gateSuccessSummary.renderOpenSmokeCheckpointFiles).Count -eq 10
  ) "surface-transition-gate-ten-immutable-checkpoints"
  Assert-Alpha6Stage1Test (
    @($gateSuccessSummary.renderOpenSmokes | Where-Object {
        [string]$_.attemptCleanup.status -cne "PASS" -or
          [long]$_.attemptCleanup.totalValidationProcessCount -ne 0L
      }).Count -eq 0
  ) "surface-transition-gate-ten-attempt-cleanups-pass"
  Assert-Alpha6Stage1Test (
    @($gateSuccessState.Commands | Where-Object {
      $_ -match 'shell am force-stop'
    }).Count -ge 30
  ) "surface-transition-gate-each-attempt-force-stopped"
  Assert-Alpha6Stage1Test (
    -not (Test-Path -LiteralPath (
      Join-Path $gateSuccessOutput "checkpoint-alpha6-stage1-correctness-alpha6-surface-gate.json"
    )) -and
      -not (Test-Path -LiteralPath (
        Join-Path $gateSuccessOutput "checkpoint-alpha6-stage1-performance-alpha6-surface-gate.json"
      ))
  ) "surface-transition-gate-no-correctness-or-performance-checkpoint"
  Assert-Alpha6Stage1Test (
    [string]$gateSuccessState.Settings["global/stay_on_while_plugged_in"] -ceq "0" -and
      [string]$gateSuccessState.Settings["system/screen_off_timeout"] -ceq "120000"
  ) "surface-transition-gate-settings-restored"
  Assert-Alpha6Stage1Test (
    [string]$gateSuccessSummary.cleanupVerification.status -ceq "PASS" -and
      $gateSuccessSummary.cleanupVerification.settingsRestored -eq $true -and
      $gateSuccessSummary.cleanupVerification.debugTestPackageInstalled -eq $false -and
      $gateSuccessSummary.cleanupVerification.macrobenchmarkTestPackageInstalled -eq $false -and
      [long]$gateSuccessSummary.cleanupVerification.totalValidationProcessCount -eq 0L -and
      (Get-Item -LiteralPath (
        [string]$gateSuccessSummary.cleanupVerificationCheckpointFile.path
      )).IsReadOnly
  ) "surface-transition-gate-cleanup-evidence"

  $gateRenderFailureOutput = Join-Path $root "surface-transition-gate-render-failure"
  $gateRenderFailureState = New-Alpha6FakeAdbState
  $gateRenderFailureRunIds = [System.Collections.Generic.List[string]]::new()
  $gateRenderFailureDownstreamCount = 0L
  $gateRenderFailureExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    $gateRenderFailureRunIds.Add([string]$RenderRunId) | Out-Null
    [System.IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
    $status = if ($gateRenderFailureRunIds.Count -eq 4) { "FAIL" } else { "PASS" }
    $reportPath = Join-Path $EvidenceDirectory "render-$RenderRunId.json"
    [System.IO.File]::WriteAllText(
      $reportPath,
      "{`"kind`":`"host-only-render-open-smoke`",`"status`":`"$status`"}",
      [System.Text.UTF8Encoding]::new($false)
    )
    (Get-Item -LiteralPath $reportPath).IsReadOnly = $true
    $reportItem = Get-Item -LiteralPath $reportPath
    return [PSCustomObject]@{
      status = $status
      runId = $RenderRunId
      reportPath = $reportItem.FullName
      reportBytes = [long]$reportItem.Length
      reportSha256 =
        (Get-FileHash -Algorithm SHA256 -LiteralPath $reportItem.FullName).Hash.ToLowerInvariant()
      stableIntervalMs = 300L
      activityInstanceDriftCount = 0L
      surfaceGenerationDriftCount = 0L
      surfaceLossCount = if ($status -ceq "FAIL") { 1L } else { 0L }
      videoOpenFailedCount = 0L
      buildCommandCount = 0L
    }
  }.GetNewClosure()
  $gateRenderFailureArgs = @{} + $gateSuccessArgs
  $gateRenderFailureArgs.OutputDirectory = $gateRenderFailureOutput
  $gateRenderFailureArgs.RunId = "alpha6-gate-render-fail"
  $gateRenderFailureArgs.TestOnlyAdbInvoker =
    New-Alpha6FakeAdbInvoker $gateRenderFailureState
  $gateRenderFailureArgs.TestOnlyRenderOpenSmokeExecutor =
    $gateRenderFailureExecutor
  $gateRenderFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $gateRenderFailureDownstreamCount += 1L
    throw "SURFACE_TRANSITION_GATE_DOWNSTREAM_STAGE_FORBIDDEN:$Stage"
  }.GetNewClosure()
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @gateRenderFailureArgs | Out-Null
  } "ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED" `
    "surface-transition-gate-fourth-render-failure-propagates"
  Assert-Alpha6Stage1Test (
    $gateRenderFailureRunIds.Count -eq 4 -and
      $gateRenderFailureDownstreamCount -eq 0L
  ) "surface-transition-gate-render-failure-stops-at-four"
  $gateRenderFailureCheckpoints = @(
    Get-ChildItem -LiteralPath $gateRenderFailureOutput `
      -Filter "checkpoint-alpha6-stage1-render-open-smoke-*.json" -File
  )
  Assert-Alpha6Stage1Test (
    $gateRenderFailureCheckpoints.Count -eq 4 -and
      @($gateRenderFailureCheckpoints | Where-Object { -not $_.IsReadOnly }).Count -eq 0 -and
      -not (Test-Path -LiteralPath (
        Join-Path $gateRenderFailureOutput (
          "checkpoint-alpha6-stage1-correctness-alpha6-gate-render-fail.json"
        )
      ))
  ) "surface-transition-gate-render-failure-checkpoint-and-downstream-zero"
  $gateRenderFailureReport = @(
    Get-ChildItem -LiteralPath $gateRenderFailureOutput `
      -Filter "failure-alpha6-stage1-*.json" -File
  )[0]
  $gateRenderFailureRecord = [System.IO.File]::ReadAllText(
    $gateRenderFailureReport.FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$gateRenderFailureRecord.phase -ceq "render-open-smoke" -and
      [string]$gateRenderFailureState.Settings["global/stay_on_while_plugged_in"] -ceq "0" -and
      [string]$gateRenderFailureState.Settings["system/screen_off_timeout"] -ceq "120000"
  ) "surface-transition-gate-render-failure-cleanup"

  $gateSettleFailureOutput = Join-Path $root "surface-transition-gate-settle-failure"
  $gateSettleFailureState = New-Alpha6FakeAdbState
  $gateSettleFailureRenderCount = 0L
  $gateSettleFailureDownstreamCount = 0L
  $gateSettleFailureArgs = @{} + $gateSuccessArgs
  $gateSettleFailureArgs.OutputDirectory = $gateSettleFailureOutput
  $gateSettleFailureArgs.RunId = "alpha6-gate-settle-fail"
  $gateSettleFailureArgs.TestOnlyAdbInvoker =
    New-Alpha6FakeAdbInvoker $gateSettleFailureState
  $gateSettleFailureArgs.TestOnlySettingsSettleExecutor = {
    param($Context, $AttemptRunId)
    $failed = & $settingsSettleExecutor $Context $AttemptRunId
    $failed.status = "FAIL"
    return $failed
  }.GetNewClosure()
  $gateSettleFailureArgs.TestOnlyRenderOpenSmokeExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    $gateSettleFailureRenderCount += 1L
    throw "SURFACE_TRANSITION_GATE_RENDER_MUST_NOT_RUN"
  }.GetNewClosure()
  $gateSettleFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $gateSettleFailureDownstreamCount += 1L
    throw "SURFACE_TRANSITION_GATE_DOWNSTREAM_STAGE_FORBIDDEN:$Stage"
  }.GetNewClosure()
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @gateSettleFailureArgs | Out-Null
  } "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED" `
    "surface-transition-gate-settle-failure-propagates"
  Assert-Alpha6Stage1Test (
    $gateSettleFailureRenderCount -eq 0L -and
      $gateSettleFailureDownstreamCount -eq 0L -and
      [string]$gateSettleFailureState.Settings["global/stay_on_while_plugged_in"] -ceq "0" -and
      [string]$gateSettleFailureState.Settings["system/screen_off_timeout"] -ceq "120000"
  ) "surface-transition-gate-settle-failure-blocks-and-restores"

  $identityFailureOutput = Join-Path $root "identity-smoke-failure-output"
  $identityFailureState = New-Alpha6FakeAdbState
  $identityFailureAdb = New-Alpha6FakeAdbInvoker $identityFailureState
  $identityFailureArgs = @{} + $preflightArgs
  $identityFailureArgs.Remove("PreflightOnly")
  $identityFailureArgs.OutputDirectory = $identityFailureOutput
  $identityFailureArgs.RunId = "alpha6-stage1-identity-fail"
  $identityFailureArgs.OriginalScreenTimeoutSetting = "120000"
  $identityFailureArgs.TestOnlyAdbInvoker = $identityFailureAdb
  $identityFailureArgs.TestOnlyIdentitySmokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    throw "SYNTHETIC_IDENTITY_SMOKE_FAILURE"
  }
  $identityFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    throw "STAGE_MUST_NOT_RUN_AFTER_IDENTITY_SMOKE_FAILURE"
  }
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @identityFailureArgs | Out-Null
  } "SYNTHETIC_IDENTITY_SMOKE_FAILURE" "identity-smoke-failure-propagates"
  Assert-Alpha6Stage1Test (
    @($identityFailureState.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "identity-smoke-failure-before-settings-mutation"
  Assert-Alpha6Stage1Test (
    -not (Test-Path -LiteralPath (
      Join-Path $identityFailureOutput "checkpoint-alpha6-stage1-device-settings-alpha6-stage1-identity-fail.json"
    ))
  ) "identity-smoke-failure-has-no-device-settings-checkpoint"
  $identityFailureReports = @(
    Get-ChildItem -LiteralPath $identityFailureOutput -Filter "failure-alpha6-stage1-*.json" -File
  )
  $identityFailureReport = [System.IO.File]::ReadAllText(
    $identityFailureReports[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$identityFailureReport.phase -ceq "identity-smoke"
  ) "identity-smoke-failure-phase-recorded"

  $fixtureFailureOutput = Join-Path $root "fixture-open-smoke-failure-output"
  $fixtureFailureState = New-Alpha6FakeAdbState
  $fixtureFailureAdb = New-Alpha6FakeAdbInvoker $fixtureFailureState
  $fixtureFailureStageCallCount = 0
  $fixtureFailureArgs = @{} + $preflightArgs
  $fixtureFailureArgs.Remove("PreflightOnly")
  $fixtureFailureArgs.OutputDirectory = $fixtureFailureOutput
  $fixtureFailureArgs.RunId = "alpha6-stage1-fixture-fail"
  $fixtureFailureArgs.OriginalScreenTimeoutSetting = "120000"
  $fixtureFailureArgs.TestOnlyAdbInvoker = $fixtureFailureAdb
  $fixtureFailureArgs.TestOnlyIdentitySmokeExecutor = $identitySmokeExecutor
  $fixtureFailureArgs.TestOnlySettingsSettleExecutor = $settingsSettleExecutor
  $fixtureFailureArgs.TestOnlyRenderOpenSmokeExecutor = $renderOpenSmokeExecutor
  $fixtureFailureArgs.TestOnlyFixtureOpenSmokeExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory)
    [System.IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
    $reportPath = Join-Path $EvidenceDirectory "fixture-failure.json"
    [System.IO.File]::WriteAllText(
      $reportPath,
      '{"kind":"host-only-fixture-open-smoke","status":"FAIL"}',
      [System.Text.UTF8Encoding]::new($false)
    )
    $item = Get-Item -LiteralPath $reportPath
    return [PSCustomObject]@{
      status = "FAIL"
      runId = $FixtureRunId
      fixtureCount = 1L
      reportPath = $item.FullName
      reportBytes = [long]$item.Length
      reportSha256 =
        (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
      failure = [PSCustomObject]@{
        stageCode = "PROVIDER_OPEN_FILE_DESCRIPTOR"
        classification = "PROVIDER_DESCRIPTOR_FAILURE"
        exceptionClass = "FileNotFoundException"
        sanitizedDetail = "SYNTHETIC_PROVIDER_OPEN_FAILURE"
      }
      buildCommandCount = 0L
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
    }
  }
  $fixtureFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $fixtureFailureStageCallCount += 1
    throw "STAGE_MUST_NOT_RUN_AFTER_FIXTURE_OPEN_SMOKE_FAILURE"
  }.GetNewClosure()
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @fixtureFailureArgs | Out-Null
  } "ALPHA6_STAGE1_FIXTURE_OPEN_SMOKE_FAILED" "fixture-open-smoke-failure-propagates"
  Assert-Alpha6Stage1Test (
    @($fixtureFailureState.Commands | Where-Object { $_ -match ' shell settings (put|delete) ' }).Count -eq 0
  ) "fixture-smoke-failure-before-settings-mutation"
  Assert-Alpha6Stage1Test ($fixtureFailureStageCallCount -eq 0) `
    "fixture-smoke-failure-skips-correctness-and-performance"
  Assert-Alpha6Stage1Test (
    @(Get-ChildItem -LiteralPath $fixtureFailureOutput `
      -Filter "checkpoint-alpha6-stage1-device-settings-*.json" -File).Count -eq 0
  ) "fixture-smoke-failure-has-no-device-settings-checkpoint"
  $fixtureFailureReports = @(
    Get-ChildItem -LiteralPath $fixtureFailureOutput -Filter "failure-alpha6-stage1-*.json" -File
  )
  $fixtureFailureReport = [System.IO.File]::ReadAllText(
    $fixtureFailureReports[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$fixtureFailureReport.phase -ceq "fixture-open-smoke" -and
      [string]$fixtureFailureReport.identity.runtimeSourceSha -ceq $runtimeSource -and
      [string]$fixtureFailureReport.identity.harnessSourceSha -ceq $harnessSource -and
      [long]$fixtureFailureReport.buildCommandCount -eq 0L -and
      [string]$fixtureFailureReport.fixtureOpenSmokeResult.failure.classification -ceq
        "PROVIDER_DESCRIPTOR_FAILURE" -and
      [string]$fixtureFailureReport.fixtureOpenSmokeResult.reportPath -cmatch
        "fixture-failure\.json$"
  ) "fixture-smoke-failure-evidence-identity"

  $settingsSettleFailureOutput = Join-Path $root "settings-settle-failure-output"
  $settingsSettleFailureArgs = @{} + $fixtureFailureArgs
  $settingsSettleFailureArgs.OutputDirectory = $settingsSettleFailureOutput
  $settingsSettleFailureArgs.RunId = "alpha6-stage1-settle-fail"
  $settingsSettleFailureArgs.TestOnlyFixtureOpenSmokeExecutor = $fixtureOpenSmokeExecutor
  $settingsSettleFailureArgs.TestOnlySettingsSettleExecutor = {
    param($Context, $AttemptRunId)
    $result = & $settingsSettleExecutor $Context $AttemptRunId
    $result.status = "FAIL"
    $result.observedConsecutiveSamples = 2L
    return $result
  }.GetNewClosure()
  $settingsSettleRenderCallCount = [PSCustomObject]@{ Count = 0 }
  $settingsSettleStageCallCount = [PSCustomObject]@{ Count = 0 }
  $settingsSettleFailureArgs.TestOnlyRenderOpenSmokeExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    $settingsSettleRenderCallCount.Count += 1
    throw "RENDER_MUST_NOT_RUN_AFTER_SETTINGS_SETTLE_FAILURE"
  }.GetNewClosure()
  $settingsSettleFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $settingsSettleStageCallCount.Count += 1
    throw "STAGE_MUST_NOT_RUN_AFTER_SETTINGS_SETTLE_FAILURE"
  }.GetNewClosure()
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @settingsSettleFailureArgs | Out-Null
  } "ALPHA6_STAGE1_DEVICE_SETTINGS_NOT_SETTLED" "settings-settle-fails-closed"
  $settingsSettleFailureCheckpointPath = Join-Path $settingsSettleFailureOutput (
    "checkpoint-alpha6-stage1-settings-settle-alpha6-stage1-settle-fail.json"
  )
  $settingsSettleFailureCheckpoint = [System.IO.File]::ReadAllText(
    $settingsSettleFailureCheckpointPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$settingsSettleFailureCheckpoint.status -ceq "FAIL" -and
      (Get-Item -LiteralPath $settingsSettleFailureCheckpointPath).IsReadOnly -and
      $settingsSettleRenderCallCount.Count -eq 0 -and
      $settingsSettleStageCallCount.Count -eq 0
  ) "settings-settle-failure-evidence-is-immutable-and-blocking"
  $settingsSettleFailureReport = [System.IO.File]::ReadAllText(
    @(
      Get-ChildItem -LiteralPath $settingsSettleFailureOutput `
        -Filter "failure-alpha6-stage1-*.json" -File
    )[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$settingsSettleFailureReport.phase -ceq "settings-settle" -and
      [string]$settingsSettleFailureReport.settingsSettleCheckpoint.status -ceq "FAIL" -and
      -not (Test-Path -LiteralPath (
        Join-Path $settingsSettleFailureOutput (
          "checkpoint-alpha6-stage1-correctness-alpha6-stage1-settle-fail.json"
        )
      ))
  ) "settings-settle-failure-report-and-downstream-block"

  $renderOpenFailureOutput = Join-Path $root "render-open-smoke-failure-output"
  $renderOpenFailureArgs = @{} + $fixtureFailureArgs
  $renderOpenFailureArgs.OutputDirectory = $renderOpenFailureOutput
  $renderOpenFailureArgs.RunId = "alpha6-stage1-render-fail"
  $renderOpenFailureArgs.TestOnlyFixtureOpenSmokeExecutor = $fixtureOpenSmokeExecutor
  $renderOpenFailureArgs.TestOnlySettingsSettleExecutor = $settingsSettleExecutor
  $renderOpenFailureArgs.TestOnlyRenderOpenSmokeExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    $result = & $renderOpenSmokeExecutor $Context $RenderRunId $EvidenceDirectory
    $result.status = "FAIL"
    $result.videoOpenFailedCount = 1L
    return $result
  }.GetNewClosure()
  $renderOpenFailureStageCallCount = [PSCustomObject]@{ Count = 0 }
  $renderOpenFailureArgs.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    $renderOpenFailureStageCallCount.Count += 1
    throw "STAGE_MUST_NOT_RUN_AFTER_RENDER_OPEN_SMOKE_FAILURE"
  }.GetNewClosure()
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @renderOpenFailureArgs | Out-Null
  } "ALPHA6_STAGE1_RENDER_OPEN_SMOKE_FAILED" "render-open-smoke-fails-closed"
  $renderOpenFailureCheckpointPath = Join-Path $renderOpenFailureOutput (
    "checkpoint-alpha6-stage1-render-open-smoke-alpha6-stage1-render-fail.json"
  )
  $renderOpenFailureCheckpoint = [System.IO.File]::ReadAllText(
    $renderOpenFailureCheckpointPath,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$renderOpenFailureCheckpoint.status -ceq "FAIL" -and
      (Get-Item -LiteralPath $renderOpenFailureCheckpointPath).IsReadOnly -and
      $renderOpenFailureStageCallCount.Count -eq 0
  ) "render-open-smoke-failure-evidence-is-immutable-and-blocking"
  $renderOpenFailureReport = [System.IO.File]::ReadAllText(
    @(
      Get-ChildItem -LiteralPath $renderOpenFailureOutput `
        -Filter "failure-alpha6-stage1-*.json" -File
    )[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [string]$renderOpenFailureReport.phase -ceq "render-open-smoke" -and
      [string]$renderOpenFailureReport.renderOpenSmokeCheckpoint.status -ceq "FAIL" -and
      -not (Test-Path -LiteralPath (
        Join-Path $renderOpenFailureOutput (
          "checkpoint-alpha6-stage1-correctness-alpha6-stage1-render-fail.json"
        )
      ))
  ) "render-smoke-failure-skips-correctness-and-performance"

  $firstResumeAfterFixtureFailure = @{} + $fixtureFailureArgs
  $firstResumeAfterFixtureFailure.Resume = $true
  $firstResumeAfterFixtureFailure.TestOnlyFixtureOpenSmokeExecutor = $fixtureOpenSmokeExecutor
  $firstResumeAfterFixtureFailure.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    return [PSCustomObject]@{
      status = $(if ($Stage -ceq "Correctness") { "FAIL" } else { "PASS" })
      buildCommandCount = 0L
    }
  }
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @firstResumeAfterFixtureFailure | Out-Null
  } "ALPHA6_STAGE1_CORRECTNESS_FAILED" `
    "first-resume-after-pre-settings-failure-reaches-correctness"
  $preSettingsResumeRecords = @(
    Get-ChildItem -LiteralPath $fixtureFailureOutput `
      -Filter "checkpoint-alpha6-stage1-device-settings-*.json" -File
  )
  $preSettingsResumeRecord = [System.IO.File]::ReadAllText(
    $preSettingsResumeRecords[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    $preSettingsResumeRecords.Count -eq 1 -and
      $preSettingsResumeRecords[0].Name -cmatch "-resume-[a-f0-9]{32}\.json$" -and
      [string]$preSettingsResumeRecord.effectiveRestoreBaseline.screenTimeout -ceq "120000"
  ) "first-resume-persists-unique-original-settings-baseline"

  foreach ($entry in @{
    "global/stay_on_while_plugged_in" = "7"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "128"
    "system/screen_off_timeout" = "1800000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }.GetEnumerator()) {
    $fixtureFailureState.Settings[$entry.Key] = [string]$entry.Value
  }
  $secondResumeAfterFixtureFailure = @{} + $firstResumeAfterFixtureFailure
  $secondResumeAfterFixtureFailure.TestOnlyStageExecutor = {
    param($Stage, $Context, $StageDirectory)
    [System.IO.Directory]::CreateDirectory($StageDirectory) | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $StageDirectory "host-only-$Stage.txt"),
      "second-resume-$Stage",
      [System.Text.UTF8Encoding]::new($false)
    )
    return [PSCustomObject]@{ status = "PASS"; buildCommandCount = 0L }
  }
  & $runner @secondResumeAfterFixtureFailure | Out-Null
  Assert-Alpha6Stage1Test (
    [string]$fixtureFailureState.Settings["global/stay_on_while_plugged_in"] -ceq "0" -and
      [string]$fixtureFailureState.Settings["system/screen_brightness_mode"] -ceq "1" -and
      [string]$fixtureFailureState.Settings["system/screen_brightness"] -ceq "77" -and
      [string]$fixtureFailureState.Settings["system/screen_off_timeout"] -ceq "120000" -and
      [string]$fixtureFailureState.Settings["system/accelerometer_rotation"] -ceq "1" -and
      [string]$fixtureFailureState.Settings["system/user_rotation"] -ceq "2"
  ) "second-resume-restores-baseline-from-prior-unique-checkpoint"
  Assert-Alpha6Stage1Test (
    @(
      Get-ChildItem -LiteralPath $fixtureFailureOutput `
        -Filter "checkpoint-alpha6-stage1-device-settings-*.json" -File
    ).Count -eq 2
  ) "multi-resume-keeps-settings-baseline-chain"

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
  $failureArgs.TestOnlyIdentitySmokeExecutor = $identitySmokeExecutor
  $failureArgs.TestOnlyFixtureOpenSmokeExecutor = $fixtureOpenSmokeExecutor
  $failureArgs.TestOnlySettingsSettleExecutor = $settingsSettleExecutor
  $failureArgs.TestOnlyRenderOpenSmokeExecutor = $renderOpenSmokeExecutor
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
  Assert-Alpha6Stage1Test (
    @($failureState.Commands | Where-Object { $_ -match 'am force-stop' }).Count -eq 4 -and
      @($failureState.Commands | Where-Object {
        $_ -match ("am force-stop " + [regex]::Escape($script:CcrPinnedAppPackage) + "$")
      }).Count -eq 2
  ) "app-force-stopped"
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
  $fixtureSmokeAttempts = @(
    Get-ChildItem -LiteralPath $failureOutput `
      -Filter "checkpoint-alpha6-stage1-fixture-open-smoke-*.json" -File
  )
  $fixtureSmokeChildRunIds = @($fixtureSmokeAttempts | ForEach-Object {
    $checkpoint = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) |
      ConvertFrom-Json
    [string]$checkpoint.result.runId
  } | Select-Object -Unique)
  Assert-Alpha6Stage1Test (
    $fixtureSmokeAttempts.Count -eq 2 -and $fixtureSmokeChildRunIds.Count -eq 2
  ) "partial-resume-reruns-fixture-smoke-with-unique-child-run-id"
  $settingsSettleAttempts = @(
    Get-ChildItem -LiteralPath $failureOutput `
      -Filter "checkpoint-alpha6-stage1-settings-settle-*.json" -File
  )
  $settingsSettleAttemptRunIds = @($settingsSettleAttempts | ForEach-Object {
    $checkpoint = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) |
      ConvertFrom-Json
    [string]$checkpoint.attemptRunId
  } | Select-Object -Unique)
  Assert-Alpha6Stage1Test (
    $settingsSettleAttempts.Count -eq 2 -and $settingsSettleAttemptRunIds.Count -eq 2
  ) "partial-resume-reruns-settings-settle-with-unique-attempt-id"
  $renderOpenAttempts = @(
    Get-ChildItem -LiteralPath $failureOutput `
      -Filter "checkpoint-alpha6-stage1-render-open-smoke-*.json" -File
  )
  $renderOpenChildRunIds = @($renderOpenAttempts | ForEach-Object {
    $checkpoint = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) |
      ConvertFrom-Json
    [string]$checkpoint.result.runId
  } | Select-Object -Unique)
  Assert-Alpha6Stage1Test (
    $renderOpenAttempts.Count -eq 2 -and $renderOpenChildRunIds.Count -eq 2
  ) "partial-resume-reruns-render-open-smoke-with-unique-child-run-id"
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
    $evidencePath = if ($Stage -ceq "Correctness") {
      Join-Path $Context.OutputDirectory "host-only-$Stage.txt"
    } else {
      Join-Path $StageDirectory "host-only-$Stage.txt"
    }
    [System.IO.File]::WriteAllText($evidencePath, "synthetic-$Stage", [System.Text.UTF8Encoding]::new($false))
    $result = [PSCustomObject]@{ status = "PASS"; buildCommandCount = 0L }
    if ($Stage -ceq "Correctness") {
      $item = Get-Item -LiteralPath $evidencePath
      $result | Add-Member -NotePropertyName evidence -NotePropertyValue @([PSCustomObject]@{
        path = $item.FullName
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
      })
    }
    return $result
  }.GetNewClosure()
  $successArgs = @{} + $failureArgs
  $successArgs.OutputDirectory = $successOutput
  $successArgs.RunId = "alpha6-stage1-success"
  $successArgs.TestOnlyAdbInvoker = $successAdb
  $successArgs.TestOnlyIdentitySmokeExecutor = {
    param($Context, $IdentityRunId, $EvidenceDirectory)
    [System.IO.File]::AppendAllText(
      $successLog,
      "IdentitySmoke`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    return & $identitySmokeExecutor $Context $IdentityRunId $EvidenceDirectory
  }.GetNewClosure()
  $successArgs.TestOnlyFixtureOpenSmokeExecutor = {
    param($Context, $FixtureRunId, $EvidenceDirectory)
    [System.IO.File]::AppendAllText(
      $successLog,
      "FixtureOpenSmoke`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    return & $fixtureOpenSmokeExecutor $Context $FixtureRunId $EvidenceDirectory
  }.GetNewClosure()
  $successArgs.TestOnlySettingsSettleExecutor = {
    param($Context, $AttemptRunId)
    [System.IO.File]::AppendAllText(
      $successLog,
      "DeviceSettings`nSettingsSettle`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    return & $settingsSettleExecutor $Context $AttemptRunId
  }.GetNewClosure()
  $successArgs.TestOnlyRenderOpenSmokeExecutor = {
    param($Context, $RenderRunId, $EvidenceDirectory)
    [System.IO.File]::AppendAllText(
      $successLog,
      "RenderOpenSmoke`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    return & $renderOpenSmokeExecutor $Context $RenderRunId $EvidenceDirectory
  }.GetNewClosure()
  $successArgs.TestOnlyStageExecutor = $successExecutor
  & $runner @successArgs | Out-Null
  $successStages = @(Get-Content -Encoding UTF8 -LiteralPath $successLog)
  Assert-Alpha6Stage1Test (
    ($successStages -join ",") -ceq
      "IdentitySmoke,FixtureOpenSmoke,DeviceSettings,SettingsSettle,RenderOpenSmoke,Correctness,Performance"
  ) "stage-order"
  $successSummaryPath = Join-Path $successOutput "alpha6-stage1-summary-alpha6-stage1-success.json"
  $successSummary = [System.IO.File]::ReadAllText($successSummaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-Alpha6Stage1Test ([string]$successSummary.status -ceq "PENDING_USER" -and
      [string]$successSummary.technicalGateStatus -ceq "PASS" -and $successSummary.releaseEligible -eq $false) "success-status"
  Assert-Alpha6Stage1Test ($successSummary.auxiliaryDecoderUsed -eq $false -and [string]$successSummary.userReverseSmoothness -ceq "PENDING_USER") "stage1-single-decoder-user-pending"
  Assert-Alpha6Stage1Test ([long]$successSummary.buildCommandCount -eq 0L) "success-build-count-zero"
  Assert-Alpha6Stage1Test (
    [string]$successSummary.identitySmoke.status -ceq "PASS" -and
      [long]$successSummary.identitySmoke.deviceSettingsMutationCount -eq 0L
  ) "identity-smoke-pass-recorded-before-stages"
  Assert-Alpha6Stage1Test (
    [string]$successSummary.fixtureOpenSmoke.status -ceq "PASS" -and
      [long]$successSummary.fixtureOpenSmoke.result.fixtureCount -eq 17L -and
      [long]$successSummary.fixtureOpenSmoke.deviceSettingsMutationCount -eq 0L
  ) "fixture-open-smoke-17-pass-recorded-before-stages"
  Assert-Alpha6Stage1Test (
    (@($successSummary.stageOrder) -join "|") -ceq
      "IdentitySmoke|FixtureOpenSmoke|DeviceSettings|SettingsSettle|RenderOpenSmoke|Correctness|Performance" -and
      [string]$successSummary.settingsSettle.status -ceq "PASS" -and
      [string]$successSummary.renderOpenSmoke.status -ceq "PASS" -and
      [long]$successSummary.debugArtifactInstallSetCount -eq 1L -and
      [long]$successSummary.debugArtifactInstallCommandCount -eq 2L
  ) "seven-stage-summary-and-single-debug-install-set"
  Assert-Alpha6Stage1Test (
    (Test-Path -LiteralPath ([string]$successSummary.settingsSettleCheckpointFile.path) -PathType Leaf) -and
      (Test-Path -LiteralPath ([string]$successSummary.renderOpenSmokeCheckpointFile.path) -PathType Leaf)
  ) "settle-and-render-checkpoint-files-recorded"
  $successCorrectnessCheckpoint = [System.IO.File]::ReadAllText(
    (Join-Path $successOutput "checkpoint-alpha6-stage1-correctness-alpha6-stage1-success.json"),
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-Alpha6Stage1Test (
    [System.IO.Path]::GetDirectoryName([string]$successCorrectnessCheckpoint.evidence[0].path) -ceq $successOutput
  ) "correctness-uses-returned-root-evidence"
  $successResume = @{} + $successArgs
  $successResume.Resume = $true
  & $runner @successResume | Out-Null
  Assert-Alpha6Stage1Test (@(Get-Content -Encoding UTF8 -LiteralPath $successLog).Count -eq 7) "resume-skips-completed-stages"

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
  $missingFixtureSummary = $successSummaryRaw | ConvertFrom-Json
  $missingFixtureSummary.PSObject.Properties.Remove("fixtureOpenSmoke")
  [System.IO.File]::WriteAllText(
    $successSummaryPath,
    ($missingFixtureSummary | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @successResume | Out-Null
  } "PINNED_MANIFEST_PROPERTY_MISSING:fixtureOpenSmoke" `
    "resume-rejects-completed-summary-without-fixture-smoke"
  [System.IO.File]::WriteAllText(
    $successSummaryPath,
    $successSummaryRaw,
    [System.Text.UTF8Encoding]::new($false)
  )
  $missingRenderSummary = $successSummaryRaw | ConvertFrom-Json
  $missingRenderSummary.PSObject.Properties.Remove("renderOpenSmoke")
  [System.IO.File]::WriteAllText(
    $successSummaryPath,
    ($missingRenderSummary | ConvertTo-Json -Depth 50),
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @successResume | Out-Null
  } "PINNED_MANIFEST_PROPERTY_MISSING:renderOpenSmoke" `
    "resume-rejects-completed-summary-without-render-open-smoke"
  [System.IO.File]::WriteAllText(
    $successSummaryPath,
    $successSummaryRaw,
    [System.Text.UTF8Encoding]::new($false)
  )
  (Get-Item -LiteralPath $successSummaryPath).IsReadOnly = $true

  $differentDeviceState = New-Alpha6FakeAdbState "samsung/test/device:37/DIFFERENT/1:user/release-keys"
  $differentDeviceResume = @{} + $successResume
  $differentDeviceResume.TestOnlyAdbInvoker = New-Alpha6FakeAdbInvoker $differentDeviceState
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @differentDeviceResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_IDENTITY_MISMATCH" "resume-device-identity-preserved"

  $fixtureEvidencePath = [string]$successSummary.fixtureOpenSmoke.result.reportPath
  $fixtureEvidenceRaw = [System.IO.File]::ReadAllText(
    $fixtureEvidencePath,
    [System.Text.Encoding]::UTF8
  )
  (Get-Item -LiteralPath $fixtureEvidencePath).IsReadOnly = $false
  [System.IO.File]::AppendAllText(
    $fixtureEvidencePath,
    "-tampered",
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-Alpha6Stage1ThrowsLike {
    & $runner @successResume | Out-Null
  } "ALPHA6_STAGE1_RESUME_EVIDENCE_HASH_MISMATCH" `
    "resume-rehashes-completed-fixture-open-report"
  [System.IO.File]::WriteAllText(
    $fixtureEvidencePath,
    $fixtureEvidenceRaw,
    [System.Text.UTF8Encoding]::new($false)
  )
  (Get-Item -LiteralPath $fixtureEvidencePath).IsReadOnly = $true

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
