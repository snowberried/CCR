$script:CcrPinnedSchemaVersion = 1
$script:CcrPinnedArtifactSetRevision = 2
$script:CcrPinnedRuntimeSourceSha = "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e"
$script:CcrPinnedRuntimeInputsTreeSha256 = "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941"
$script:CcrPinnedVersionName = "0.2.0-alpha.4"
$script:CcrPinnedVersionCode = 5
$script:CcrPinnedDebugAppSha256 = "5a7febeb74b2abe9ed8cc5651d145044f16c55203e2beb875ce901f35fdcaf80"
$script:CcrPinnedSigningCertificateSha256 = "49379c1b2a2fec8a50c320955a7027c515aff10f28483b08ae9c27b3ffcfbef0"
$script:CcrPinnedAppPackage = "com.snowberried.ctcinereviewer.internal"
$script:CcrPinnedDebugTestPackage = "$script:CcrPinnedAppPackage.test"
$script:CcrPinnedMacrobenchmarkPackage = "com.snowberried.ctcinereviewer.macrobenchmark"
$script:CcrPinnedRunner = "androidx.test.runner.AndroidJUnitRunner"
$script:CcrPinnedRoles = @("debugApp", "debugTest", "benchmarkApp", "macrobenchmarkTest")

function Test-CcrPinnedProperty {
  param([Parameter(Mandatory = $true)][object]$Value, [Parameter(Mandatory = $true)][string]$Name)
  return $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CcrPinnedRequiredProperty {
  param([Parameter(Mandatory = $true)][object]$Value, [Parameter(Mandatory = $true)][string]$Name)
  if (-not (Test-CcrPinnedProperty $Value $Name)) { throw "PINNED_MANIFEST_PROPERTY_MISSING:$Name" }
  return $Value.PSObject.Properties[$Name].Value
}

function Assert-CcrPinnedNullableEqual {
  param([object]$Expected, [object]$Actual, [string]$Failure)
  if (($null -eq $Expected) -xor ($null -eq $Actual)) { throw $Failure }
  if ($null -ne $Expected -and [string]$Expected -cne [string]$Actual) { throw $Failure }
}

function Test-CcrPinnedSha256 {
  param([object]$Value)
  return $null -ne $Value -and ([string]$Value) -cmatch "^[a-f0-9]{64}$"
}

function Test-CcrPinnedGitSha {
  param([object]$Value)
  return $null -ne $Value -and ([string]$Value) -cmatch "^[a-f0-9]{40}$"
}

function Assert-CcrPinnedRunId {
  param([object]$RunId)
  if ($null -eq $RunId -or ([string]$RunId) -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$") {
    throw "PINNED_RUN_ID_INVALID"
  }
  return [string]$RunId
}

function Get-CcrPinnedRepoRoot {
  return [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Test-CcrPinnedAbsolutePath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) { return $false }
  if ($Path -match "^[A-Za-z]:[^\\/]") { return $false }
  return $true
}

function Test-CcrPinnedPathWithin {
  param([string]$Candidate, [string]$Root)
  $pathSeparators = [char[]]@([char]92, [char]47)
  $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd($pathSeparators)
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($pathSeparators)
  if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $candidateFull.StartsWith(
    $rootFull + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Get-CcrPinnedHarnessSourceSha {
  param([string]$RepoRoot = (Get-CcrPinnedRepoRoot))
  $value = (& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "PINNED_HARNESS_SOURCE_UNAVAILABLE" }
  $sha = (($value | Select-Object -First 1) -as [string]).Trim().ToLowerInvariant()
  if (-not (Test-CcrPinnedGitSha $sha)) { throw "PINNED_HARNESS_SOURCE_INVALID" }
  return $sha
}

function Get-CcrPinnedAndroidSdkTools {
  param([string]$SdkRoot = "")
  if (-not $SdkRoot) {
    $SdkRoot = if ($env:ANDROID_HOME) {
      $env:ANDROID_HOME
    } elseif ($env:ANDROID_SDK_ROOT) {
      $env:ANDROID_SDK_ROOT
    } else {
      Join-Path $env:LOCALAPPDATA "Android\Sdk"
    }
  }
  $sdk = [System.IO.Path]::GetFullPath($SdkRoot)
  $tools = [PSCustomObject]@{
    SdkRoot = $sdk
    Adb = Join-Path $sdk "platform-tools\adb.exe"
    ApkAnalyzer = Join-Path $sdk "cmdline-tools\latest\bin\apkanalyzer.bat"
    ApkSigner = Join-Path $sdk "build-tools\36.0.0\apksigner.bat"
  }
  foreach ($entry in @("Adb", "ApkAnalyzer", "ApkSigner")) {
    if (-not (Test-Path -LiteralPath $tools.$entry -PathType Leaf)) { throw "PINNED_ANDROID_TOOL_MISSING:$entry" }
  }
  return $tools
}

function Invoke-CcrPinnedTool {
  param([string]$FilePath, [string[]]$Arguments, [string]$Failure)
  $lines = @(& $FilePath @Arguments 2>&1)
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) { throw "$Failure exit=$exitCode output=$($lines -join ' ')" }
  return ($lines -join "`n").Trim()
}

function Get-CcrPinnedApkIdentity {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [Parameter(Mandatory = $true)][object]$Tools
  )
  $path = [string](Get-CcrPinnedRequiredProperty $Artifact "path")
  $packageName = Invoke-CcrPinnedTool $Tools.ApkAnalyzer @("manifest", "application-id", $path) "PINNED_APK_PACKAGE_INSPECTION_FAILED"
  $versionNameText = Invoke-CcrPinnedTool $Tools.ApkAnalyzer @("manifest", "version-name", $path) "PINNED_APK_VERSION_NAME_INSPECTION_FAILED"
  $versionCodeText = Invoke-CcrPinnedTool $Tools.ApkAnalyzer @("manifest", "version-code", $path) "PINNED_APK_VERSION_CODE_INSPECTION_FAILED"
  $manifestXml = Invoke-CcrPinnedTool $Tools.ApkAnalyzer @("manifest", "print", $path) "PINNED_APK_MANIFEST_INSPECTION_FAILED"
  $certText = Invoke-CcrPinnedTool $Tools.ApkSigner @("verify", "--print-certs", $path) "PINNED_APK_CERTIFICATE_INSPECTION_FAILED"

  $instrumentation = [regex]::Matches($manifestXml, "(?s)<instrumentation\b(?<attributes>[^>]*)>")
  if ($instrumentation.Count -gt 1) { throw "PINNED_APK_MULTIPLE_INSTRUMENTATION_ENTRIES:$($Artifact.role)" }
  $runner = $null
  $targetPackage = $null
  if ($instrumentation.Count -eq 1) {
    $attributes = $instrumentation[0].Groups["attributes"].Value
    $runnerMatch = [regex]::Match($attributes, 'android:name="([^"]+)"')
    $targetMatch = [regex]::Match($attributes, 'android:targetPackage="([^"]+)"')
    if (-not $runnerMatch.Success -or -not $targetMatch.Success) {
      throw "PINNED_APK_INSTRUMENTATION_PARSE_FAILED:$($Artifact.role)"
    }
    $runner = $runnerMatch.Groups[1].Value
    $targetPackage = $targetMatch.Groups[1].Value
  }

  $certMatches = [regex]::Matches($certText, "(?im)certificate SHA-256 digest:\s*([0-9a-f:]+)")
  $certificates = @($certMatches | ForEach-Object { $_.Groups[1].Value.Replace(":", "").ToLowerInvariant() } | Select-Object -Unique)
  if ($certificates.Count -ne 1 -or -not (Test-CcrPinnedSha256 $certificates[0])) {
    throw "PINNED_APK_CERTIFICATE_PARSE_FAILED:$($Artifact.role)"
  }
  $versionName = if ($versionNameText -eq "UNKNOWN") { $null } else { $versionNameText }
  $versionCode = if ($versionCodeText -eq "UNKNOWN") {
    $null
  } elseif ($versionCodeText -match "^\d+$") {
    [long]$versionCodeText
  } else {
    throw "PINNED_APK_VERSION_CODE_PARSE_FAILED:$($Artifact.role)"
  }
  return [PSCustomObject]@{
    packageName = $packageName
    versionName = $versionName
    versionCode = $versionCode
    signingCertificateSha256 = $certificates[0]
    runner = $runner
    targetPackage = $targetPackage
  }
}

function Get-CcrPinnedExpectedRoleIdentity {
  param([Parameter(Mandatory = $true)][string]$Role)
  switch ($Role) {
    "debugApp" {
      return [PSCustomObject]@{ packageName = $script:CcrPinnedAppPackage; versionName = $script:CcrPinnedVersionName; versionCode = $script:CcrPinnedVersionCode; runner = $null; targetPackage = $null }
    }
    "debugTest" {
      return [PSCustomObject]@{ packageName = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedAppPackage }
    }
    "benchmarkApp" {
      return [PSCustomObject]@{ packageName = $script:CcrPinnedAppPackage; versionName = $script:CcrPinnedVersionName; versionCode = $script:CcrPinnedVersionCode; runner = $null; targetPackage = $null }
    }
    "macrobenchmarkTest" {
      return [PSCustomObject]@{ packageName = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; targetPackage = $script:CcrPinnedMacrobenchmarkPackage }
    }
    default { throw "PINNED_ARTIFACT_ROLE_UNKNOWN:$Role" }
  }
}

function Import-CcrPinnedArtifactManifest {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [string]$RepoRoot = (Get-CcrPinnedRepoRoot),
    [string]$ExpectedHarnessSourceSha = "",
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null,
    [string]$TestOnlyExpectedDebugAppSha256 = $script:CcrPinnedDebugAppSha256
  )
  if (-not (Test-CcrPinnedAbsolutePath $ArtifactManifest)) { throw "PINNED_MANIFEST_PATH_NOT_ABSOLUTE" }
  $manifestPath = [System.IO.Path]::GetFullPath($ArtifactManifest)
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "PINNED_MANIFEST_NOT_FOUND" }
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  if (Test-CcrPinnedPathWithin $manifestPath $repo) { throw "PINNED_MANIFEST_INSIDE_WORKTREE" }
  $raw = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
  try { $manifest = $raw | ConvertFrom-Json } catch { throw "PINNED_MANIFEST_JSON_INVALID" }

  if ([int](Get-CcrPinnedRequiredProperty $manifest "schemaVersion") -ne $script:CcrPinnedSchemaVersion) { throw "PINNED_MANIFEST_SCHEMA_MISMATCH" }
  if ([int](Get-CcrPinnedRequiredProperty $manifest "artifactSetRevision") -ne $script:CcrPinnedArtifactSetRevision) { throw "PINNED_MANIFEST_REVISION_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "runtimeSourceSha") -cne $script:CcrPinnedRuntimeSourceSha) { throw "PINNED_MANIFEST_RUNTIME_SOURCE_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "runtimeInputsTreeSha256") -cne $script:CcrPinnedRuntimeInputsTreeSha256) { throw "PINNED_MANIFEST_RUNTIME_TREE_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $manifest "versionName") -cne $script:CcrPinnedVersionName -or [int](Get-CcrPinnedRequiredProperty $manifest "versionCode") -ne $script:CcrPinnedVersionCode) {
    throw "PINNED_MANIFEST_VERSION_MISMATCH"
  }
  if ((Get-CcrPinnedRequiredProperty $manifest "syntheticOnly") -ne $true -or (Get-CcrPinnedRequiredProperty $manifest "containsRealMediaMetadata") -ne $false) {
    throw "PINNED_MANIFEST_PRIVACY_MISMATCH"
  }
  $harnessSourceSha = [string](Get-CcrPinnedRequiredProperty $manifest "harnessSourceSha")
  if (-not (Test-CcrPinnedGitSha $harnessSourceSha)) { throw "PINNED_MANIFEST_HARNESS_SOURCE_INVALID" }
  if (-not $ExpectedHarnessSourceSha) { $ExpectedHarnessSourceSha = Get-CcrPinnedHarnessSourceSha $repo }
  if ($harnessSourceSha -cne $ExpectedHarnessSourceSha) { throw "PINNED_MANIFEST_HARNESS_SOURCE_MISMATCH" }

  $artifacts = @((Get-CcrPinnedRequiredProperty $manifest "artifacts"))
  if ($artifacts.Count -ne $script:CcrPinnedRoles.Count) { throw "PINNED_MANIFEST_ARTIFACT_COUNT_MISMATCH" }
  $seenRoles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $normalized = [System.Collections.Generic.List[object]]::new()
  foreach ($artifact in $artifacts) {
    $role = [string](Get-CcrPinnedRequiredProperty $artifact "role")
    if ($role -notin $script:CcrPinnedRoles) { throw "PINNED_ARTIFACT_ROLE_UNKNOWN:$role" }
    if (-not $seenRoles.Add($role)) { throw "PINNED_ARTIFACT_ROLE_DUPLICATE:$role" }
    foreach ($property in @("path", "bytes", "sha256", "packageName", "versionName", "versionCode", "signingCertificateSha256", "runner", "targetPackage")) {
      if (-not (Test-CcrPinnedProperty $artifact $property)) { throw "PINNED_ARTIFACT_PROPERTY_MISSING:$role/$property" }
    }
    $declaredPath = [string]$artifact.path
    if (-not (Test-CcrPinnedAbsolutePath $declaredPath)) { throw "PINNED_ARTIFACT_PATH_NOT_ABSOLUTE:$role" }
    $fullPath = [System.IO.Path]::GetFullPath($declaredPath)
    if (Test-CcrPinnedPathWithin $fullPath $repo) { throw "PINNED_ARTIFACT_INSIDE_WORKTREE:$role" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "PINNED_ARTIFACT_MISSING:$role" }
    $item = Get-Item -LiteralPath $fullPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "PINNED_ARTIFACT_REPARSE_POINT_FORBIDDEN:$role" }
    $physicalPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fullPath).ProviderPath)
    if (-not $seenPaths.Add($physicalPath)) { throw "PINNED_ARTIFACT_PHYSICAL_PATH_DUPLICATE:$role" }
    if ([System.IO.Path]::GetExtension($physicalPath) -cne ".apk") { throw "PINNED_ARTIFACT_NOT_APK:$role" }
    if ([long]$artifact.bytes -ne [long]$item.Length) { throw "PINNED_ARTIFACT_BYTE_SIZE_MISMATCH:$role" }
    if (-not (Test-CcrPinnedSha256 $artifact.sha256)) { throw "PINNED_ARTIFACT_SHA_INVALID:$role" }
    $actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $physicalPath).Hash.ToLowerInvariant()
    if ([string]$artifact.sha256 -cne $actualSha) { throw "PINNED_ARTIFACT_SHA_MISMATCH:$role" }
    if ($role -eq "debugApp" -and $actualSha -cne $TestOnlyExpectedDebugAppSha256) { throw "PINNED_DEBUG_APP_SHA_MISMATCH" }

    $artifact.path = $physicalPath
    $normalized.Add($artifact) | Out-Null
  }
  foreach ($role in $script:CcrPinnedRoles) {
    if (-not $seenRoles.Contains($role)) { throw "PINNED_ARTIFACT_ROLE_MISSING:$role" }
  }

  if ($null -eq $IdentityReader) { $IdentityReader = ${function:Get-CcrPinnedApkIdentity} }
  if ($null -eq $AndroidTools) { $AndroidTools = Get-CcrPinnedAndroidSdkTools }
  foreach ($artifact in $normalized) {
    $expected = Get-CcrPinnedExpectedRoleIdentity ([string]$artifact.role)
    $actual = & $IdentityReader $artifact $AndroidTools
    if ($null -eq $actual) { throw "PINNED_APK_IDENTITY_UNAVAILABLE:$($artifact.role)" }
    foreach ($property in @("packageName", "versionName", "versionCode", "signingCertificateSha256", "runner", "targetPackage")) {
      if (-not (Test-CcrPinnedProperty $actual $property)) { throw "PINNED_APK_IDENTITY_PROPERTY_MISSING:$($artifact.role)/$property" }
    }
    if ([string]$artifact.packageName -cne [string]$actual.packageName -or [string]$artifact.packageName -cne [string]$expected.packageName) {
      throw "PINNED_ARTIFACT_PACKAGE_MISMATCH:$($artifact.role)"
    }
    Assert-CcrPinnedNullableEqual $artifact.versionName $actual.versionName "PINNED_ARTIFACT_VERSION_NAME_INSPECTION_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.versionCode $actual.versionCode "PINNED_ARTIFACT_VERSION_CODE_INSPECTION_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.versionName $expected.versionName "PINNED_ARTIFACT_VERSION_NAME_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.versionCode $expected.versionCode "PINNED_ARTIFACT_VERSION_CODE_MISMATCH:$($artifact.role)"
    if (-not (Test-CcrPinnedSha256 $artifact.signingCertificateSha256) -or
        [string]$artifact.signingCertificateSha256 -cne [string]$actual.signingCertificateSha256 -or
        [string]$artifact.signingCertificateSha256 -cne $script:CcrPinnedSigningCertificateSha256) {
      throw "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:$($artifact.role)"
    }
    Assert-CcrPinnedNullableEqual $artifact.runner $actual.runner "PINNED_ARTIFACT_RUNNER_INSPECTION_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.targetPackage $actual.targetPackage "PINNED_ARTIFACT_TARGET_INSPECTION_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.runner $expected.runner "PINNED_ARTIFACT_RUNNER_MISMATCH:$($artifact.role)"
    Assert-CcrPinnedNullableEqual $artifact.targetPackage $expected.targetPackage "PINNED_ARTIFACT_TARGET_MISMATCH:$($artifact.role)"
  }

  $byRole = @{}
  foreach ($artifact in $normalized) { $byRole[[string]$artifact.role] = $artifact }
  return [PSCustomObject]@{
    ManifestPath = $manifestPath
    ManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    Manifest = $manifest
    Artifacts = $byRole
    RuntimeSourceSha = $script:CcrPinnedRuntimeSourceSha
    HarnessSourceSha = $harnessSourceSha
    RuntimeInputsTreeSha256 = $script:CcrPinnedRuntimeInputsTreeSha256
  }
}

