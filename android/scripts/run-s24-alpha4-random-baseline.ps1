param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateRange(1, 240)][int]$MaxMinutes = 25,
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")
. (Join-Path $PSScriptRoot "alpha4-baseline-contract.ps1")
$deadlineUtc = New-CcrAlpha4DeadlineUtc -MaxMinutes $MaxMinutes

$testClass = "com.snowberried.ctcinereviewer.gate.Alpha4RandomSeekBaselineTest#deterministicPilotRandomSeekAlpha4Baseline"
$reportName = "s24-alpha4-random-seek-baseline-v1.json"
$summaryName = if ($PreflightOnly) { "alpha4-random-baseline-preflight-v1.json" } else { "alpha4-random-baseline-v1-summary.json" }

function Write-CcrAlpha4RandomJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  [System.IO.File]::SetAttributes($fullPath, [System.IO.FileAttributes]::ReadOnly)
  return $fullPath
}

function Read-CcrAlpha4RandomJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Failure)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $Failure }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw $Failure }
}

function Assert-CcrAlpha4RandomFileIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$Failure
  )
  if (-not (Test-CcrPinnedPathWithin $Path $OutputRoot) -or
      -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
      $ExpectedSha256 -notmatch '^[0-9a-f]{64}$' -or
      (Get-Item -LiteralPath $Path).Length -le 0 -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
    throw $Failure
  }
}

function New-CcrAlpha4RandomCheckpointBase {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][int]$MaxMinutes
  )
  return [ordered]@{
    schemaVersion = 1
    kind = $Kind
    status = $Status
    artifactManifestSha256 = $Context.ArtifactSet.ManifestSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $Context "debugTest").sha256
    device = [ordered]@{
      serial = $Context.Serial
      fingerprint = $Context.Fingerprint
    }
    parameters = [ordered]@{
      maxMinutes = $MaxMinutes
      testClass = $testClass
      reportName = $reportName
      resumeGranularity = "whole-instrumentation-restart; complete-pass-evidence-only-reuse"
    }
  }
}

function Assert-CcrAlpha4RandomSummaryIdentity {
  param([object]$Summary, [object]$Context, [int]$ExpectedMaxMinutes)
  if ([string]$Summary.kind -cne "s24-alpha4-random-baseline" -or
      [string]$Summary.artifactManifestSha256 -cne $Context.ArtifactSet.ManifestSha256 -or
      [int]$Summary.artifactSetRevision -ne $script:CcrPinnedArtifactSetRevision -or
      [string]$Summary.runtimeSourceSha -cne $Context.ArtifactSet.RuntimeSourceSha -or
      [string]$Summary.harnessSourceSha -cne $Context.ArtifactSet.HarnessSourceSha -or
      [string]$Summary.runtimeInputsTreeSha256 -cne $Context.ArtifactSet.RuntimeInputsTreeSha256 -or
      [string]$Summary.debugAppSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugApp").sha256 -or
      [string]$Summary.debugTestApkSha256 -cne [string](Get-CcrPinnedArtifact $Context "debugTest").sha256 -or
      [string]$Summary.device.serial -cne $Context.Serial -or
      [string]$Summary.device.fingerprint -cne $Context.Fingerprint -or
      [int]$Summary.maxMinutes -ne $ExpectedMaxMinutes -or
      [string]$Summary.resumeGranularity -cne
        "whole-instrumentation-restart; complete-pass-evidence-only-reuse") {
    throw "ALPHA4_RANDOM_RESUME_SUMMARY_IDENTITY_MISMATCH"
  }
  return $Summary
}

