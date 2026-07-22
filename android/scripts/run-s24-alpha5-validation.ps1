param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateRange(1, 240)][int]$MaxMinutes = 120,
  [ValidateSet("A", "B", "C", "D", "E", "F", "G", "H")][string]$StopAfter = "H",
  [switch]$Resume,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-alpha5-pinned-artifacts.ps1")
$deadlineUtc = New-CcrAlpha5DeadlineUtc $MaxMinutes
Set-CcrAlpha5ActiveDeadline $deadlineUtc
if ($StopAfter -cnotin @("A", "B", "C", "D", "E", "F", "G", "H")) {
  throw "ALPHA5_ORCHESTRATOR_STOP_AFTER_NOT_CANONICAL:$StopAfter"
}
$context = Invoke-CcrAlpha5PinnedPreflight `
  -ArtifactManifest $ArtifactManifest -ArtifactManifestSha256 $ArtifactManifestSha256 `
  -OutputDirectory $OutputDirectory

$sessionPath = Join-Path $context.OutputDirectory "checkpoint-alpha5-session.json"
if ($Resume) {
  if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { throw "ALPHA5_SESSION_CHECKPOINT_MISSING" }
  $session = [System.IO.File]::ReadAllText($sessionPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  if ([string]$session.status -cne "PASS" -or [int]$session.maxMinutes -ne $MaxMinutes) { throw "ALPHA5_SESSION_CHECKPOINT_MISMATCH" }
  Assert-CcrAlpha5PreflightDomain $session ([bool]$PreflightOnly) "ALPHA5_SESSION_PREFLIGHT_DOMAIN_MISMATCH"
  Assert-CcrAlpha5IdentityRecord $session.identity $context "ALPHA5_SESSION_CHECKPOINT_IDENTITY_MISMATCH" | Out-Null
  $context | Add-Member -Force -NotePropertyName SavedSettings -NotePropertyValue $session.savedSettings
} else {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $session = [ordered]@{
    schemaVersion = 1; kind = "alpha5-validation-session"; status = "PASS"; maxMinutes = $MaxMinutes
    preflightOnly = [bool]$PreflightOnly
    identity = New-CcrAlpha5IdentityRecord $context; savedSettings = $context.SavedSettings
    resumeContract = "completed-stage-only; exact identity and device required"
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-CcrAlpha5ImmutableJson $sessionPath $session | Out-Null
}

function Get-CcrAlpha5RemainingMinutes {
  $remaining = ($deadlineUtc - [DateTime]::UtcNow).TotalMinutes
  if ($remaining -le 0) { throw "ALPHA5_MAX_MINUTES_EXCEEDED:orchestrator" }
  return [Math]::Max(1, [Math]::Min(240, [int][Math]::Ceiling($remaining)))
}

function Get-CcrAlpha5EvidenceFiles {
  param([string]$Directory)
  return @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object {
    $_.Name -notlike "run-id-*.lock"
  } | Sort-Object FullName | ForEach-Object {
    [ordered]@{
      path = $_.FullName
      bytes = [long]$_.Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    }
  })
}

function Assert-CcrAlpha5StageCheckpoint {
  param([object]$Checkpoint, [string]$Stage)
  $expectedStatus = if ($Stage -ceq "H") { "PENDING_USER" } else { "PASS" }
  if ([string]$Checkpoint.status -cne $expectedStatus -or [string]$Checkpoint.stage -cne $Stage -or
      @($Checkpoint.evidence).Count -eq 0) {
    throw "ALPHA5_ORCHESTRATOR_RESUME_IDENTITY_MISMATCH:$Stage"
  }
  Assert-CcrAlpha5PreflightDomain $Checkpoint ([bool]$PreflightOnly) "ALPHA5_ORCHESTRATOR_RESUME_PREFLIGHT_DOMAIN_MISMATCH:$Stage"
  Assert-CcrAlpha5IdentityRecord $Checkpoint.identity $context "ALPHA5_ORCHESTRATOR_RESUME_IDENTITY_MISMATCH:$Stage" | Out-Null
  foreach ($file in @($Checkpoint.evidence)) {
    if (-not (Test-Path -LiteralPath ([string]$file.path) -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$file.path)).Hash.ToLowerInvariant() -cne [string]$file.sha256) {
      throw "ALPHA5_ORCHESTRATOR_RESUME_EVIDENCE_MISMATCH:$Stage"
    }
  }
}