function Invoke-CcrPinnedAdbRaw {
  param(
    [Parameter(Mandatory = $true)][string]$Adb,
    [scriptblock]$AdbInvoker,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  if ($null -ne $AdbInvoker) {
    $result = & $AdbInvoker $Arguments
    if ($null -eq $result -or -not (Test-CcrPinnedProperty $result "exitCode") -or -not (Test-CcrPinnedProperty $result "output")) {
      throw "PINNED_FAKE_ADB_RESULT_INVALID"
    }
    return [PSCustomObject]@{ exitCode = [int]$result.exitCode; output = [string]$result.output }
  }
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # adb writes successful pull progress to stderr. Do not let the caller's
    # Stop preference turn that native stderr stream into a terminating error.
    $ErrorActionPreference = "Continue"
    $lines = @(& $Adb @Arguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  return [PSCustomObject]@{ exitCode = $exitCode; output = ($lines -join "`n").Trim() }
}

function Invoke-CcrPinnedAdb {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string[]]$Arguments)
  return Invoke-CcrPinnedAdbRaw $Context.Adb $Context.AdbInvoker $Arguments
}

function Test-CcrPinnedPackageInstalled {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$PackageName)
  $query = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "pm", "list", "packages", "--user", "0", $PackageName)
  if ($query.exitCode -ne 0) { throw "PINNED_PACKAGE_QUERY_FAILED:$PackageName" }
  $exactLine = "package:$PackageName"
  return @($query.output -split "`r?`n" | Where-Object { $_.Trim() -ceq $exactLine }).Count -gt 0
}

