param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

function Write-CcrPerfJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  [System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($Path),
    ($Value | ConvertTo-Json -Depth 20),
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Get-CcrBenchmarkEvidenceFromOutput {
  param([Parameter(Mandatory = $true)][string]$Output)
  $matches = [regex]::Matches(
    $Output,
    '(?m)^INSTRUMENTATION_STATUS: ccrBenchmarkHarnessV2=(?<json>\{[^\r\n]*\})\r?$'
  )
  if ($matches.Count -ne 1) { throw "PINNED_BENCHMARK_STATUS_JSON_COUNT_MISMATCH" }
  try {
    return $matches[0].Groups["json"].Value | ConvertFrom-Json
  } catch {
    throw "PINNED_BENCHMARK_STATUS_JSON_INVALID"
  }
}

function Assert-CcrBenchmarkData {
  param([Parameter(Mandatory = $true)][string]$Path)
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  try { $null = $text | ConvertFrom-Json } catch { throw "PINNED_BENCHMARK_DATA_JSON_INVALID" }
  foreach ($metric in @(
    "ccrPublicationIntervalP50Us",
    "ccrPublishedFpsMilli",
    "ccrRawLagMax",
    "ccrOutstandingForegroundTargetDepthMax",
    "ccrAcceptedTargetCount",
    "ccrReleaseAfterAcceptedTargetCount",
    "ccrHoldPrefetchStarted",
    "ccrHoldPrefetchCompleted",
    "ccrCounterComplete",
    "ccrRunIteration",
    "ccrRunIdHash53",
    "ccrTraceIdentityHash53",
    "ccrRuntimeSourceHash53",
    "ccrHarnessSourceHash53",
    "ccrRuntimeInputsTreeHash53"
  )) {
    if (-not $text.Contains('"' + $metric + '"')) { throw "PINNED_BENCHMARK_DATA_METRIC_MISSING:$metric" }
  }
}

function Assert-CcrPerformanceGate {
  param(
    [Parameter(Mandatory = $true)][object]$Evidence,
    [Parameter(Mandatory = $true)][object]$Scenario
  )
  foreach ($iteration in @($Evidence.iterations)) {
    $iterationNumber = [int]$iteration.runIteration
    if ([long]$iteration.activeMs -le 0 -or [long]$iteration.published -le 0 -or
        [long]$iteration.acceptedTargetCount -le 0) {
      throw "PINNED_PERF_EMPTY_MEASUREMENT:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.publicationIntervalP50Us -gt [long]$Scenario.IntervalP50UsMax) {
      throw "PINNED_PERF_INTERVAL_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([double]$iteration.publishedFps -lt [double]$Scenario.PublishedFpsMin) {
      throw "PINNED_PERF_FPS_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.rawLagMax -gt [long]$Scenario.RawLagMax) {
      throw "PINNED_PERF_RAW_LAG_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.outstandingForegroundTargetDepthMax -gt 1) {
      throw "PINNED_PERF_OUTSTANDING_TARGET_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.releaseAfterAcceptedTargetCount -ne 0) {
      throw "PINNED_PERF_RELEASE_ACCEPTANCE_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
    if ([long]$iteration.holdPrefetchStarted -ne 0 -or [long]$iteration.holdPrefetchCompleted -ne 0) {
      throw "PINNED_PERF_HOLD_PREFETCH_GATE_FAILED:$($Scenario.Method)/$iterationNumber"
    }
  }
}

function Test-CcrPackageAbsent {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$PackageName)
  return -not (Test-CcrPinnedPackageInstalled $Context $PackageName)
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
$summaryPath = Join-Path $context.OutputDirectory "navigation-perf-v2-summary.json"

if ($PreflightOnly) {
  $preflight = [PSCustomObject]@{
    schemaVersion = 2
    kind = "s24-navigation-perf-preflight"
    status = "PASS"
    preflightOnly = $true
    deviceMutationCount = 0
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    artifactManifest = $context.ArtifactSet.ManifestPath
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    serial = $context.Serial
    model = $context.Model
    fingerprint = $context.Fingerprint
    securityPatch = $context.SecurityPatch
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Write-CcrPerfJson $summaryPath $preflight
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}

$scenarios = @(
  [PSCustomObject]@{
    Method = "hold1080PlusOne"
    Label = "+1"
    RunPrefix = "perf-plus1"
    IntervalP50UsMax = 132200L
    PublishedFpsMin = 6.79
    RawLagMax = 1L
  },
  [PSCustomObject]@{
    Method = "hold1080PlusFive"
    Label = "+5"
    RunPrefix = "perf-plus5"
    IntervalP50UsMax = 151900L
    PublishedFpsMin = 6.45
    RawLagMax = 5L
  }
)

$remoteDirectories = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$primaryFailure = $null
$manualReviewReady = $false
$settingsSaved = $false

try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $settingsSaved = $true
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"
  $wake = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
  if ($wake.exitCode -ne 0) { throw "PINNED_PERF_DEVICE_WAKE_FAILED" }
  $unlock = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "wm", "dismiss-keyguard")
  if ($unlock.exitCode -ne 0) { throw "PINNED_PERF_KEYGUARD_DISMISS_FAILED" }

  Install-CcrPinnedArtifactSet $context "Benchmark"

  foreach ($scenario in $scenarios) {
    $runId = New-CcrPinnedRunId $context.OutputDirectory $scenario.RunPrefix
    $remoteDirectory = "/sdcard/Android/media/$script:CcrPinnedMacrobenchmarkPackage/$runId"
    $remoteDirectories.Add($remoteDirectory) | Out-Null
    Remove-CcrPinnedRemoteTraceDirectory $context $remoteDirectory
    $createRemote = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "mkdir", "-p", $remoteDirectory)
    if ($createRemote.exitCode -ne 0) { throw "PINNED_BENCHMARK_REMOTE_DIRECTORY_CREATE_FAILED:$($scenario.Method)" }

    $instrumentation = Invoke-CcrPinnedInstrumentation `
      -Context $context `
      -TestRole "macrobenchmarkTest" `
      -ClassName "com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark#$($scenario.Method)" `
      -RunId $runId `
      -ExpectedTestCount 1 `
      -AdditionalArguments @{
        "additionalTestOutputDir" = $remoteDirectory
        "androidx.benchmark.output.enable" = "true"
      }

    $evidence = Get-CcrBenchmarkEvidenceFromOutput $instrumentation.Output
    $localRunDirectory = Join-Path $context.OutputDirectory $runId
    if (Test-Path -LiteralPath $localRunDirectory) { throw "PINNED_BENCHMARK_LOCAL_RUN_ALREADY_EXISTS:$runId" }
    $pull = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "pull", $remoteDirectory, $localRunDirectory)
    if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $localRunDirectory -PathType Container)) {
      throw "PINNED_BENCHMARK_OUTPUT_PULL_FAILED:$($scenario.Method)"
    }

    $instrumentationPath = Join-Path $localRunDirectory "instrumentation-output.txt"
    [System.IO.File]::WriteAllText($instrumentationPath, $instrumentation.Output, [System.Text.UTF8Encoding]::new($false))
    $evidencePath = Join-Path $localRunDirectory "ccrBenchmarkHarnessV2.json"
    Write-CcrPerfJson $evidencePath $evidence

    $files = @(Get-ChildItem -Recurse -File -LiteralPath $localRunDirectory)
    $traces = @($files | Where-Object {
      $_.Name.Contains("perfetto-trace", [System.StringComparison]::OrdinalIgnoreCase) -and $_.Length -gt 0
    })
    if ($traces.Count -ne 3) { throw "PINNED_BENCHMARK_VALID_TRACE_COUNT_MISMATCH:$($scenario.Method)" }
    $benchmarkDataFiles = @($files | Where-Object {
      $_.Name.EndsWith("benchmarkData.json", [System.StringComparison]::OrdinalIgnoreCase) -and $_.Length -gt 0
    })
    if ($benchmarkDataFiles.Count -ne 1) { throw "PINNED_BENCHMARK_DATA_COUNT_MISMATCH:$($scenario.Method)" }
    if ((Get-Item -LiteralPath $evidencePath).Length -le 0) { throw "PINNED_BENCHMARK_EVIDENCE_EMPTY:$($scenario.Method)" }

    Assert-CcrBenchmarkData $benchmarkDataFiles[0].FullName
    Assert-CcrPinnedBenchmarkEvidence $evidence $context.ArtifactSet $runId $scenario.Method $traces.Count | Out-Null
    Assert-CcrPerformanceGate $evidence $scenario

    $results.Add([PSCustomObject]@{
      scenario = $scenario.Method
      label = $scenario.Label
      runId = $runId
      status = "PASS"
      traceCount = $traces.Count
      tracePaths = @($traces | ForEach-Object FullName)
      benchmarkDataPath = $benchmarkDataFiles[0].FullName
      evidencePath = $evidencePath
      thresholds = [PSCustomObject]@{
        publicationIntervalP50UsMax = $scenario.IntervalP50UsMax
        publishedFpsMin = $scenario.PublishedFpsMin
        rawLagMax = $scenario.RawLagMax
        outstandingForegroundTargetDepthMax = 1
        releaseAfterAcceptedTargetCount = 0
        holdPrefetchStarted = 0
        holdPrefetchCompleted = 0
        validTraceCount = 3
      }
      iterations = @($evidence.iterations)
    }) | Out-Null
  }
} catch {
  $primaryFailure = $_
} finally {
  foreach ($remoteDirectory in $remoteDirectories) {
    try {
      Remove-CcrPinnedRemoteTraceDirectory $context $remoteDirectory
    } catch {
      $cleanupFailures.Add("REMOTE_OUTPUT_CLEANUP_FAILED:${remoteDirectory}:$($_.Exception.Message)") | Out-Null
    }
  }

  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch {
    $cleanupFailures.Add("PINNED_CLEANUP_FAILED:$($_.Exception.Message)") | Out-Null
  }

  if ($settingsSaved) {
    foreach ($setting in @(
      @("global", "stay_on_while_plugged_in", $context.SavedSettings.stayAwake),
      @("system", "screen_brightness_mode", $context.SavedSettings.brightnessMode),
      @("system", "screen_brightness", $context.SavedSettings.brightness),
      @("system", "screen_off_timeout", $context.SavedSettings.screenTimeout),
      @("system", "accelerometer_rotation", $context.SavedSettings.accelerometerRotation),
      @("system", "user_rotation", $context.SavedSettings.userRotation)
    )) {
      try {
        $actual = Get-CcrPinnedDeviceSetting $context $setting[0] $setting[1]
        if ([string]$actual -cne [string]$setting[2]) {
          $cleanupFailures.Add("SETTING_RESTORE_VERIFY_FAILED:$($setting[0])/$($setting[1])") | Out-Null
        }
      } catch {
        $cleanupFailures.Add("SETTING_RESTORE_VERIFY_FAILED:$($setting[0])/$($setting[1]):$($_.Exception.Message)") | Out-Null
      }
    }
  }

  foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
    try {
      if (-not (Test-CcrPackageAbsent $context $packageName)) {
        $cleanupFailures.Add("TEST_PACKAGE_STILL_INSTALLED:$packageName") | Out-Null
      }
    } catch {
      $cleanupFailures.Add("TEST_PACKAGE_ABSENCE_VERIFY_FAILED:${packageName}:$($_.Exception.Message)") | Out-Null
    }
  }

  try {
    $debugApp = Get-CcrPinnedArtifact $context "debugApp"
    $installDebug = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "install", "-r", [string]$debugApp.path)
    if ($installDebug.exitCode -ne 0 -or $installDebug.output -notmatch "(?m)^Success\s*$") {
      throw "PINNED_DEBUG_APP_REINSTALL_FAILED"
    }
    Assert-CcrPinnedInstalledArtifact $context "debugApp"
    $launch = Invoke-CcrPinnedAdb $context @(
      "-s", $context.Serial, "shell", "am", "start", "-n", "$script:CcrPinnedAppPackage/.MainActivity"
    )
    if ($launch.exitCode -ne 0 -or $launch.output -match "(?i)error|exception") {
      throw "PINNED_DEBUG_APP_LAUNCH_FAILED"
    }
    $manualReviewReady = $true
  } catch {
    $cleanupFailures.Add("MANUAL_REVIEW_APP_PREPARE_FAILED:$($_.Exception.Message)") | Out-Null
  }

  $status = if ($null -eq $primaryFailure -and $cleanupFailures.Count -eq 0 -and $results.Count -eq 2) { "PASS" } else { "FAIL" }
  $summary = [PSCustomObject]@{
    schemaVersion = 2
    kind = "s24-navigation-perf"
    status = $status
    primaryFailure = if ($null -eq $primaryFailure) { $null } else { $primaryFailure.Exception.Message }
    cleanupFailures = @($cleanupFailures)
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    artifactManifest = $context.ArtifactSet.ManifestPath
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $context "macrobenchmarkTest").sha256
    fixedDebugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    measurementDescription = "source-equivalent pinned benchmark measurement build"
    serial = $context.Serial
    model = $context.Model
    fingerprint = $context.Fingerprint
    securityPatch = $context.SecurityPatch
    scenarios = @($results)
    manualReviewReady = $manualReviewReady
    testPackagesRemoved = -not (@($cleanupFailures) | Where-Object { $_ -match "TEST_PACKAGE" })
    settingsRestored = -not (@($cleanupFailures) | Where-Object { $_ -match "SETTING_" })
    remoteOutputsRemoved = -not (@($cleanupFailures) | Where-Object { $_ -match "REMOTE_OUTPUT" })
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  try {
    Write-CcrPerfJson $summaryPath $summary
  } catch {
    $cleanupFailures.Add("SUMMARY_WRITE_FAILED:$($_.Exception.Message)") | Out-Null
  }
}

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  $messages = [System.Collections.Generic.List[string]]::new()
  if ($null -ne $primaryFailure) { $messages.Add("PRIMARY:$($primaryFailure.Exception.Message)") | Out-Null }
  foreach ($failure in $cleanupFailures) { $messages.Add("CLEANUP:$failure") | Out-Null }
  throw ($messages -join " | ")
}

Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
