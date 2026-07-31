param(
  [ValidateRange(1, 30)][int]$IdleMinutes = 10,
  [ValidateRange(1, 60)][int]$MaxMinutes = 15,
  [switch]$Resume,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-validation-common.ps1")
$startedAt = [DateTime]::UtcNow
$context = New-CcrS24Context "s24-idle" $OutputDirectory
if (-not $Resume) {
  Clear-CcrRunArtifacts $context `
    @("idle-summary.json", "representative-idle-report.json") `
    @("idle*.log")
}
$checkpoint = Get-CcrCheckpoint $context -Resume:$Resume
if ($Resume) {
  if ([int]$checkpoint.idleMinutes -ne $IdleMinutes) { throw "S24_CHECKPOINT_PARAMETER_MISMATCH" }
} else {
  $checkpoint | Add-Member -NotePropertyName idleMinutes -NotePropertyValue $IdleMinutes
  $checkpoint | Add-Member -NotePropertyName resumeGranularity -NotePropertyValue "whole-instrumentation-restart"
}
Save-CcrCheckpoint $context $checkpoint
$reportName = "representative-idle-report.json"
$summaryPath = Join-Path $context.OutputDirectory "idle-summary.json"
$deadline = $startedAt.AddMinutes($MaxMinutes)
$status = "Pending"
$reason = "NOT_STARTED"
$failure = $null
$pulled = $false

try {
  Enter-CcrDeviceState $context
  if ([int]$checkpoint.completedIterations -ge 1 -and (Test-Path -LiteralPath (Join-Path $context.OutputDirectory $reportName))) {
    $status = "PASS"
    $reason = "RESUMED_COMPLETED_CHECKPOINT"
  } else {
    $source = Join-Path $context.AndroidRoot "app\src\androidTest\java\com\snowberried\ctcinereviewer\gate\RepresentativeResolutionEnduranceTest.kt"
    if (-not (Test-CcrInstrumentationContract $source "RepresentativeMemoryEnduranceTest" "idleActivityRemainsZeroWhenRequested")) {
      $status = "Pending"
      $reason = "INSTRUMENTATION_CONTRACT_NOT_IMPLEMENTED"
    } else {
      Install-CcrDebugTestApks $context $deadline
      Clear-CcrAppReport $context $reportName
      $run = Invoke-CcrInstrumentation $context `
        "com.snowberried.ctcinereviewer.gate.RepresentativeMemoryEnduranceTest#idleActivityRemainsZeroWhenRequested" `
        @{ representativeIdleMinutes = $IdleMinutes } "idle" $deadline
      $pulled = Copy-CcrAppReport $context $reportName
      if ($run.status -eq "PASS" -and $pulled) {
        $measurement = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $context.OutputDirectory $reportName) | ConvertFrom-Json
        if ($measurement.status -eq "PASS") {
          $checkpoint.completedIterations = 1
          $checkpoint.nextIteration = 1
          $status = "PASS"
          $reason = "IDLE_ACTIVITY_ZERO"
        } else {
          $status = "FAIL"
          $reason = "IDLE_REPORT_FAILED"
        }
      } elseif ($run.status -eq "TIME_LIMIT") {
        $status = "Pending"
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
    schemaVersion = 1; kind = "s24-idle"; status = $status; reason = $reason
    versionName = $script:CcrExpectedVersionName; versionCode = $script:CcrExpectedVersionCode
    commitSha = $context.CommitSha; model = $context.Model; durationMinutes = $IdleMinutes
    reportRecovered = [bool]$pulled; chargingAtStart = $context.BatteryAtStart.pluggedOrCharging
    batteryAtStart = $context.BatteryAtStart; batteryAtEnd = $batteryAtEnd
    cleanupFailures = $cleanupFailures; resumeGranularity = "whole-instrumentation-restart"
    syntheticOnly = $true; containsRealMediaMetadata = $false
  })
}

if ($failure) { throw $failure }
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
