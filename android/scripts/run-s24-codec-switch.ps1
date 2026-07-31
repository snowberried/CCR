param(
  [ValidateRange(1, 5000)][int]$Iterations = 500,
  [ValidateRange(1, 100)][int]$ChunkSize = 25,
  [ValidateRange(1, 120)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-validation-common.ps1")
$startedAt = [DateTime]::UtcNow
$context = New-CcrS24Context "s24-codec-switch" $OutputDirectory
if (-not $Resume) {
  Clear-CcrRunArtifacts $context @("codec-switch-summary.json") @("codec-switch-*.json", "codec-switch-*.log")
}
$checkpoint = Get-CcrCheckpoint $context -Resume:$Resume
if ($Resume) {
  if ([int]$checkpoint.requestedIterations -ne $Iterations -or [int]$checkpoint.chunkSize -ne $ChunkSize) {
    throw "S24_CHECKPOINT_PARAMETER_MISMATCH"
  }
} else {
  $checkpoint | Add-Member -NotePropertyName requestedIterations -NotePropertyValue $Iterations
  $checkpoint | Add-Member -NotePropertyName chunkSize -NotePropertyValue $ChunkSize
}
Save-CcrCheckpoint $context $checkpoint
$summaryPath = Join-Path $context.OutputDirectory "codec-switch-summary.json"
$deadline = $startedAt.AddMinutes($MaxMinutes)
$completed = [int]$checkpoint.completedIterations
$status = "Pending"
$reason = "NOT_STARTED"
$failure = $null
$reports = [System.Collections.Generic.List[string]]::new()
if ($Resume) {
  Get-ChildItem -File -LiteralPath $context.OutputDirectory -Filter "codec-switch-*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "codec-switch-summary.json" } |
    ForEach-Object { $reports.Add($_.Name) }
}

try {
  Enter-CcrDeviceState $context
  $source = Join-Path $context.AndroidRoot "app\src\androidTest\java\com\snowberried\ctcinereviewer\gate\RepresentativeResolutionEnduranceTest.kt"
  if (-not (Test-CcrInstrumentationContract $source "RepresentativeMemoryEnduranceTest" "codecSwitchWhenRequested")) {
    $reason = "INSTRUMENTATION_CONTRACT_NOT_IMPLEMENTED"
  } elseif ($completed -ge $Iterations) {
    $status = "INCONCLUSIVE"
    $reason = "RESUMED_COMPLETED_CHECKPOINT_RESOURCE_PLATEAU_NOT_PROVEN"
  } else {
    Install-CcrDebugTestApks $context $deadline
    while ($completed -lt $Iterations -and [DateTime]::UtcNow -lt $deadline) {
      $count = [Math]::Min($ChunkSize, $Iterations - $completed)
      $first = $completed
      $last = $completed + $count - 1
      $appReport = "representative-codec-switch-report.json"
      Clear-CcrAppReport $context $appReport
      $run = Invoke-CcrInstrumentation $context `
        "com.snowberried.ctcinereviewer.gate.RepresentativeMemoryEnduranceTest#codecSwitchWhenRequested" `
        @{ representativeSwitchIterations = $count } ("codec-switch-{0:D5}-{1:D5}" -f $first, $last) $deadline
      $targetName = "codec-switch-{0:D5}-{1:D5}.json" -f $first, $last
      $pulled = Copy-CcrAppReport $context $appReport $targetName
      if ($pulled) { $reports.Add($targetName) }
      if ($run.status -ne "PASS" -or -not $pulled) {
        $reason = if ($run.status -eq "TIME_LIMIT") { "MAX_MINUTES_REACHED" } else { "INSTRUMENTATION_OR_REPORT_FAILED" }
        if ($run.status -ne "TIME_LIMIT") { $status = "FAIL" }
        break
      }
      $completed += $count
      $checkpoint.completedIterations = $completed
      $checkpoint.nextIteration = $completed
      $checkpoint.status = "Pending"
      Save-CcrCheckpoint $context $checkpoint
    }
    if ($completed -ge $Iterations) {
      $status = "INCONCLUSIVE"
      $reason = "CHUNKED_CORRECTNESS_COMPLETE_RESOURCE_PLATEAU_NOT_PROVEN"
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
    schemaVersion = 1; kind = "s24-codec-switch"; status = $status; reason = $reason
    versionName = $script:CcrExpectedVersionName; versionCode = $script:CcrExpectedVersionCode
    commitSha = $context.CommitSha; model = $context.Model
    requestedIterations = $Iterations; completedIterations = $completed; chunkSize = $ChunkSize
    continuity = "CHUNKED_SAFE_CHECKPOINTS; not a continuous 500-switch resource plateau proof"
    recoveredReports = $reports; chargingAtStart = $context.BatteryAtStart.pluggedOrCharging
    batteryAtStart = $context.BatteryAtStart; batteryAtEnd = $batteryAtEnd
    cleanupFailures = $cleanupFailures
    syntheticOnly = $true; containsRealMediaMetadata = $false
  })
}

if ($failure) { throw $failure }
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