function Assert-CcrAlpha4RandomCompletedSummary {
  param([object]$Summary, [object]$Context, [int]$ExpectedMaxMinutes)
  Assert-CcrAlpha4RandomSummaryIdentity $Summary $Context $ExpectedMaxMinutes | Out-Null
  if ([string]$Summary.status -cne "PASS" -or [string]$Summary.baselineCompleteness -cne "COMPLETE_TRACE_MERGED" -or
      [string]$Summary.decoderStageTimingStatus -cne "PASS" -or
      [string]$Summary.deterministicNodeContractValidation -cne "PASS") {
    throw "ALPHA4_RANDOM_RESUME_PASS_SUMMARY_INCOMPLETE"
  }
  foreach ($artifact in @(
    @([string]$Summary.report, [string]$Summary.reportSha256, "ALPHA4_RANDOM_RESUME_REPORT_IDENTITY_MISMATCH"),
    @([string]$Summary.rawTrace, [string]$Summary.rawTraceSha256, "ALPHA4_RANDOM_RESUME_TRACE_IDENTITY_MISMATCH"),
    @([string]$Summary.stageTiming, [string]$Summary.stageTimingSha256, "ALPHA4_RANDOM_RESUME_STAGE_TIMING_IDENTITY_MISMATCH"),
    @([string]$Summary.mergedReport, [string]$Summary.mergedReportSha256, "ALPHA4_RANDOM_RESUME_MERGED_REPORT_IDENTITY_MISMATCH")
  )) {
    Assert-CcrAlpha4RandomFileIdentity $artifact[0] $artifact[1] $Context.OutputDirectory $artifact[2]
  }
  $report = Read-CcrAlpha4RandomJson ([string]$Summary.report) "ALPHA4_RANDOM_RESUME_REPORT_JSON_INVALID"
  if ([string]$report.runId -cne [string]$Summary.runId) { throw "ALPHA4_RANDOM_RESUME_REPORT_RUN_ID_MISMATCH" }
  Assert-CcrAlpha4RandomBaselineReport $report $Context.ArtifactSet.RuntimeSourceSha `
    $Context.ArtifactSet.RuntimeInputsTreeSha256 $Context.ArtifactSet.HarnessSourceSha `
    ([string](Get-CcrPinnedArtifact $Context "debugApp").sha256) `
    ([string](Get-CcrPinnedArtifact $Context "debugTest").sha256) | Out-Null
  Invoke-CcrAlpha4NodeReportValidation ([string]$Summary.report) $Context.ArtifactSet.HarnessSourceSha `
    ([string](Get-CcrPinnedArtifact $Context "debugTest").sha256)
  $stage = Read-CcrAlpha4RandomJson ([string]$Summary.stageTiming) "ALPHA4_RANDOM_RESUME_STAGE_TIMING_JSON_INVALID"
  $recomputedTimings = @(Get-CcrAlpha4TraceStageTiming -TracePath ([string]$Summary.rawTrace) -Report $report)
  if ([string]$stage.kind -cne "alpha4-random-source-equivalent-timing-stage-timing" -or
      [string]$stage.status -cne "PASS" -or [string]$stage.runId -cne [string]$Summary.runId -or
      [string]$stage.traceSha256 -cne [string]$Summary.rawTraceSha256 -or
      [int]$stage.timingCount -ne 250 -or
      (($recomputedTimings | ConvertTo-Json -Depth 12 -Compress) -cne
       (@($stage.timings) | ConvertTo-Json -Depth 12 -Compress))) {
    throw "ALPHA4_RANDOM_RESUME_STAGE_TIMING_CONTENT_MISMATCH"
  }
  $merged = Read-CcrAlpha4RandomJson ([string]$Summary.mergedReport) "ALPHA4_RANDOM_RESUME_MERGED_REPORT_JSON_INVALID"
  Assert-CcrAlpha4MergedBaselineReport $merged | Out-Null
  $recomputedMerged = Merge-CcrAlpha4TraceStageTiming $report $recomputedTimings ([string]$Summary.rawTraceSha256)
  if (($recomputedMerged | ConvertTo-Json -Depth 20 -Compress) -cne ($merged | ConvertTo-Json -Depth 20 -Compress)) {
    throw "ALPHA4_RANDOM_RESUME_MERGED_REPORT_CONTENT_MISMATCH"
  }
  return $Summary
}

function Assert-CcrAlpha4RandomSettingsRestored {
  param([Parameter(Mandatory = $true)][object]$Context)
  foreach ($setting in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    $actual = Get-CcrPinnedDeviceSetting $Context $setting[0] $setting[1]
    if ([string]$actual -cne [string]$setting[2]) {
      throw "ALPHA4_RANDOM_BASELINE_SETTING_RESTORE_MISMATCH:$($setting[0])/$($setting[1])"
    }
  }
}

function Start-CcrAlpha4RandomTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$RemotePath)
  if ($RemotePath -notmatch '^/data/local/tmp/ccr-alpha4-random-[A-Za-z0-9._-]+\.atrace$') {
    throw "ALPHA4_RANDOM_BASELINE_TRACE_PATH_INVALID"
  }
  $categories = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace", "--list_categories")
  if ($categories.exitCode -ne 0 -or $categories.output -notmatch '(?m)^\s*view\s+-') {
    throw "ALPHA4_RANDOM_BASELINE_ATRACE_VIEW_UNAVAILABLE"
  }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_STALE_TRACE_CLEAR_FAILED" }
  $start = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "shell", "atrace", "--async_start", "-c", "-b", "65536",
    "-a", $script:CcrPinnedAppPackage, "view"
  )
  if ($start.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_TRACE_START_FAILED" }
}

