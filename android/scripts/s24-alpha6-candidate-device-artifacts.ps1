$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Keep the historical revision 4 entry point intact. The active device bridge
# reuses only its audited Alpha 6 host/device primitives and then explicitly
# enters through the strict revision 5 candidate importer.
$script:CcrAlpha6HistoricalPinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
$script:CcrAlpha6CandidateArtifactsPath = Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"
. $script:CcrAlpha6HistoricalPinnedPath
. $script:CcrAlpha6CandidateArtifactsPath

# The candidate importer rebinds runtime and signer values from validated
# inputs. Keep only the non-secret active harness constants explicit at load
# time so host-side contract functions cannot fall back to Alpha 4 defaults.
$script:CcrPinnedArtifactSetRevision = $script:CcrCandidateArtifactSetRevision
$script:CcrPinnedVersionName = "0.2.0-alpha.6"
$script:CcrPinnedVersionCode = 7
$script:CcrPinnedRuntimeSourceSha = $null
$script:CcrPinnedRuntimeInputsTreeSha256 = $null
$script:CcrPinnedDebugAppSha256 = $null
$script:CcrAlpha6FixtureOpenRequiredFixtures = @(
  "h264-ip.mp4",
  "h264-bframes.mp4",
  "vfr.mp4",
  "long-gop.mp4",
  "nonzero-pts.mp4",
  "one-frame.mp4",
  "two-frame.mp4",
  "short-last-gop.mp4",
  "rotation-90.mp4",
  "rotation-180.mp4",
  "rotation-270.mp4",
  "hevc-main8.mp4",
  "burst.mp4",
  "switch-a.mp4",
  "switch-b.mp4",
  "par-8-9.mp4",
  "duplicate-pts.mp4"
)

function Get-CcrAlpha6CandidatePublicFileRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_FILE_MISSING:$full"
  }
  $item = Get-Item -Force -LiteralPath $full
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_FILE_INVALID:$full"
  }
  $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $relative = if (Test-CcrPinnedPathWithin $full $repo) {
    $full.Substring($repo.Length).TrimStart([char[]]"\/").Replace('\', '/')
  } else {
    [System.IO.Path]::GetFileName($full)
  }
  return [PSCustomObject][ordered]@{
    repositoryRelativePath = $relative
    path = $full
    bytes = [long]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
  }
}

function Get-CcrAlpha6CandidatePublicSigningIdentity {
  param(
    [string]$RepoRoot = (Get-CcrCandidateRepoRoot),
    [string]$SigningDirectory = (Join-Path (Get-CcrCandidateRepoRoot) "android\signing")
  )
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  $signing = [System.IO.Path]::GetFullPath($SigningDirectory)
  $policyPath = Join-Path $signing "ccr-internal-pilot-v1-policy.json"
  $fingerprintPath = Join-Path $signing "ccr-internal-pilot-v1-cert.sha256"
  $certificatePath = Join-Path $signing "ccr-internal-pilot-v1-cert.pem"
  $policyRecord = Get-CcrAlpha6CandidatePublicFileRecord $policyPath $repo
  $fingerprintRecord = Get-CcrAlpha6CandidatePublicFileRecord $fingerprintPath $repo
  $certificateRecord = Get-CcrAlpha6CandidatePublicFileRecord $certificatePath $repo
  try {
    $policy = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_JSON_INVALID"
  }
  $fingerprint = Get-CcrCandidatePublicPolicyFingerprint $fingerprintPath
  foreach ($contract in @(
    @("schemaVersion", 1),
    @("status", "SIGNING_BASELINE_READY"),
    @("purpose", $script:CcrCandidateSigningPurpose),
    @("signingLineage", $script:CcrCandidateSigningLineage),
    @("signingMode", "SIGNED_CANDIDATE"),
    @("artifactSetRevision", $script:CcrCandidateArtifactSetRevision),
    @("alias", $script:CcrCandidateSigningAlias),
    @("certificateSha256", $fingerprint),
    @("expectedSigningCertificateSha256", $fingerprint),
    @("keyAlgorithm", "RSA-4096"),
    @("productionOrPlayKeyShared", $false),
    @("standardDebugKeyShared", $false)
  )) {
    $actual = Get-CcrPinnedRequiredProperty $policy ([string]$contract[0])
    if (($actual | ConvertTo-Json -Compress) -cne ($contract[1] | ConvertTo-Json -Compress)) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_CONTRACT_MISMATCH:$($contract[0])"
    }
  }
  $certificateFingerprint = Get-CcrCandidatePublicCertificateSha256 $certificatePath
  if ($certificateFingerprint -cne $fingerprint) {
    throw "ALPHA6_CANDIDATE_PUBLIC_CERTIFICATE_MISMATCH"
  }
  return [PSCustomObject][ordered]@{
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    signingLineage = $script:CcrCandidateSigningLineage
    expectedSigningCertificateSha256 = $fingerprint
    publicPolicy = $policyRecord
    publicFingerprint = $fingerprintRecord
    publicCertificate = $certificateRecord
  }
}

function Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged {
  param([Parameter(Mandatory = $true)][object]$Context)
  $identity = Get-CcrPinnedRequiredProperty $Context "PublicSigningIdentity"
  foreach ($name in @("publicPolicy", "publicFingerprint", "publicCertificate")) {
    $record = Get-CcrPinnedRequiredProperty $identity $name
    $path = [System.IO.Path]::GetFullPath([string](Get-CcrPinnedRequiredProperty $record "path"))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_MISSING_AFTER_PREFLIGHT:$name"
    }
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [long]$item.Length -ne [long](Get-CcrPinnedRequiredProperty $record "bytes") -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne
          [string](Get-CcrPinnedRequiredProperty $record "sha256")) {
      throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_CHANGED_AFTER_PREFLIGHT:$name"
    }
  }
  if ([string](Get-CcrPinnedRequiredProperty $identity "signingMode") -cne "SIGNED_CANDIDATE" -or
      (Get-CcrPinnedRequiredProperty $identity "candidateSigning") -ne $true -or
      [string](Get-CcrPinnedRequiredProperty $identity "signingLineage") -cne $script:CcrCandidateSigningLineage -or
      [string](Get-CcrPinnedRequiredProperty $identity "expectedSigningCertificateSha256") -cne
        $script:CcrPinnedSigningCertificateSha256) {
    throw "ALPHA6_CANDIDATE_PUBLIC_POLICY_IDENTITY_MISMATCH"
  }
  return $true
}

