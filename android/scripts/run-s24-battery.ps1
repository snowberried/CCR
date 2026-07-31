param(
  [ValidateSet("idle", "navigation")][string]$Scenario = "idle",
  [ValidateRange(1, 60)][int]$Minutes = 30,
  [ValidateRange(1, 120)][int]$MaxMinutes = 35,
  [switch]$Resume,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-validation-common.ps1")
$startedAt = [DateTime]::UtcNow
$context = New-CcrS24Context "s24-battery-$Scenario" $OutputDirectory
if (-not $Resume) {
  Clear-CcrRunArtifacts $context `
    @("battery-$Scenario-summary.json", "representative-battery-$Scenario-report.json") `
    @("battery-$Scenario*.log")
}
$checkpoint = Get-CcrCheckpoint $context -Resume:$Resume
if ($Resume) {
  if ([int]$checkpoint.measurementMinutes -ne $Minutes) { throw "S24_CHECKPOINT_PARAMETER_MISMATCH" }
} else {
  $checkpoint | Add-Member -NotePropertyName measurementMinutes -NotePropertyValue $Minutes
  $checkpoint | Add-Member -NotePropertyName resumeGranularity -NotePropertyValue "whole-instrumentation-restart"
}
Save-CcrCheckpoint $context $checkpoint
$reportName = "representative-battery-$Scenario-report.json"
$summaryPath = Join-Path $context.OutputDirectory "battery-$Scenario-summary.json"
$deadline = $startedAt.AddMinutes($MaxMinutes)
$status = "Pending"
$reason = "NOT_STARTED"
$failure = $null
$pulled = $false

try {
  if ([int]$checkpoint.completedIterations -ge 1 -and (Test-Path -LiteralPath (Join-Path $context.OutputDirectory $reportName))) {
    $measurement = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $context.OutputDirectory $reportName) | ConvertFrom-Json
    $status = [string]$measurement.status
    $reason = "RESUMED_COMPLETED_CHECKPOINT"
    $pulled = $true
  } elseif ($context.BatteryAtStart.pluggedOrCharging) {
    $status = "NOT_EVALUABLE"
    $reason = "USB_OR_CHARGING_AT_START"
  } else {
    Enter-CcrDeviceState $context
    $source = Join-Path $context.AndroidRoot "app\src\androidTest\java\com\snowberried\ctcinereviewer\gate\RepresentativeResolutionEnduranceTest.kt"
    if (-not (Test-CcrInstrumentationContract $source "RepresentativeBatteryValidationTest" "unpluggedThirtyMinuteMeasurementWhenRequested")) {
      $reason = "INSTRUMENTATION_CONTRACT_NOT_IMPLEMENTED"
    } else {
      Install-CcrDebugTestApks $context $deadline
      Clear-CcrAppReport $context $reportName
      $run = Invoke-CcrInstrumentation $context `
        "com.snowberried.ctcinereviewer.gate.RepresentativeBatteryValidationTest#unpluggedThirtyMinuteMeasurementWhenRequested" `
        @{ batteryScenario = $Scenario; batteryMinutes = $Minutes } "battery-$Scenario" $deadline
      $pulled = Copy-CcrAppReport $context $reportName
      if ($run.status -eq "PASS" -and $pulled) {
        $measurement = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $context.OutputDirectory $reportName) | ConvertFrom-Json
        $status = [string]$measurement.status
        $reason = [string]$measurement.body.reason
        $checkpoint.completedIterations = 1
        $checkpoint.nextIteration = 1
      } elseif ($run.status -eq "TIME_LIMIT") {
        $reason = "MAX_MINUTES_REACHED"
      } else {
        $status = "FAIL"
        $reason = "INSTRUMENTATION_OR_REPORT_FAILED"
      }
    }
  }
} catch {
  $reason = $_.Exception.Message
  if ($reason -like "S24_MAX_MINUTES_REACHED*") {
    $status = "Pending"
  } else {
    $failure = $_
    $status = "FAIL"
  }
} finally {
  if (-not $pulled) {
    try { $pulled = Copy-CcrAppReport $context $reportName } catch { $pulled = $false }
  }
  $cleanupFailures = @(Complete-CcrCleanup $context)
  $batteryAtEnd = Get-CcrBatteryStateSafe $context
  $cleanupFailures = @($context.CleanupFailures)
  if ($cleanupFailures.Count -gt 0 -and $status -ne "FAIL") {
    $status = "FAIL"
    $reason = "CLEANUP_FAILED"
  }
  $checkpoint.status = $status
  Save-CcrCheckpoint $context $checkpoint
  Save-CcrJson $summaryPath ([PSCustomObject]@{
    schemaVersion = 1; kind = "s24-battery-$Scenario"; status = $status; reason = $reason
    versionName = $script:CcrExpectedVersionName; versionCode = $script:CcrExpectedVersionCode
    commitSha = $context.CommitSha; model = $context.Model; scenario = $Scenario
    requestedMinutes = $Minutes; drainPassClaimed = $false; reportRecovered = [bool]$pulled
    chargingAtStart = $context.BatteryAtStart.pluggedOrCharging
    batteryAtStart = $context.BatteryAtStart; batteryAtEnd = $batteryAtEnd
    cleanupFailures = $cleanupFailures; resumeGranularity = "whole-instrumentation-restart"
    syntheticOnly = $true; containsRealMediaMetadata = $false
  })
}

if ($failure) { throw $failure }
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