function Stop-CcrAlpha4RandomTrace {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath
  )
  if (Test-Path -LiteralPath $LocalPath) { throw "ALPHA4_RANDOM_BASELINE_LOCAL_TRACE_ALREADY_EXISTS" }
  $stop = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "atrace --async_stop > $RemotePath")
  if ($stop.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_TRACE_STOP_FAILED" }
  $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $RemotePath, $LocalPath)
  if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $LocalPath -PathType Leaf) -or
      (Get-Item -LiteralPath $LocalPath).Length -le 0) {
    throw "ALPHA4_RANDOM_BASELINE_TRACE_PULL_FAILED"
  }
  return $LocalPath
}

function Remove-CcrAlpha4RandomRemoteTrace {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$RemotePath)
  if (-not $RemotePath) { return }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-f", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_REMOTE_TRACE_REMOVE_FAILED" }
  $verify = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "ls", "-d", $RemotePath)
  if ($verify.exitCode -eq 0) { throw "ALPHA4_RANDOM_BASELINE_REMOTE_TRACE_STILL_PRESENT" }
}

function Save-CcrAlpha4FailedRandomReport {
  param([object]$Context, [string]$RunId, [string]$TargetPath)
  if (-not $RunId -or (Test-Path -LiteralPath $TargetPath)) { return $null }
  $pull = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "exec-out", "run-as", $script:CcrPinnedAppPackage, "cat", "files/$reportName"
  )
  if ($pull.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($pull.output)) { return $null }
  try { $report = $pull.output | ConvertFrom-Json } catch { return $null }
  if ([string]$report.runId -cne $RunId -or $report.syntheticOnly -ne $true -or $report.containsRealMediaMetadata -ne $false) {
    return $null
  }
  $serialized = $report | ConvertTo-Json -Depth 20 -Compress
  if (Test-CcrAlpha4PrivateMediaReference $serialized) {
    return $null
  }
  return Write-CcrAlpha4RandomJson $TargetPath $report
}

function Invoke-CcrAlpha4NodeReportValidation {
  param(
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [Parameter(Mandatory = $true)][string]$ExpectedHarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$ExpectedTestApkSha256
  )
  $node = Get-Command node.exe, node -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $node) { throw "ALPHA4_RANDOM_BASELINE_NODE_VALIDATOR_UNAVAILABLE" }
  $modulePath = Join-Path (Get-CcrPinnedRepoRoot) "android\tools\alpha4-baseline-contract.mjs"
  if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "ALPHA4_RANDOM_BASELINE_NODE_CONTRACT_MISSING"
  }
  $moduleUri = ([Uri][System.IO.Path]::GetFullPath($modulePath)).AbsoluteUri
  $validationScript = @'