function Get-CcrPinnedS24Device {
  param([Parameter(Mandatory = $true)][string]$Adb, [scriptblock]$AdbInvoker)
  $devicesResult = Invoke-CcrPinnedAdbRaw $Adb $AdbInvoker @("devices")
  if ($devicesResult.exitCode -ne 0) { throw "PINNED_ADB_DEVICES_FAILED" }
  $devices = @($devicesResult.output -split "`r?`n" | Where-Object { $_ -match "^\S+\s+device$" })
  if ($devices.Count -ne 1) { throw "PINNED_EXACTLY_ONE_ANDROID_DEVICE_REQUIRED" }
  $serial = ($devices[0] -split "\s+")[0]
  $properties = @{}
  foreach ($entry in @(
    @("model", "ro.product.model"),
    @("manufacturer", "ro.product.manufacturer"),
    @("fingerprint", "ro.build.fingerprint"),
    @("securityPatch", "ro.build.version.security_patch"),
    @("sdk", "ro.build.version.sdk")
  )) {
    $result = Invoke-CcrPinnedAdbRaw $Adb $AdbInvoker @("-s", $serial, "shell", "getprop", $entry[1])
    if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.output)) { throw "PINNED_DEVICE_PROPERTY_FAILED:$($entry[1])" }
    $properties[$entry[0]] = $result.output.Trim()
  }
  if ($properties.manufacturer -cne "samsung" -and $properties.manufacturer -cne "Samsung") { throw "PINNED_SAMSUNG_DEVICE_REQUIRED:$($properties.manufacturer)" }
  if ($properties.model -notlike "SM-S928*") { throw "PINNED_S24_ULTRA_SM_S928_REQUIRED:$($properties.model)" }
  return [PSCustomObject]@{
    Serial = $serial
    Model = $properties.model
    Manufacturer = $properties.manufacturer
    Fingerprint = $properties.fingerprint
    SecurityPatch = $properties.securityPatch
    Sdk = $properties.sdk
  }
}