function Assert-CcrAlpha6CandidateDeviceIdentityUnchanged {
  param([Parameter(Mandatory = $true)][object]$Context)
  Assert-CcrAlpha6ArtifactSetUnchanged $Context | Out-Null
  Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged $Context | Out-Null
  return $true
}

function Get-CcrAlpha6CandidateDeviceSettingsSnapshot {
  param([Parameter(Mandatory = $true)][object]$Context)
  return [PSCustomObject][ordered]@{
    stayAwake = Get-CcrPinnedDeviceSetting $Context "global" "stay_on_while_plugged_in"
    brightnessMode = Get-CcrPinnedDeviceSetting $Context "system" "screen_brightness_mode"
    brightness = Get-CcrPinnedDeviceSetting $Context "system" "screen_brightness"
    screenTimeout = Get-CcrPinnedDeviceSetting $Context "system" "screen_off_timeout"
    accelerometerRotation = Get-CcrPinnedDeviceSetting $Context "system" "accelerometer_rotation"
    userRotation = Get-CcrPinnedDeviceSetting $Context "system" "user_rotation"
  }
}

function Invoke-CcrAlpha6CandidateIdentitySmokeInstrumentation {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  $directory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
  if (-not (Test-CcrPinnedPathWithin $directory ([string]$Context.OutputDirectory))) {
    throw "ALPHA6_IDENTITY_SMOKE_EVIDENCE_PATH_FORBIDDEN"
  }
  if (Test-Path -LiteralPath $directory) {
    throw "ALPHA6_IDENTITY_SMOKE_EVIDENCE_ALREADY_EXISTS"
  }
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  Install-CcrPinnedArtifactSet $Context "Debug"
  $invocation = Invoke-CcrPinnedInstrumentation `
    -Context $Context `
    -TestRole "debugTest" `
    -ClassName (
      "com.snowberried.ctcinereviewer.gate.Alpha6CandidateIdentitySmokeTest" +
      "#candidateIdentityMatchesInstalledRevisionFiveArtifacts"
    ) `
    -RunId $RunId `
    -ExpectedTestCount 1 `
    -FailureReportPath (Join-Path $directory "failure-alpha6-candidate-identity-smoke-v1.json")
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  return [PSCustomObject][ordered]@{
    status = "PASS"
    kind = "alpha6-candidate-identity-smoke-instrumentation"
    runId = $RunId
    executedTestCount = 1
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision =
      [int](Get-CcrPinnedRequiredProperty $Context.ArtifactSet.Manifest "artifactSetRevision")
    installedDebugAppSha256 = [string](Get-CcrPinnedArtifact $Context "debugApp").sha256
    installedDebugTestSha256 = [string](Get-CcrPinnedArtifact $Context "debugTest").sha256
    expectedSigningCertificateSha256 =
      [string]$Context.PublicSigningIdentity.expectedSigningCertificateSha256
    packageName = [string](Get-CcrPinnedArtifact $Context "debugApp").packageName
    instrumentationPackageName = [string](Get-CcrPinnedArtifact $Context "debugTest").packageName
    debugArtifactInstallSetCount = 1L
    debugArtifactInstallCommandCount = 2L
    instrumentationOutput = [string]$invocation.Output
    buildCommandCount = 0L
  }
}

