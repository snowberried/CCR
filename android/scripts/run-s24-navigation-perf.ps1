param(
  [ValidateRange(1, 4)][int]$ScenarioLimit = 4,
  [ValidateSet("all", "1080")][string]$ScenarioSet = "all",
  [ValidateRange(1, 120)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-validation-common.ps1")
$startedAt = [DateTime]::UtcNow
$context = New-CcrS24Context "s24-navigation-perf" $OutputDirectory
if (-not $Resume) {
  Clear-CcrRunArtifacts $context @("navigation-perf-summary.json") @("hold*.gradle*.log")
}
$checkpoint = Get-CcrCheckpoint $context -Resume:$Resume
if ($Resume) {
  if ([int]$checkpoint.scenarioLimit -ne $ScenarioLimit) { throw "S24_CHECKPOINT_PARAMETER_MISMATCH" }
  if ([string]$checkpoint.scenarioSet -ne $ScenarioSet) { throw "S24_CHECKPOINT_PARAMETER_MISMATCH" }
} else {
  $checkpoint | Add-Member -NotePropertyName scenarioLimit -NotePropertyValue $ScenarioLimit
  $checkpoint | Add-Member -NotePropertyName scenarioSet -NotePropertyValue $ScenarioSet
}
Save-CcrCheckpoint $context $checkpoint
$summaryPath = Join-Path $context.OutputDirectory "navigation-perf-summary.json"
$traceDirectory = Join-Path $context.OutputDirectory "traces"
[System.IO.Directory]::CreateDirectory($traceDirectory) | Out-Null
if (-not $Resume) {
  Get-ChildItem -Recurse -File -LiteralPath $traceDirectory -ErrorAction SilentlyContinue | Remove-Item -Force
}
$deadline = $startedAt.AddMinutes($MaxMinutes)
$availableScenarios = if ($ScenarioSet -eq "1080") {
  @("hold1080PlusOne", "hold1080PlusFive")
} else {
  @("hold720PlusOne", "hold720PlusFive", "hold1080PlusOne", "hold1080PlusFive")
}
$scenarios = $availableScenarios | Select-Object -First $ScenarioLimit
$completed = [int]$checkpoint.completedIterations
$status = "Pending"
$reason = "NOT_STARTED"
$failure = $null
$recovered = [System.Collections.Generic.List[string]]::new()
if ($Resume) {
  Get-ChildItem -File -LiteralPath $traceDirectory -ErrorAction SilentlyContinue |
    ForEach-Object { $recovered.Add($_.Name) }
}

function Invoke-GradleStep {
  param([string[]]$Tasks, [string]$LogStem)
  $stdout = Join-Path $context.OutputDirectory "$LogStem.gradle.log"
  $stderr = Join-Path $context.OutputDirectory "$LogStem.gradle.err.log"
  (Invoke-CcrTimedProcess `
    (Join-Path $context.AndroidRoot "gradlew.bat") `
    $Tasks `
    $deadline `
    $stdout `
    $stderr `
    "(?m)^BUILD SUCCESSFUL" `
    $context.AndroidRoot).status
}

try {
  Enter-CcrDeviceState $context
  if ($completed -lt $scenarios.Count) {
    $build = Invoke-GradleStep @("assembleInternalBenchmark", ":macrobenchmark:assembleInternalBenchmark", "--no-daemon") "build"
    if ($build -ne "PASS") {
      $status = if ($build -eq "TIME_LIMIT") { "Pending" } else { "FAIL" }
      $reason = if ($build -eq "TIME_LIMIT") { "MAX_MINUTES_REACHED_DURING_BUILD" } else { "BENCHMARK_BUILD_FAILED" }
    } else {
      while ($completed -lt $scenarios.Count -and [DateTime]::UtcNow -lt $deadline) {
        $scenario = $scenarios[$completed]
        $startedAt = [DateTime]::UtcNow
        $selector = "-Pandroid.testInstrumentationRunnerArguments.class=com.snowberried.ctcinereviewer.macrobenchmark.CcrProductMacrobenchmark#$scenario"
        $run = Invoke-GradleStep @(
          ":macrobenchmark:connectedInternalBenchmarkAndroidTest",
          $selector,
          "--no-daemon"
        ) $scenario
        $sourceRoots = @(
          (Join-Path $context.AndroidRoot "macrobenchmark\build\outputs\connected_android_test_additional_output"),
          (Join-Path $context.AndroidRoot "macrobenchmark\build\outputs\androidTest-results")
        )
        foreach ($sourceRoot in $sourceRoots) {
          if (-not (Test-Path -LiteralPath $sourceRoot)) { continue }
          Get-ChildItem -Recurse -File -LiteralPath $sourceRoot |
            Where-Object { $_.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2) -and $_.Name -match "perfetto-trace|benchmarkData|additionaltestoutput|^TEST-.*\.xml$" } |
            ForEach-Object {
              $targetName = "$scenario-$($_.Name)"
              $target = Join-Path $traceDirectory $targetName
              Copy-Item -LiteralPath $_.FullName -Destination $target -Force
              if (-not $recovered.Contains($targetName)) { $recovered.Add($targetName) }
            }
        }
        if ($run -ne "PASS") {
          $status = if ($run -eq "TIME_LIMIT") { "Pending" } else { "FAIL" }
          $reason = if ($run -eq "TIME_LIMIT") { "MAX_MINUTES_REACHED" } else { "MACROBENCHMARK_FAILED: $scenario" }
          break
        }
        $completed += 1
        $checkpoint.completedIterations = $completed
        $checkpoint.nextIteration = $completed
        Save-CcrCheckpoint $context $checkpoint
      }
    }
  }
  if ($completed -ge $scenarios.Count -and $recovered.Count -gt 0) {
    $status = "MEASURED_PENDING_ANALYSIS"
    $reason = "PERFETTO_AND_BENCHMARK_OUTPUT_RECOVERED; PERFORMANCE_GATE_NOT_AUTO_PASSED"
  } elseif ($completed -ge $scenarios.Count) {
    $status = "FAIL"
    $reason = "BENCHMARK_ARTIFACT_RECOVERY_FAILED"
  } elseif ($status -eq "Pending" -and $reason -eq "NOT_STARTED") {
    $reason = "MAX_MINUTES_REACHED"
  }
} catch {
  $failure = $_
  $status = "FAIL"
  $reason = $_.Exception.Message
} finally {
  & (Join-Path $context.AndroidRoot "gradlew.bat") --stop | Out-Null
  if ($LASTEXITCODE -ne 0) { $context.CleanupFailures.Add("GRADLE_STOP_FAILED") | Out-Null }
  $cleanupFailures = @(Complete-CcrCleanup $context @("com.snowberried.ctcinereviewer.macrobenchmark"))
  $batteryAtEnd = Get-CcrBatteryStateSafe $context
  $cleanupFailures = @($context.CleanupFailures)
  if ($cleanupFailures.Count -gt 0 -and $status -ne "FAIL") {
    $status = "FAIL"
    $reason = "CLEANUP_FAILED"
  }
  $checkpoint.completedIterations = $completed
  $checkpoint.nextIteration = $completed
  $checkpoint.status = $status
  Save-CcrCheckpoint $context $checkpoint
  Save-CcrJson $summaryPath ([PSCustomObject]@{
    schemaVersion = 1; kind = "s24-navigation-perf"; status = $status; reason = $reason
    versionName = $script:CcrExpectedVersionName; versionCode = $script:CcrExpectedVersionCode
    commitSha = $context.CommitSha; model = $context.Model
    scenarios = $scenarios; completedScenarios = $completed; recoveredFiles = $recovered
    alpha3Baseline = [PSCustomObject]@{
      hold1080PlusOneIntervalP50Ms = 188.9; hold1080PlusOneFps = 4.529
      hold1080PlusFiveIntervalP50Ms = 217.0; hold1080PlusFiveFps = 4.299
    }
    gate = "Pending until counters prove >=30% interval reduction, >=1.5x fps, outstanding target depth <=1, +1 raw lag <=1, +5 raw lag <=5, and no correctness regression"
    sourceIdentity = "clean committed worktree required"
    chargingAtStart = $context.BatteryAtStart.pluggedOrCharging
    batteryAtStart = $context.BatteryAtStart; batteryAtEnd = $batteryAtEnd
    cleanupFailures = $cleanupFailures
    syntheticOnly = $true; containsRealMediaMetadata = $false
  })
}

if ($failure) { throw $failure }
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
