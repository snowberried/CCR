$ErrorActionPreference = "Stop"

# Alpha.5 intentionally reuses the audited artifact/ADB primitives.  The
# constants below are rebound in the caller's script scope; no Alpha.4 file is
# changed and no build command exists in this helper.
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

$script:CcrAlpha5BasePinnedPreflight = ${function:Invoke-CcrPinnedPreflight}
$script:CcrPinnedArtifactSetRevision = 3
$script:CcrPinnedRuntimeSourceSha = "823c39504a1ddd8f0e457755ebff0d067d6dc863"
$script:CcrPinnedRuntimeInputsTreeSha256 = "9689cadf140b54d0b93f67749e527fc8fab1392d0cd4117893ea91908f7530b3"
$script:CcrPinnedVersionName = "0.2.0-alpha.5"
$script:CcrPinnedVersionCode = 6
$script:CcrPinnedMainActivityClass = "com.snowberried.ctcinereviewer.MainActivity"
$script:CcrPinnedMainActivityComponent = "$script:CcrPinnedAppPackage/$script:CcrPinnedMainActivityClass"

$script:CcrAlpha5BaseAdbRaw = ${function:Invoke-CcrPinnedAdbRaw}
$script:CcrAlpha5ActiveDeadlineUtc = $null
$script:CcrAlpha5CleanupDeadlineUtc = $null

function Set-CcrAlpha5ActiveDeadline {
  param([Parameter(Mandatory = $true)][datetime]$DeadlineUtc)
  $script:CcrAlpha5ActiveDeadlineUtc = $DeadlineUtc.ToUniversalTime()
}

function Enter-CcrAlpha5CleanupWindow {
  param([ValidateRange(1, 5)][int]$Minutes = 2)
  $script:CcrAlpha5CleanupDeadlineUtc = [DateTime]::UtcNow.AddMinutes($Minutes)
  $script:CcrAlpha5ActiveDeadlineUtc = $script:CcrAlpha5CleanupDeadlineUtc
}

function ConvertTo-CcrAlpha5WindowsCommandLine {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $quoted = foreach ($argument in $Arguments) {
    if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') { $argument; continue }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $argument.ToCharArray()) {
      if ($character -eq [char]92) { $slashes += 1; continue }
      if ($character -eq [char]34) {
        if ($slashes -gt 0) { [void]$builder.Append((([string][char]92 * ($slashes * 2 + 1)))) }
        else { [void]$builder.Append([char]92) }
        [void]$builder.Append([char]34)
      } else {
        if ($slashes -gt 0) { [void]$builder.Append((([string][char]92 * $slashes))) }
        [void]$builder.Append($character)
      }
      $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append((([string][char]92 * ($slashes * 2)))) }
    [void]$builder.Append('"')
    $builder.ToString()
  }
  return ($quoted -join ' ')
}

function Stop-CcrAlpha5ProcessTree {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
  if ($Process.HasExited) { return }
  $treeKillSucceeded = $false
  try {
    # Available on newer .NET runtimes.
    $Process.Kill($true)
    $treeKillSucceeded = $true
  } catch {
    # Windows PowerShell 5.1 runs on .NET Framework, which has no Kill(bool).
    $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
    $taskkillInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $taskkillInfo.FileName = $taskkillPath
    $taskkillInfo.Arguments = "/PID $($Process.Id) /T /F"
    $taskkillInfo.UseShellExecute = $false
    $taskkillInfo.CreateNoWindow = $true
    $taskkillInfo.RedirectStandardOutput = $true
    $taskkillInfo.RedirectStandardError = $true
    $taskkill = [System.Diagnostics.Process]::new()
    $taskkill.StartInfo = $taskkillInfo
    try {
      if ($taskkill.Start()) {
        $stdout = $taskkill.StandardOutput.ReadToEndAsync()
        $stderr = $taskkill.StandardError.ReadToEndAsync()
        if ($taskkill.WaitForExit(10000)) {
          $taskkill.WaitForExit()
          $treeKillSucceeded = $taskkill.ExitCode -eq 0
          $null = $stdout.Result
          $null = $stderr.Result
        } else {
          try { $taskkill.Kill() } catch { }
        }
      }
    } finally { $taskkill.Dispose() }
  }
  try { $Process.WaitForExit(5000) | Out-Null } catch { }
  $Process.Refresh()
  if (-not $treeKillSucceeded -or -not $Process.HasExited) {
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
    throw "ALPHA5_PROCESS_TREE_TERMINATION_FAILED"
  }
}

