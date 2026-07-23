$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Alpha 6 reuses the audited manifest/APK primitives. Runtime, harness, runtime
# input tree, manifest and APK hashes are deliberately supplied by the caller:
# this file is committed before the final Alpha 6 artifact identities exist.
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

$script:CcrAlpha6BaseImportPinnedArtifactManifest = ${function:Import-CcrPinnedArtifactManifest}
$script:CcrPinnedArtifactSetRevision = 4
$script:CcrPinnedVersionName = "0.2.0-alpha.6"
$script:CcrPinnedVersionCode = 7
$script:CcrPinnedRuntimeSourceSha = $null
$script:CcrPinnedRuntimeInputsTreeSha256 = $null
$script:CcrPinnedDebugAppSha256 = $null

function Test-CcrAlpha6NonZeroGitSha {
  param([object]$Value)
  return (Test-CcrPinnedGitSha $Value) -and ([string]$Value -cne ("0" * 40))
}

function Test-CcrAlpha6NonZeroSha256 {
  param([object]$Value)
  return (Test-CcrPinnedSha256 $Value) -and ([string]$Value -cne ("0" * 64))
}

function Assert-CcrAlpha6ManifestSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256
  )
  if (-not (Test-CcrAlpha6NonZeroSha256 $ArtifactManifestSha256)) {
    throw "ALPHA6_MANIFEST_EXPECTED_SHA_INVALID"
  }
  if (-not (Test-CcrPinnedAbsolutePath $ArtifactManifest)) {
    throw "ALPHA6_MANIFEST_PATH_NOT_ABSOLUTE"
  }
  $path = [System.IO.Path]::GetFullPath($ArtifactManifest)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ALPHA6_MANIFEST_NOT_FOUND"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  if ($actual -cne $ArtifactManifestSha256.ToLowerInvariant()) {
    throw "ALPHA6_MANIFEST_SHA_MISMATCH"
  }
  return $actual
}

function Assert-CcrAlpha6ExternalOutputDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$RepoRoot = (Get-CcrPinnedRepoRoot)
  )
  if (-not (Test-CcrPinnedAbsolutePath $OutputDirectory)) {
    throw "ALPHA6_OUTPUT_PATH_NOT_ABSOLUTE"
  }
  $output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
  $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if (Test-CcrPinnedPathWithin $output $repo) { throw "ALPHA6_OUTPUT_INSIDE_WORKTREE" }
  $cursor = $output
  while ($cursor) {
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -Force -LiteralPath $cursor
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ALPHA6_OUTPUT_REPARSE_POINT_FORBIDDEN:$cursor"
      }
    }
    $parent = [System.IO.Path]::GetDirectoryName($cursor)
    if (-not $parent -or $parent -ceq $cursor) { break }
    $cursor = $parent
  }
  [System.IO.Directory]::CreateDirectory($output) | Out-Null
  return $output
}

function Assert-CcrAlpha6SourceIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$HarnessSourceSha
  )
  $head = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or $head[0].Trim().ToLowerInvariant() -cne $HarnessSourceSha) {
    throw "ALPHA6_SOURCE_HEAD_MISMATCH"
  }
  $null = @(& git -C $RepoRoot cat-file -e "$RuntimeSourceSha`^{commit}" 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "ALPHA6_RUNTIME_SOURCE_COMMIT_UNAVAILABLE" }
  $status = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all 2>$null)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw "ALPHA6_SOURCE_WORKTREE_NOT_CLEAN" }
  return $true
}