(async () => {
const fs = await import("node:fs");
const contract = await import(process.argv[2]);
const report = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
contract.validateAlpha4BaselineReport(report, {
  expectedHarnessSourceSha: process.argv[4],
  expectedTestApkSha256: process.argv[5],
});
})().catch(() => process.exit(1));
'@
  $encodedValidationScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($validationScript))
  $bootstrap = 'eval(Buffer.from(process.argv[1],String.fromCharCode(98,97,115,101,54,52)).toString())'
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $node.Source --input-type=module --eval $bootstrap $encodedValidationScript `
      $moduleUri ([System.IO.Path]::GetFullPath($ReportPath)) $ExpectedHarnessSourceSha $ExpectedTestApkSha256 2>&1)
    $exitCode = [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_NODE_CONTRACT_REJECTED" }
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "random-preflight"
$summaryPath = Join-Path $context.OutputDirectory $summaryName
if ($Resume -and $PreflightOnly) { throw "ALPHA4_RANDOM_RESUME_PREFLIGHT_ONLY_CONFLICT" }

if ($PreflightOnly) {
  if (Test-Path -LiteralPath $summaryPath) { throw "ALPHA4_RANDOM_BASELINE_SUMMARY_ALREADY_EXISTS:$summaryName" }
  $preflight = [ordered]@{
    schemaVersion = 1
    kind = "s24-alpha4-random-baseline-preflight"
    status = "PASS"
    preflightOnly = $true
    deviceMutationCount = 0
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    device = [ordered]@{
      serial = $context.Serial
      model = $context.Model
      fingerprint = $context.Fingerprint
      securityPatch = $context.SecurityPatch
      sdk = $context.Sdk
    }
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    maxMinutes = $MaxMinutes
    deadlineUtc = $deadlineUtc.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
  }
  $path = Write-CcrAlpha4RandomJson $summaryPath $preflight
  Get-Content -Raw -Encoding UTF8 -LiteralPath $path
  return
}

$primaryFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$mutationStarted = $false
$settingsSaved = $false
$sessionCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha4-random-00-session.json"
$sessionCheckpointSha256 = $null
$attemptStartedCheckpointPath = $null
$attemptStartedCheckpointSha256 = $null
$attemptFailedCheckpointPath = $null
$attemptPassCheckpointPath = $null
$preservedPriorSummaryPath = $null

if ($Resume) {
  $sessionCheckpoint = Read-CcrAlpha4RandomJson $sessionCheckpointPath "ALPHA4_RANDOM_RESUME_SESSION_CHECKPOINT_MISSING_OR_INVALID"
  Assert-CcrAlpha4RandomSessionCheckpointIdentity $sessionCheckpoint $context $MaxMinutes $testClass $reportName | Out-Null
  $sessionCheckpointSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sessionCheckpointPath).Hash.ToLowerInvariant()
  $context | Add-Member -Force -NotePropertyName SavedSettings -NotePropertyValue $sessionCheckpoint.savedSettings
  $settingsSaved = $true
  try {
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    $existingSummary = Read-CcrAlpha4RandomJson $summaryPath "ALPHA4_RANDOM_RESUME_SUMMARY_INVALID"
    Assert-CcrAlpha4RandomSummaryIdentity $existingSummary $context $MaxMinutes | Out-Null
    $restartIncompletePass = $false
    if ([string]$existingSummary.status -ceq "PASS") {
      $passCheckpoints = @(Get-ChildItem -LiteralPath $context.OutputDirectory -File -Filter "checkpoint-alpha4-random-attempt-*-pass.json")
      if ($passCheckpoints.Count -eq 0) {
        $preservedPriorSummaryPath = Join-Path $context.OutputDirectory (
          "alpha4-random-baseline-v1-prior-incomplete-pass-$([Guid]::NewGuid().ToString('N')).json"
        )
        [System.IO.File]::SetAttributes($summaryPath, [System.IO.FileAttributes]::Normal)
        Move-Item -LiteralPath $summaryPath -Destination $preservedPriorSummaryPath
        [System.IO.File]::SetAttributes($preservedPriorSummaryPath, [System.IO.FileAttributes]::ReadOnly)
        $restartIncompletePass = $true
      } elseif ($passCheckpoints.Count -eq 1) {
        $passCheckpoint = Read-CcrAlpha4RandomJson $passCheckpoints[0].FullName "ALPHA4_RANDOM_RESUME_PASS_CHECKPOINT_INVALID"
        if ([string]$passCheckpoint.kind -cne "s24-alpha4-random-attempt-checkpoint" -or
            [string]$passCheckpoint.status -cne "PASS" -or
            [string]$passCheckpoint.runId -cne [string]$existingSummary.runId -or
            [string]$passCheckpoint.sessionCheckpointSha256 -cne $sessionCheckpointSha256 -or
            [string]$passCheckpoint.summary -cne $summaryPath -or
            [string]$passCheckpoint.summarySha256 -cne
              (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash.ToLowerInvariant()) {
          throw "ALPHA4_RANDOM_RESUME_PASS_CHECKPOINT_IDENTITY_MISMATCH"
        }
        Assert-CcrAlpha4RandomCompletedSummary $existingSummary $context $MaxMinutes | Out-Null
        Assert-CcrPinnedInstalledArtifact $context "debugApp"
        Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
        return
      } else {
        throw "ALPHA4_RANDOM_RESUME_PASS_CHECKPOINT_COUNT_MISMATCH:$($passCheckpoints.Count)"
      }
    }
    if (-not $restartIncompletePass) {
      if ([string]$existingSummary.status -cne "FAIL") { throw "ALPHA4_RANDOM_RESUME_SUMMARY_STATUS_INVALID" }
      $preservedPriorSummaryPath = Join-Path $context.OutputDirectory (
        "alpha4-random-baseline-v1-prior-failure-$([Guid]::NewGuid().ToString('N')).json"
      )
      [System.IO.File]::SetAttributes($summaryPath, [System.IO.FileAttributes]::Normal)
      Move-Item -LiteralPath $summaryPath -Destination $preservedPriorSummaryPath
      [System.IO.File]::SetAttributes($preservedPriorSummaryPath, [System.IO.FileAttributes]::ReadOnly)
    }
    } else {
      foreach ($orphanPassCheckpoint in @(
        Get-ChildItem -LiteralPath $context.OutputDirectory -File -Filter "checkpoint-alpha4-random-attempt-*-pass.json"
      )) {
        $preservedCheckpoint = Join-Path $context.OutputDirectory (
          "$([System.IO.Path]::GetFileNameWithoutExtension($orphanPassCheckpoint.Name))-prior-incomplete-$([Guid]::NewGuid().ToString('N')).json"
        )
        [System.IO.File]::SetAttributes($orphanPassCheckpoint.FullName, [System.IO.FileAttributes]::Normal)
        Move-Item -LiteralPath $orphanPassCheckpoint.FullName -Destination $preservedCheckpoint
        [System.IO.File]::SetAttributes($preservedCheckpoint, [System.IO.FileAttributes]::ReadOnly)
      }
    }
  } catch {
    $resumeValidationFailure = $_
    try {
      foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) {
        if ($failure) { throw "ALPHA4_RANDOM_RESUME_CLEANUP_FAILED:$failure" }
      }
      Assert-CcrAlpha4RandomSettingsRestored $context
    } catch {
      throw "ALPHA4_RANDOM_RESUME_VALIDATION_AND_RESTORE_FAILED:$($resumeValidationFailure.Exception.Message)|$($_.Exception.Message)"
    }
    throw $resumeValidationFailure
  }
  $mutationStarted = $true
} else {
  if (Test-Path -LiteralPath $summaryPath) { throw "ALPHA4_RANDOM_BASELINE_SUMMARY_ALREADY_EXISTS:$summaryName" }
  if (Test-Path -LiteralPath $sessionCheckpointPath) { throw "ALPHA4_RANDOM_SESSION_CHECKPOINT_ALREADY_EXISTS" }
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $settingsSaved = $true
  $sessionCheckpoint = New-CcrAlpha4RandomCheckpointBase `
    $context "s24-alpha4-random-session-checkpoint" "PASS" $MaxMinutes
  $sessionCheckpoint.completedStage = "session-settings-captured"
  $sessionCheckpoint.savedSettings = $context.SavedSettings
  Write-CcrAlpha4RandomJson $sessionCheckpointPath $sessionCheckpoint | Out-Null
  $sessionCheckpointSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sessionCheckpointPath).Hash.ToLowerInvariant()
}