function Assert-CcrAlpha6FixtureOpenReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet("Smoke", "Diagnostic")][string]$Mode,
    [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL")][string]$ExpectedStatus,
    [long]$MinimumStartedAtElapsedRealtimeNs = 0
  )
  $kind = if ($Mode -ceq "Smoke") {
    "alpha6-fixture-open-smoke"
  } else {
    "alpha6-fixture-open-diagnostic"
  }
  Assert-CcrPinnedReport `
    -Report $Report -ArtifactSet $Context.ArtifactSet -RunId $RunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind $kind -ExpectedStatus $ExpectedStatus | Out-Null
  $app = Get-CcrPinnedArtifact $Context "debugApp"
  $device = Get-CcrPinnedRequiredProperty $Report "device"
  if ([int](Get-CcrPinnedRequiredProperty $Report "schemaVersion") -ne 1 -or
      [string](Get-CcrPinnedRequiredProperty $Report "applicationId") -cne
        [string]$app.packageName -or
      [string](Get-CcrPinnedRequiredProperty $Report "appVersionName") -cne
        [string]$app.versionName -or
      [long](Get-CcrPinnedRequiredProperty $Report "appVersionCode") -ne
        [long]$app.versionCode -or
      [string](Get-CcrPinnedRequiredProperty $device "manufacturer") -cne "samsung" -or
      [string](Get-CcrPinnedRequiredProperty $device "model") -cne [string]$Context.Model -or
      [string](Get-CcrPinnedRequiredProperty $device "fingerprint") -cne
        [string]$Context.Fingerprint -or
      [string](Get-CcrPinnedRequiredProperty $device "securityPatch") -cne
        [string]$Context.SecurityPatch -or
      [int](Get-CcrPinnedRequiredProperty $device "sdk") -ne [int]$Context.Sdk) {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_DEVICE_OR_APP_IDENTITY_MISMATCH"
  }
  foreach ($contract in @(
    @("writeOpenCount", 0L),
    @("fullFrameDecodeCount", 0L),
    @("performanceScenarioCount", 0L)
  )) {
    if ([long](Get-CcrPinnedRequiredProperty $Report ([string]$contract[0])) -ne [long]$contract[1]) {
      throw "ALPHA6_FIXTURE_OPEN_REPORT_ZERO_CONTRACT_MISMATCH:$($contract[0])"
    }
  }
  if ($ExpectedStatus -ceq "FAIL") {
    $failure = Get-CcrPinnedRequiredProperty $Report "failure"
    foreach ($name in @("stageCode", "classification", "exceptionClass", "sanitizedDetail")) {
      if ([string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $failure $name))) {
        throw "ALPHA6_FIXTURE_OPEN_FAILURE_DETAIL_MISSING:$name"
      }
    }
    return $Report
  }
  $expectedFixtureCount = if ($Mode -ceq "Smoke") { 17L } else { 1L }
  foreach ($name in @(
    "fixtureCount",
    "assetHashPassCount",
    "providerOpenPassCount",
    "cacheVerificationPassCount",
    "extractorFdOnlyPassCount",
    "videoTrackPassCount",
    "sampleEnumerationPassCount",
    "hardwareDecoderCandidatePassCount"
  )) {
    if ([long](Get-CcrPinnedRequiredProperty $Report $name) -ne $expectedFixtureCount) {
      throw "ALPHA6_FIXTURE_OPEN_REPORT_COUNT_MISMATCH:$Mode/$name"
    }
  }
  $expectedExplicitRangeCount = if ($Mode -ceq "Diagnostic") { 1L } else { 0L }
  $expectedCodecCount = if ($Mode -ceq "Diagnostic") { 1L } else { 0L }
  if ([long](Get-CcrPinnedRequiredProperty $Report "extractorExplicitRangePassCount") -ne
      $expectedExplicitRangeCount -or
      [long](Get-CcrPinnedRequiredProperty $Report "codecConfigureStartPassCount") -ne
      $expectedCodecCount -or
      @((Get-CcrPinnedRequiredProperty $Report "fixtures")).Count -ne $expectedFixtureCount) {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_MODE_CONTRACT_MISMATCH:$Mode"
  }
  $expectedFixtures = @(if ($Mode -ceq "Smoke") {
      $script:CcrAlpha6FixtureOpenRequiredFixtures
    } else {
      "h264-ip.mp4"
    })
  $fixtureReports = @((Get-CcrPinnedRequiredProperty $Report "fixtures"))
  $actualFixtures = @($fixtureReports | ForEach-Object {
    [string](Get-CcrPinnedRequiredProperty $_ "fixture")
  })
  if (($actualFixtures -join "|") -cne ($expectedFixtures -join "|") -or
      @($actualFixtures | Select-Object -Unique).Count -ne $expectedFixtures.Count) {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_FIXTURE_IDENTITY_MISMATCH:$Mode"
  }
  foreach ($fixtureReport in $fixtureReports) {
    $fixtureName = [string](Get-CcrPinnedRequiredProperty $fixtureReport "fixture")
    $fixtureId = [System.IO.Path]::GetFileNameWithoutExtension($fixtureName)
    $goldenPath = Join-Path ([string]$Context.RepoRoot) (
      "android\testdata\frame-accuracy\$fixtureId.json"
    )
    try {
      $golden = [System.IO.File]::ReadAllText(
        $goldenPath,
        [System.Text.Encoding]::UTF8
      ) | ConvertFrom-Json
    } catch {
      throw "ALPHA6_FIXTURE_OPEN_GOLDEN_READ_FAILED:$fixtureId"
    }
    $expectedSha = [string](Get-CcrPinnedRequiredProperty $golden "sourceSha256")
    $expectedSampleCount = [long](Get-CcrPinnedRequiredProperty $golden "frameCount")
    $expectedFrames = @(
      (Get-CcrPinnedRequiredProperty $golden "frames") |
        Sort-Object { [int](Get-CcrPinnedRequiredProperty $_ "sampleOrdinal") }
    )
    $asset = Get-CcrPinnedRequiredProperty $fixtureReport "asset"
    $provider = Get-CcrPinnedRequiredProperty $fixtureReport "providerDescriptor"
    $fdOnly = Get-CcrPinnedRequiredProperty $fixtureReport "extractorFdOnly"
    $fdOnlyResult = Get-CcrPinnedRequiredProperty $fdOnly "result"
    $hardware = Get-CcrPinnedRequiredProperty $fixtureReport "hardwareDecoderCandidate"
    $hardwareResult = Get-CcrPinnedRequiredProperty $hardware "result"
    if ([string](Get-CcrPinnedRequiredProperty $fixtureReport "status") -cne "PASS" -or
        [string](Get-CcrPinnedRequiredProperty $golden "fixture") -cne $fixtureName -or
        $expectedSha -cnotmatch "^[a-f0-9]{64}$" -or
        [string](Get-CcrPinnedRequiredProperty $fixtureReport "expectedSourceSha256") -cne
          $expectedSha -or
        [long](Get-CcrPinnedRequiredProperty $fixtureReport "expectedSampleCount") -ne
          $expectedSampleCount -or
        [long](Get-CcrPinnedRequiredProperty $asset "byteCount") -le 0L -or
        [string](Get-CcrPinnedRequiredProperty $asset "sha256") -cne $expectedSha -or
        [string](Get-CcrPinnedRequiredProperty $provider "authority") -cne
          "$($app.packageName).fixture" -or
        (Get-CcrPinnedRequiredProperty $provider "resolved") -ne $true -or
        (Get-CcrPinnedRequiredProperty $provider "exported") -ne $false -or
        (Get-CcrPinnedRequiredProperty $provider "regularFile") -ne $true -or
        (Get-CcrPinnedRequiredProperty $provider "seekable") -ne $true -or
        [long](Get-CcrPinnedRequiredProperty $provider "initialOffset") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $provider "statSize") -ne
          [long](Get-CcrPinnedRequiredProperty $asset "byteCount") -or
        [long](Get-CcrPinnedRequiredProperty $provider "byteCount") -ne
          [long](Get-CcrPinnedRequiredProperty $asset "byteCount") -or
        [string](Get-CcrPinnedRequiredProperty $provider "sha256") -cne $expectedSha -or
        [string](Get-CcrPinnedRequiredProperty $fixtureReport "cachePfdSha256") -cne
          $expectedSha -or
        [string](Get-CcrPinnedRequiredProperty $fdOnly "status") -cne "PASS" -or
        [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "trackCount") -le 0L -or
        [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "videoTrackIndex") -lt 0L -or
        [string](Get-CcrPinnedRequiredProperty $fdOnlyResult "mime") -cnotmatch "^video/" -or
        [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "sampleCount") -ne
          $expectedSampleCount -or
        [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "firstPtsUs") -ne
          [long](Get-CcrPinnedRequiredProperty $expectedFrames[0] "ptsUs") -or
        [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "lastPtsUs") -ne
          [long](Get-CcrPinnedRequiredProperty $expectedFrames[-1] "ptsUs") -or
        [string](Get-CcrPinnedRequiredProperty $hardware "status") -cne "PASS" -or
        [string]::IsNullOrWhiteSpace(
          [string](Get-CcrPinnedRequiredProperty $hardwareResult "componentName")
        ) -or
        (Get-CcrPinnedRequiredProperty $hardwareResult "hardwareAccelerated") -ne $true -or
        (Get-CcrPinnedRequiredProperty $hardwareResult "softwareOnly") -ne $false -or
        [long](Get-CcrPinnedRequiredProperty $fixtureReport "fullFrameDecodeCount") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $fixtureReport "performanceScenarioCount") -ne 0L) {
      throw "ALPHA6_FIXTURE_OPEN_REPORT_FIXTURE_CONTRACT_MISMATCH:$fixtureId"
    }
    $explicit = Get-CcrPinnedRequiredProperty $fixtureReport "extractorExplicitRange"
    $codec = Get-CcrPinnedRequiredProperty $fixtureReport "codecConfigureStart"
    if ($Mode -ceq "Smoke") {
      if ($null -ne $explicit -or $null -ne $codec) {
        throw "ALPHA6_FIXTURE_OPEN_REPORT_SMOKE_DID_EXTRA_WORK:$fixtureId"
      }
    } else {
      $explicitResult = Get-CcrPinnedRequiredProperty $explicit "result"
      $codecResult = Get-CcrPinnedRequiredProperty $codec "result"
      if ([string](Get-CcrPinnedRequiredProperty $explicit "status") -cne "PASS" -or
          [long](Get-CcrPinnedRequiredProperty $explicitResult "sampleCount") -ne
            $expectedSampleCount -or
          [long](Get-CcrPinnedRequiredProperty $explicitResult "firstPtsUs") -ne
            [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "firstPtsUs") -or
          [long](Get-CcrPinnedRequiredProperty $explicitResult "lastPtsUs") -ne
            [long](Get-CcrPinnedRequiredProperty $fdOnlyResult "lastPtsUs") -or
          [string](Get-CcrPinnedRequiredProperty $codec "status") -cne "PASS" -or
          (Get-CcrPinnedRequiredProperty $codecResult "surfaceReady") -ne $true -or
          (Get-CcrPinnedRequiredProperty $codecResult "configured") -ne $true -or
          (Get-CcrPinnedRequiredProperty $codecResult "started") -ne $true -or
          [long](Get-CcrPinnedRequiredProperty $codecResult "queuedInputBufferCount") -ne 0L -or
          [long](Get-CcrPinnedRequiredProperty $codecResult "dequeuedOutputBufferCount") -ne 0L) {
        throw "ALPHA6_FIXTURE_OPEN_REPORT_DIAGNOSTIC_CONTRACT_MISMATCH:$fixtureId"
      }
    }
  }
  return $Report
}

function Receive-CcrAlpha6FixtureOpenReport {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$ReportName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet("Smoke", "Diagnostic")][string]$Mode,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [long]$MinimumStartedAtElapsedRealtimeNs = 0
  )
  if ($ReportName -notmatch "^[A-Za-z0-9._-]+\.json$") {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_NAME_INVALID"
  }
  $packageName = [string](Get-CcrPinnedArtifact $Context "debugApp").packageName
  $result = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "exec-out", "run-as", $packageName, "cat", "files/$ReportName"
  )
  if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.output)) {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_PULL_FAILED:$ReportName"
  }
  $target = Join-Path $EvidenceDirectory $ReportName
  if (Test-Path -LiteralPath $target) { throw "ALPHA6_FIXTURE_OPEN_REPORT_ALREADY_EXISTS" }
  [System.IO.File]::WriteAllText(
    $target,
    ([string]$result.output),
    [System.Text.UTF8Encoding]::new($false)
  )
  (Get-Item -LiteralPath $target).IsReadOnly = $true
  try { $report = $result.output | ConvertFrom-Json } catch {
    throw "ALPHA6_FIXTURE_OPEN_REPORT_JSON_INVALID:$ReportName"
  }
  $status = [string](Get-CcrPinnedRequiredProperty $report "status")
  if ($status -notin @("PASS", "FAIL")) { throw "ALPHA6_FIXTURE_OPEN_REPORT_STATUS_INVALID" }
  Assert-CcrAlpha6FixtureOpenReport `
    -Report $report -Context $Context -RunId $RunId -Mode $Mode `
    -ExpectedStatus $status -MinimumStartedAtElapsedRealtimeNs $MinimumStartedAtElapsedRealtimeNs | Out-Null
  return [PSCustomObject][ordered]@{
    Path = $target
    Bytes = [long](Get-Item -LiteralPath $target).Length
    Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    Report = $report
  }
}

function Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [Parameter(Mandatory = $true)][ValidateSet("Smoke", "Diagnostic")][string]$Mode,
    [switch]$SkipInstall
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  $directory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
  if (-not (Test-CcrPinnedPathWithin $directory ([string]$Context.OutputDirectory))) {
    throw "ALPHA6_FIXTURE_OPEN_EVIDENCE_PATH_FORBIDDEN"
  }
  if (Test-Path -LiteralPath $directory) {
    throw "ALPHA6_FIXTURE_OPEN_EVIDENCE_ALREADY_EXISTS"
  }
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  if (-not $SkipInstall) { Install-CcrPinnedArtifactSet $Context "Debug" }
  $isSmoke = $Mode -ceq "Smoke"
  $reportName = if ($isSmoke) {
    "s24-alpha6-fixture-open-smoke-v1.json"
  } else {
    "s24-alpha6-fixture-open-diagnostic-v1.json"
  }
  $className = if ($isSmoke) {
    "com.snowberried.ctcinereviewer.gate.Alpha6FixtureOpenSmokeTest" +
      "#allRequiredFixturesOpenWithoutFrameDecodeOrPerformance"
  } else {
    "com.snowberried.ctcinereviewer.gate.Alpha6FixtureOpenDiagnosticTest" +
      "#h264IpOpenPipelineIsDiagnosedWithoutFrameDecode"
  }
  Clear-CcrPinnedRemoteReport `
    -Context $Context -PackageName ([string](Get-CcrPinnedArtifact $Context "debugApp").packageName) `
    -ReportName $reportName
  $minimumStartedAt = Get-CcrPinnedDeviceElapsedRealtimeNs $Context
  $instrumentationFailure = $null
  $invocation = $null
  try {
    $invocation = Invoke-CcrPinnedInstrumentation `
      -Context $Context -TestRole "debugTest" -ClassName $className `
      -RunId $RunId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $directory "failure-alpha6-fixture-open-$($Mode.ToLowerInvariant())-v1.json")
  } catch {
    $instrumentationFailure = $_
  }
  $received = $null
  $receiveFailure = $null
  try {
    $received = Receive-CcrAlpha6FixtureOpenReport `
      -Context $Context -ReportName $reportName -RunId $RunId -Mode $Mode `
      -EvidenceDirectory $directory -MinimumStartedAtElapsedRealtimeNs $minimumStartedAt
  } catch {
    $receiveFailure = $_
  }
  if ($null -ne $receiveFailure) {
    if ($null -ne $instrumentationFailure) {
      throw "PRIMARY=$($instrumentationFailure.Exception.Message); REPORT=$($receiveFailure.Exception.Message)"
    }
    throw $receiveFailure
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  $report = $received.Report
  if ($null -ne $instrumentationFailure -or [string]$report.status -cne "PASS") {
    $failure = if ([string]$report.status -ceq "FAIL") {
      Get-CcrPinnedRequiredProperty $report "failure"
    } else {
      [PSCustomObject][ordered]@{
        stageCode = "INSTRUMENTATION"
        classification = "INSTRUMENTATION_EXECUTION_FAILURE"
        exceptionClass = "HostInstrumentationFailure"
        sanitizedDetail = "SEE_PINNED_INSTRUMENTATION_FAILURE_REPORT"
      }
    }
    return [PSCustomObject][ordered]@{
      status = "FAIL"
      kind = "alpha6-candidate-fixture-open-$($Mode.ToLowerInvariant())-instrumentation"
      runId = $RunId
      fixtureCount = [long]$report.fixtureCount
      reportPath = [string]$received.Path
      reportBytes = [long]$received.Bytes
      reportSha256 = [string]$received.Sha256
      failure = $failure
      instrumentationFailure = $(if ($null -ne $instrumentationFailure) {
          [string]$instrumentationFailure.Exception.Message
        } else {
          $null
        })
      runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
      harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
      runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
      artifactSetRevision =
        [int](Get-CcrPinnedRequiredProperty $Context.ArtifactSet.Manifest "artifactSetRevision")
      buildCommandCount = 0L
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
    }
  }
  return [PSCustomObject][ordered]@{
    status = "PASS"
    kind = "alpha6-candidate-fixture-open-$($Mode.ToLowerInvariant())-instrumentation"
    runId = $RunId
    fixtureCount = [long]$report.fixtureCount
    reportPath = [string]$received.Path
    reportBytes = [long]$received.Bytes
    reportSha256 = [string]$received.Sha256
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision =
      [int](Get-CcrPinnedRequiredProperty $Context.ArtifactSet.Manifest "artifactSetRevision")
    instrumentationOutput = [string]$invocation.Output
    buildCommandCount = 0L
    fullFrameDecodeCount = 0L
    performanceScenarioCount = 0L
  }
}

function Assert-CcrAlpha6RenderOpenReport {
  param(
    [Parameter(Mandatory = $true)][object]$Report,
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL")][string]$ExpectedStatus,
    [long]$MinimumStartedAtElapsedRealtimeNs = 0
  )
  Assert-CcrPinnedReport `
    -Report $Report -ArtifactSet $Context.ArtifactSet -RunId $RunId `
    -AppRole "debugApp" -TestRole "debugTest" `
    -MinimumStartedAtElapsedRealtimeNs $MinimumStartedAtElapsedRealtimeNs `
    -ExpectedKind "alpha6-render-open-smoke" -ExpectedStatus $ExpectedStatus | Out-Null
  $app = Get-CcrPinnedArtifact $Context "debugApp"
  $device = Get-CcrPinnedRequiredProperty $Report "device"
  if ([int](Get-CcrPinnedRequiredProperty $Report "schemaVersion") -ne 1 -or
      [string](Get-CcrPinnedRequiredProperty $Report "fixture") -cne "h264-ip.mp4" -or
      [string](Get-CcrPinnedRequiredProperty $Report "applicationId") -cne
        [string]$app.packageName -or
      [string](Get-CcrPinnedRequiredProperty $Report "appVersionName") -cne
        [string]$app.versionName -or
      [long](Get-CcrPinnedRequiredProperty $Report "appVersionCode") -ne
        [long]$app.versionCode -or
      [string](Get-CcrPinnedRequiredProperty $device "manufacturer") -cne "samsung" -or
      [string](Get-CcrPinnedRequiredProperty $device "model") -cne [string]$Context.Model -or
      [string](Get-CcrPinnedRequiredProperty $device "fingerprint") -cne
        [string]$Context.Fingerprint -or
      [string](Get-CcrPinnedRequiredProperty $device "securityPatch") -cne
        [string]$Context.SecurityPatch -or
      [int](Get-CcrPinnedRequiredProperty $device "sdk") -ne [int]$Context.Sdk -or
      [long](Get-CcrPinnedRequiredProperty $Report "stableIntervalMs") -ne 300L -or
      [long](Get-CcrPinnedRequiredProperty $Report "writeOpenCount") -ne 0L -or
      [long](Get-CcrPinnedRequiredProperty $Report "performanceScenarioCount") -ne 0L) {
    throw "ALPHA6_RENDER_OPEN_REPORT_IDENTITY_OR_ZERO_CONTRACT_MISMATCH"
  }
  $evidence = Get-CcrPinnedRequiredProperty $Report "activitySurfaceEvidence"
  foreach ($name in @("beforeOpen", "afterOpen", "statusSequence")) {
    if (-not (Test-CcrPinnedProperty $evidence $name)) {
      throw "ALPHA6_RENDER_OPEN_SURFACE_EVIDENCE_MISSING:$name"
    }
  }
  if ($ExpectedStatus -ceq "FAIL") {
    $failure = Get-CcrPinnedRequiredProperty $Report "failure"
    $classification = [string](Get-CcrPinnedRequiredProperty $failure "classification")
    if ($classification -notin @(
        "SURFACE_NOT_STABLE_BEFORE_OPEN",
        "SURFACE_LOST_DURING_OPEN",
        "STALE_ACTIVITY_INSTANCE",
        "PROVIDER_OR_EXTRACTOR_OPEN_FAILURE",
        "DECODER_SURFACE_UNAVAILABLE",
        "UNCLASSIFIED_AFTER_STABLE_SURFACE"
      )) {
      throw "ALPHA6_RENDER_OPEN_FAILURE_CLASSIFICATION_INVALID:$classification"
    }
    foreach ($name in @("stageCode", "exceptionClass", "sanitizedDetail")) {
      if ([string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $failure $name))) {
        throw "ALPHA6_RENDER_OPEN_FAILURE_DETAIL_MISSING:$name"
      }
    }
    return $Report
  }
  foreach ($contract in @(
    @("activityInstanceDriftCount", 0L),
    @("surfaceGenerationDriftCount", 0L),
    @("surfaceLossCount", 0L),
    @("videoOpenFailedCount", 0L),
    @("fullFrameDecodeCount", 1L)
  )) {
    if ([long](Get-CcrPinnedRequiredProperty $Report ([string]$contract[0])) -ne
        [long]$contract[1]) {
      throw "ALPHA6_RENDER_OPEN_REPORT_COUNTER_MISMATCH:$($contract[0])"
    }
  }
  foreach ($name in @(
    "providerOrExtractorEntered",
    "indexReceived",
    "metadataReceived",
    "firstFramePublished",
    "hardwareAccelerated"
  )) {
    if ((Get-CcrPinnedRequiredProperty $Report $name) -ne $true) {
      throw "ALPHA6_RENDER_OPEN_REPORT_BOOLEAN_MISMATCH:$name"
    }
  }
  $beforeOpen = Get-CcrPinnedRequiredProperty $evidence "beforeOpen"
  $afterOpen = Get-CcrPinnedRequiredProperty $evidence "afterOpen"
  $statusSequence = @((Get-CcrPinnedRequiredProperty $evidence "statusSequence"))
  $beforeActivityId = [string](Get-CcrPinnedRequiredProperty $beforeOpen "activityInstanceId")
  $afterActivityId = [string](Get-CcrPinnedRequiredProperty $afterOpen "activityInstanceId")
  $beforeGeneration = [long](Get-CcrPinnedRequiredProperty $beforeOpen "surfaceGeneration")
  $afterGeneration = [long](Get-CcrPinnedRequiredProperty $afterOpen "surfaceGeneration")
  foreach ($snapshot in @($beforeOpen, $afterOpen)) {
    if ([string](Get-CcrPinnedRequiredProperty $snapshot "scenarioState") -cne "RESUMED" -or
        (Get-CcrPinnedRequiredProperty $snapshot "activityFinishing") -ne $false -or
        (Get-CcrPinnedRequiredProperty $snapshot "activityDestroyed") -ne $false -or
        (Get-CcrPinnedRequiredProperty $snapshot "decorAttached") -ne $true -or
        (Get-CcrPinnedRequiredProperty $snapshot "surfaceViewPresent") -ne $true -or
        (Get-CcrPinnedRequiredProperty $snapshot "surfaceValid") -ne $true -or
        (Get-CcrPinnedRequiredProperty $snapshot "decoderSurfaceAvailable") -ne $true) {
      throw "ALPHA6_RENDER_OPEN_SURFACE_SNAPSHOT_NOT_CURRENT"
    }
  }
  if ([string]::IsNullOrWhiteSpace($beforeActivityId) -or
      $beforeActivityId -cne $afterActivityId -or
      $beforeGeneration -lt 1L -or $beforeGeneration -ne $afterGeneration) {
    throw "ALPHA6_RENDER_OPEN_SURFACE_SNAPSHOT_DRIFT"
  }
  if ($statusSequence.Count -lt 1) {
    throw "ALPHA6_RENDER_OPEN_STATUS_SEQUENCE_EMPTY"
  }
  $lastStatusTimestamp = 0L
  for ($index = 0; $index -lt $statusSequence.Count; $index += 1) {
    $status = $statusSequence[$index]
    $timestamp = [long](Get-CcrPinnedRequiredProperty $status "capturedAtElapsedRealtimeNs")
    if ([long](Get-CcrPinnedRequiredProperty $status "ordinal") -ne $index -or
        [long](Get-CcrPinnedRequiredProperty $status "sequence") -ne $index -or
        $timestamp -le 0L -or $timestamp -lt $lastStatusTimestamp -or
        [string]::IsNullOrWhiteSpace(
          [string](Get-CcrPinnedRequiredProperty $status "status")
        )) {
      throw "ALPHA6_RENDER_OPEN_STATUS_SEQUENCE_INVALID:$index"
    }
    $lastStatusTimestamp = $timestamp
  }
  $expectedFrameKey = Get-CcrPinnedRequiredProperty $Report "expectedFrameKey"
  $actualFrameKey = Get-CcrPinnedRequiredProperty $Report "actualFrameKey"
  foreach ($frameKey in @($expectedFrameKey, $actualFrameKey)) {
    if ([long](Get-CcrPinnedRequiredProperty $frameKey "displayFrameIndex") -ne 0L -or
        [long](Get-CcrPinnedRequiredProperty $frameKey "duplicateOrdinal") -lt 0L) {
      throw "ALPHA6_RENDER_OPEN_REPORT_FRAME_KEY_INVALID"
    }
    [void](Get-CcrPinnedRequiredProperty $frameKey "ptsUs")
  }
  if ([long](Get-CcrPinnedRequiredProperty $Report "providerReadOpenCount") -lt 1L -or
      [string]::IsNullOrWhiteSpace([string](Get-CcrPinnedRequiredProperty $Report "codecComponent")) -or
      ($expectedFrameKey | ConvertTo-Json -Compress) -cne
        ($actualFrameKey | ConvertTo-Json -Compress) -or
      [long](Get-CcrPinnedRequiredProperty $Report "expectedTextureTimestampNs") -ne
        [long](Get-CcrPinnedRequiredProperty $Report "actualTextureTimestampNs")) {
    throw "ALPHA6_RENDER_OPEN_REPORT_FRAME_CONTRACT_MISMATCH"
  }
  return $Report
}

function Receive-CcrAlpha6RenderOpenReport {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [long]$MinimumStartedAtElapsedRealtimeNs = 0
  )
  $reportName = "s24-alpha6-render-open-smoke-v1.json"
  $packageName = [string](Get-CcrPinnedArtifact $Context "debugApp").packageName
  $result = Invoke-CcrPinnedAdb $Context @(
    "-s", $Context.Serial, "exec-out", "run-as", $packageName, "cat", "files/$reportName"
  )
  if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.output)) {
    throw "ALPHA6_RENDER_OPEN_REPORT_PULL_FAILED"
  }
  $target = Join-Path $EvidenceDirectory $reportName
  if (Test-Path -LiteralPath $target) { throw "ALPHA6_RENDER_OPEN_REPORT_ALREADY_EXISTS" }
  [System.IO.File]::WriteAllText(
    $target,
    [string]$result.output,
    [System.Text.UTF8Encoding]::new($false)
  )
  (Get-Item -LiteralPath $target).IsReadOnly = $true
  try { $report = $result.output | ConvertFrom-Json } catch {
    throw "ALPHA6_RENDER_OPEN_REPORT_JSON_INVALID"
  }
  $status = [string](Get-CcrPinnedRequiredProperty $report "status")
  if ($status -notin @("PASS", "FAIL")) { throw "ALPHA6_RENDER_OPEN_REPORT_STATUS_INVALID" }
  Assert-CcrAlpha6RenderOpenReport `
    -Report $report -Context $Context -RunId $RunId -ExpectedStatus $status `
    -MinimumStartedAtElapsedRealtimeNs $MinimumStartedAtElapsedRealtimeNs | Out-Null
  $item = Get-Item -LiteralPath $target
  return [PSCustomObject][ordered]@{
    Path = $target
    Bytes = [long]$item.Length
    Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    Report = $report
  }
}

function Invoke-CcrAlpha6CandidateRenderOpenInstrumentation {
  param(
    [Parameter(Mandatory = $true)][object]$Context,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$SkipInstall
  )
  Assert-CcrPinnedRunId $RunId | Out-Null
  $directory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
  if (-not (Test-CcrPinnedPathWithin $directory ([string]$Context.OutputDirectory))) {
    throw "ALPHA6_RENDER_OPEN_EVIDENCE_PATH_FORBIDDEN"
  }
  if (Test-Path -LiteralPath $directory) {
    throw "ALPHA6_RENDER_OPEN_EVIDENCE_ALREADY_EXISTS"
  }
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  if (-not $SkipInstall) {
    Install-CcrPinnedArtifactSet $Context "Debug"
  } else {
    Assert-CcrPinnedInstalledArtifact $Context "debugApp"
    Assert-CcrPinnedInstalledArtifact $Context "debugTest"
  }
  Clear-CcrPinnedRemoteReport `
    -Context $Context `
    -PackageName ([string](Get-CcrPinnedArtifact $Context "debugApp").packageName) `
    -ReportName "s24-alpha6-render-open-smoke-v1.json"
  $minimumStartedAt = Get-CcrPinnedDeviceElapsedRealtimeNs $Context
  $instrumentationFailure = $null
  $invocation = $null
  try {
    $invocation = Invoke-CcrPinnedInstrumentation `
      -Context $Context -TestRole "debugTest" `
      -ClassName (
        "com.snowberried.ctcinereviewer.gate.Alpha6RenderOpenSmokeTest" +
          "#h264IpRendersFirstExactFrameOnStableCurrentSurface"
      ) `
      -RunId $RunId -ExpectedTestCount 1 `
      -FailureReportPath (Join-Path $directory "failure-alpha6-render-open-instrumentation-v1.json")
  } catch {
    $instrumentationFailure = $_
  }
  $received = $null
  $receiveFailure = $null
  try {
    $received = Receive-CcrAlpha6RenderOpenReport `
      -Context $Context -RunId $RunId -EvidenceDirectory $directory `
      -MinimumStartedAtElapsedRealtimeNs $minimumStartedAt
  } catch {
    $receiveFailure = $_
  }
  if ($null -ne $receiveFailure) {
    if ($null -ne $instrumentationFailure) {
      throw "PRIMARY=$($instrumentationFailure.Exception.Message); REPORT=$($receiveFailure.Exception.Message)"
    }
    throw $receiveFailure
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $Context | Out-Null
  $report = $received.Report
  $common = [ordered]@{
    kind = "alpha6-candidate-render-open-smoke-instrumentation"
    runId = $RunId
    reportPath = [string]$received.Path
    reportBytes = [long]$received.Bytes
    reportSha256 = [string]$received.Sha256
    runtimeSourceSha = [string]$Context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = [string]$Context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = [string]$Context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision =
      [int](Get-CcrPinnedRequiredProperty $Context.ArtifactSet.Manifest "artifactSetRevision")
    buildCommandCount = 0L
    performanceScenarioCount = 0L
  }
  if ($null -ne $instrumentationFailure -or [string]$report.status -cne "PASS") {
    $failure = if ([string]$report.status -ceq "FAIL") {
      Get-CcrPinnedRequiredProperty $report "failure"
    } else {
      [PSCustomObject][ordered]@{
        stageCode = "INSTRUMENTATION"
        classification = "UNCLASSIFIED_AFTER_STABLE_SURFACE"
        exceptionClass = "HostInstrumentationFailure"
        sanitizedDetail = "SEE_PINNED_INSTRUMENTATION_FAILURE_REPORT"
      }
    }
    return [PSCustomObject]($common + [ordered]@{
      status = "FAIL"
      failure = $failure
      instrumentationFailure = $(if ($null -ne $instrumentationFailure) {
          [string]$instrumentationFailure.Exception.Message
        } else {
          $null
        })
    })
  }
  return [PSCustomObject]($common + [ordered]@{
    status = "PASS"
    stableIntervalMs = [long]$report.stableIntervalMs
    activityInstanceId =
      [string](Get-CcrPinnedRequiredProperty $report.activitySurfaceEvidence.beforeOpen "activityInstanceId")
    surfaceGeneration =
      [long](Get-CcrPinnedRequiredProperty $report.activitySurfaceEvidence.beforeOpen "surfaceGeneration")
    activityInstanceDriftCount = [long]$report.activityInstanceDriftCount
    surfaceGenerationDriftCount = [long]$report.surfaceGenerationDriftCount
    surfaceLossCount = [long]$report.surfaceLossCount
    videoOpenFailedCount = [long]$report.videoOpenFailedCount
    instrumentationOutput = [string]$invocation.Output
  })
}