function Assert-CcrAlpha6ValidationScriptsBuildFree {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ValidationScriptPaths)
  if ($ValidationScriptPaths.Count -eq 0) { throw "ALPHA6_VALIDATION_SCRIPT_SET_EMPTY" }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $records = [System.Collections.Generic.List[object]]::new()
  foreach ($path in $ValidationScriptPaths) {
    if (-not (Test-CcrPinnedAbsolutePath $path)) { throw "ALPHA6_VALIDATION_SCRIPT_PATH_NOT_ABSOLUTE" }
    $full = [System.IO.Path]::GetFullPath($path)
    if (-not $seen.Add($full)) { throw "ALPHA6_VALIDATION_SCRIPT_DUPLICATE:$full" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or
        [System.IO.Path]::GetExtension($full) -cne ".ps1") {
      throw "ALPHA6_VALIDATION_SCRIPT_INVALID:$full"
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $full,
      [ref]$tokens,
      [ref]$errors
    )
    if (@($errors).Count -ne 0) { throw "ALPHA6_VALIDATION_SCRIPT_PARSE_FAILED:$full" }
    $commands = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
      $name = [string]$command.GetCommandName()
      $text = $command.Extent.Text
      $leafName = if ([string]::IsNullOrWhiteSpace($name)) { "" } else { [System.IO.Path]::GetFileName($name) }
      $directBuildTool = $leafName -cmatch '(?i)^(?:gradlew(?:\.bat)?|gradle(?:\.bat)?|msbuild(?:\.exe)?|mvnw?(?:\.cmd)?|cargo(?:\.exe)?)$'
      $npmBuild = $leafName -cmatch '(?i)^npm(?:\.cmd)?$' -and $text -cmatch '(?i)\b(?:run\s+)?build\b'
      $dotnetBuild = $leafName -cmatch '(?i)^dotnet(?:\.exe)?$' -and $text -cmatch '(?i)\bbuild\b'
      $processBuild = ($name -cmatch '(?i)^Start-Process$' -or $text.TrimStart().StartsWith('&')) -and
        $text -cmatch '(?i)(?:gradlew?|msbuild|mvnw?|npm|dotnet|cargo)' -and
        $text -cmatch '(?i)(?:assemble|bundle|build)'
      if ($directBuildTool -or $npmBuild -or $dotnetBuild -or $processBuild) {
        throw "ALPHA6_DEVICE_VALIDATION_BUILD_COMMAND_FORBIDDEN:$full"
      }
    }
    $records.Add([PSCustomObject][ordered]@{
      path = $full
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
    }) | Out-Null
  }
  return $records.ToArray()
}

function Assert-CcrAlpha6ArtifactSetUnchanged {
  param([Parameter(Mandatory = $true)][object]$Context)
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Context.ArtifactSet.ManifestPath).Hash.ToLowerInvariant() -cne
      [string]$Context.ArtifactSet.ManifestSha256) {
    throw "ALPHA6_ARTIFACT_MANIFEST_CHANGED_AFTER_PREFLIGHT"
  }
  foreach ($role in $script:CcrPinnedRoles) {
    $artifact = $Context.ArtifactSet.Artifacts[$role]
    if ($null -eq $artifact -or -not (Test-Path -LiteralPath $artifact.path -PathType Leaf)) {
      throw "ALPHA6_ARTIFACT_MISSING_AFTER_PREFLIGHT:$role"
    }
    $item = Get-Item -LiteralPath $artifact.path
    if ([long]$item.Length -ne [long]$artifact.bytes -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact.path).Hash.ToLowerInvariant() -cne [string]$artifact.sha256) {
      throw "ALPHA6_ARTIFACT_CHANGED_AFTER_PREFLIGHT:$role"
    }
  }
  return $true
}

