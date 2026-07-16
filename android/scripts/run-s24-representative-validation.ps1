param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactManifest,
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

$appPackage = "com.snowberried.ctcinereviewer.internal"
$testPackage = "$appPackage.test"
$testClass = "com.snowberried.ctcinereviewer.gate.S24RepresentativeResolutionAccuracyTest"
$reportName = "representative-resolution-exact-report.json"

function Write-S24RepresentativeReadOnlyJson {
  param([object]$Context, [string]$FileName, [object]$Value)
  if ($FileName -notmatch "^[A-Za-z0-9._-]+\.json$") { throw "REPRESENTATIVE_EVIDENCE_NAME_INVALID" }
  $path = Join-Path $Context.OutputDirectory $FileName
  if (Test-Path -LiteralPath $path) { throw "REPRESENTATIVE_EVIDENCE_ALREADY_EXISTS:$FileName" }
  $json = $Value | ConvertTo-Json -Depth 12
  $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::ReadOnly)
  return $path
}

function New-S24RepresentativePreflightEvidence {
  param([object]$Context)
  $artifacts = @($Context.ArtifactSet.Artifacts.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $artifact = $_.Value
    [ordered]@{
      role = [string]$artifact.role
      bytes = [long]$artifact.bytes
      sha256 = [string]$artifact.sha256
      packageName = [string]$artifact.packageName
      versionName = $artifact.versionName
      versionCode = $artifact.versionCode
      signingCertificateSha256 = [string]$artifact.signingCertificateSha256
      runner = $artifact.runner
      targetPackage = $artifact.targetPackage
    }
  })
  return [ordered]@{
    schemaVersion = 1
    kind = "s24-representative-preflight-v2"
    status = "PASS"
    preflightOnly = $true
    deviceMutationCount = 0
    recordedAtUtc = [DateTime]::UtcNow.ToString("o")
    artifactManifestSha256 = $Context.ArtifactSet.ManifestSha256
    artifactSetRevision = 2
    runtimeSourceSha = $Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $Context.ArtifactSet.RuntimeInputsTreeSha256
    device = [ordered]@{
      serial = $Context.Serial
      model = $Context.Model
      fingerprint = $Context.Fingerprint
      securityPatch = $Context.SecurityPatch
      sdk = $Context.Sdk
    }
    artifacts = $artifacts
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
}

function Assert-S24RepresentativePackageAbsent {
  param([object]$Context, [string]$PackageName)
  $query = Invoke-CcrPinnedAdb $Context @("-s", $Context.Serial, "shell", "pm", "path", $PackageName)
  if ($query.exitCode -ne 0) { throw "REPRESENTATIVE_TEST_PACKAGE_CLEANUP_QUERY_FAILED:$PackageName" }
  if ($query.output -match "(?m)^package:") { throw "REPRESENTATIVE_TEST_PACKAGE_CLEANUP_FAILED:$PackageName" }
}