function Invoke-CcrAlpha6CandidateDeviceHostPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactManifest,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
    [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
    [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
    [string]$ExpectedVersionName = "0.2.0-alpha.6",
    [int]$ExpectedVersionCode = 7,
    [Parameter(Mandatory = $true)][bool]$PreflightOnly,
    [Parameter(Mandatory = $true)][long]$BuildCommandCount,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ValidationScriptPaths,
    [string]$RepoRoot = (Get-CcrCandidateRepoRoot),
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
  $repo = [System.IO.Path]::GetFullPath($RepoRoot)
  foreach ($path in $ValidationScriptPaths) {
    $full = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-CcrPinnedPathWithin $full $repo)) {
      throw "ALPHA6_CANDIDATE_VALIDATION_SCRIPT_OUTSIDE_REPOSITORY:$full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw "ALPHA6_VALIDATION_SCRIPT_INVALID:$full"
    }
    $item = Get-Item -Force -LiteralPath $full
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "ALPHA6_CANDIDATE_VALIDATION_SCRIPT_REPARSE_POINT:$full"
    }
  }
  $scripts = @(Assert-CcrAlpha6ValidationScriptsBuildFree $ValidationScriptPaths)
  if ($null -eq $SourceIdentityVerifier) {
    Assert-CcrAlpha6SourceIdentity $repo $RuntimeSourceSha $HarnessSourceSha | Out-Null
  } elseif ((& $SourceIdentityVerifier $repo $RuntimeSourceSha $HarnessSourceSha) -ne $true) {
    throw "ALPHA6_SOURCE_IDENTITY_VERIFIER_REJECTED"
  }
  $output = Assert-CcrAlpha6ExternalOutputDirectory $OutputDirectory $repo
  $publicIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity -RepoRoot $repo `
    -SigningDirectory (Join-Path $repo "android\signing")
  $set = Import-CcrAlpha6CandidateArtifactManifest `
    -ArtifactManifest $ArtifactManifest `
    -ExpectedHarnessSourceSha $HarnessSourceSha.ToLowerInvariant() `
    -ExpectedDebugAppSha256 $ExpectedDebugAppSha256.ToLowerInvariant() `
    -ExpectedRuntimeSourceSha $RuntimeSourceSha.ToLowerInvariant() `
    -ExpectedRuntimeInputsTreeSha256 $RuntimeInputsTreeSha256.ToLowerInvariant() `
    -ExpectedVersionName $ExpectedVersionName `
    -ExpectedVersionCode $ExpectedVersionCode `
    -RepoRoot $repo `
    -FingerprintPath ([string]$publicIdentity.publicFingerprint.path) `
    -AndroidTools $AndroidTools `
    -IdentityReader $IdentityReader
  if ($set.ManifestSha256 -cne $manifestSha) { throw "ALPHA6_PREFLIGHT_MANIFEST_SHA_MISMATCH" }
  if ([int](Get-CcrPinnedRequiredProperty $set.Manifest "artifactSetRevision") -ne 5 -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "signingMode") -cne "SIGNED_CANDIDATE" -or
      (Get-CcrPinnedRequiredProperty $set.Manifest "candidateSigning") -ne $true -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "signingLineage") -cne
        [string]$publicIdentity.signingLineage -or
      [string](Get-CcrPinnedRequiredProperty $set.Manifest "expectedSigningCertificateSha256") -cne
        [string]$publicIdentity.expectedSigningCertificateSha256) {
    throw "ALPHA6_CANDIDATE_IMPORTED_IDENTITY_MISMATCH"
  }
  Reserve-CcrPinnedRunId $output $RunId | Out-Null
  $context = [PSCustomObject][ordered]@{
    ArtifactSet = $set
    PublicSigningIdentity = $publicIdentity
    OutputDirectory = $output
    RunId = $RunId
    PreflightOnly = $PreflightOnly
    BuildCommandCount = 0L
    RuntimeSourceSha = $RuntimeSourceSha.ToLowerInvariant()
    HarnessSourceSha = $HarnessSourceSha.ToLowerInvariant()
    RuntimeInputsTreeSha256 = $RuntimeInputsTreeSha256.ToLowerInvariant()
    ArtifactManifestSha256 = $manifestSha
    RepoRoot = $repo
    DebugAppSha256 = $ExpectedDebugAppSha256.ToLowerInvariant()
    ValidationScripts = $scripts
  }
  Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  return $context
}