function Invoke-CcrPinnedPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$RepoRoot = (Get-CcrPinnedRepoRoot),
    [string]$ExpectedHarnessSourceSha = "",
    [object]$AndroidTools = $null,
    [scriptblock]$IdentityReader = $null,
    [scriptblock]$AdbInvoker = $null,
    [string]$TestOnlyExpectedDebugAppSha256 = $script:CcrPinnedDebugAppSha256
  )
  # Artifact validation is intentionally complete before the first ADB invocation.
  $set = Import-CcrPinnedArtifactManifest $ArtifactManifest $RepoRoot $ExpectedHarnessSourceSha $AndroidTools $IdentityReader $TestOnlyExpectedDebugAppSha256
  if ($null -eq $AndroidTools) { $AndroidTools = Get-CcrPinnedAndroidSdkTools }
  if (-not (Test-CcrPinnedAbsolutePath $OutputDirectory)) { throw "PINNED_OUTPUT_DIRECTORY_NOT_ABSOLUTE" }
  $output = [System.IO.Path]::GetFullPath($OutputDirectory)
  $device = Get-CcrPinnedS24Device $AndroidTools.Adb $AdbInvoker
  [System.IO.Directory]::CreateDirectory($output) | Out-Null
  return [PSCustomObject]@{
    ArtifactSet = $set
    OutputDirectory = $output
    AndroidTools = $AndroidTools
    Adb = $AndroidTools.Adb
    AdbInvoker = $AdbInvoker
    Serial = $device.Serial
    Model = $device.Model
    Fingerprint = $device.Fingerprint
    SecurityPatch = $device.SecurityPatch
    Sdk = $device.Sdk
  }
}