function New-CcrAlpha6TimedAdbInvoker {
  param(
    [Parameter(Mandatory = $true)][string]$AdbPath,
    [Parameter(Mandatory = $true)][object]$DeadlineState
  )
  $resolvedAdb = [System.IO.Path]::GetFullPath($AdbPath)
  return {
    param($Arguments)
    $deadline = if ($DeadlineState.CleanupMode) {
      [datetime]$DeadlineState.CleanupDeadlineUtc
    } else {
      [datetime]$DeadlineState.ValidationDeadlineUtc
    }
    $remainingMs = [long][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remainingMs -le 0L) {
      return [PSCustomObject]@{ exitCode = 124; output = "ALPHA6_ADB_DEADLINE_EXCEEDED" }
    }
    foreach ($argument in @($Arguments)) {
      if ([string]$argument -match '"') { throw "ALPHA6_ADB_ARGUMENT_QUOTE_FORBIDDEN" }
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = [System.Diagnostics.ProcessStartInfo]@{
      FileName = $resolvedAdb
      Arguments = (@($Arguments | ForEach-Object { '"' + [string]$_ + '"' }) -join ' ')
      UseShellExecute = $false
      RedirectStandardOutput = $true
      RedirectStandardError = $true
      CreateNoWindow = $true
    }
    try {
      if (-not $process.Start()) { throw "ALPHA6_ADB_PROCESS_START_FAILED" }
      $stdout = $process.StandardOutput.ReadToEndAsync()
      $stderr = $process.StandardError.ReadToEndAsync()
      $boundedMs = [int][Math]::Min([int]::MaxValue, [Math]::Max(1L, $remainingMs))
      if (-not $process.WaitForExit($boundedMs)) {
        try { $process.Kill() } catch { }
        try { $null = $process.WaitForExit(2000) } catch { }
        return [PSCustomObject]@{
          exitCode = 124
          output = "ALPHA6_ADB_PROCESS_TIMEOUT"
        }
      }
      $process.WaitForExit()
      $output = (($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) -join "`n").Trim()
      return [PSCustomObject]@{ exitCode = [int]$process.ExitCode; output = $output }
    } finally {
      $process.Dispose()
    }
  }.GetNewClosure()
}

function Initialize-CcrAlpha6PinnedDeviceSettings {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [AllowEmptyString()][string]$OriginalStayAwakeSetting = "",
    [AllowEmptyString()][string]$OriginalScreenTimeoutSetting = "",
    [object]$ResumeRestoreBaseline = $null
  )
  $observed = Save-CcrPinnedDeviceSettings $Context
  $missing = [System.Collections.Generic.List[string]]::new()
  $settingSpecs = @(
    [PSCustomObject]@{ Property = "stayAwake"; Namespace = "global"; Name = "stay_on_while_plugged_in"; ToolValue = "7" },
    [PSCustomObject]@{ Property = "brightnessMode"; Namespace = "system"; Name = "screen_brightness_mode"; ToolValue = "0" },
    [PSCustomObject]@{ Property = "brightness"; Namespace = "system"; Name = "screen_brightness"; ToolValue = "128" },
    [PSCustomObject]@{ Property = "screenTimeout"; Namespace = "system"; Name = "screen_off_timeout"; ToolValue = "1800000" },
    [PSCustomObject]@{ Property = "accelerometerRotation"; Namespace = "system"; Name = "accelerometer_rotation"; ToolValue = "0" },
    [PSCustomObject]@{ Property = "userRotation"; Namespace = "system"; Name = "user_rotation"; ToolValue = "0" }
  )
  $resumeBaselineProvided = $null -ne $ResumeRestoreBaseline
  $resumeObservedStateCompatible = $true
  $interruptedAttemptStateDetected = $false
  if ($resumeBaselineProvided) {
    foreach ($spec in $settingSpecs) {
      $baselineValue = [string](Get-CcrPinnedRequiredProperty $ResumeRestoreBaseline $spec.Property)
      $observedValue = [string]$observed.($spec.Property)
      if ($observedValue -cne $baselineValue -and $observedValue -cne $spec.ToolValue) {
        $resumeObservedStateCompatible = $false
      }
      if ($baselineValue -cne $spec.ToolValue -and $observedValue -ceq $spec.ToolValue) {
        $interruptedAttemptStateDetected = $true
      }
    }
    if (-not $resumeObservedStateCompatible) {
      $missing.Add("resume_device_settings_changed") | Out-Null
    } elseif ($interruptedAttemptStateDetected) {
      foreach ($spec in $settingSpecs) {
        $baselineValue = [string](Get-CcrPinnedRequiredProperty $ResumeRestoreBaseline $spec.Property)
        Set-CcrPinnedDeviceSetting $Context $spec.Namespace $spec.Name $baselineValue
        $Context.SavedSettings.($spec.Property) = $baselineValue
      }
    }
  }
  $staleStayAwake = [string]$Context.SavedSettings.stayAwake -ceq "15"
  $staleScreenTimeout = [string]$Context.SavedSettings.screenTimeout -ceq "600000"
  if ($staleStayAwake -and -not $resumeBaselineProvided -and [string]::IsNullOrWhiteSpace($OriginalStayAwakeSetting)) {
    $missing.Add("stay_on_while_plugged_in") | Out-Null
  }
  if ($staleScreenTimeout -and -not $resumeBaselineProvided -and [string]::IsNullOrWhiteSpace($OriginalScreenTimeoutSetting)) {
    $missing.Add("screen_off_timeout") | Out-Null
  }
  $record = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-device-settings-preflight"
    status = $(if ($missing.Count -eq 0) { "PASS" } else { "BLOCKED" })
    observed = [PSCustomObject][ordered]@{
      stayAwake = [string]$observed.stayAwake
      brightnessMode = [string]$observed.brightnessMode
      brightness = [string]$observed.brightness
      screenTimeout = [string]$observed.screenTimeout
      accelerometerRotation = [string]$observed.accelerometerRotation
      userRotation = [string]$observed.userRotation
    }
    staleStayAwakeDetected = $staleStayAwake
    staleScreenTimeoutDetected = $staleScreenTimeout
    trustedOriginalStayAwakeProvided = -not [string]::IsNullOrWhiteSpace($OriginalStayAwakeSetting)
    trustedOriginalScreenTimeoutProvided = -not [string]::IsNullOrWhiteSpace($OriginalScreenTimeoutSetting)
    resumeRestoreBaselineProvided = $resumeBaselineProvided
    resumeObservedStateCompatible = $resumeObservedStateCompatible
    interruptedAttemptStateDetected = $interruptedAttemptStateDetected
    restoredInterruptedAttemptBeforeValidation = $resumeBaselineProvided -and $resumeObservedStateCompatible -and $interruptedAttemptStateDetected
    missingTrustedOriginalSettings = $missing.ToArray()
    restoredBeforeValidation = $false
  }
  if ($missing.Count -ne 0) { return $record }
  if ($staleStayAwake) {
    $trustedStayAwake = if ($resumeBaselineProvided) {
      [string](Get-CcrPinnedRequiredProperty $ResumeRestoreBaseline "stayAwake")
    } else { $OriginalStayAwakeSetting }
    Set-CcrPinnedDeviceSetting $Context "global" "stay_on_while_plugged_in" $trustedStayAwake
    $Context.SavedSettings.stayAwake = $trustedStayAwake
  }
  if ($staleScreenTimeout) {
    $trustedScreenTimeout = if ($resumeBaselineProvided) {
      [string](Get-CcrPinnedRequiredProperty $ResumeRestoreBaseline "screenTimeout")
    } else { $OriginalScreenTimeoutSetting }
    Set-CcrPinnedDeviceSetting $Context "system" "screen_off_timeout" $trustedScreenTimeout
    $Context.SavedSettings.screenTimeout = $trustedScreenTimeout
  }
  $record.restoredBeforeValidation = $record.restoredInterruptedAttemptBeforeValidation -or $staleStayAwake -or $staleScreenTimeout
  $record | Add-Member -NotePropertyName effectiveRestoreBaseline -NotePropertyValue ([PSCustomObject][ordered]@{
    stayAwake = [string]$Context.SavedSettings.stayAwake
    brightnessMode = [string]$Context.SavedSettings.brightnessMode
    brightness = [string]$Context.SavedSettings.brightness
    screenTimeout = [string]$Context.SavedSettings.screenTimeout
    accelerometerRotation = [string]$Context.SavedSettings.accelerometerRotation
    userRotation = [string]$Context.SavedSettings.userRotation
  })
  return $record
}