$runId = $null
$received = $null
$failedReportPath = $null
$instrumentationStartedAt = 0L
$traceStarted = $false
$traceStopped = $false
$remoteTracePath = $null
$localTracePath = $null
$stageTimingPath = $null
$stageTimingSha256 = $null
$mergedReportPath = $null
$mergedReportSha256 = $null
try {
  Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "random-before-device-mutation"
  $runId = New-CcrPinnedRunId $context.OutputDirectory "alpha4-random"
  $attemptStartedCheckpoint = New-CcrAlpha4RandomCheckpointBase `
    $context "s24-alpha4-random-attempt-checkpoint" "IN_PROGRESS" $MaxMinutes
  $attemptStartedCheckpoint.runId = $runId
  $attemptStartedCheckpoint.sessionCheckpoint = $sessionCheckpointPath
  $attemptStartedCheckpoint.sessionCheckpointSha256 = $sessionCheckpointSha256
  $attemptStartedCheckpoint.restartGranularity = "WHOLE_INSTRUMENTATION_NEW_RUN_ID"
  $attemptStartedCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha4-random-attempt-$runId-started.json"
  Write-CcrAlpha4RandomJson $attemptStartedCheckpointPath $attemptStartedCheckpoint | Out-Null
  $attemptStartedCheckpointSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $attemptStartedCheckpointPath).Hash.ToLowerInvariant()
  $mutationStarted = $true
  Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
  Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
  Set-CcrPinnedDeviceSetting $context "system" "accelerometer_rotation" "0"
  Set-CcrPinnedDeviceSetting $context "system" "user_rotation" "0"
  $wake = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
  if ($wake.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_DEVICE_WAKE_FAILED" }
  $unlock = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "wm", "dismiss-keyguard")
  if ($unlock.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_KEYGUARD_DISMISS_FAILED" }

  Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "random-before-install"
  Install-CcrPinnedArtifactSet $context "Debug"
  Clear-CcrPinnedRemoteReport $context $script:CcrPinnedAppPackage $reportName
  $remoteTracePath = "/data/local/tmp/ccr-alpha4-random-$runId.atrace"
  $localTracePath = Join-Path $context.OutputDirectory "$runId-alpha4-random.atrace"
  Start-CcrAlpha4RandomTrace $context $remoteTracePath
  $traceStarted = $true
  try {
    $invocation = Invoke-CcrAlpha4TimedInstrumentation `
      -Context $context -TestRole "debugTest" -ClassName $testClass -RunId $runId `
      -DeadlineUtc $deadlineUtc -ExpectedTestCount 1
  } finally {
    Stop-CcrAlpha4RandomTrace $context $remoteTracePath $localTracePath | Out-Null
    $traceStopped = $true
  }
  $instrumentationStartedAt = $invocation.MinimumStartedAtElapsedRealtimeNs
  $received = Receive-CcrPinnedReport `
    -Context $context -ReportName $reportName -RunId $runId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $instrumentationStartedAt `
    -ExpectedKind "alpha4-random-source-equivalent-timing-baseline" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  Assert-CcrAlpha4RandomBaselineReport `
    -Report $received.Report `
    -ExpectedRuntimeSourceSha $context.ArtifactSet.RuntimeSourceSha `
    -ExpectedRuntimeInputsTreeSha256 $context.ArtifactSet.RuntimeInputsTreeSha256 `
    -ExpectedHarnessSourceSha $context.ArtifactSet.HarnessSourceSha `
    -ExpectedDebugAppSha256 ([string](Get-CcrPinnedArtifact $context "debugApp").sha256) `
    -ExpectedDebugTestSha256 ([string](Get-CcrPinnedArtifact $context "debugTest").sha256) | Out-Null
  Invoke-CcrAlpha4NodeReportValidation `
    -ReportPath $received.Path `
    -ExpectedHarnessSourceSha $context.ArtifactSet.HarnessSourceSha `
    -ExpectedTestApkSha256 ([string](Get-CcrPinnedArtifact $context "debugTest").sha256)
  $stageTimings = @(Get-CcrAlpha4TraceStageTiming -TracePath $localTracePath -Report $received.Report)
  $traceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $localTracePath).Hash.ToLowerInvariant()
  $stageEvidence = [ordered]@{
    schemaVersion = 1
    kind = "alpha4-random-source-equivalent-timing-stage-timing"
    status = "PASS"
    runId = $runId
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    traceSha256 = $traceSha256
    traceBytes = (Get-Item -LiteralPath $localTracePath).Length
    timingCount = $stageTimings.Count
    acceptedToFirstDecoderOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
    acceptedToTargetOutput = "MEASURED_OR_NOT_APPLICABLE_CACHE_HIT"
    timings = $stageTimings
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  $stageTimingPath = Write-CcrAlpha4RandomJson `
    (Join-Path $context.OutputDirectory "$runId-alpha4-random-stage-timing-v1.json") $stageEvidence
  $stageTimingSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $stageTimingPath).Hash.ToLowerInvariant()
  $mergedReport = Merge-CcrAlpha4TraceStageTiming `
    -Report $received.Report -Timings $stageTimings -TraceSha256 $traceSha256
  Assert-CcrAlpha4MergedBaselineReport $mergedReport | Out-Null
  $mergedReportPath = Write-CcrAlpha4RandomJson `
    (Join-Path $context.OutputDirectory "$runId-alpha4-random-trace-merged-v1.json") $mergedReport
  $mergedReportSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $mergedReportPath).Hash.ToLowerInvariant()
  Assert-CcrAlpha4Deadline -DeadlineUtc $deadlineUtc -Stage "random-complete"
  [System.IO.File]::SetAttributes($received.Path, [System.IO.FileAttributes]::ReadOnly)
  [System.IO.File]::SetAttributes($localTracePath, [System.IO.FileAttributes]::ReadOnly)
} catch {
  $primaryFailure = $_
  try {
    $failedReportPath = Save-CcrAlpha4FailedRandomReport `
      -Context $context -RunId $runId -TargetPath (Join-Path $context.OutputDirectory "$runId-failed-$reportName")
  } catch {
    $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_FAILED_REPORT_RECOVERY_ERROR:$($_.Exception.Message)") | Out-Null
  }
} finally {
  if ($traceStarted -and -not $traceStopped) {
    try {
      if ($localTracePath -and -not (Test-Path -LiteralPath $localTracePath)) {
        Stop-CcrAlpha4RandomTrace $context $remoteTracePath $localTracePath | Out-Null
      } else {
        $stop = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "atrace", "--async_stop")
        if ($stop.exitCode -ne 0) { throw "ALPHA4_RANDOM_BASELINE_TRACE_EMERGENCY_STOP_FAILED" }
      }
      $traceStopped = $true
    } catch {
      $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_TRACE_FINALIZE_FAILED:$($_.Exception.Message)") | Out-Null
    }
  }
  if ($remoteTracePath) {
    try { Remove-CcrAlpha4RandomRemoteTrace $context $remoteTracePath } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
  if ($localTracePath -and (Test-Path -LiteralPath $localTracePath -PathType Leaf)) {
    try { [System.IO.File]::SetAttributes($localTracePath, [System.IO.FileAttributes]::ReadOnly) } catch {
      $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_LOCAL_TRACE_READ_ONLY_FAILED:$($_.Exception.Message)") | Out-Null
    }
  }
  if ($mutationStarted) {
    try {
      foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
    } catch {
      $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null
    }
    foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
      try {
        if (Test-CcrPinnedPackageInstalled $context $packageName) {
          $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_TEST_PACKAGE_STILL_INSTALLED:$packageName") | Out-Null
        }
      } catch {
        $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_PACKAGE_ABSENCE_CHECK_FAILED:${packageName}:$($_.Exception.Message)") | Out-Null
      }
    }
    if ($settingsSaved) {
      try { Assert-CcrAlpha4RandomSettingsRestored $context } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
    }
    try { Assert-CcrPinnedInstalledArtifact $context "debugApp" } catch {
      $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_DEBUG_APP_IDENTITY_LOST:$($_.Exception.Message)") | Out-Null
    }
  }

  $status = if ($null -eq $primaryFailure -and $cleanupFailures.Count -eq 0 -and $null -ne $received) { "PASS" } else { "FAIL" }
  $summary = [ordered]@{
    schemaVersion = 1
    kind = "s24-alpha4-random-baseline"
    status = $status
    primaryFailure = if ($null -eq $primaryFailure) { $null } else { $primaryFailure.Exception.Message }
    cleanupFailures = @($cleanupFailures)
    baselineOnly = $true
    renderMode = if ($null -eq $received) { $null } else { [string]$received.Report.renderMode }
    pixelExactnessEvidence = if ($null -eq $received) { $null } else { [string]$received.Report.pixelExactnessEvidence }
    memoryMeasurement = if ($null -eq $received) { $null } else { [string]$received.Report.memoryMeasurement }
    inSessionMemory = if ($null -eq $received) { @() } else {
      @($received.Report.fixtures | ForEach-Object {
        [ordered]@{
          fixtureId = [string]$_.fixtureId
          javaUsedBytes = [long]$_.inSessionMemory.javaUsedBytes
          nativeAllocatedBytes = [long]$_.inSessionMemory.nativeAllocatedBytes
          totalPssBytes = [long]$_.inSessionMemory.totalPssBytes
        }
      })
    }
    timingBaselineOnly = $true
    exactnessEvidenceScope = "SEPARATE_FROZEN_GATES; pilot timing run is not a pixel-correctness PASS"
    performanceJudgement = "MEASURED_NOT_GATED"
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    device = [ordered]@{
      serial = $context.Serial
      model = $context.Model
      fingerprint = $context.Fingerprint
      securityPatch = $context.SecurityPatch
      sdk = $context.Sdk
    }
    runId = $runId
    sessionCheckpoint = $sessionCheckpointPath
    sessionCheckpointSha256 = $sessionCheckpointSha256
    attemptStartedCheckpoint = $attemptStartedCheckpointPath
    attemptStartedCheckpointSha256 = $attemptStartedCheckpointSha256
    resumeAttempt = $Resume.IsPresent
    resumeGranularity = "whole-instrumentation-restart; complete-pass-evidence-only-reuse"
    preservedPriorSummary = $preservedPriorSummaryPath
    report = if ($null -eq $received) { $failedReportPath } else { $received.Path }
    reportSha256 = if ($null -eq $received -or -not (Test-Path -LiteralPath $received.Path)) {
      $null
    } else {
      (Get-FileHash -Algorithm SHA256 -LiteralPath $received.Path).Hash.ToLowerInvariant()
    }
    rawTrace = $localTracePath
    rawTraceSha256 = if ($localTracePath -and (Test-Path -LiteralPath $localTracePath)) {
      (Get-FileHash -Algorithm SHA256 -LiteralPath $localTracePath).Hash.ToLowerInvariant()
    } else { $null }
    stageTiming = $stageTimingPath
    stageTimingSha256 = $stageTimingSha256
    mergedReport = $mergedReportPath
    mergedReportSha256 = $mergedReportSha256
    baselineCompleteness = if ($mergedReportPath) { "COMPLETE_TRACE_MERGED" } else { "PENDING_TRACE_MERGE_BLOCKS_ALPHA5" }
    decoderStageTimingStatus = if ($mergedReportPath) { "PASS" } else { "PENDING_BLOCKS_ALPHA5" }
    deterministicNodeContractValidation = if ($mergedReportPath) { "PASS" } else { "PENDING_BLOCKS_ALPHA5" }
    fixtureCount = if ($null -eq $received) { $null } else { [int]$received.Report.fixtureCount }
    targetCount = if ($null -eq $received) { $null } else { [int]$received.Report.targetCount }
    mismatchCount = if ($null -eq $received) { $null } else { [long]$received.Report.mismatchCount }
    writeOpenCount = if ($null -eq $received) { $null } else { [long]$received.Report.writeOpenCount }
    settingsRestored = -not (@($cleanupFailures) | Where-Object { $_ -match "SETTING" })
    testPackagesRemoved = -not (@($cleanupFailures) | Where-Object { $_ -match "PACKAGE" })
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    maxMinutes = $MaxMinutes
    deadlineUtc = $deadlineUtc.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    instrumentationTimeoutMode = "device-toybox-timeout+host-deadline-check"
  }
  try {
    Write-CcrAlpha4RandomJson $summaryPath $summary | Out-Null
  } catch {
    $cleanupFailures.Add("ALPHA4_RANDOM_BASELINE_SUMMARY_WRITE_FAILED:$($_.Exception.Message)") | Out-Null
  }
}

