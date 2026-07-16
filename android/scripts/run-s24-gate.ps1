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
$exactClass = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest"
$releaseMethod = "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest#releaseThenCancelAcceptsNoNewForegroundRequestDuringGracePeriods"
$exactReportName = "s24-frame-accuracy-report.json"
$sequentialReportName = "s24-forward-sequential-report.json"
$releaseReportName = "s24-release-cancel-grace-report.json"

function Assert-S24Zero {
  param([object]$Value, [string]$Failure)
  if ($null -eq $Value -or [long]$Value -ne 0) { throw $Failure }
}

function Write-S24ReadOnlyJson {
  param([object]$Context, [string]$FileName, [object]$Value)
  if ($FileName -notmatch "^[A-Za-z0-9._-]+\.json$") { throw "S24_EVIDENCE_NAME_INVALID" }
  $path = Join-Path $Context.OutputDirectory $FileName
  if (Test-Path -LiteralPath $path) { throw "S24_EVIDENCE_ALREADY_EXISTS:$FileName" }
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

function New-S24PreflightEvidence {
  param([object]$Context, [string]$Kind)
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
    kind = $Kind
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

function Assert-S24AppReportIdentity {
  param([object]$Context, [object]$Report, [string]$Kind)
  if ([string]$Report.appVersionName -cne "0.2.0-alpha.4" -or [int]$Report.appVersionCode -ne 5) {
    throw "S24_REPORT_VERSION_MISMATCH:$Kind"
  }
  if ([string]$Report.appCommitSha -cne $Context.ArtifactSet.RuntimeSourceSha) {
    throw "S24_REPORT_RUNTIME_SOURCE_MISMATCH:$Kind"
  }
  if ([string]$Report.device.model -cne $Context.Model) { throw "S24_REPORT_DEVICE_MODEL_MISMATCH:$Kind" }
  if ((Test-CcrPinnedProperty $Report.device "fingerprint") -and [string]$Report.device.fingerprint -cne $Context.Fingerprint) {
    throw "S24_REPORT_DEVICE_FINGERPRINT_MISMATCH:$Kind"
  }
  if ([string]$Report.device.securityPatch -cne $Context.SecurityPatch) {
    throw "S24_REPORT_DEVICE_SECURITY_PATCH_MISMATCH:$Kind"
  }
}

function Assert-S24GateCounters {
  param([object]$Report, [string]$Kind)
  Assert-S24Zero $Report.mismatchCount "S24_REPORT_MISMATCH_NONZERO:$Kind"
  Assert-S24Zero $Report.writeOpenCount "S24_REPORT_WRITE_OPEN_NONZERO:$Kind"
  foreach ($field in @(
    "staleDiscard", "staleBeforeSwap", "swapFailures", "surfaceInvalid",
    "publicationInvariantViolations", "cacheRejectionCount", "cacheThrashCount", "textureDoubleReleaseCount"
  )) {
    Assert-S24Zero $Report.gateCounters.$field "S24_REPORT_GATE_COUNTER_NONZERO:$Kind/$field"
  }
}

function Assert-S24HardwareFixtures {
  param([object[]]$Fixtures, [switch]$RequireProfile)
  foreach ($fixture in $Fixtures) {
    if ([string]$fixture.sourceSha256 -notmatch "^[a-f0-9]{64}$" -or
        [string]::IsNullOrWhiteSpace([string]$fixture.codec) -or
        [string]::IsNullOrWhiteSpace([string]$fixture.codecComponent) -or
        $fixture.hardwareAccelerated -ne $true) {
      throw "S24_FIXTURE_HARDWARE_METADATA_MISMATCH:$($fixture.fixture)"
    }
    if ($RequireProfile -and [string]::IsNullOrWhiteSpace([string]$fixture.profile)) {
      throw "S24_FIXTURE_PROFILE_MISSING:$($fixture.fixture)"
    }
  }
}

function Assert-S24PackageAbsent {
  param([object]$Context, [string]$PackageName)
  if (Test-CcrPinnedPackageInstalled $Context $PackageName) { throw "S24_TEST_PACKAGE_CLEANUP_FAILED:$PackageName" }
}

function Assert-S24SettingsRestored {
  param([object]$Context)
  if (-not (Test-CcrPinnedProperty $Context "SavedSettings")) { throw "S24_SAVED_SETTINGS_MISSING" }
  foreach ($entry in @(
    @("global", "stay_on_while_plugged_in", $Context.SavedSettings.stayAwake),
    @("system", "screen_brightness_mode", $Context.SavedSettings.brightnessMode),
    @("system", "screen_brightness", $Context.SavedSettings.brightness),
    @("system", "screen_off_timeout", $Context.SavedSettings.screenTimeout),
    @("system", "accelerometer_rotation", $Context.SavedSettings.accelerometerRotation),
    @("system", "user_rotation", $Context.SavedSettings.userRotation)
  )) {
    $actual = Get-CcrPinnedDeviceSetting $Context $entry[0] $entry[1]
    if ([string]$actual -cne [string]$entry[2]) { throw "S24_SETTING_RESTORE_MISMATCH:$($entry[0])/$($entry[1])" }
  }
}

$context = Invoke-CcrPinnedPreflight -ArtifactManifest $ArtifactManifest -OutputDirectory $OutputDirectory
if ($PreflightOnly) {
  $evidence = New-S24PreflightEvidence $context "s24-exact-preflight-v2"
  Write-Output (Write-S24ReadOnlyJson $context "s24-gate-preflight.json" $evidence)
  return
}

$primaryFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$mutationStarted = $false
$result = $null
try {
  Save-CcrPinnedDeviceSettings $context | Out-Null
  $exactRunId = New-CcrPinnedRunId $context.OutputDirectory "s24-exact"
  $releaseRunId = New-CcrPinnedRunId $context.OutputDirectory "s24-release"
  $mutationStarted = $true
  Install-CcrPinnedArtifactSet $context "Debug"

  Clear-CcrPinnedRemoteReport $context $appPackage $exactReportName
  Clear-CcrPinnedRemoteReport $context $appPackage $sequentialReportName
  $exactInvocation = Invoke-CcrPinnedInstrumentation `
    -Context $context -TestRole "debugTest" -ClassName $exactClass -RunId $exactRunId -ExpectedTestCount 2
  $exactReceived = Receive-CcrPinnedReport `
    -Context $context -ReportName $exactReportName -RunId $exactRunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $exactInvocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "frame-accuracy-exact" -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 2
  $sequentialReceived = Receive-CcrPinnedReport `
    -Context $context -ReportName $sequentialReportName -RunId $exactRunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $exactInvocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "forward-sequential-exact" -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 2

  $exact = $exactReceived.Report
  $sequential = $sequentialReceived.Report
  Assert-S24AppReportIdentity $context $exact "frame-accuracy-exact"
  Assert-S24AppReportIdentity $context $sequential "forward-sequential-exact"
  Assert-S24GateCounters $exact "frame-accuracy-exact"
  Assert-S24GateCounters $sequential "forward-sequential-exact"
  if ([int]$exact.device.displayWidth -le 0 -or [int]$exact.device.displayHeight -le 0 -or [double]$exact.device.refreshRate -le 0) {
    throw "S24_REPORT_DISPLAY_MISSING:frame-accuracy-exact"
  }

  $fullFixtures = @($exact.fixtures)
  $fullFrameCount = [long](($fullFixtures | Measure-Object -Property frameCount -Sum).Sum)
  if ($fullFixtures.Count -ne 17 -or $fullFrameCount -ne 236) { throw "S24_FULL_FIXTURE_COUNT_MISMATCH" }
  Assert-S24HardwareFixtures $fullFixtures -RequireProfile

  $sequentialFixtures = @($sequential.fixtures)
  $sequentialFrameCount = [long](($sequentialFixtures | Measure-Object -Property frameCount -Sum).Sum)
  if ($sequentialFixtures.Count -ne 3 -or $sequentialFrameCount -ne 68) { throw "S24_SEQUENTIAL_FIXTURE_COUNT_MISMATCH" }
  Assert-S24HardwareFixtures $sequentialFixtures -RequireProfile

  $sequentialRuns = @($sequential.forwardSequentialRuns)
  $sequentialTargetCount = [long](($sequentialRuns | Measure-Object -Property requestCount -Sum).Sum)
  $actualRunKeys = ($sequentialRuns | ForEach-Object { "$($_.fixture):$([int]$_.stride)" } | Sort-Object) -join ","
  $expectedRunKeys = @(
    "h264-bframes.mp4:1", "h264-bframes.mp4:5", "long-gop.mp4:1",
    "long-gop.mp4:5", "vfr.mp4:1", "vfr.mp4:5"
  ) | Sort-Object
  if ($sequentialRuns.Count -ne 6 -or $sequentialTargetCount -ne 77 -or $actualRunKeys -cne ($expectedRunKeys -join ",")) {
    throw "S24_SEQUENTIAL_RUN_COUNT_MISMATCH"
  }
  foreach ($run in $sequentialRuns) {
    Assert-S24Zero $run.mismatchCount "S24_SEQUENTIAL_RUN_MISMATCH_NONZERO"
    if ([long]$run.sequentialEntryCount -le 0 -or [long]$run.sequentialOutputCount -le 0) {
      throw "S24_SEQUENTIAL_PATH_NOT_EXERCISED"
    }
  }

  Clear-CcrPinnedRemoteReport $context $appPackage $releaseReportName
  $releaseInvocation = Invoke-CcrPinnedInstrumentation `
    -Context $context -TestRole "debugTest" -ClassName $releaseMethod -RunId $releaseRunId -ExpectedTestCount 1
  $releaseReceived = Receive-CcrPinnedReport `
    -Context $context -ReportName $releaseReportName -RunId $releaseRunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $releaseInvocation.MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "release-cancel-grace" -ExpectedTestCount 1 -ExpectedInstrumentationTestCount 1
  $release = $releaseReceived.Report
  Assert-S24AppReportIdentity $context $release "release-cancel-grace"
  if ($release.hardwareDecoderRequired -ne $true -or [string]::IsNullOrWhiteSpace([string]$release.codecComponent)) {
    throw "S24_RELEASE_HARDWARE_DECODER_MISSING"
  }
  foreach ($field in @(
    "requestedFrameIndexChangeAfterRelease", "acceptedForegroundRequestCountAfterRelease",
    "requestedFrameIndexChangeAfterCancel", "acceptedForegroundRequestCountAfterCancel", "writeOpenCount"
  )) {
    Assert-S24Zero $release.$field "S24_RELEASE_CANCEL_COUNTER_NONZERO:$field"
  }

  foreach ($path in @($exactReceived.Path, $sequentialReceived.Path, $releaseReceived.Path)) {
    [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::ReadOnly)
  }
  $summary = [ordered]@{
    schemaVersion = 2
    kind = "s24-exact-gate-v2"
    status = "PASS"
    artifactManifestSha256 = $context.ArtifactSet.ManifestSha256
    artifactSetRevision = 2
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = [string](Get-CcrPinnedArtifact $context "debugApp").sha256
    debugTestApkSha256 = [string](Get-CcrPinnedArtifact $context "debugTest").sha256
    device = [ordered]@{ serial = $context.Serial; model = $context.Model; fingerprint = $context.Fingerprint }
    exactRunId = $exactRunId
    releaseRunId = $releaseRunId
    fullFixtureCount = $fullFixtures.Count
    fullFrameCount = $fullFrameCount
    sequentialRunCount = $sequentialRuns.Count
    sequentialTargetCount = $sequentialTargetCount
    releaseAcceptedForegroundRequestCount = 0
    reports = @(
      [System.IO.Path]::GetFileName($exactReceived.Path),
      [System.IO.Path]::GetFileName($sequentialReceived.Path),
      [System.IO.Path]::GetFileName($releaseReceived.Path)
    )
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  $summaryPath = Write-S24ReadOnlyJson $context "s24-gate-summary.json" $summary
  $result = [PSCustomObject]@{ status = "PASS"; summary = $summaryPath; reports = $summary.reports }
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
      try { Assert-S24PackageAbsent $context $packageName } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
    }
    try { Assert-S24SettingsRestored $context } catch { $cleanupFailures.Add($_.Exception.Message) | Out-Null }
  }
}

if ($null -ne $primaryFailure -and $cleanupFailures.Count -gt 0) {
  throw "PRIMARY=$($primaryFailure.Exception.Message); CLEANUP=$($cleanupFailures -join ' | ')"
}
if ($null -ne $primaryFailure) { throw $primaryFailure }
if ($cleanupFailures.Count -gt 0) { throw "CLEANUP=$($cleanupFailures -join ' | ')" }
Write-Output $result