function Invoke-CcrAlpha6PinnedHostPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
    [Parameter(Mandatory = $true)][bool]$PreflightOnly,
    [Parameter(Mandatory = $true)][long]$BuildCommandCount,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ValidationScriptPaths,
    [string]$RepoRoot = (Get-CcrPinnedRepoRoot),
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null,
    [scriptblock]$SourceIdentityVerifier = $null
  )
  if (-not (Test-CcrAlpha6NonZeroGitSha $RuntimeSourceSha)) { throw "ALPHA6_RUNTIME_SOURCE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroGitSha $HarnessSourceSha)) { throw "ALPHA6_HARNESS_SOURCE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroSha256 $RuntimeInputsTreeSha256)) { throw "ALPHA6_RUNTIME_INPUTS_TREE_SHA_INVALID" }
  if (-not (Test-CcrAlpha6NonZeroSha256 $ExpectedDebugAppSha256)) { throw "ALPHA6_DEBUG_APP_SHA_INVALID" }
  if ($BuildCommandCount -ne 0L) { throw "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO" }
  Assert-CcrPinnedRunId $RunId | Out-Null
  $manifestSha = Assert-CcrAlpha6ManifestSha256 $ArtifactManifest $ArtifactManifestSha256
  $scripts = @(Assert-CcrAlpha6ValidationScriptsBuildFree $ValidationScriptPaths)
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  if ($null -eq $SourceIdentityVerifier) {
    Assert-CcrAlpha6SourceIdentity $repo $RuntimeSourceSha $HarnessSourceSha | Out-Null
  } elseif ((& $SourceIdentityVerifier $repo $RuntimeSourceSha $HarnessSourceSha) -ne $true) {
    throw "ALPHA6_SOURCE_IDENTITY_VERIFIER_REJECTED"
  }
  $output = Assert-CcrAlpha6ExternalOutputDirectory $OutputDirectory $repo

  # Rebind only for this explicit v4 import. No future Alpha 6 source or
  # artifact identity is tracked as a placeholder in this helper.
  $script:CcrPinnedRuntimeSourceSha = $RuntimeSourceSha.ToLowerInvariant()
  $script:CcrPinnedRuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256.ToLowerInvariant()
  $script:CcrPinnedDebugAppSha256 = $ExpectedDebugAppSha256.ToLowerInvariant()
  $set = & $script:CcrAlpha6BaseImportPinnedArtifactManifest `
    -ArtifactManifest $ArtifactManifest `
    -RepoRoot $repo `
    -ExpectedHarnessSourceSha $HarnessSourceSha.ToLowerInvariant() `
    -AndroidTools $AndroidTools `
    -IdentityReader $IdentityReader `
    -TestOnlyExpectedDebugAppSha256 $ExpectedDebugAppSha256.ToLowerInvariant()
  if ($set.ManifestSha256 -cne $manifestSha) { throw "ALPHA6_PREFLIGHT_MANIFEST_SHA_MISMATCH" }
  Reserve-CcrPinnedRunId $output $RunId | Out-Null
  $context = [PSCustomObject][ordered]@{
    ArtifactSet = $set
    OutputDirectory = $output
    RunId = $RunId
    PreflightOnly = $PreflightOnly
    BuildCommandCount = 0L
    RuntimeSourceSha = $RuntimeSourceSha.ToLowerInvariant()
    HarnessSourceSha = $HarnessSourceSha.ToLowerInvariant()
    RuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256.ToLowerInvariant()
    ArtifactManifestSha256 = $manifestSha
    DebugAppSha256 = $ExpectedDebugAppSha256.ToLowerInvariant()
    ValidationScripts = $scripts
  }
  Assert-CcrAlpha6ArtifactSetUnchanged $context | Out-Null
  return $context
}