function Reserve-CcrPinnedRunId {
  param([Parameter(Mandatory = $true)][string]$OutputDirectory, [Parameter(Mandatory = $true)][string]$RunId)
  Assert-CcrPinnedRunId $RunId | Out-Null
  [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
  $path = Join-Path $OutputDirectory "run-id-$RunId.lock"
  try {
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes("$RunId`n")
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush()
    } finally {
      $stream.Dispose()
    }
  } catch [System.IO.IOException] {
    throw "PINNED_RUN_ID_DUPLICATE:$RunId"
  }
  return $RunId
}

function New-CcrPinnedRunId {
  param([Parameter(Mandatory = $true)][string]$OutputDirectory, [string]$Prefix = "s24")
  $runId = "$Prefix-$([Guid]::NewGuid().ToString('N'))"
  return Reserve-CcrPinnedRunId $OutputDirectory $runId
}

function Get-CcrPinnedArtifact {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Role)
  if (-not $Context.ArtifactSet.Artifacts.ContainsKey($Role)) { throw "PINNED_ARTIFACT_ROLE_MISSING:$Role" }
  return $Context.ArtifactSet.Artifacts[$Role]
}

function Assert-CcrPinnedInstalledArtifact {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Role)
  $artifact = Get-CcrPinnedArtifact $Context $Role
  $query = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "pm", "path", [string]$artifact.packageName)
  if ($query.exitCode -ne 0) { throw "PINNED_INSTALLED_PACKAGE_QUERY_FAILED:$Role" }
  $paths = @($query.output -split "`r?`n" | Where-Object { $_ -match "^package:.+" } | ForEach-Object { $_.Substring(8).Trim() })
  if ($paths.Count -ne 1) { throw "PINNED_INSTALLED_APK_PATH_AMBIGUOUS:$Role" }
  $local = Join-Path $Context.OutputDirectory "installed-$Role-$([Guid]::NewGuid().ToString('N')).apk"
  try {
    $pull = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "pull", $paths[0], $local)
    if ($pull.exitCode -ne 0 -or -not (Test-Path -LiteralPath $local -PathType Leaf)) { throw "PINNED_INSTALLED_APK_PULL_FAILED:$Role" }
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToLowerInvariant()
    if ($sha -cne [string]$artifact.sha256) { throw "PINNED_INSTALLED_APK_SHA_MISMATCH:$Role" }
    $installedArtifact = [PSCustomObject]@{ role = $Role; path = $local }
    $installedIdentity = Get-CcrPinnedApkIdentity $installedArtifact $Context.AndroidTools
    foreach ($property in @("packageName", "versionName", "versionCode", "signingCertificateSha256", "runner", "targetPackage")) {
      Assert-CcrPinnedNullableEqual $artifact.$property $installedIdentity.$property "PINNED_INSTALLED_APK_IDENTITY_MISMATCH:$Role/$property"
    }
  } finally {
    if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
  }
}

function Install-CcrPinnedArtifactSet {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][ValidateSet("Debug", "Benchmark")][string]$Mode
  )
  $roles = if ($Mode -eq "Debug") { @("debugApp", "debugTest") } else { @("benchmarkApp", "macrobenchmarkTest") }
  foreach ($role in $roles) {
    $artifact = Get-CcrPinnedArtifact $Context $role
    $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "install", "-r", [string]$artifact.path)
    if ($result.exitCode -ne 0 -or $result.output -notmatch "(?m)^Success\s*$") { throw "PINNED_APK_INSTALL_FAILED:$role" }
    Assert-CcrPinnedInstalledArtifact $Context $role
  }
}

function Get-CcrPinnedDeviceElapsedRealtimeNs {
  param([Parameter(Mandatory = $true)][object]$Context)
  $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "cat", "/proc/uptime")
  if ($result.exitCode -ne 0 -or $result.output -notmatch "^([0-9]+(?:\.[0-9]+)?)\s") { throw "PINNED_DEVICE_UPTIME_UNAVAILABLE" }
  $seconds = [decimal]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
  return [long]($seconds * 1000000000)
}