if ($null -ne $primaryFailure -or $cleanupFailures.Count -gt 0) {
  try {
    $failedCheckpoint = New-CcrAlpha4RandomCheckpointBase `
      $context "s24-alpha4-random-attempt-checkpoint" "FAIL" $MaxMinutes
    $failedCheckpoint.runId = $runId
    $failedCheckpoint.sessionCheckpoint = $sessionCheckpointPath
    $failedCheckpoint.sessionCheckpointSha256 = $sessionCheckpointSha256
    $failedCheckpoint.attemptStartedCheckpoint = $attemptStartedCheckpointPath
    $failedCheckpoint.attemptStartedCheckpointSha256 = $attemptStartedCheckpointSha256
    $failedCheckpoint.restartGranularity = "WHOLE_INSTRUMENTATION_NEW_RUN_ID"
    $failedCheckpoint.primaryFailure = if ($null -eq $primaryFailure) { $null } else { $primaryFailure.Exception.Message }
    $failedCheckpoint.cleanupFailures = @($cleanupFailures)
    $failedCheckpoint.summary = if (Test-Path -LiteralPath $summaryPath) { $summaryPath } else { $null }
    $failedCheckpoint.summarySha256 = if (Test-Path -LiteralPath $summaryPath) {
      (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash.ToLowerInvariant()
    } else { $null }
    $attemptIdentity = if ($runId) { $runId } else { [Guid]::NewGuid().ToString("N") }
    $attemptFailedCheckpointPath = Join-Path $context.OutputDirectory `
      "checkpoint-alpha4-random-attempt-$attemptIdentity-failed.json"
    Write-CcrAlpha4RandomJson $attemptFailedCheckpointPath $failedCheckpoint | Out-Null
  } catch {
    $cleanupFailures.Add("ALPHA4_RANDOM_FAILED_CHECKPOINT_WRITE_FAILED:$($_.Exception.Message)") | Out-Null
  }
  $messages = [System.Collections.Generic.List[string]]::new()
  if ($null -ne $primaryFailure) { $messages.Add("PRIMARY:$($primaryFailure.Exception.Message)") | Out-Null }
  foreach ($failure in $cleanupFailures) { $messages.Add("CLEANUP:$failure") | Out-Null }
  throw ($messages -join " | ")
}