function Invoke-CcrAlpha5TimedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$TimeoutFailure
  )
  if ($null -eq $script:CcrAlpha5ActiveDeadlineUtc) { throw "ALPHA5_DEADLINE_NOT_CONFIGURED" }
  $remainingMs = [long][Math]::Floor(($script:CcrAlpha5ActiveDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
  if ($remainingMs -le 0) { throw $TimeoutFailure }
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = ConvertTo-CcrAlpha5WindowsCommandLine $Arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "ALPHA5_PROCESS_START_FAILED:$FilePath" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit([int][Math]::Min($remainingMs, [int]::MaxValue))) {
      try { Stop-CcrAlpha5ProcessTree $process } catch { throw "$TimeoutFailure/$($_.Exception.Message)" }
      throw $TimeoutFailure
    }
    $process.WaitForExit()
    $output = @($stdout.Result.TrimEnd(), $stderr.Result.TrimEnd()) |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return [PSCustomObject]@{ exitCode = [int]$process.ExitCode; output = ($output -join "`n").Trim() }
  } finally { $process.Dispose() }
}

function Invoke-CcrPinnedTool {
  param([string]$FilePath, [string[]]$Arguments, [string]$Failure)
  $target = $FilePath
  $processArguments = $Arguments
  if ([System.IO.Path]::GetExtension($FilePath) -in @(".bat", ".cmd")) {
    $target = $env:ComSpec
    # `call` keeps the quoted batch path as a command token instead of making
    # cmd.exe treat escaped quotes as literal filename characters.
    $processArguments = @("/d", "/s", "/c", "call", $FilePath) + @($Arguments)
  }
  $result = Invoke-CcrAlpha5TimedProcess $target $processArguments "ALPHA5_APK_INSPECTION_DEADLINE_EXCEEDED:$Failure"
  if ($result.exitCode -ne 0) { throw "$Failure exit=$($result.exitCode) output=$($result.output)" }
  return $result.output
}

function Invoke-CcrPinnedAdbRaw {
  param(
    [Parameter(Mandatory = $true)][string]$Adb,
    [scriptblock]$AdbInvoker,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  if ($null -ne $AdbInvoker) { return & $script:CcrAlpha5BaseAdbRaw $Adb $AdbInvoker $Arguments }
  return Invoke-CcrAlpha5TimedProcess $Adb $Arguments "ALPHA5_ADB_DEADLINE_EXCEEDED"
}

function Assert-CcrAlpha5ManifestSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256
  )
  if (-not (Test-CcrPinnedSha256 $ArtifactManifestSha256)) {
    throw "ALPHA5_MANIFEST_EXPECTED_SHA_INVALID"
  }
  if (-not (Test-CcrPinnedAbsolutePath $ArtifactManifest)) {
    throw "ALPHA5_MANIFEST_PATH_NOT_ABSOLUTE"
  }
  $path = [System.IO.Path]::GetFullPath($ArtifactManifest)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ALPHA5_MANIFEST_NOT_FOUND"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  if ($actual -cne $ArtifactManifestSha256.ToLowerInvariant()) {
    throw "ALPHA5_MANIFEST_SHA_MISMATCH"
  }
  return $actual
}