function Invoke-CcrPinnedInstrumentation {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][ValidateSet("debugTest", "macrobenchmarkTest")][string]$TestRole,
    [Parameter(Mandatory = $true)][string]$ClassName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [int]$ExpectedTestCount = 1,
    [hashtable]$AdditionalArguments = @{}
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  if ($ExpectedTestCount -lt 1) { throw "PINNED_EXPECTED_TEST_COUNT_INVALID" }
  $test = Get-CcrPinnedArtifact $Context $TestRole
  $app = Get-CcrPinnedArtifact $Context $(if ($TestRole -eq "debugTest") { "debugApp" } else { "benchmarkApp" })
  $required = [ordered]@{
    class = $ClassName
    runId = $RunId
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = $script:CcrPinnedArtifactSetRevision
    expectedAppSha256 = [string]$app.sha256
    expectedTestApkSha256 = [string]$test.sha256
  }
  foreach ($key in $AdditionalArguments.Keys) {
    if ($required.Contains($key)) { throw "PINNED_INSTRUMENTATION_ARGUMENT_OVERRIDE:$key" }
    $required[$key] = [string]$AdditionalArguments[$key]
  }
  $args = @("-s", $Context.Serial, "shell", "am", "instrument", "-w", "-r")
  foreach ($key in @($required.Keys | Sort-Object)) { $args += @("-e", [string]$key, [string]$required[$key]) }
  $args += "$($test.packageName)/$($test.runner)"
  $minimumStartedAt = Get-CcrPinnedDeviceElapsedRealtimeNs $Context
  $result = Invoke-CcrPinnedAdb $Context $args
  if ($result.exitCode -ne 0 -or $result.output -notmatch "OK \($ExpectedTestCount tests?\)") {
    throw "PINNED_INSTRUMENTATION_FAILED:$TestRole"
  }
  return [PSCustomObject]@{ RunId = $RunId; MinimumStartedAtElapsedRealtimeNs = $minimumStartedAt; Output = $result.output }
}

function Clear-CcrPinnedRemoteReport {
  param([Parameter(Mandatory = $true)][object]$Context, [string]$PackageName, [Parameter(Mandatory = $true)][string]$ReportName)
  if (-not $PackageName) { $PackageName = $script:CcrPinnedAppPackage }
  if ($ReportName -notmatch "^[A-Za-z0-9._-]+\.json$") { throw "PINNED_REPORT_NAME_INVALID" }
  $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "run-as", $PackageName, "rm", "-f", "files/$ReportName")
  if ($result.exitCode -ne 0) { throw "PINNED_STALE_REPORT_CLEAR_FAILED:$ReportName" }
  $check = "run-as $PackageName sh -c 'if [ -e files/$ReportName ]; then exit 7; else exit 0; fi'"
  $absence = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", $check)
  if ($absence.exitCode -eq 7) { throw "PINNED_STALE_REPORT_STILL_PRESENT:$ReportName" }
  if ($absence.exitCode -ne 0) { throw "PINNED_STALE_REPORT_ABSENCE_CHECK_FAILED:$ReportName" }
}

function Assert-CcrPinnedReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][object]$ArtifactSet,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$AppRole,
    [Parameter(Mandatory = $true)][string]$TestRole,
    [long]$MinimumStartedAtElapsedRealtimeNs = 0,
    [string]$ExpectedKind = "",
    [int]$ExpectedTestCount = 1,
    [int]$ExpectedInstrumentationTestCount = 1
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  if ([string](Get-CcrPinnedRequiredProperty $Report "runId") -cne $RunId) { throw "PINNED_REPORT_RUN_ID_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $Report "runtimeSourceSha") -cne $ArtifactSet.RuntimeSourceSha -or
      [string](Get-CcrPinnedRequiredProperty $Report "harnessSourceSha") -cne $ArtifactSet.HarnessSourceSha -or
      [string](Get-CcrPinnedRequiredProperty $Report "runtimeInputsTreeSha256") -cne $ArtifactSet.RuntimeInputsTreeSha256 -or
      [int](Get-CcrPinnedRequiredProperty $Report "artifactSetRevision") -ne $script:CcrPinnedArtifactSetRevision) {
    throw "PINNED_REPORT_SOURCE_IDENTITY_MISMATCH"
  }
  $started = [long](Get-CcrPinnedRequiredProperty $Report "startedAtElapsedRealtimeNs")
  $finished = [long](Get-CcrPinnedRequiredProperty $Report "finishedAtElapsedRealtimeNs")
  if ($started -le 0 -or $finished -lt $started -or ($MinimumStartedAtElapsedRealtimeNs -gt 0 -and $started -lt $MinimumStartedAtElapsedRealtimeNs)) {
    throw "PINNED_REPORT_STALE_OR_TIME_INVALID"
  }
  if ([string](Get-CcrPinnedRequiredProperty $Report "status") -cne "PASS") { throw "PINNED_REPORT_STATUS_MISMATCH" }
  if ((Get-CcrPinnedRequiredProperty $Report "syntheticOnly") -ne $true -or
      (Get-CcrPinnedRequiredProperty $Report "containsRealMediaMetadata") -ne $false) {
    throw "PINNED_REPORT_PRIVACY_MISMATCH"
  }
  $kind = if (Test-CcrPinnedProperty $Report "reportKind") {
    [string]$Report.reportKind
  } elseif (Test-CcrPinnedProperty $Report "kind") {
    [string]$Report.kind
  } else {
    throw "PINNED_REPORT_KIND_MISSING"
  }
  if ($ExpectedKind -and $kind -cne $ExpectedKind) { throw "PINNED_REPORT_KIND_MISMATCH" }
  $app = $ArtifactSet.Artifacts[$AppRole]
  $test = $ArtifactSet.Artifacts[$TestRole]
  if ([string](Get-CcrPinnedRequiredProperty $Report "appSha256") -cne [string]$app.sha256 -or
      [string](Get-CcrPinnedRequiredProperty $Report "testApkSha256") -cne [string]$test.sha256) {
    throw "PINNED_REPORT_ARTIFACT_IDENTITY_MISMATCH"
  }
  if ([int](Get-CcrPinnedRequiredProperty $Report "testCount") -ne $ExpectedTestCount -or
      [int](Get-CcrPinnedRequiredProperty $Report "instrumentationExpectedTestCount") -ne $ExpectedInstrumentationTestCount) {
    throw "PINNED_REPORT_TEST_COUNT_MISMATCH"
  }
  return $Report
}