function Assert-S24RepresentativeSettingsRestored {
  param([object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings")) { throw "REPRESENTATIVE_SAVED_SETTINGS_MISSING" }
  foreach ($entry in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    $actual = Get-CcrPinnedDeviceSetting $Context $entry[0] $entry[1]
    if ([string]$actual -cne [string]$entry[2]) {
      throw "REPRESENTATIVE_SETTING_RESTORE_MISMATCH:$($entry[0])/$($entry[1])"
    }
  }
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
if ($PreflightOnly) {
  $evidence = New-S24RepresentativePreflightEvidence $context
  Write-Output (Write-S24RepresentativeReadOnlyJson $context "s24-representative-preflight.json" $evidence)
  return
}

$primaryFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$mutationStarted = $false
$result = $null
try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $runId = New-CcrPinnedRunId $context.OutputDirectory "s24-representative"
  $mutationStarted = $true
  Install-CcrPinnedArtifactSet $context "Debug"
  Clear-CcrPinnedRemoteReport $context $appPackage $reportName
  $invocation = Invoke-CcrPinnedInstrumentation `
    -Context $context -TestRole "debugTest" -ClassName $testClass -RunId $runId -ExpectedTestCount 1
  $received = Receive-CcrPinnedReport `
    -Context $context -ReportName $reportName -RunId $runId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $invocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "representative-resolution-exact-subset" `
    -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  $report = $received.Report
  if ([string]$report.appVersionName -cne "0.2.0-alpha.4" -or [int]$report.appVersionCode -ne 5) {
    throw "REPRESENTATIVE_REPORT_VERSION_MISMATCH"
  }
  if ([string]$report.appCommitSha -cne $context.ArtifactSet.RuntimeSourceSha) {
    throw "REPRESENTATIVE_REPORT_RUNTIME_SOURCE_MISMATCH"
  }
  if ([string]$report.device.model -cne $context.Model -or
      [string]$report.device.securityPatch -cne $context.SecurityPatch -or
      [string]$report.device.sdk -cne [string]$context.Sdk) {
    throw "REPRESENTATIVE_REPORT_DEVICE_IDENTITY_MISMATCH"
  }
  if ([long]$report.mismatchCount -ne 0) { throw "REPRESENTATIVE_MISMATCH_NONZERO" }
  if ([long]$report.writeOpenCount -ne 0) { throw "REPRESENTATIVE_WRITE_OPEN_NONZERO" }

  $fixtures = @($report.fixtures)
  $actualFixtureNames = ($fixtures | ForEach-Object { [string]$_.fixture } | Sort-Object) -join ","
  $expectedFixtureNames = @(
    "720p-h264-bframes.mp4",
    "1080p-h264-bframes.mp4",
    "1080p-h264-long-gop.mp4",
    "1080p-hevc-main8.mp4",
    "1080p-vfr.mp4",
    "1080p-switch-a.mp4",
    "1080p-switch-b.mp4"
  ) | Sort-Object
  if ($fixtures.Count -ne 7 -or $actualFixtureNames -cne ($expectedFixtureNames -join ",")) {
    throw "REPRESENTATIVE_FIXTURE_COUNT_OR_IDENTITY_MISMATCH"
  }
  foreach ($fixture in $fixtures) {
    if ([string]$fixture.sourceSha256 -notmatch "^[a-f0-9]{64}$" -or
        [long]$fixture.frameCount -lt 300 -or
        [long]$fixture.selectedFrameCount -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$fixture.codecComponent) -or
        $fixture.hardwareAccelerated -ne $true -or
        [long]$fixture.writeOpenCount -ne 0) {
      throw "REPRESENTATIVE_FIXTURE_GATE_FAILED:$($fixture.fixture)"
    }
  }

  [System.IO.File]::SetAttributes($received.Path, [System.IO.FileAttributes]::ReadOnly)
  $summary = [ordered]@{
    schemaVersion = 2
    kind = "s24-representative-exact-gate-v2"
    status = "PASS"
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    artifactSetRevision = 2
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    device = [ordered]@{ serial = $context.Serial; model = $context.Model; fingerprint = $context.Fingerprint }
    runId = $runId
    fixtureCount = $fixtures.Count
    mismatchCount = 0
    writeOpenCount = 0
    report = [System.IO.Path]::GetFileName($received.Path)
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  $summaryPath = Write-S24RepresentativeReadOnlyJson $context "s24-representative-summary.json" $summary
  $result = [PSCustomObject]@{ status = "PASS"; summary = $summaryPath; report = $received.Path }
} catch {
  $primaryFailure = $_
} finally {
  if ($mutationStarted) {
    try {
      foreach ($failure in @(Invoke-CcrPinnedCleanup $context)) { $cleanupFailures.Add([string]$failure) | Out-Null }
    } catch {
      $cleanupFailures.Add("CLEANUP_EXCEPTION:$($_.Exception.Message)") | Out-Null
    }
    foreach ($packageName in @($testPackage, "com.snowberried.ctcinereviewer.macrobenchmark")) {
      try { Assert-S24RepresentativePackageAbsent $context $packageName } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
    }
    try { Assert-S24RepresentativeSettingsRestored $context } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
}

if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }
Write-Output $result