function Assert-CcrAlpha5ForwardReverseParity {
  param([Parameter(Mandatory = $true)][string]$EvidencePath)
  $forwardPath = Join-Path $context.OutputDirectory "stage-C\forward-perf\alpha5-navigation-perf-forward-v1.json"
  $reversePath = Join-Path $context.OutputDirectory "stage-D\reverse-perf\alpha5-navigation-perf-reverse-v1.json"
  foreach ($path in @($forwardPath, $reversePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ALPHA5_PARITY_SUMMARY_MISSING:$path" }
  }
  $forward = [System.IO.File]::ReadAllText($forwardPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $reverse = [System.IO.File]::ReadAllText($reversePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-CcrAlpha5IdentityRecord $forward.identity $context "ALPHA5_PARITY_FORWARD_IDENTITY_MISMATCH" | Out-Null
  Assert-CcrAlpha5IdentityRecord $reverse.identity $context "ALPHA5_PARITY_REVERSE_IDENTITY_MISMATCH" | Out-Null
  $pairs = @(
    @("hold1080PlusOne", "hold1080MinusOne", 1),
    @("hold1080PlusFive", "hold1080MinusFive", 5)
  )
  $comparisons = @()
  foreach ($pair in $pairs) {
    $f = @($forward.scenarios | Where-Object { [string]$_.method -ceq $pair[0] })
    $r = @($reverse.scenarios | Where-Object { [string]$_.method -ceq $pair[1] })
    if ($f.Count -ne 1 -or $r.Count -ne 1) { throw "ALPHA5_PARITY_SCENARIO_MISSING:$($pair[2])" }
    $forwardFps = @($f[0].publishedFpsMilli)
    $reverseFps = @($r[0].publishedFpsMilli)
    if ($forwardFps.Count -ne 3 -or $reverseFps.Count -ne 3) { throw "ALPHA5_PARITY_RUN_COUNT_MISMATCH:$($pair[2])" }
    for ($index = 0; $index -lt 3; $index += 1) {
      $higher = [Math]::Max([double]$forwardFps[$index], [double]$reverseFps[$index])
      if ($higher -le 0) { throw "ALPHA5_PARITY_FPS_INVALID:$($pair[2])/$index" }
      $difference = [Math]::Abs([double]$forwardFps[$index] - [double]$reverseFps[$index]) / $higher
      if ($difference -gt 0.25) { throw "ALPHA5_PARITY_DIFFERENCE_EXCEEDED:$($pair[2])/$index" }
      $comparisons += [ordered]@{
        stride = [int]$pair[2]; iteration = $index + 1
        forwardFpsMilli = [double]$forwardFps[$index]; reverseFpsMilli = [double]$reverseFps[$index]
        relativeDifference = $difference; maximumAllowed = 0.25
      }
    }
  }
  $evidence = [ordered]@{
    schemaVersion = 1; kind = "alpha5-forward-reverse-fps-parity"; status = "PASS"
    identity = New-CcrAlpha5IdentityRecord $context; comparisons = $comparisons
    thresholdContract = "ALPHA5_BIDIRECTIONAL_VALIDATION_V1_USER_APPROVED"
    buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-CcrAlpha5ImmutableJson $EvidencePath $evidence | Out-Null
}

function Invoke-CcrAlpha5Stage {
  param([Parameter(Mandatory = $true)][string]$Stage)
  Assert-CcrAlpha5Deadline $deadlineUtc "orchestrator-before-$Stage"
  $checkpointPath = Join-Path $context.OutputDirectory "checkpoint-alpha5-stage-$Stage.json"
  if ($Resume -and (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
    $checkpoint = [System.IO.File]::ReadAllText($checkpointPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-CcrAlpha5StageCheckpoint $checkpoint $Stage
    if ($Stage -ceq "H" -and -not $PreflightOnly) {
      Assert-CcrAlpha5SettingsRestored $context | Out-Null
      Assert-CcrPinnedInstalledArtifact $context "debugApp"
      foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
        if (Test-CcrPinnedPackageInstalled $context $packageName) { throw "ALPHA5_H_RESUME_TEST_PACKAGE_PRESENT:$packageName" }
      }
      $focus = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "dumpsys", "activity", "activities")
      if ($focus.exitCode -ne 0 -or $focus.output -notmatch "(?m)mResumedActivity:.*$([regex]::Escape($script:CcrPinnedMainActivityComponent))(?:\s|\})") {
        throw "ALPHA5_H_RESUME_MAIN_ACTIVITY_NOT_FOREGROUND"
      }
    }
    return $checkpoint
  }
  if (Test-Path -LiteralPath $checkpointPath) { throw "ALPHA5_ORCHESTRATOR_CHECKPOINT_ALREADY_EXISTS:$Stage" }
  $stageDirectory = Join-Path $context.OutputDirectory "stage-$Stage"
  [System.IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
  $common = @{
    ArtifactManifest = $context.ArtifactSet.ManifestPath
    ArtifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    MaxMinutes = Get-CcrAlpha5RemainingMinutes
    AbsoluteDeadlineUtc = $deadlineUtc
  }
  if ($PreflightOnly) { $common.PreflightOnly = $true }
  if ($Resume) { $common.Resume = $true }
  switch ($Stage) {
    "A" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "full") -Stage Full | Out-Null
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "release-cancel") -Stage ReleaseCancel | Out-Null
    }
    "B" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "representative") -Stage Representative | Out-Null
    }
    "C" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "forward-exact") -Stage Forward | Out-Null
      if (-not $PreflightOnly) {
        & (Join-Path $PSScriptRoot "run-s24-alpha5-navigation-perf.ps1") @common `
          -OutputDirectory (Join-Path $stageDirectory "forward-perf") -Direction Forward | Out-Null
      }
    }
    "D" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "reverse-exact") -Stage Reverse | Out-Null
      if (-not $PreflightOnly) {
        & (Join-Path $PSScriptRoot "run-s24-alpha5-navigation-perf.ps1") @common `
          -OutputDirectory (Join-Path $stageDirectory "reverse-perf") -Direction Reverse | Out-Null
        Assert-CcrAlpha5ForwardReverseParity (Join-Path $stageDirectory "forward-reverse-parity-v1.json")
      }
    }
    "E" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-random.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "random") | Out-Null
    }
    "F" {
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "direction") -Stage Direction | Out-Null
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "reverse-lifecycle") -Stage ReverseLifecycle | Out-Null
    }
    "G" {
      if (($deadlineUtc - [DateTime]::UtcNow).TotalMinutes -lt 11.0) {
        throw "ALPHA5_RESOURCE_REQUIRES_ELEVEN_MINUTES_REMAINING"
      }
      & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") @common `
        -OutputDirectory (Join-Path $stageDirectory "resource") -Stage Resource | Out-Null
    }
    "H" {
      $manualPath = Join-Path $stageDirectory "manual-user-evaluation-v1.json"
      $installed = $null
      $foreground = $null
      if (-not $PreflightOnly) {
        foreach ($failure in @(Restore-CcrPinnedDeviceSettings $context)) { throw "ALPHA5_H_SETTING_RESTORE_FAILED:$failure" }
        Assert-CcrAlpha5SettingsRestored $context | Out-Null
        $debugApp = Get-CcrPinnedArtifact $context "debugApp"
        $install = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "install", "-r", [string]$debugApp.path)
        if ($install.exitCode -ne 0 -or $install.output -notmatch "(?m)^Success\s*$") { throw "ALPHA5_H_DEBUG_INSTALL_FAILED" }
        Assert-CcrPinnedInstalledArtifact $context "debugApp"
        foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
          foreach ($failure in @(Remove-CcrPinnedPackageIfInstalled $context $packageName)) { throw "ALPHA5_H_TEST_PACKAGE_REMOVE_FAILED:$failure" }
          if (Test-CcrPinnedPackageInstalled $context $packageName) { throw "ALPHA5_H_TEST_PACKAGE_STILL_INSTALLED:$packageName" }
        }
        $launch = Invoke-CcrPinnedAdb $context @(
          "-s", $context.Serial, "shell", "am", "start", "-W", "-n", $script:CcrPinnedMainActivityComponent
        )
        if ($launch.exitCode -ne 0 -or $launch.output -notmatch "(?m)^Status:\s*ok\s*$") { throw "ALPHA5_H_MAIN_ACTIVITY_LAUNCH_FAILED" }
        $focus = Invoke-CcrPinnedAdb $context @("-s", $context.Serial, "shell", "dumpsys", "activity", "activities")
        if ($focus.exitCode -ne 0 -or $focus.output -notmatch "(?m)mResumedActivity:.*$([regex]::Escape($script:CcrPinnedMainActivityComponent))(?:\s|\})") {
          throw "ALPHA5_H_MAIN_ACTIVITY_NOT_FOREGROUND"
        }
        $installed = [ordered]@{
          packageName = $script:CcrPinnedAppPackage; versionName = $script:CcrPinnedVersionName
          versionCode = $script:CcrPinnedVersionCode; sha256 = [string]$debugApp.sha256
          installedPullHashVerified = $true; testPackagesAbsent = $true; settingsReadback = "PASS"
        }
        $foreground = $script:CcrPinnedMainActivityComponent
      }
      $manual = [ordered]@{
        schemaVersion = 1; kind = "alpha5-manual-user-evaluation"; status = "PENDING_USER"
        identity = New-CcrAlpha5IdentityRecord $context
        requestedChecks = @(
          "+1 tap", "+1 hold", "-1 tap", "-1 hold",
          "+5 tap", "+5 hold", "-5 tap", "-5 hold",
          "forward/reverse same-stride speed similarity", "stop control at chosen frame",
          "release overshoot", "direct frame index input", "near random frame", "far random frame",
          "timeline final seek", "H.264 to HEVC file switch", "HEVC to H.264 file switch",
          "portrait and landscape", "background and resume",
          "black/green/blank/previous-file frame absence"
        )
        passClaimed = $false; buildCommandCount = 0
        installedArtifact = $installed; foregroundActivity = $foreground
        syntheticOnly = $true; containsRealMediaMetadata = $false
      }
      Write-CcrAlpha5ImmutableJson $manualPath $manual | Out-Null
    }
    default { throw "ALPHA5_ORCHESTRATOR_STAGE_UNKNOWN:$Stage" }
  }
  Assert-CcrAlpha5Deadline $deadlineUtc "orchestrator-after-$Stage"
  $evidence = @(Get-CcrAlpha5EvidenceFiles $stageDirectory)
  if ($evidence.Count -eq 0) { throw "ALPHA5_ORCHESTRATOR_STAGE_EVIDENCE_EMPTY:$Stage" }
  $checkpoint = [ordered]@{
    schemaVersion = 1; kind = "alpha5-validation-stage-checkpoint"
    status = if ($Stage -ceq "H") { "PENDING_USER" } else { "PASS" }
    stage = $Stage; preflightOnly = [bool]$PreflightOnly
    completedAtUtc = [DateTime]::UtcNow.ToString("o"); identity = New-CcrAlpha5IdentityRecord $context
    evidence = $evidence; buildCommandCount = 0
    syntheticOnly = $true; containsRealMediaMetadata = $false
  }
  Write-CcrAlpha5ImmutableJson $checkpointPath $checkpoint | Out-Null
  return $checkpoint
}

