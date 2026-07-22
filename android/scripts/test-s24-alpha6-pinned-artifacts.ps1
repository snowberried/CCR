$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1")

$passed = 0
function Assert-Alpha6PinnedTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_PINNED_TEST_FAILED:$Name" }
  $script:passed += 1
}
function Assert-Alpha6PinnedThrows {
  param([scriptblock]$Action, [string]$Expected, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ([string]$message -cne $Expected) {
    throw "ALPHA6_PINNED_EXPECTED_THROW_FAILED:$Name/$message/$Expected"
  }
  $script:passed += 1
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-pinned-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
  $runtimeSource = "1" * 40
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $certificate = $script:CcrPinnedSigningCertificateSha256
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
    [System.IO.File]::WriteAllText($path, "alpha6-$($role.role)", [System.Text.UTF8Encoding]::new($false))
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    $artifact = [PSCustomObject][ordered]@{
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
    }
    $artifacts.Add($artifact) | Out-Null
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
    artifactSetRevision = 4
    runtimeSourceSha = $runtimeSource
    harnessSourceSha = $harnessSource
    runtimeInputsTreeSha256 = $runtimeTree
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $artifacts.ToArray()
  }
  $manifestPath = Join-Path $root "artifact-manifest-v4.json"
  function Write-Alpha6PinnedManifest {
    [System.IO.File]::WriteAllText(
      $manifestPath,
      ($manifest | ConvertTo-Json -Depth 12),
      [System.Text.UTF8Encoding]::new($false)
    )
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  }
  $manifestSha = Write-Alpha6PinnedManifest
  $safeValidationScript = Join-Path $root "run-alpha6-device-validation.ps1"
  [System.IO.File]::WriteAllText(
    $safeValidationScript,
    'param([switch]$PreflightOnly) Write-Output "device validation host contract"',
    [System.Text.UTF8Encoding]::new($false)
  )
  $tools = [PSCustomObject]@{
    Adb = "must-not-be-called"
    ApkAnalyzer = "fake-apkanalyzer"
    ApkSigner = "fake-apksigner"
  }
  $identityCalls = 0
  $identityReader = {
    param($Artifact, $Tools)
    $script:identityCalls += 1
    return $identities[[string]$Artifact.role]
  }
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $common = @{
    ArtifactManifest = $manifestPath
    ArtifactManifestSha256 = $manifestSha
    OutputDirectory = (Join-Path $root "output")
    RunId = "alpha6-test-0001"
    RuntimeSourceSha = $runtimeSource
    HarnessSourceSha = $harnessSource
    RuntimeInputsTreeSha256 = $runtimeTree
    ExpectedDebugAppSha256 = [string]$artifacts[0].sha256
    PreflightOnly = $true
    BuildCommandCount = 0L
    ValidationScriptPaths = @($safeValidationScript)
    AndroidTools = $tools
    IdentityReader = $identityReader
    SourceIdentityVerifier = $sourceVerifier
  }

  $context = Invoke-CcrAlpha6PinnedHostPreflight @common
  Assert-Alpha6PinnedTest ($context.ArtifactSet.Manifest.artifactSetRevision -eq 4) "v4-revision"
  Assert-Alpha6PinnedTest ($context.RuntimeSourceSha -ceq $runtimeSource) "runtime-source-explicit"
  Assert-Alpha6PinnedTest ($context.HarnessSourceSha -ceq $harnessSource) "harness-source-explicit"
  Assert-Alpha6PinnedTest ($context.RuntimeInputsTreeSha256 -ceq $runtimeTree) "runtime-tree-explicit"
  Assert-Alpha6PinnedTest ($context.ArtifactManifestSha256 -ceq $manifestSha) "manifest-sha-explicit"
  Assert-Alpha6PinnedTest ($context.DebugAppSha256 -ceq [string]$artifacts[0].sha256) "debug-app-sha-explicit"
  Assert-Alpha6PinnedTest ($context.PreflightOnly -eq $true) "preflight-only-recorded"
  Assert-Alpha6PinnedTest ($context.BuildCommandCount -eq 0L) "device-build-count-zero"
  Assert-Alpha6PinnedTest ($context.ValidationScripts.Count -eq 1 -and
      (Test-CcrPinnedSha256 $context.ValidationScripts[0].sha256)) "validation-script-hash-recorded"
  Assert-Alpha6PinnedTest ($identityCalls -eq 4) "host-artifact-identity-inspected"
  Assert-Alpha6PinnedTest ((Assert-CcrAlpha6ArtifactSetUnchanged $context) -eq $true) "artifact-set-unchanged"

  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @common | Out-Null
  } "PINNED_RUN_ID_DUPLICATE:alpha6-test-0001" "run-id-must-be-unique"

  $beforeRejectedIdentity = $identityCalls
  $badManifestHash = @{} + $common
  $badManifestHash.RunId = "alpha6-test-0002"
  $badManifestHash.ArtifactManifestSha256 = "4" * 64
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @badManifestHash | Out-Null
  } "ALPHA6_MANIFEST_SHA_MISMATCH" "manifest-sha-fail-closed"
  Assert-Alpha6PinnedTest ($identityCalls -eq $beforeRejectedIdentity) "manifest-rejection-before-apk-inspection"

  $badRuntime = @{} + $common
  $badRuntime.RunId = "alpha6-test-0003"
  $badRuntime.RuntimeSourceSha = "4" * 40
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @badRuntime | Out-Null
  } "PINNED_MANIFEST_RUNTIME_SOURCE_MISMATCH" "runtime-source-mismatch"

  $badHarness = @{} + $common
  $badHarness.RunId = "alpha6-test-0004"
  $badHarness.HarnessSourceSha = "4" * 40
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @badHarness | Out-Null
  } "PINNED_MANIFEST_HARNESS_SOURCE_MISMATCH" "harness-source-mismatch"

  $badTree = @{} + $common
  $badTree.RunId = "alpha6-test-0005"
  $badTree.RuntimeInputsTreeSha256 = "4" * 64
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @badTree | Out-Null
  } "PINNED_MANIFEST_RUNTIME_TREE_MISMATCH" "runtime-tree-mismatch"

  $badDebugSha = @{} + $common
  $badDebugSha.RunId = "alpha6-test-0006"
  $badDebugSha.ExpectedDebugAppSha256 = "4" * 64
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @badDebugSha | Out-Null
  } "PINNED_DEBUG_APP_SHA_MISMATCH" "exact-debug-app-sha"

  $nonZeroBuild = @{} + $common
  $nonZeroBuild.RunId = "alpha6-test-0007"
  $nonZeroBuild.BuildCommandCount = 1L
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @nonZeroBuild | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO" "device-build-count-negative"

  [System.IO.File]::WriteAllText(
    $safeValidationScript,
    '& .\gradlew.bat assembleInternalDebug',
    [System.Text.UTF8Encoding]::new($false)
  )
  $buildScript = @{} + $common
  $buildScript.RunId = "alpha6-test-0008"
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @buildScript | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COMMAND_FORBIDDEN:$safeValidationScript" "assemble-command-negative"
  [System.IO.File]::WriteAllText(
    $safeValidationScript,
    'npm.cmd run build',
    [System.Text.UTF8Encoding]::new($false)
  )
  $buildScript.RunId = "alpha6-test-0008b"
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @buildScript | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COMMAND_FORBIDDEN:$safeValidationScript" "build-command-negative"
  [System.IO.File]::WriteAllText(
    $safeValidationScript,
    'param([switch]$PreflightOnly) Write-Output "gradlew and assemble are forbidden words, not commands"',
    [System.Text.UTF8Encoding]::new($false)
  )

  $sourceRejected = @{} + $common
  $sourceRejected.RunId = "alpha6-test-0009"
  $sourceRejected.SourceIdentityVerifier = { param($Repo, $Runtime, $Harness) return $false }
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @sourceRejected | Out-Null
  } "ALPHA6_SOURCE_IDENTITY_VERIFIER_REJECTED" "source-identity-negative"

  $emptyScripts = @{} + $common
  $emptyScripts.RunId = "alpha6-test-0010"
  $emptyScripts.ValidationScriptPaths = @()
  Assert-Alpha6PinnedThrows {
    Invoke-CcrAlpha6PinnedHostPreflight @emptyScripts | Out-Null
  } "ALPHA6_VALIDATION_SCRIPT_SET_EMPTY" "validation-script-set-required"

  foreach ($case in @(
    [PSCustomObject]@{ Name = "zero-runtime"; Parameter = "RuntimeSourceSha"; Value = "0" * 40; Error = "ALPHA6_RUNTIME_SOURCE_SHA_INVALID" },
    [PSCustomObject]@{ Name = "zero-harness"; Parameter = "HarnessSourceSha"; Value = "0" * 40; Error = "ALPHA6_HARNESS_SOURCE_SHA_INVALID" },
    [PSCustomObject]@{ Name = "zero-runtime-tree"; Parameter = "RuntimeInputsTreeSha256"; Value = "0" * 64; Error = "ALPHA6_RUNTIME_INPUTS_TREE_SHA_INVALID" },
    [PSCustomObject]@{ Name = "zero-debug-sha"; Parameter = "ExpectedDebugAppSha256"; Value = "0" * 64; Error = "ALPHA6_DEBUG_APP_SHA_INVALID" }
  )) {
    $arguments = @{} + $common
    $arguments.RunId = "alpha6-test-$($case.Name)"
    $arguments[$case.Parameter] = $case.Value
    Assert-Alpha6PinnedThrows {
      Invoke-CcrAlpha6PinnedHostPreflight @arguments | Out-Null
    } $case.Error $case.Name
  }

  $source = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    [System.Text.Encoding]::UTF8
  )
  Assert-Alpha6PinnedTest ($source -notmatch '(?m)^\s*\$script:CcrPinned(?:RuntimeSourceSha|RuntimeInputsTreeSha256|DebugAppSha256)\s*=\s*"[0-9a-f]{40,64}"') "no-tracked-alpha6-sha-placeholder"
  Assert-Alpha6PinnedTest ($source -notmatch 'Invoke-CcrPinnedPreflight|Get-CcrPinnedS24Device|Invoke-CcrPinnedAdb') "host-preflight-has-no-adb-path"
  Assert-Alpha6PinnedTest ($source.Contains("New-CcrAlpha6TimedAdbInvoker") -and
    $source.Contains("Initialize-CcrAlpha6PinnedDeviceSettings")) "deadline-and-stale-settings-helpers-present"
  Assert-Alpha6PinnedTest ($source.Contains('$null = $process.WaitForExit(2000)') -and
    -not $source.Contains('try { $process.WaitForExit() } catch { }')) "timeout-cleanup-remains-bounded"

  $deadlineState = [PSCustomObject]@{
    ValidationDeadlineUtc = [DateTime]::UtcNow.AddSeconds(5)
    CleanupMode = $false
    CleanupDeadlineUtc = [DateTime]::UtcNow.AddSeconds(5)
  }
  $timedInvoker = New-CcrAlpha6TimedAdbInvoker (Join-Path $env:SystemRoot "System32\where.exe") $deadlineState
  $quick = & $timedInvoker @("cmd.exe")
  Assert-Alpha6PinnedTest ($quick.exitCode -eq 0 -and $quick.output -match "cmd.exe") "timed-invoker-success"
  $deadlineState.ValidationDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(150)
  $timedPowerShell = New-CcrAlpha6TimedAdbInvoker (Join-Path $PSHOME "powershell.exe") $deadlineState
  $timedOut = & $timedPowerShell @("-NoProfile", "-Command", "Start-Sleep -Seconds 2")
  Assert-Alpha6PinnedTest ($timedOut.exitCode -eq 124 -and $timedOut.output -ceq "ALPHA6_ADB_PROCESS_TIMEOUT") "timed-invoker-kills-hung-process"
  $deadlineState.ValidationDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(-1)
  $expired = & $timedInvoker @("cmd.exe")
  Assert-Alpha6PinnedTest ($expired.exitCode -eq 124 -and $expired.output -ceq "ALPHA6_ADB_DEADLINE_EXCEEDED") "expired-deadline-never-starts-process"

  $settingsState = @{
    "global/stay_on_while_plugged_in" = "7"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "128"
    "system/screen_off_timeout" = "1800000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }
  $settingsInvoker = {
    param($Arguments)
    $operation = [string]$Arguments[4]
    $key = "$($Arguments[5])/$($Arguments[6])"
    if ($operation -ceq "get") { return [PSCustomObject]@{ exitCode = 0; output = [string]$settingsState[$key] } }
    if ($operation -ceq "put") { $settingsState[$key] = [string]$Arguments[7]; return [PSCustomObject]@{ exitCode = 0; output = "" } }
    if ($operation -ceq "delete") { $settingsState[$key] = "null"; return [PSCustomObject]@{ exitCode = 0; output = "" } }
    return [PSCustomObject]@{ exitCode = 1; output = "unexpected" }
  }.GetNewClosure()
  $settingsContext = [PSCustomObject]@{ Adb = "fake-adb"; AdbInvoker = $settingsInvoker; Serial = "FAKE-S24" }
  $restoreBaseline = [PSCustomObject][ordered]@{
    stayAwake = "0"; brightnessMode = "1"; brightness = "77"; screenTimeout = "120000"
    accelerometerRotation = "1"; userRotation = "2"
  }
  $interrupted = Initialize-CcrAlpha6PinnedDeviceSettings -Context $settingsContext -ResumeRestoreBaseline $restoreBaseline
  Assert-Alpha6PinnedTest ($interrupted.status -ceq "PASS" -and
    $interrupted.interruptedAttemptStateDetected -eq $true -and
    $interrupted.restoredInterruptedAttemptBeforeValidation -eq $true -and
    [string]$settingsState["system/screen_off_timeout"] -ceq "120000") "resume-restores-known-tool-setting-vector"

  $settingsState["system/screen_brightness"] = "200"
  $changed = Initialize-CcrAlpha6PinnedDeviceSettings -Context $settingsContext -ResumeRestoreBaseline $restoreBaseline
  Assert-Alpha6PinnedTest ($changed.status -ceq "BLOCKED" -and
    @($changed.missingTrustedOriginalSettings) -ccontains "resume_device_settings_changed" -and
    [string]$settingsState["system/screen_brightness"] -ceq "200") "resume-blocks-on-possible-user-setting-change"

  $devicePending = @{} + $common
  $devicePending.RunId = "alpha6-test-0011"
  $devicePending.PreflightOnly = $false
  $deviceContext = Invoke-CcrAlpha6PinnedHostPreflight @devicePending
  Assert-Alpha6PinnedTest ($deviceContext.PreflightOnly -eq $false -and
      $deviceContext.BuildCommandCount -eq 0L) "device-validation-pending-build-count-zero"

  [System.IO.File]::AppendAllText([string]$artifacts[0].path, "tamper")
  Assert-Alpha6PinnedThrows {
    Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  } "ALPHA6_ARTIFACT_CHANGED_AFTER_PREFLIGHT:debugApp" "post-preflight-artifact-tamper"
} finally {
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "Alpha 6 pinned-artifact v4 host tests passed: $passed"
