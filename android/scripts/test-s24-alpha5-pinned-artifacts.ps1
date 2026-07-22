$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-alpha5-pinned-artifacts.ps1")
Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMinutes(5))

$passed = 0
function Assert-Alpha5Test {
  param([bool]$Condition, [string]$Failure)
  if (-not $Condition) { throw $Failure }
  $script:passed += 1
}

function Assert-Alpha5Throws {
  param([scriptblock]$Action, [string]$Expected)
  try { & $Action; throw "ALPHA5_TEST_EXPECTED_FAILURE_NOT_THROWN:$Expected" } catch {
    Assert-Alpha5Test ($_.Exception.Message -like "*$Expected*") "ALPHA5_TEST_WRONG_FAILURE:$Expected/$($_.Exception.Message)"
  }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("ccr-alpha5-script-test-" + [Guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
  $cert = $script:CcrPinnedSigningCertificateSha256
  $harness = "1111111111111111111111111111111111111111"
  $identities = @{
    debugApp = [PSCustomObject]@{ packageName = $script:CcrPinnedAppPackage; versionName = $script:CcrPinnedVersionName; versionCode = $script:CcrPinnedVersionCode; signingCertificateSha256 = $cert; runner = $null; targetPackage = $null }
    debugTest = [PSCustomObject]@{ packageName = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; signingCertificateSha256 = $cert; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedAppPackage }
    benchmarkApp = [PSCustomObject]@{ packageName = $script:CcrPinnedAppPackage; versionName = $script:CcrPinnedVersionName; versionCode = $script:CcrPinnedVersionCode; signingCertificateSha256 = $cert; runner = $null; targetPackage = $null }
    macrobenchmarkTest = [PSCustomObject]@{ packageName = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; signingCertificateSha256 = $cert; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedMacrobenchmarkPackage }
  }
  $artifacts = @()
  $index = 0
  foreach ($role in $script:CcrPinnedRoles) {
    $index += 1
    $path = Join-Path $root "$role.apk"
    [System.IO.File]::WriteAllText($path, "alpha5-$role-$index", [System.Text.UTF8Encoding]::new($false))
    $identity = $identities[$role]
    $artifacts += [ordered]@{
      role = $role; path = $path; bytes = [long](Get-Item -LiteralPath $path).Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
      packageName = $identity.packageName; versionName = $identity.versionName; versionCode = $identity.versionCode
      signingCertificateSha256 = $cert; runner = $identity.runner; targetPackage = $identity.targetPackage
    }
  }
  $manifestPath = Join-Path $root "artifact-manifest-v3.json"
  $manifest = [ordered]@{
    schemaVersion = 1; artifactSetRevision = 3
    runtimeSourceSha = $script:CcrPinnedRuntimeSourceSha
    harnessSourceSha = $harness
    runtimeInputsTreeSha256 = $script:CcrPinnedRuntimeInputsTreeSha256
    versionName = $script:CcrPinnedVersionName; versionCode = $script:CcrPinnedVersionCode
    syntheticOnly = $true; containsRealMediaMetadata = $false
    artifacts = $artifacts
  }
  function Write-Alpha5TestManifest {
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  }
  $manifestSha = Write-Alpha5TestManifest
  Assert-Alpha5Test ((Assert-CcrAlpha5ManifestSha256 $manifestPath $manifestSha) -ceq $manifestSha) "ALPHA5_TEST_VALID_MANIFEST_SHA"

  $adbCalls = 0
  $fakeAdb = { param($Arguments) $script:adbCalls += 1; [PSCustomObject]@{ exitCode = 99; output = "unexpected" } }
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5PinnedPreflight -ArtifactManifest $manifestPath `
      -ArtifactManifestSha256 ("0" * 64) -OutputDirectory (Join-Path $root "out") `
      -ExpectedHarnessSourceSha $harness -AdbInvoker $fakeAdb
  } "ALPHA5_MANIFEST_SHA_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_MANIFEST_SHA_FAILURE_TOUCHED_ADB"

  $manifest.artifactSetRevision = 2
  $wrongRevisionSha = Write-Alpha5TestManifest
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5PinnedPreflight -ArtifactManifest $manifestPath `
      -ArtifactManifestSha256 $wrongRevisionSha -OutputDirectory (Join-Path $root "out") `
      -ExpectedHarnessSourceSha $harness -AdbInvoker $fakeAdb
  } "PINNED_MANIFEST_REVISION_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_REVISION_FAILURE_TOUCHED_ADB"
  $manifest.artifactSetRevision = 3

  $manifest.runtimeSourceSha = "2222222222222222222222222222222222222222"
  $wrongRuntimeSha = Write-Alpha5TestManifest
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5PinnedPreflight -ArtifactManifest $manifestPath `
      -ArtifactManifestSha256 $wrongRuntimeSha -OutputDirectory (Join-Path $root "out") `
      -ExpectedHarnessSourceSha $harness -AdbInvoker $fakeAdb
  } "PINNED_MANIFEST_RUNTIME_SOURCE_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_RUNTIME_FAILURE_TOUCHED_ADB"
  $manifest.runtimeSourceSha = $script:CcrPinnedRuntimeSourceSha

  $manifest.runtimeInputsTreeSha256 = "3" * 64
  $wrongTreeSha = Write-Alpha5TestManifest
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5PinnedPreflight -ArtifactManifest $manifestPath `
      -ArtifactManifestSha256 $wrongTreeSha -OutputDirectory (Join-Path $root "out") `
      -ExpectedHarnessSourceSha $harness -AdbInvoker $fakeAdb
  } "PINNED_MANIFEST_RUNTIME_TREE_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_TREE_FAILURE_TOUCHED_ADB"
  $manifest.runtimeInputsTreeSha256 = $script:CcrPinnedRuntimeInputsTreeSha256

  $manifest.versionCode = 5
  $wrongVersionSha = Write-Alpha5TestManifest
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5PinnedPreflight -ArtifactManifest $manifestPath `
      -ArtifactManifestSha256 $wrongVersionSha -OutputDirectory (Join-Path $root "out") `
      -ExpectedHarnessSourceSha $harness -AdbInvoker $fakeAdb
  } "PINNED_MANIFEST_VERSION_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_VERSION_FAILURE_TOUCHED_ADB"
  $manifest.versionCode = 6

  $validSha = Write-Alpha5TestManifest
  $identityReader = { param($Artifact, $Tools) return $identities[[string]$Artifact.role] }
  $fakeTools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
  $script:CcrPinnedDebugAppSha256 = [string]$artifacts[0].sha256
  $validSet = Import-CcrPinnedArtifactManifest -ArtifactManifest $manifestPath -RepoRoot (Get-CcrPinnedRepoRoot) `
    -ExpectedHarnessSourceSha $harness -AndroidTools $fakeTools -IdentityReader $identityReader `
    -TestOnlyExpectedDebugAppSha256 $script:CcrPinnedDebugAppSha256
  Assert-Alpha5Test ($validSet.ManifestSha256 -ceq $validSha) "ALPHA5_TEST_VALID_LOCAL_ARTIFACT_SET"

  $snapshotRoot = Assert-CcrAlpha5ExternalOutputDirectory (Join-Path $root "snapshot-out")
  $snapshot = New-CcrAlpha5ManifestSnapshot $manifestPath $validSha $snapshotRoot
  [System.IO.File]::AppendAllText($manifestPath, "tamper-source-after-snapshot")
  Assert-Alpha5Test ((Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot).Hash.ToLowerInvariant() -ceq $validSha) "ALPHA5_TEST_MANIFEST_SNAPSHOT_NOT_IMMUTABLE"
  $validSha = Write-Alpha5TestManifest

  Assert-Alpha5Throws {
    Assert-CcrAlpha5ExternalOutputDirectory (Join-Path (Get-CcrPinnedRepoRoot) "android\forbidden-alpha5-output")
  } "ALPHA5_OUTPUT_INSIDE_WORKTREE"

  $fakeContext = [PSCustomObject]@{
    ArtifactSet = $validSet; Serial = "SERIAL123"; Model = "SM-S928N"; Fingerprint = "samsung/test/fingerprint"
    SecurityPatch = "2026-06-05"; Sdk = "36"
  }
  $identityRecord = New-CcrAlpha5IdentityRecord $fakeContext
  Assert-Alpha5Test ([string]$identityRecord.artifactManifestSha256 -ceq [string]$validSet.ManifestSha256) "ALPHA5_TEST_IDENTITY_RECORD_MANIFEST_SHA"
  Assert-Alpha5Test ([string]$identityRecord.debugAppSha256 -ceq [string]$validSet.Artifacts.debugApp.sha256) "ALPHA5_TEST_IDENTITY_RECORD_DEBUG_SHA"
  Assert-CcrAlpha5IdentityRecord $identityRecord $fakeContext | Out-Null
  $identityRecord.device.serial = "OTHER"
  Assert-Alpha5Throws { Assert-CcrAlpha5IdentityRecord $identityRecord $fakeContext } "ALPHA5_IDENTITY_MISMATCH/device.serial"

  $repoStatus = @(& git -C (Get-CcrPinnedRepoRoot) status --porcelain=v1 --untracked-files=all)
  $repoHead = ((& git -C (Get-CcrPinnedRepoRoot) rev-parse HEAD) | Select-Object -First 1).Trim()
  Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMinutes(2))
  if ($repoStatus.Count -eq 0) {
    Assert-CcrAlpha5SourceFreeze (Get-CcrPinnedRepoRoot) $repoHead
    Assert-Alpha5Test $true "ALPHA5_TEST_SOURCE_FREEZE_CLEAN_FAILED"
  } else {
    Assert-Alpha5Throws { Assert-CcrAlpha5SourceFreeze (Get-CcrPinnedRepoRoot) $repoHead } "ALPHA5_SOURCE_FREEZE_WORKTREE_NOT_CLEAN"
  }

  $pingIdsBefore = @(Get-Process -Name ping -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMilliseconds(100))
  Assert-Alpha5Throws {
    Invoke-CcrAlpha5TimedProcess $env:ComSpec @("/c", "ping", "-n", "6", "127.0.0.1") "ALPHA5_TEST_PROCESS_TIMEOUT"
  } "ALPHA5_TEST_PROCESS_TIMEOUT"
  Start-Sleep -Milliseconds 200
  $newPingProcesses = @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $pingIdsBefore })
  Assert-Alpha5Test ($newPingProcesses.Count -eq 0) "ALPHA5_TEST_PROCESS_TREE_NOT_TERMINATED"
  Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMinutes(5))
  Assert-CcrAlpha5PreflightDomain ([PSCustomObject]@{ preflightOnly = $false }) $false "ALPHA5_TEST_PREFLIGHT_DOMAIN_FALSE"
  Assert-CcrAlpha5PreflightDomain ([PSCustomObject]@{ preflightOnly = $true }) $true "ALPHA5_TEST_PREFLIGHT_DOMAIN_TRUE"
  Assert-Alpha5Throws {
    Assert-CcrAlpha5PreflightDomain ([PSCustomObject]@{ preflightOnly = $true }) $false "ALPHA5_TEST_PREFLIGHT_DOMAIN_MISMATCH"
  } "ALPHA5_TEST_PREFLIGHT_DOMAIN_MISMATCH"
  Assert-Alpha5Throws {
    Assert-CcrAlpha5PreflightDomain ([PSCustomObject]@{}) $false "ALPHA5_TEST_PREFLIGHT_DOMAIN_MISSING"
  } "ALPHA5_TEST_PREFLIGHT_DOMAIN_MISSING"
  $quotedProcess = Invoke-CcrAlpha5TimedProcess $env:ComSpec @("/d", "/s", "/c", "echo alpha5 quoted argument") "ALPHA5_TEST_QUOTED_PROCESS_TIMEOUT"
  Assert-Alpha5Test ($quotedProcess.exitCode -eq 0 -and $quotedProcess.output.Trim() -ceq "alpha5 quoted argument") "ALPHA5_TEST_WINDOWS_ARGUMENT_QUOTING_FAILED"
  $toolScript = Join-Path $root "alpha5 tool wrapper.cmd"
  [System.IO.File]::WriteAllText($toolScript, "@echo alpha5 tool wrapper", [System.Text.Encoding]::ASCII)
  $toolOutput = Invoke-CcrPinnedTool $toolScript @() "ALPHA5_TEST_TOOL_FAILED"
  Assert-Alpha5Test ($toolOutput.Trim() -ceq "alpha5 tool wrapper") "ALPHA5_TEST_BATCH_TOOL_WRAPPER_FAILED"
  [System.IO.File]::WriteAllText($toolScript, "@ping -n 6 127.0.0.1 >nul", [System.Text.Encoding]::ASCII)
  Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMilliseconds(100))
  Assert-Alpha5Throws { Invoke-CcrPinnedTool $toolScript @() "ALPHA5_TEST_TOOL_FAILED" } "ALPHA5_APK_INSPECTION_DEADLINE_EXCEEDED"
  Start-Sleep -Milliseconds 200
  $newToolPingProcesses = @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $pingIdsBefore })
  Assert-Alpha5Test ($newToolPingProcesses.Count -eq 0) "ALPHA5_TEST_TOOL_PROCESS_TREE_NOT_TERMINATED"
  Set-CcrAlpha5ActiveDeadline ([DateTime]::UtcNow.AddMinutes(5))

  $adbCalls = 0
  [System.IO.File]::AppendAllText([string]$artifacts[0].path, "tamper")
  Assert-Alpha5Throws {
    Import-CcrPinnedArtifactManifest -ArtifactManifest $manifestPath -RepoRoot (Get-CcrPinnedRepoRoot) `
      -ExpectedHarnessSourceSha $harness -AndroidTools $fakeTools -IdentityReader $identityReader `
      -TestOnlyExpectedDebugAppSha256 $script:CcrPinnedDebugAppSha256
  } "PINNED_ARTIFACT_BYTE_SIZE_MISMATCH"
  Assert-Alpha5Test ($adbCalls -eq 0) "ALPHA5_TEST_ARTIFACT_FAILURE_TOUCHED_ADB"

  foreach ($name in @(
    "run-s24-alpha5-instrumentation.ps1", "run-s24-alpha5-navigation-perf.ps1",
    "run-s24-alpha5-random.ps1", "run-s24-alpha5-validation.ps1"
  )) {
    $source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name), [System.Text.Encoding]::UTF8)
    Assert-Alpha5Test ($source -notmatch '(?im)gradlew|assemble(?:Internal|Debug|Release|AndroidTest|Benchmark)') "ALPHA5_TEST_BUILD_COMMAND_FORBIDDEN:$name"
  }
  $orchestrator = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha5-validation.ps1"), [System.Text.Encoding]::UTF8)
  $instrumentation = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1"), [System.Text.Encoding]::UTF8)
  $performance = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha5-navigation-perf.ps1"), [System.Text.Encoding]::UTF8)
  $random = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha5-random.ps1"), [System.Text.Encoding]::UTF8)
  Assert-Alpha5Throws {
    & (Join-Path $PSScriptRoot "run-s24-alpha5-instrumentation.ps1") `
      -ArtifactManifest $manifestPath -ArtifactManifestSha256 $validSha -OutputDirectory (Join-Path $root "case-stage") -Stage full
  } "ALPHA5_INSTRUMENTATION_STAGE_NOT_CANONICAL"
  Assert-Alpha5Throws {
    & (Join-Path $PSScriptRoot "run-s24-alpha5-navigation-perf.ps1") `
      -ArtifactManifest $manifestPath -ArtifactManifestSha256 $validSha -OutputDirectory (Join-Path $root "case-direction") -Direction forward
  } "ALPHA5_PERF_DIRECTION_NOT_CANONICAL"
  Assert-Alpha5Throws {
    & (Join-Path $PSScriptRoot "run-s24-alpha5-validation.ps1") `
      -ArtifactManifest $manifestPath -ArtifactManifestSha256 $validSha -OutputDirectory (Join-Path $root "case-stop") -StopAfter h
  } "ALPHA5_ORCHESTRATOR_STOP_AFTER_NOT_CANONICAL"
  Assert-Alpha5Test ($orchestrator -match 'correctnessBeforePerformance = \$true') "ALPHA5_TEST_CORRECTNESS_ORDER_MARKER_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'status = "PENDING_USER"') "ALPHA5_TEST_MANUAL_PENDING_MARKER_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'ALPHA5_SESSION_PREFLIGHT_DOMAIN_MISMATCH' -and $orchestrator -match 'ALPHA5_ORCHESTRATOR_RESUME_PREFLIGHT_DOMAIN_MISMATCH' -and $orchestrator -match 'ALPHA5_ORCHESTRATOR_RESUME_SUMMARY_PREFLIGHT_DOMAIN_MISMATCH') "ALPHA5_TEST_PREFLIGHT_RESUME_GUARDS_MISSING"
  Assert-Alpha5Test (([regex]::Matches($random, 'FailureReportPath')).Count -eq 2) "ALPHA5_TEST_RANDOM_FAILURE_REPORT_PATHS_MISSING"
  foreach ($manualCheck in @(
    '+1 tap', '+1 hold', '-1 tap', '-1 hold', '+5 tap', '+5 hold', '-5 tap', '-5 hold',
    'forward/reverse same-stride speed similarity', 'release overshoot', 'direct frame index input',
    'near random frame', 'far random frame', 'timeline final seek', 'H.264 to HEVC file switch',
    'HEVC to H.264 file switch', 'portrait and landscape', 'background and resume',
    'black/green/blank/previous-file frame absence'
  )) {
    Assert-Alpha5Test ($orchestrator.Contains("`"$manualCheck`"")) "ALPHA5_TEST_MANUAL_CHECK_MISSING:$manualCheck"
  }
  Assert-Alpha5Test ($orchestrator -match 'ALPHA5_RESOURCE_REQUIRES_ELEVEN_MINUTES_REMAINING') "ALPHA5_TEST_RESOURCE_DEADLINE_GUARD_MISSING"
  Assert-Alpha5Test ($script:CcrPinnedMainActivityComponent -ceq 'com.snowberried.ctcinereviewer.internal/com.snowberried.ctcinereviewer.MainActivity') "ALPHA5_TEST_H_COMPONENT_IDENTITY_MISMATCH"
  Assert-Alpha5Test ($orchestrator -match 'CcrPinnedMainActivityComponent' -and $orchestrator -match 'ALPHA5_H_MAIN_ACTIVITY_NOT_FOREGROUND' -and $orchestrator -match 'Assert-CcrPinnedInstalledArtifact') "ALPHA5_TEST_H_INSTALL_FOREGROUND_GUARD_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'PRIMARY=.*CLEANUP=' -and $orchestrator -match 'Assert-CcrAlpha5SettingsRestored') "ALPHA5_TEST_ORCHESTRATOR_CLEANUP_FAILURE_GUARD_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'stay_on_while_plugged_in" "7"' -and $orchestrator -match 'screen_off_timeout" "1800000"' -and $orchestrator -match 'ALPHA5_ORCHESTRATOR_AWAKE_SETTING_MISMATCH' -and $orchestrator -match 'ALPHA5_PARTIAL_SETTING_RESTORE_FAILED') "ALPHA5_TEST_ORCHESTRATOR_AWAKE_GUARD_MISSING"
  Assert-Alpha5Test ($instrumentation -match 'FailureReportPath') "ALPHA5_TEST_INSTRUMENTATION_FAILURE_REPORT_MISSING"
  Assert-Alpha5Test ($performance -match 'ALPHA5_PERF_TRACE_SHA_DUPLICATE' -and $performance -match 'minimumFps = 12\.0' -and $performance -match 'minimumFps = 10\.0' -and $performance -match 'maximumLagMax' -and $performance -match 'PERFORMANCE_MISS' -and $performance -notmatch 'throw "ALPHA5_REVERSE_PERFORMANCE_GATE_FAILED') "ALPHA5_TEST_PERF_PERFORMANCE_THRESHOLDS_MISSING"
  Assert-Alpha5Test ($performance.Contains('(@($benchmarks[0].metrics.ccrRunIteration.runs) | ForEach-Object { [int]$_ }) -join ","')) "ALPHA5_TEST_PERF_RUN_ITERATION_INTEGER_NORMALIZATION_MISSING"
  Assert-Alpha5Test ($performance -match 'Assert-CcrPinnedBenchmarkEvidence' -and $instrumentation -match 'Assert-CcrPinnedReport' -and $random -match 'Assert-CcrPinnedReport') "ALPHA5_TEST_RESUME_FULL_REPORT_IDENTITY_GUARD_MISSING"
  Assert-Alpha5Test ($performance -match 'PINNED_MANIFEST_SYNTHETIC_ONLY_AND_PULLED_FILE_WHITELIST') "ALPHA5_TEST_PERF_PRIVACY_WHITELIST_MISSING"
  Assert-Alpha5Test ($random -match 'maximumAllowedP95Us = 791002L' -and $random -match 'maximumAllowedMaxUs = 2194244L' -and $random -match 'PERFORMANCE_MISS' -and $random -notmatch 'throw "ALPHA5_RANDOM_PERFORMANCE_GATE_FAILED') "ALPHA5_TEST_RANDOM_PERFORMANCE_THRESHOLDS_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'performanceMissStages' -and $orchestrator -match 'PERFORMANCE_MISS_PARTIAL' -and $orchestrator -notmatch 'throw "ALPHA5_PARITY_DIFFERENCE_EXCEEDED') "ALPHA5_TEST_NON_BLOCKING_PERFORMANCE_STATUS_MISSING"
  Assert-Alpha5Test ($orchestrator -match '(?s)"C"\s*\{.*run-s24-alpha5-navigation-perf\.ps1.*-Direction Forward.*if \(-not \$PreflightOnly\)' -and
      $orchestrator -match '(?s)"D"\s*\{.*run-s24-alpha5-navigation-perf\.ps1.*-Direction Reverse.*if \(-not \$PreflightOnly\)') "ALPHA5_TEST_PERF_PREFLIGHT_ORCHESTRATION_MISSING"
  Assert-Alpha5Test ($instrumentation -match 'ALPHA5_INSTRUMENTATION_RESUME_PREFLIGHT_DOMAIN_MISMATCH' -and
      $performance -match 'ALPHA5_PERF_RESUME_PREFLIGHT_DOMAIN_MISMATCH' -and
      $random -match 'ALPHA5_RANDOM_RESUME_PREFLIGHT_DOMAIN_MISMATCH') "ALPHA5_TEST_CHILD_PREFLIGHT_RESUME_DOMAIN_GUARDS_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'ALPHA5_PARITY_RESUME_EVIDENCE_MISMATCH' -and
      $orchestrator -match 'ALPHA5_ORCHESTRATOR_RESUME_PERFORMANCE_STATUS_MISMATCH') "ALPHA5_TEST_RESUME_PERFORMANCE_RECOMPUTE_MISSING"
  Assert-Alpha5Test ($orchestrator -match 'overallGateStatus' -and
      $orchestrator -match 'PENDING_USER_PERFORMANCE_MISS' -and
      $orchestrator -match 'ALPHA5_ORCHESTRATOR_RESUME_SUMMARY_STATUS_MISMATCH') "ALPHA5_TEST_FINAL_SUMMARY_STATUS_RECOMPUTE_MISSING"
  Assert-Alpha5Test ($instrumentation -match 'actualMeasurementDurationMs.*600000L' -and $instrumentation -match 'totalViolationCount') "ALPHA5_TEST_RESOURCE_REPORT_GATES_MISSING"
  Assert-Alpha5Test ($instrumentation -match 'foreach \(\$fixture in @\("h264-bframes\.mp4", "long-gop\.mp4", "vfr\.mp4"\)\)') "ALPHA5_TEST_SEQUENTIAL_FIXTURE_CONTRACT_MISMATCH"
  foreach ($resumeContract in @(
    [PSCustomObject]@{ Name = "instrumentation"; Source = $instrumentation },
    [PSCustomObject]@{ Name = "performance"; Source = $performance },
    [PSCustomObject]@{ Name = "random"; Source = $random }
  )) {
    Assert-Alpha5Test ($resumeContract.Source -notmatch '\[int\]\$existing\.maxMinutes -ne \$MaxMinutes') "ALPHA5_TEST_DYNAMIC_REMAINING_TIME_RESUME_REJECTED:$($resumeContract.Name)"
    Assert-Alpha5Test ($resumeContract.Source -match '\$storedMaxMinutes -lt 1 -or \$storedMaxMinutes -gt 240') "ALPHA5_TEST_STORED_DEADLINE_RANGE_GUARD_MISSING:$($resumeContract.Name)"
  }
} finally {
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "Alpha5 pinned-artifact script tests passed: $passed"