$completedSummary = Read-CcrAlpha4RandomJson $summaryPath "ALPHA4_RANDOM_PASS_SUMMARY_INVALID"
Assert-CcrAlpha4RandomCompletedSummary $completedSummary $context $MaxMinutes | Out-Null
$passCheckpoint = New-CcrAlpha4RandomCheckpointBase `
  $context "s24-alpha4-random-attempt-checkpoint" "PASS" $MaxMinutes
$passCheckpoint.runId = $runId
$passCheckpoint.sessionCheckpoint = $sessionCheckpointPath
$passCheckpoint.sessionCheckpointSha256 = $sessionCheckpointSha256
$passCheckpoint.attemptStartedCheckpoint = $attemptStartedCheckpointPath
$passCheckpoint.attemptStartedCheckpointSha256 = $attemptStartedCheckpointSha256
$passCheckpoint.summary = $summaryPath
$passCheckpoint.summarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash.ToLowerInvariant()
$passCheckpoint.reportSha256 = [string]$completedSummary.reportSha256
$passCheckpoint.rawTraceSha256 = [string]$completedSummary.rawTraceSha256
$passCheckpoint.stageTimingSha256 = [string]$completedSummary.stageTimingSha256
$passCheckpoint.mergedReportSha256 = [string]$completedSummary.mergedReportSha256
$passCheckpoint.reuseContract = "COMPLETE_PASS_AND_ALL_EVIDENCE_SHA_REVALIDATED"
$attemptPassCheckpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha4-random-attempt-$runId-pass.json"
Write-CcrAlpha4RandomJson $attemptPassCheckpointPath $passCheckpoint | Out-Null
Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