function Assert-CcrAlpha5ExternalOutputDirectory {
  param([Parameter(Mandatory = $true)][string]$OutputDirectory, [string]$RepoRoot = (Get-CcrPinnedRepoRoot))
  if (-not (Test-CcrPinnedAbsolutePath $OutputDirectory)) { throw "ALPHA5_OUTPUT_PATH_NOT_ABSOLUTE" }
  $output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
  $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if (Test-CcrPinnedPathWithin $output $repo) { throw "ALPHA5_OUTPUT_INSIDE_WORKTREE" }
  $cursor = $output
  while ($cursor) {
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -Force -LiteralPath $cursor
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ALPHA5_OUTPUT_REPARSE_POINT_FORBIDDEN:$cursor"
      }
    }
    $parent = [System.IO.Path]::GetDirectoryName($cursor)
    if (-not $parent -or $parent -ceq $cursor) { break }
    $cursor = $parent
  }
  [System.IO.Directory]::CreateDirectory($output) | Out-Null
  $created = Get-Item -Force -LiteralPath $output
  if (($created.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "ALPHA5_OUTPUT_REPARSE_POINT_FORBIDDEN:$output"
  }
  return $output
}

function New-CcrAlpha5ManifestSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
  )
  if (-not (Test-CcrPinnedAbsolutePath $ArtifactManifest)) { throw "ALPHA5_MANIFEST_PATH_NOT_ABSOLUTE" }
  $sourcePath = [System.IO.Path]::GetFullPath($ArtifactManifest)
  $sourceItem = Get-Item -Force -LiteralPath $sourcePath -ErrorAction Stop
  if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "ALPHA5_MANIFEST_REPARSE_POINT_FORBIDDEN"
  }
  $stream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $memory = [System.IO.MemoryStream]::new()
    try {
      $stream.CopyTo($memory)
      $bytes = $memory.ToArray()
    } finally { $memory.Dispose() }
  } finally { $stream.Dispose() }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $actual = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
  if ($actual -cne $ArtifactManifestSha256.ToLowerInvariant()) { throw "ALPHA5_MANIFEST_SHA_MISMATCH" }
  $snapshot = Join-Path $OutputDirectory "artifact-manifest-$actual.snapshot.json"
  if (Test-Path -LiteralPath $snapshot) {
    $item = Get-Item -Force -LiteralPath $snapshot
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot).Hash.ToLowerInvariant() -cne $actual) {
      throw "ALPHA5_MANIFEST_SNAPSHOT_IDENTITY_MISMATCH"
    }
  } else {
    $target = [System.IO.File]::Open($snapshot, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $target.Write($bytes, 0, $bytes.Length); $target.Flush($true) } finally { $target.Dispose() }
  }
  [System.IO.File]::SetAttributes($snapshot, [System.IO.FileAttributes]::ReadOnly)
  return [System.IO.Path]::GetFullPath($snapshot)
}