$stages = @("A", "B", "C", "D", "E", "F", "G", "H")
$lastIndex = [Array]::IndexOf($stages, $StopAfter)
if ($lastIndex -lt 0) { throw "ALPHA5_ORCHESTRATOR_STOP_AFTER_UNKNOWN:$StopAfter" }
$completed = [System.Collections.Generic.List[object]]::new()
try {
  if (-not $PreflightOnly) {
    Set-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in" "7"
    Set-CcrPinnedDeviceSetting $context "system" "screen_off_timeout" "1800000"
    if ((Get-CcrPinnedDeviceSetting $context "global" "stay_on_while_plugged_in") -cne "7" -or
        (Get-CcrPinnedDeviceSetting $context "system" "screen_off_timeout") -cne "1800000") {
      throw "ALPHA5_ORCHESTRATOR_AWAKE_SETTING_MISMATCH"
    }
  }
  for ($index = 0; $index -le $lastIndex; $index += 1) {
    $completed.Add((Invoke-CcrAlpha5Stage $stages[$index])) | Out-Null
  }
  if (-not $PreflightOnly -and $StopAfter -cne "H") {
    foreach ($failure in @(Restore-CcrPinnedDeviceSettings $context)) { throw "ALPHA5_PARTIAL_SETTING_RESTORE_FAILED:$failure" }
    Assert-CcrAlpha5SettingsRestored $context | Out-Null
  }
} catch {
  $primaryFailure = $_
  $cleanupFailures = [System.Collections.Generic.List[string]]::new()
  # Fail-safe cleanup is attempted even if a child process was interrupted.
  Enter-CcrAlpha5CleanupWindow
  try {
    foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
  } catch { $cleanupFailures.Add("CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null }
  try { Assert-CcrAlpha5SettingsRestored $context | Out-Null } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  if ($cleanupFailures.Count -gt 0) {
    throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
  }
  throw $primaryFailure
}

$summaryPath = Join-Path $context.OutputDirectory "alpha5-validation-summary-through-$($StopAfter.ToLowerInvariant())-v1.json"
if (Test-Path -LiteralPath $summaryPath) {
  if (-not $Resume) { throw "ALPHA5_ORCHESTRATOR_SUMMARY_ALREADY_EXISTS" }
  $existingSummary = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  if ([string]$existingSummary.identity.artifactManifestSha256 -cne $context.ArtifactSet.ManifestSha256 -or
      [string]$existingSummary.stopAfter -cne $StopAfter) {
    throw "ALPHA5_ORCHESTRATOR_RESUME_SUMMARY_IDENTITY_MISMATCH"
  }
  Assert-CcrAlpha5PreflightDomain $existingSummary ([bool]$PreflightOnly) "ALPHA5_ORCHESTRATOR_RESUME_SUMMARY_PREFLIGHT_DOMAIN_MISMATCH"
  Assert-CcrAlpha5IdentityRecord $existingSummary.identity $context "ALPHA5_ORCHESTRATOR_RESUME_SUMMARY_IDENTITY_MISMATCH" | Out-Null
  Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryPath
  return
}
$status = if ($StopAfter -ceq "H") { "PENDING_USER" } else { "PASS_PARTIAL" }
$summary = [ordered]@{
  schemaVersion = 1; kind = "alpha5-s24-validation"; status = $status
  stopAfter = $StopAfter; maxMinutes = $MaxMinutes; preflightOnly = [bool]$PreflightOnly
  identity = New-CcrAlpha5IdentityRecord $context
  stages = @($completed | ForEach-Object { [ordered]@{ stage = $_.stage; status = $_.status; evidenceCount = @($_.evidence).Count } })
  correctnessBeforePerformance = $true
  manualEvaluation = if ($StopAfter -ceq "H") { "PENDING_USER" } else { "NOT_REACHED" }
  buildCommandCount = 0; syntheticOnly = $true; containsRealMediaMetadata = $false
}
Write-Output (Write-CcrAlpha5ImmutableJson $summaryPath $summary)
