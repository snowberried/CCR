param(
  [ValidateRange(1, 500)][int]$Iterations = 50,
  [ValidateRange(1, 120)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-validation-common.ps1")
$startedAt = [DateTime]::UtcNow
$context = New-CcrS24Context "s24-lifecycle" $OutputDirectory
if (-not $Resume) {
  Clear-CcrRunArtifacts $context @("lifecycle-summary.json") @("lifecycle-*.log")
}
$checkpoint = Get-CcrCheckpoint $context -Resume:$Resume
if ($Resume) {
  if ([int]$checkpoint.requestedIterations -ne $Iterations) { throw "S24_CHECKPOINT_PARAMETER_MISMATCH" }
} else {
  $checkpoint | Add-Member -NotePropertyName requestedIterations -NotePropertyValue $Iterations
}
Save-CcrCheckpoint $context $checkpoint
$summaryPath = Join-Path $context.OutputDirectory "lifecycle-summary.json"
$deadline = $startedAt.AddMinutes($MaxMinutes)
$completed = [int]$checkpoint.completedIterations
$status = "Pending"
$reason = "NOT_STARTED"
$failure = $null

try {
  Enter-CcrDeviceState $context
  $source = Join-Path $context.AndroidRoot "app\src\androidTest\java\com\snowberried\ctcinereviewer\ViewerLifecycleTest.kt"
  if (-not (Test-CcrInstrumentationContract $source "ViewerLifecycleTest" "decodeDuringRotationAndRepeatedBackgroundRestorePublishRequestedFrame")) {
    $reason = "INSTRUMENTATION_CONTRACT_NOT_IMPLEMENTED"
  } elseif ($completed -ge $Iterations) {
    $status = "INCONCLUSIVE"
    $reason = "RESUMED_COMPLETED_CHECKPOINT_RESOURCE_PLATEAU_NOT_MEASURED"
  } else {
    Install-CcrDebugTestApks $context $deadline
    while ($completed -lt $Iterations -and [DateTime]::UtcNow -lt $deadline) {
      $run = Invoke-CcrInstrumentation $context `
        "com.snowberried.ctcinereviewer.ViewerLifecycleTest#decodeDuringRotationAndRepeatedBackgroundRestorePublishRequestedFrame" `
        @{} ("lifecycle-{0:D4}" -f $completed) $deadline
      if ($run.status -ne "PASS") {
        $reason = if ($run.status -eq "TIME_LIMIT") { "MAX_MINUTES_REACHED" } else { "LIFECYCLE_CORRECTNESS_FAILED" }
        if ($run.status -ne "TIME_LIMIT") { $status = "FAIL" }
        break
      }
      $completed += 1
      $checkpoint.completedIterations = $completed
      $checkpoint.nextIteration = $completed
      Save-CcrCheckpoint $context $checkpoint
    }
    if ($completed -ge $Iterations) {
      $status = "INCONCLUSIVE"
      $reason = "CORRECTNESS_PASSED_RESOURCE_PLATEAU_NOT_MEASURED"
    } elseif ($status -ne "FAIL") {
      $status = "Pending"
      if ($reason -eq "NOT_STARTED") { $reason = "MAX_MINUTES_REACHED" }
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
  $cleanupFailures = @(Complete-CcrCleanup $context)
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
    schemaVersion = 1; kind = "s24-lifecycle"; status = $status; reason = $reason
    versionName = $script:CcrExpectedVersionName; versionCode = $script:CcrExpectedVersionCode
    commitSha = $context.CommitSha; model = $context.Model
    requestedIterations = $Iterations; completedIterations = $completed
    perIterationContract = "2 rotations + 3 background/foreground Surface detach/reattach cycles"
    resourcePlateau = "INCONCLUSIVE_NO_PER_CYCLE_RESOURCE_SAMPLES"
    chargingAtStart = $context.BatteryAtStart.pluggedOrCharging
    batteryAtStart = $context.BatteryAtStart; batteryAtEnd = $batteryAtEnd
    cleanupFailures = $cleanupFailures
    syntheticOnly = $true; containsRealMediaMetadata = $false
  })
}

if ($failure) { throw $failure }
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