function Receive-CcrPinnedReport {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$ReportName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$AppRole,
    [Parameter(Mandatory = $true)][string]$TestRole,
    [long]$MinimumStartedAtElapsedRealtimeNs,
    [string]$ExpectedKind = "",
    [string]$PackageName = "",
    [int]$ExpectedTestCount = 1,
    [int]$ExpectedInstrumentationTestCount = 1
  )
  if (-not $PackageName) { $PackageName = [string](Get-CcrPinnedArtifact $Context $AppRole).packageName }
  if ($ReportName -notmatch "^[A-Za-z0-9._-]+\.json$") { throw "PINNED_REPORT_NAME_INVALID" }
  $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "exec-out", "run-as", $PackageName, "cat", "files/$ReportName")
  if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.output)) { throw "PINNED_REPORT_PULL_FAILED:$ReportName" }
  try { $report = $result.output | ConvertFrom-Json } catch { throw "PINNED_REPORT_JSON_INVALID:$ReportName" }
  Assert-CcrPinnedReport $report $Context.ArtifactSet $RunId $AppRole $TestRole $MinimumStartedAtElapsedRealtimeNs $ExpectedKind $ExpectedTestCount $ExpectedInstrumentationTestCount | Out-Null
  $target = Join-Path $Context.OutputDirectory "$RunId-$ReportName"
  [System.IO.File]::WriteAllText($target, $result.output, [System.Text.UTF8Encoding]::new($false))
  return [PSCustomObject]@{ Path = $target; Report = $report }
}

function Assert-CcrPinnedBenchmarkEvidence {
  param(
    [Parameter(Mandatory = $true)][object]$Evidence,
    [Parameter(Mandatory = $true)][object]$ArtifactSet,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExpectedScenario,
    [int]$RecoveredValidTraceCount
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  if ([int](Get-CcrPinnedRequiredProperty $Evidence "schemaVersion") -ne 1 -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "reportKind") -cne "ccr-benchmark-harness-v2" -or
      [int](Get-CcrPinnedRequiredProperty $Evidence "artifactSetRevision") -ne $script:CcrPinnedArtifactSetRevision) {
    throw "PINNED_BENCHMARK_REPORT_SCHEMA_MISMATCH"
  }
  if ([string](Get-CcrPinnedRequiredProperty $Evidence "runId") -cne $RunId) { throw "PINNED_BENCHMARK_RUN_ID_MISMATCH" }
  if ([string](Get-CcrPinnedRequiredProperty $Evidence "runtimeSourceSha") -cne $ArtifactSet.RuntimeSourceSha -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "harnessSourceSha") -cne $ArtifactSet.HarnessSourceSha -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "runtimeInputsTreeSha256") -cne $ArtifactSet.RuntimeInputsTreeSha256) {
    throw "PINNED_BENCHMARK_SOURCE_IDENTITY_MISMATCH"
  }
  if ([string](Get-CcrPinnedRequiredProperty $Evidence "scenario") -cne $ExpectedScenario -or
      [string](Get-CcrPinnedRequiredProperty $Evidence "measurementDescription") -cne "source-equivalent pinned benchmark measurement build") {
    throw "PINNED_BENCHMARK_SCENARIO_MISMATCH"
  }
  $expectedTraceCount = [int](Get-CcrPinnedRequiredProperty $Evidence "expectedTraceCount")
  $traceIdentityCount = [int](Get-CcrPinnedRequiredProperty $Evidence "traceIdentityCount")
  if ($expectedTraceCount -ne 3 -or $traceIdentityCount -ne 3 -or $RecoveredValidTraceCount -ne 3) {
    throw "PINNED_BENCHMARK_TRACE_COUNT_MISMATCH"
  }
  $iterations = @((Get-CcrPinnedRequiredProperty $Evidence "iterations"))
  if ($iterations.Count -ne 3) { throw "PINNED_BENCHMARK_ITERATION_COUNT_MISMATCH" }
  $seenIterations = [System.Collections.Generic.HashSet[int]]::new()
  $seenTraceIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $requiredIterationFields = @(
    "runIteration", "traceIdentity", "counterComplete", "activeMs", "published", "publishedFps",
    "publicationIntervalP50Us", "publicationIntervalP95Us", "publicationIntervalMaxUs",
    "rawLagP50", "rawLagP95", "rawLagMax", "outstandingForegroundTargetDepthMax",
    "acceptedTargetCount", "releaseAfterAcceptedTargetCount", "holdPrefetchStarted", "holdPrefetchCompleted"
  )
  foreach ($iteration in $iterations) {
    foreach ($field in $requiredIterationFields) {
      if (-not (Test-CcrPinnedProperty $iteration $field)) { throw "PINNED_BENCHMARK_COUNTER_MISSING:$field" }
    }
    if ($iteration.counterComplete -ne $true) { throw "PINNED_BENCHMARK_COUNTER_INCOMPLETE" }
    if (-not $seenIterations.Add([int]$iteration.runIteration)) { throw "PINNED_BENCHMARK_ITERATION_DUPLICATE" }
    if (-not $seenTraceIdentities.Add([string]$iteration.traceIdentity)) { throw "PINNED_BENCHMARK_TRACE_IDENTITY_DUPLICATE" }
  }
  if (($seenIterations | Sort-Object) -join "," -ne "1,2,3" -or $seenTraceIdentities.Count -ne 3) {
    throw "PINNED_BENCHMARK_ITERATION_IDENTITY_MISMATCH"
  }
  return $Evidence
}