function Assert-CcrAlpha5SourceFreeze {
  param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][string]$ExpectedHarnessSourceSha)
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  $head = Invoke-CcrAlpha5TimedProcess "git.exe" @("-C", $repo, "rev-parse", "HEAD") "ALPHA5_SOURCE_FREEZE_GIT_TIMEOUT"
  if ($head.exitCode -ne 0 -or $head.output.Trim() -cne $ExpectedHarnessSourceSha) {
    throw "ALPHA5_SOURCE_FREEZE_HEAD_MISMATCH"
  }
  $status = Invoke-CcrAlpha5TimedProcess "git.exe" @("-C", $repo, "status", "--porcelain=v1", "--untracked-files=all") "ALPHA5_SOURCE_FREEZE_GIT_TIMEOUT"
  if ($status.exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($status.output)) {
    throw "ALPHA5_SOURCE_FREEZE_WORKTREE_NOT_CLEAN"
  }
  $inputs = @(
    "android/scripts/s24-pinned-artifacts.ps1",
    "android/scripts/s24-alpha5-pinned-artifacts.ps1",
    "android/scripts/alpha4-baseline-contract.ps1",
    "android/scripts/run-s24-alpha5-instrumentation.ps1",
    "android/scripts/run-s24-alpha5-navigation-perf.ps1",
    "android/scripts/run-s24-alpha5-random.ps1",
    "android/scripts/run-s24-alpha5-validation.ps1",
    "android/scripts/test-s24-alpha5-pinned-artifacts.ps1",
    "android/tools/verify-runtime-inputs-alpha5.mjs",
    "android/validation/runtime-inputs-alpha5-v1.json"
  )
  foreach ($relative in $inputs) {
    $tracked = Invoke-CcrAlpha5TimedProcess "git.exe" @("-C", $repo, "ls-files", "--error-unmatch", "--", $relative) "ALPHA5_SOURCE_FREEZE_GIT_TIMEOUT"
    if ($tracked.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($tracked.output)) { throw "ALPHA5_SOURCE_FREEZE_INPUT_UNTRACKED:$relative" }
    $path = Join-Path $repo ($relative -replace '/', '\')
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "ALPHA5_SOURCE_FREEZE_REPARSE_POINT:$relative" }
  }
  $diff = Invoke-CcrAlpha5TimedProcess "git.exe" @("-C", $repo, "diff", "--quiet", "HEAD", "--") "ALPHA5_SOURCE_FREEZE_GIT_TIMEOUT"
  if ($diff.exitCode -ne 0) { throw "ALPHA5_SOURCE_FREEZE_HEAD_BYTES_MISMATCH" }
  $node = (Get-Command node -ErrorAction Stop).Source
  $runtime = Invoke-CcrAlpha5TimedProcess $node @((Join-Path $repo "android\tools\verify-runtime-inputs-alpha5.mjs")) "ALPHA5_RUNTIME_INPUT_VERIFY_TIMEOUT"
  if ($runtime.exitCode -ne 0) { throw "ALPHA5_RUNTIME_INPUT_VERIFY_FAILED:$($runtime.output)" }
}