function Get-CcrPinnedDeviceSetting {
  param([object]$Context, [string]$Namespace, [string]$Name)
  $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "settings", "get", $Namespace, $Name)
  if ($result.exitCode -ne 0) { throw "PINNED_SETTING_READ_FAILED:$Namespace/$Name" }
  return $result.output.Trim()
}

function Set-CcrPinnedDeviceSetting {
  param([object]$Context, [string]$Namespace, [string]$Name, [object]$Value)
  $args = if ($null -eq $Value -or [string]$Value -eq "null") {
    @("-s", $Context.Serial, "shell", "settings", "delete", $Namespace, $Name)
  } else {
    @("-s", $Context.Serial, "shell", "settings", "put", $Namespace, $Name, [string]$Value)
  }
  $result = Invoke-CcrPinnedAdb $Context $args
  if ($result.exitCode -ne 0) { throw "PINNED_SETTING_WRITE_FAILED:$Namespace/$Name" }
}

function Save-CcrPinnedDeviceSettings {
  param([Parameter(Mandatory = $true)][object]$Context)
  $Context | Add-Member -Force -NotePropertyName SavedSettings -NotePropertyValue ([PSCustomObject]@{
    stayAwake = Get-CcrPinnedDeviceSetting $Context "global" "stay_on_while_plugged_in"
    brightnessMode = Get-CcrPinnedDeviceSetting $Context "system" "screen_brightness_mode"
    brightness = Get-CcrPinnedDeviceSetting $Context "system" "screen_brightness"
    screenTimeout = Get-CcrPinnedDeviceSetting $Context "system" "screen_off_timeout"
    accelerometerRotation = Get-CcrPinnedDeviceSetting $Context "system" "accelerometer_rotation"
    userRotation = Get-CcrPinnedDeviceSetting $Context "system" "user_rotation"
  })
  return $Context.SavedSettings
}

function Restore-CcrPinnedDeviceSettings {
  param([Parameter(Mandatory = $true)][object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings") -or $null -eq $Context.SavedSettings) { return @() }
  $failures = [System.Collections.Generic.List[string]]::new()
  foreach ($setting in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    try { Set-CcrPinnedDeviceSetting $Context $setting[0] $setting[1] $setting[2] } catch { $failures.Add($_.Exception.Message) | Out-Null }
  }
  return @($failures)
}

function Remove-CcrPinnedRemoteTraceDirectory {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$RemotePath)
  $prefixes = @(
    "/sdcard/Android/media/$script:CcrPinnedMacrobenchmarkPackage/",
    "/sdcard/Android/data/$script:CcrPinnedMacrobenchmarkPackage/"
  )
  if ($RemotePath.Contains("..") -or -not ($prefixes | Where-Object { $RemotePath.StartsWith($_, [System.StringComparison]::Ordinal) })) {
    throw "PINNED_REMOTE_TRACE_PATH_FORBIDDEN"
  }
  $remove = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "rm", "-rf", $RemotePath)
  if ($remove.exitCode -ne 0) { throw "PINNED_REMOTE_TRACE_REMOVE_FAILED" }
  $verify = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "ls", "-d", $RemotePath)
  if ($verify.exitCode -eq 0) { throw "PINNED_REMOTE_TRACE_STILL_PRESENT" }
}

function Remove-CcrPinnedPackageIfInstalled {
  param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$PackageName)
  $failures = [System.Collections.Generic.List[string]]::new()
  try {
    if (-not (Test-CcrPinnedPackageInstalled $Context $PackageName)) { return @() }
  } catch {
    return @("PACKAGE_QUERY_FAILED:${PackageName}:$($_.Exception.Message)")
  }
  $result = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "uninstall", $PackageName)
  if ($result.exitCode -ne 0) {
    return @("UNINSTALL_FAILED:$PackageName")
  }
  try {
    if (Test-CcrPinnedPackageInstalled $Context $PackageName) { $failures.Add("PACKAGE_STILL_INSTALLED:$PackageName") | Out-Null }
  } catch {
    $failures.Add("PACKAGE_QUERY_FAILED:${PackageName}:$($_.Exception.Message)") | Out-Null
  }
  return @($failures)
}

function Invoke-CcrPinnedCleanup {
  param([Parameter(Mandatory = $true)][object]$Context, [switch]$RemoveApp)
  $failures = [System.Collections.Generic.List[string]]::new()
  foreach ($packageName in @($script:CcrPinnedDebugTestPackage, $script:CcrPinnedMacrobenchmarkPackage)) {
    foreach ($failure in @(Remove-CcrPinnedPackageIfInstalled $Context $packageName)) { $failures.Add([string]$failure) | Out-Null }
  }
  $stop = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "am", "force-stop", $script:CcrPinnedAppPackage)
  if ($stop.exitCode -ne 0) { $failures.Add("FORCE_STOP_FAILED:$script:CcrPinnedAppPackage") | Out-Null }
  if ($RemoveApp) {
    foreach ($failure in @(Remove-CcrPinnedPackageIfInstalled $Context $script:CcrPinnedAppPackage)) { $failures.Add([string]$failure) | Out-Null }
  }
  foreach ($failure in @(Restore-CcrPinnedDeviceSettings $Context)) { $failures.Add([string]$failure) | Out-Null }
  return @($failures)
}