function Invoke-CcrAlpha5PinnedPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$RepoRoot = (Get-CcrPinnedRepoRoot),
    [string]$ExpectedHarnessSourceSha = "",
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null,
    [scriptblock]$AdbInvoker = $null
  )
  # All source/artifact checks and immutable manifest capture happen before ADB.
  if ($null -eq $script:CcrAlpha5ActiveDeadlineUtc) { throw "ALPHA5_DEADLINE_NOT_CONFIGURED" }
  Assert-CcrAlpha5ManifestSha256 $ArtifactManifest $ArtifactManifestSha256 | Out-Null
  $output = Assert-CcrAlpha5ExternalOutputDirectory $OutputDirectory $RepoRoot
  $snapshot = New-CcrAlpha5ManifestSnapshot $ArtifactManifest $ArtifactManifestSha256 $output
  $raw = [System.IO.File]::ReadAllText($snapshot, [System.Text.Encoding]::UTF8)
  try { $manifest = $raw | ConvertFrom-Json } catch { throw "ALPHA5_MANIFEST_JSON_INVALID" }
  if ([int](Get-CcrPinnedRequiredProperty $manifest "schemaVersion") -ne $script:CcrPinnedSchemaVersion) { throw "PINNED_MANIFEST_SCHEMA_MISMATCH" }
  if ([int](Get-CcrPinnedRequiredProperty $manifest "artifactSetRevision") -ne $script:CcrPinnedArtifactSetRevision) { throw "PINNED_MANIFEST_REVISION_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "runtimeSourceSha") -cne $script:CcrPinnedRuntimeSourceSha) { throw "PINNED_MANIFEST_RUNTIME_SOURCE_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "runtimeInputsTreeSha256") -cne $script:CcrPinnedRuntimeInputsTreeSha256) { throw "PINNED_MANIFEST_RUNTIME_TREE_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "versionName") -cne $script:CcrPinnedVersionName -or
      [int](Get-CcrPinnedRequiredProperty $manifest "versionCode") -ne $script:CcrPinnedVersionCode) { throw "PINNED_MANIFEST_VERSION_MISMATCH" }
  if ((Get-CcrPinnedRequiredProperty $manifest "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $manifest "containsRealMediaMetadata") -ne $false) { throw "PINNED_MANIFEST_PRIVACY_MISMATCH" }
  $debugEntries = @($manifest.artifacts | Where-Object { [string]$_.role -ceq "debugApp" })
  if ($debugEntries.Count -ne 1 -or -not (Test-CcrPinnedSha256 $debugEntries[0].sha256)) {
    throw "ALPHA5_MANIFEST_DEBUG_APP_SHA_INVALID"
  }
  # The external manifest SHA is the trust anchor, so its debug APK hash is
  # safe to use as the immutable expected value without a circular tracked hash.
  $script:CcrPinnedDebugAppSha256 = [string]$debugEntries[0].sha256
  $manifestHarnessSha = [string](Get-CcrPinnedRequiredProperty $manifest "harnessSourceSha")
  if ($ExpectedHarnessSourceSha -and $ExpectedHarnessSourceSha -cne $manifestHarnessSha) { throw "ALPHA5_EXPECTED_HARNESS_SOURCE_MISMATCH" }
  Assert-CcrAlpha5SourceFreeze ([System.IO.Path]::GetFullPath($RepoRoot)) $manifestHarnessSha
  $parameters = @{
    ArtifactManifest = $snapshot
    OutputDirectory = $output
    RepoRoot = $RepoRoot
    ExpectedHarnessSourceSha = $manifestHarnessSha
    AndroidTools = $AndroidTools
    IdentityReader = $IdentityReader
    AdbInvoker = $AdbInvoker
    TestOnlyExpectedDebugAppSha256 = $script:CcrPinnedDebugAppSha256
  }
  $context = & $script:CcrAlpha5BasePinnedPreflight @parameters
  $set = $context.ArtifactSet
  if ($set.ManifestSha256 -cne $ArtifactManifestSha256.ToLowerInvariant() -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot).Hash.ToLowerInvariant() -cne $ArtifactManifestSha256.ToLowerInvariant()) {
    throw "ALPHA5_PREFLIGHT_MANIFEST_SHA_MISMATCH"
  }
  $set | Add-Member -Force -NotePropertyName OriginalManifestPath -NotePropertyValue ([System.IO.Path]::GetFullPath($ArtifactManifest))
  $set | Add-Member -Force -NotePropertyName ManifestSnapshotPath -NotePropertyValue $snapshot
  return $context
}

function Assert-CcrAlpha5Deadline {
  param([Parameter(Mandatory = $true)][datetime]$DeadlineUtc, [Parameter(Mandatory = $true)][string]$Stage)
  if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw "ALPHA5_MAX_MINUTES_EXCEEDED:$Stage" }
}

function New-CcrAlpha5DeadlineUtc {
  param([ValidateRange(1, 240)][int]$MaxMinutes)
  return [DateTime]::UtcNow.AddMinutes($MaxMinutes)
}

function Write-CcrAlpha5ImmutableJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  if (Test-Path -LiteralPath $Path) { throw "ALPHA5_EVIDENCE_ALREADY_EXISTS:$Path" }
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally { $stream.Dispose() }
  [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::ReadOnly)
  return [System.IO.Path]::GetFullPath($Path)
}

function Assert-CcrAlpha5EvidenceFileRecord {
  param(
    [Parameter(Mandatory = $true)][object]$Record,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Failure
  )
  foreach ($field in @("path", "bytes", "sha256")) {
    if (-not (Test-CcrPinnedProperty $Record $field)) { throw "$Failure/missing-$field" }
  }
  if (-not (Test-CcrPinnedAbsolutePath ([string]$Record.path)) -or -not (Test-CcrPinnedSha256 ([string]$Record.sha256))) {
    throw "$Failure/identity"
  }
  $path = [System.IO.Path]::GetFullPath([string]$Record.path)
  $output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
  if (-not (Test-CcrPinnedPathWithin $path $output) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "$Failure/path"
  }
  $item = Get-Item -Force -LiteralPath $path
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      [long]$item.Length -le 0 -or [long]$item.Length -ne [long]$Record.bytes) {
    throw "$Failure/file"
  }
  $cursor = [System.IO.Path]::GetDirectoryName($path)
  while ($cursor -and (Test-CcrPinnedPathWithin $cursor $output)) {
    $directory = Get-Item -Force -LiteralPath $cursor
    if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Failure/reparse" }
    if ($cursor.TrimEnd('\', '/') -ceq $output) { break }
    $cursor = [System.IO.Path]::GetDirectoryName($cursor)
  }
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne [string]$Record.sha256) {
    throw "$Failure/hash"
  }
  return $path
}

function New-CcrAlpha5IdentityRecord {
  param([Parameter(Mandatory = $true)][object]$Context)
  return [PSCustomObject][ordered]@{
    artifactManifest = $Context.ArtifactSet.ManifestPath
    artifactManifestSha256 = $Context.ArtifactSet.ManifestSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    versionName = $script:CcrPinnedVersionName
    versionCode = $script:CcrPinnedVersionCode
    applicationId = $script:CcrPinnedAppPackage
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $Context "debugTest").sha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256
    device = [PSCustomObject][ordered]@{
      serial = $Context.Serial
      model = $Context.Model
      fingerprint = $Context.Fingerprint
      securityPatch = $Context.SecurityPatch
      sdk = $Context.Sdk
    }
  }
}

function Assert-CcrAlpha5IdentityRecord {
  param([Parameter(Mandatory = $true)][object]$Actual, [Parameter(Mandatory = $true)][object]$Context, [string]$Failure = "ALPHA5_IDENTITY_MISMATCH")
  $expectedFields = [ordered]@{
    artifactManifestSha256 = [string]$Context.ArtifactSet.ManifestSha256
    artifactSetRevision = [string]$script:CcrPinnedArtifactSetRevision
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    versionName = [string]$script:CcrPinnedVersionName
    versionCode = [string]$script:CcrPinnedVersionCode
    applicationId = [string]$script:CcrPinnedAppPackage
    debugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $Context "debugTest").sha256
    benchmarkAppSha256 = [string](Get-CcrPinnedArtifact $Context "benchmarkApp").sha256
    macrobenchmarkTestSha256 = [string](Get-CcrPinnedArtifact $Context "macrobenchmarkTest").sha256
  }
  foreach ($field in $expectedFields.Keys) {
    $actualValue = if (Test-CcrPinnedProperty $Actual $field) { [string](Get-CcrPinnedRequiredProperty $Actual $field) } else { "<missing>" }
    $expectedValue = [string]($expectedFields[$field])
    if ($actualValue -cne $expectedValue) { throw "$Failure/$field actual=$actualValue expected=$expectedValue" }
  }
  if (-not (Test-CcrPinnedProperty $Actual "device")) { throw "$Failure/device" }
  foreach ($field in @("serial", "model", "fingerprint", "securityPatch", "sdk")) {
    $contextField = $field.Substring(0,1).ToUpperInvariant() + $field.Substring(1)
    if (-not (Test-CcrPinnedProperty $Actual.device $field) -or
        [string](Get-CcrPinnedRequiredProperty $Actual.device $field) -cne [string](Get-CcrPinnedRequiredProperty $Context $contextField)) { throw "$Failure/device.$field" }
  }
  return $true
}

function Assert-CcrAlpha5SettingsRestored {
  param([Parameter(Mandatory = $true)][object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings")) { throw "ALPHA5_SAVED_SETTINGS_MISSING" }
  foreach ($entry in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    $actual = Get-CcrPinnedDeviceSetting $Context $entry[0] $entry[1]
    if ([string]$actual -cne [string]$entry[2]) { throw "ALPHA5_SETTING_RESTORE_READBACK_MISMATCH:$($entry[0])/$($entry[1])" }
  }
  return $true
}
