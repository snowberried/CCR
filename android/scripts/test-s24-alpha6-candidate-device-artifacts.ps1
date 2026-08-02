$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$bridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $bridgePath

$passed = 0
function Assert-CcrAlpha6CandidateBridgeTest {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ALPHA6_CANDIDATE_BRIDGE_TEST_FAILED:$Name" }
  $script:passed += 1
}

function Assert-CcrAlpha6CandidateBridgeThrows {
  param([scriptblock]$Action, [string]$Pattern, [string]$Name)
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($null -eq $message -or $message -notlike $Pattern) {
    throw "ALPHA6_CANDIDATE_BRIDGE_EXPECTED_THROW_FAILED:$Name/$message/$Pattern"
  }
  $script:passed += 1
}

function Copy-CcrAlpha6CandidateBridgeValue {
  param([Parameter(Mandatory = $true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-candidate-bridge-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
  $repo = Get-CcrCandidateRepoRoot
  $runtimeSource = "c98264f2a10026a908e94c961bb13e4af2d59e60"
  $harnessSource = "2" * 40
  $runtimeTree = "3" * 64
  $certificate = Get-CcrCandidatePublicPolicyFingerprint
  $otherCertificate = "4" * 64
  $roles = @(
    [PSCustomObject]@{ role = "debugApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "debugTest"; package = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedAppPackage },
    [PSCustomObject]@{ role = "benchmarkApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "macrobenchmarkTest"; package = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedMacrobenchmarkPackage }
  )
  $artifacts = [System.Collections.Generic.List[object]]::new()
  $identities = @{}
  $originalArtifactText = @{}
  foreach ($role in $roles) {
    $path = Join-Path $root "$($role.role).apk"
    $text = "candidate-bridge-$($role.role)"
    $originalArtifactText[$role.role] = $text
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    $artifacts.Add([PSCustomObject][ordered]@{
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
    }) | Out-Null
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
    artifactSetRevision = 5
    signingLineage = $script:CcrCandidateSigningLineage
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    expectedSigningCertificateSha256 = $certificate
    runtimeSourceSha = $runtimeSource
    harnessSourceSha = $harnessSource
    runtimeInputsTreeSha256 = $runtimeTree
    embeddedRuntimeSourceSha = [PSCustomObject]@{
      debugApp = $runtimeSource
      benchmarkApp = $runtimeSource
    }
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $artifacts.ToArray()
  }
  $manifestPath = Join-Path $root "artifact-manifest-v5.json"
  function Write-CcrAlpha6CandidateBridgeManifest {
    param([object]$Value = $manifest, [string]$Path = $manifestPath)
    [System.IO.File]::WriteAllText(
      $Path,
      (($Value | ConvertTo-Json -Depth 15) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
  $manifestSha = Write-CcrAlpha6CandidateBridgeManifest
  $debugSha = [string]$artifacts[0].sha256
  $tools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
  $identityReader = {
    param($Artifact, $Tools)
    return $identities[[string]$Artifact.role]
  }.GetNewClosure()
  $sourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $closedScripts = @(
    (Join-Path $PSScriptRoot "run-s24-alpha6-stage1.ps1"),
    $bridgePath,
    (Join-Path $PSScriptRoot "s24-alpha6-candidate-artifacts.ps1"),
    (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"),
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1"),
    (Join-Path $PSScriptRoot "alpha6-tail-contract.ps1")
  ) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
  $script:nextRun = 0
  function Invoke-CcrAlpha6CandidateBridgeTestPreflight {
    param(
      [object]$Manifest = $manifest,
      [scriptblock]$Reader = $identityReader,
      [string]$ExpectedDebugSha = $debugSha,
      [long]$BuildCommandCount = 0L,
      [string[]]$Scripts = $closedScripts,
      [string]$ExpectedManifestSha = $null,
      [string]$RunId = $null,
      [string]$ExpectedRuntimeSource = $runtimeSource,
      [string]$ExpectedRuntimeTree = $runtimeTree,
      [string]$ExpectedVersionName = "0.2.0-alpha.6",
      [int]$ExpectedVersionCode = 7
    )
    $path = Join-Path $root "manifest-$([Guid]::NewGuid().ToString('N')).json"
    $sha = Write-CcrAlpha6CandidateBridgeManifest $Manifest $path
    if ([string]::IsNullOrEmpty($ExpectedManifestSha)) { $ExpectedManifestSha = $sha }
    if ([string]::IsNullOrEmpty($RunId)) {
      $script:nextRun += 1
      $RunId = "bridge-$($script:nextRun)"
    }
    return Invoke-CcrAlpha6CandidateDeviceHostPreflight `
      -ArtifactManifest $path `
      -ArtifactManifestSha256 $ExpectedManifestSha `
      -OutputDirectory (Join-Path $root "output") `
      -RunId $RunId `
      -RuntimeSourceSha $ExpectedRuntimeSource `
      -HarnessSourceSha $harnessSource `
      -RuntimeInputsTreeSha256 $ExpectedRuntimeTree `
      -ExpectedDebugAppSha256 $ExpectedDebugSha `
      -ExpectedVersionName $ExpectedVersionName `
      -ExpectedVersionCode $ExpectedVersionCode `
      -PreflightOnly $true `
      -BuildCommandCount $BuildCommandCount `
      -ValidationScriptPaths $Scripts `
      -RepoRoot $repo `
      -AndroidTools $tools `
      -IdentityReader $Reader `
      -SourceIdentityVerifier $sourceVerifier
  }

  $context = Invoke-CcrAlpha6CandidateBridgeTestPreflight -RunId "bridge-positive"
  foreach ($entry in @(
    @("Model", "SM-S928N"),
    @("Fingerprint", "samsung/test/device:37/TEST/1:user/release-keys"),
    @("SecurityPatch", "2026-06-01"),
    @("Sdk", 37)
  )) {
    $context | Add-Member -NotePropertyName ([string]$entry[0]) -NotePropertyValue $entry[1]
  }
  Assert-CcrAlpha6CandidateBridgeTest (
    [int]$context.ArtifactSet.Manifest.artifactSetRevision -eq 5 -and
      [string]$context.PublicSigningIdentity.signingMode -ceq "SIGNED_CANDIDATE" -and
      $context.PublicSigningIdentity.candidateSigning -eq $true -and
      [string]$context.PublicSigningIdentity.signingLineage -ceq "ccr-internal-pilot-v1" -and
      [string]$context.PublicSigningIdentity.expectedSigningCertificateSha256 -ceq $certificate
  ) "positive-candidate-identity"
  Assert-CcrAlpha6CandidateBridgeTest (
    @($context.ValidationScripts).Count -eq 7 -and
      @($context.PublicSigningIdentity.publicPolicy, $context.PublicSigningIdentity.publicFingerprint,
        $context.PublicSigningIdentity.publicCertificate | Where-Object {
          [string]$_.sha256 -cmatch "^[a-f0-9]{64}$" -and [long]$_.bytes -gt 0L
        }).Count -eq 3
  ) "closed-scripts-and-public-policy-records"
  Assert-CcrAlpha6CandidateBridgeTest (
    $context.BuildCommandCount -eq 0L -and (Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context)
  ) "zero-build-and-post-import-rehash"

  $v1Manifest = Copy-CcrAlpha6CandidateBridgeValue $manifest
  $v1Manifest.versionName = "1.0.0"
  $v1Manifest.versionCode = 8
  foreach ($artifact in @($v1Manifest.artifacts | Where-Object role -in @("debugApp", "benchmarkApp"))) {
    $artifact.versionName = "1.0.0"
    $artifact.versionCode = 8
  }
  $savedDebugIdentity = $identities.debugApp
  $savedBenchmarkIdentity = $identities.benchmarkApp
  try {
    $identities.debugApp = Copy-CcrAlpha6CandidateBridgeValue $savedDebugIdentity
    $identities.benchmarkApp = Copy-CcrAlpha6CandidateBridgeValue $savedBenchmarkIdentity
    $identities.debugApp.versionName = "1.0.0"
    $identities.debugApp.versionCode = 8
    $identities.benchmarkApp.versionName = "1.0.0"
    $identities.benchmarkApp.versionCode = 8
    $v1Context = Invoke-CcrAlpha6CandidateBridgeTestPreflight `
      -Manifest $v1Manifest `
      -RunId "bridge-v1-positive" `
      -ExpectedVersionName "1.0.0" `
      -ExpectedVersionCode 8
    Assert-CcrAlpha6CandidateBridgeTest (
      [string]$v1Context.ArtifactSet.Manifest.versionName -ceq "1.0.0" -and
        [int]$v1Context.ArtifactSet.Manifest.versionCode -eq 8 -and
        $script:CcrPinnedVersionName -ceq "1.0.0" -and
        $script:CcrPinnedVersionCode -eq 8
    ) "v1-explicit-version-contract"
  } finally {
    $identities.debugApp = $savedDebugIdentity
    $identities.benchmarkApp = $savedBenchmarkIdentity
    $script:CcrPinnedVersionName = "0.2.0-alpha.6"
    $script:CcrPinnedVersionCode = 7
  }

  $fixtureRecords = @($script:CcrAlpha6FixtureOpenRequiredFixtures | ForEach-Object {
    $fixtureName = [string]$_
    $fixtureId = [System.IO.Path]::GetFileNameWithoutExtension($fixtureName)
    $golden = [System.IO.File]::ReadAllText(
      (Join-Path $repo "android\testdata\frame-accuracy\$fixtureId.json"),
      [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $frames = @($golden.frames | Sort-Object { [int]$_.sampleOrdinal })
    [PSCustomObject][ordered]@{
      fixture = $fixtureName
      expectedSourceSha256 = [string]$golden.sourceSha256
      expectedSampleCount = [long]$golden.frameCount
      status = "PASS"
      asset = [PSCustomObject]@{
        byteCount = 100L
        sha256 = [string]$golden.sourceSha256
      }
      providerDescriptor = [PSCustomObject]@{
        authority = "$($script:CcrPinnedAppPackage).fixture"
        resolved = $true
        exported = $false
        statSize = 100L
        regularFile = $true
        seekable = $true
        initialOffset = 0L
        byteCount = 100L
        sha256 = [string]$golden.sourceSha256
      }
      cachePfdSha256 = [string]$golden.sourceSha256
      extractorFdOnly = [PSCustomObject]@{
        status = "PASS"
        result = [PSCustomObject]@{
          trackCount = 1L
          videoTrackIndex = 0L
          mime = "video/avc"
          sampleCount = [long]$golden.frameCount
          firstPtsUs = [long]$frames[0].ptsUs
          lastPtsUs = [long]$frames[-1].ptsUs
        }
        failure = $null
      }
      extractorExplicitRange = $null
      hardwareDecoderCandidate = [PSCustomObject]@{
        status = "PASS"
        result = [PSCustomObject]@{
          componentName = "c2.vendor.decoder"
          hardwareAccelerated = $true
          softwareOnly = $false
        }
        failure = $null
      }
      codecConfigureStart = $null
      fullFrameDecodeCount = 0L
      performanceScenarioCount = 0L
    }
  })
  $fixtureReport = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-fixture-open-smoke"
    status = "PASS"
    applicationId = $script:CcrPinnedAppPackage
    appVersionName = "0.2.0-alpha.6"
    appVersionCode = 7L
    device = [PSCustomObject]@{
      manufacturer = "samsung"
      model = $context.Model
      fingerprint = $context.Fingerprint
      securityPatch = $context.SecurityPatch
      sdk = $context.Sdk
    }
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    runId = "bridge-fixture-report"
    startedAtElapsedRealtimeNs = 100L
    finishedAtElapsedRealtimeNs = 200L
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = 5
    testCount = 1
    instrumentationExpectedTestCount = 1
    appSha256 = $context.ArtifactSet.Artifacts.debugApp.sha256
    testApkSha256 = $context.ArtifactSet.Artifacts.debugTest.sha256
    fixtureCount = 17L
    assetHashPassCount = 17L
    providerOpenPassCount = 17L
    cacheVerificationPassCount = 17L
    extractorFdOnlyPassCount = 17L
    extractorExplicitRangePassCount = 0L
    videoTrackPassCount = 17L
    sampleEnumerationPassCount = 17L
    hardwareDecoderCandidatePassCount = 17L
    codecConfigureStartPassCount = 0L
    writeOpenCount = 0L
    fullFrameDecodeCount = 0L
    performanceScenarioCount = 0L
    fixtures = $fixtureRecords
  }
  Assert-CcrAlpha6FixtureOpenReport `
    -Report $fixtureReport -Context $context -RunId "bridge-fixture-report" `
    -Mode "Smoke" -ExpectedStatus "PASS" | Out-Null
  Assert-CcrAlpha6CandidateBridgeTest $true "fixture-open-smoke-report-17-positive"

  $renderOpenFrameKey = [PSCustomObject][ordered]@{
    displayFrameIndex = 0L
    ptsUs = 0L
    duplicateOrdinal = 0L
  }
  $renderOpenSurfaceBefore = [PSCustomObject][ordered]@{
    capturedAtElapsedRealtimeNs = 120L
    scenarioState = "RESUMED"
    activityInstanceId = "1234"
    activityFinishing = $false
    activityDestroyed = $false
    decorAttached = $true
    surfaceViewPresent = $true
    surfaceValid = $true
    surfaceGeneration = 3L
    decoderSurfaceAvailable = $true
  }
  $renderOpenReport = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha6-render-open-smoke"
    status = "PASS"
    applicationId = $script:CcrPinnedAppPackage
    appVersionName = "0.2.0-alpha.6"
    appVersionCode = 7L
    device = [PSCustomObject]@{
      manufacturer = "samsung"
      model = $context.Model
      fingerprint = $context.Fingerprint
      securityPatch = $context.SecurityPatch
      sdk = $context.Sdk
    }
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    runId = "bridge-render-open"
    startedAtElapsedRealtimeNs = 100L
    finishedAtElapsedRealtimeNs = 200L
    runtimeSourceSha = $context.ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $context.ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $context.ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = 5
    testCount = 1L
    instrumentationExpectedTestCount = 1L
    appSha256 = $context.ArtifactSet.Artifacts.debugApp.sha256
    testApkSha256 = $context.ArtifactSet.Artifacts.debugTest.sha256
    fixture = "h264-ip.mp4"
    stableIntervalMs = 300L
    activityInstanceDriftCount = 0L
    surfaceGenerationDriftCount = 0L
    surfaceLossCount = 0L
    videoOpenFailedCount = 0L
    providerOrExtractorEntered = $true
    providerReadOpenCount = 1L
    indexReceived = $true
    metadataReceived = $true
    firstFramePublished = $true
    expectedFrameKey = $renderOpenFrameKey
    actualFrameKey = Copy-CcrAlpha6CandidateBridgeValue $renderOpenFrameKey
    expectedTextureTimestampNs = 0L
    actualTextureTimestampNs = 0L
    hardwareAccelerated = $true
    codecComponent = "c2.vendor.decoder"
    writeOpenCount = 0L
    fullFrameDecodeCount = 1L
    performanceScenarioCount = 0L
    activitySurfaceEvidence = [PSCustomObject][ordered]@{
      beforeOpen = $renderOpenSurfaceBefore
      afterOpen = Copy-CcrAlpha6CandidateBridgeValue $renderOpenSurfaceBefore
      statusSequence = @(
        [PSCustomObject]@{
          ordinal = 0L
          sequence = 0L
          capturedAtElapsedRealtimeNs = 130L
          status = "indexing"
          detail = $null
        },
        [PSCustomObject]@{
          ordinal = 1L
          sequence = 1L
          capturedAtElapsedRealtimeNs = 160L
          status = "frame 1/12"
          detail = $null
        }
      )
    }
    failure = $null
  }
  Assert-CcrAlpha6RenderOpenReport `
    -Report $renderOpenReport -Context $context -RunId "bridge-render-open" `
    -ExpectedStatus "PASS" | Out-Null
  Assert-CcrAlpha6CandidateBridgeTest $true "render-open-stable-current-surface-positive"

  $renderReceiveContext = $context | Select-Object *
  $renderReceiveContext | Add-Member -NotePropertyName Serial -NotePropertyValue "FAKE-S24"
  $renderReceiveContext | Add-Member -NotePropertyName Adb -NotePropertyValue "fake-adb"
  $renderOpenRaw = $renderOpenReport | ConvertTo-Json -Depth 30
  $renderReceiveContext | Add-Member -NotePropertyName AdbInvoker -NotePropertyValue {
    param($Arguments)
    return [PSCustomObject]@{ exitCode = 0; output = $renderOpenRaw }
  }.GetNewClosure()
  $renderReceiveDirectory = Join-Path $root "render-open-report-positive"
  [System.IO.Directory]::CreateDirectory($renderReceiveDirectory) | Out-Null
  $renderReceived = Receive-CcrAlpha6RenderOpenReport `
    -Context $renderReceiveContext -RunId "bridge-render-open" `
    -EvidenceDirectory $renderReceiveDirectory
  Assert-CcrAlpha6CandidateBridgeTest (
    (Get-Item -LiteralPath $renderReceived.Path).IsReadOnly -and
      [string]$renderReceived.Report.activitySurfaceEvidence.beforeOpen.activityInstanceId -ceq
        "1234" -and
      [long]$renderReceived.Report.activitySurfaceEvidence.beforeOpen.surfaceGeneration -eq 3L
  ) "render-open-actual-report-shape-received"

  $badStatusSequence = Copy-CcrAlpha6CandidateBridgeValue $renderOpenReport
  $badStatusSequence.activitySurfaceEvidence.statusSequence[1].capturedAtElapsedRealtimeNs = 120L
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6RenderOpenReport `
      -Report $badStatusSequence -Context $context -RunId "bridge-render-open" `
      -ExpectedStatus "PASS" | Out-Null
  } "ALPHA6_RENDER_OPEN_STATUS_SEQUENCE_INVALID:1" `
    "render-open-status-timestamp-regression-rejected"

  foreach ($case in @(
    @("surface-loss", "SURFACE_LOST_DURING_OPEN", "GATE_SURFACE_NOT_CURRENT"),
    @("generation-drift", "SURFACE_LOST_DURING_OPEN", "GATE_SURFACE_GENERATION_CHANGED"),
    @("stale-activity", "STALE_ACTIVITY_INSTANCE", "GATE_ACTIVITY_INSTANCE_STALE")
  )) {
    $failureReport = Copy-CcrAlpha6CandidateBridgeValue $renderOpenReport
    $failureReport.status = "FAIL"
    $failureReport.runId = "bridge-render-$([string]$case[0])"
    $failureReport.failure = [PSCustomObject]@{
      classification = [string]$case[1]
      stageCode = [string]$case[2]
      exceptionClass = "Alpha6StableGateException"
      sanitizedDetail = "state=RESUMED,surface=false,generation=4"
    }
    Assert-CcrAlpha6RenderOpenReport `
      -Report $failureReport -Context $context -RunId $failureReport.runId `
      -ExpectedStatus "FAIL" | Out-Null
    Assert-CcrAlpha6CandidateBridgeTest $true "render-open-$([string]$case[0])-classified"
  }

  $badRenderOpen = Copy-CcrAlpha6CandidateBridgeValue $renderOpenReport
  $badRenderOpen.surfaceGenerationDriftCount = 1L
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6RenderOpenReport `
      -Report $badRenderOpen -Context $context -RunId "bridge-render-open" `
      -ExpectedStatus "PASS" | Out-Null
  } "ALPHA6_RENDER_OPEN_REPORT_COUNTER_MISMATCH:surfaceGenerationDriftCount" `
    "render-open-generation-drift-pass-rejected"

  $badFixtureIdentity = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $badFixtureIdentity.fixtures[0].fixture = "unexpected.mp4"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6FixtureOpenReport `
      -Report $badFixtureIdentity -Context $context -RunId "bridge-fixture-report" `
      -Mode "Smoke" -ExpectedStatus "PASS" | Out-Null
  } "ALPHA6_FIXTURE_OPEN_REPORT_FIXTURE_IDENTITY_MISMATCH:*" `
    "fixture-open-smoke-fixture-identity-rejected"

  $badFixtureSha = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $badFixtureSha.fixtures[0].expectedSourceSha256 = "0" * 64
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6FixtureOpenReport `
      -Report $badFixtureSha -Context $context -RunId "bridge-fixture-report" `
      -Mode "Smoke" -ExpectedStatus "PASS" | Out-Null
  } "ALPHA6_FIXTURE_OPEN_REPORT_FIXTURE_CONTRACT_MISMATCH:*" `
    "fixture-open-smoke-golden-sha-rejected"

  $badFixtureApp = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $badFixtureApp.applicationId = "com.example.wrong"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6FixtureOpenReport `
      -Report $badFixtureApp -Context $context -RunId "bridge-fixture-report" `
      -Mode "Smoke" -ExpectedStatus "PASS" | Out-Null
  } "ALPHA6_FIXTURE_OPEN_REPORT_DEVICE_OR_APP_IDENTITY_MISMATCH" `
    "fixture-open-smoke-app-identity-rejected"

  $diagnosticReport = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $diagnosticReport.kind = "alpha6-fixture-open-diagnostic"
  foreach ($name in @(
    "fixtureCount",
    "assetHashPassCount",
    "providerOpenPassCount",
    "cacheVerificationPassCount",
    "extractorFdOnlyPassCount",
    "extractorExplicitRangePassCount",
    "videoTrackPassCount",
    "sampleEnumerationPassCount",
    "hardwareDecoderCandidatePassCount",
    "codecConfigureStartPassCount"
  )) {
    $diagnosticReport.$name = 1L
  }
  $diagnosticFixture = $diagnosticReport.fixtures[0]
  $diagnosticFixture.extractorExplicitRange =
    Copy-CcrAlpha6CandidateBridgeValue $diagnosticFixture.extractorFdOnly
  $diagnosticFixture.codecConfigureStart = [PSCustomObject]@{
    status = "PASS"
    result = [PSCustomObject]@{
      componentName = "c2.vendor.decoder"
      surfaceReady = $true
      configured = $true
      started = $true
      queuedInputBufferCount = 0L
      dequeuedOutputBufferCount = 0L
    }
    failure = $null
  }
  $diagnosticReport.fixtures = @($diagnosticFixture)
  Assert-CcrAlpha6FixtureOpenReport `
    -Report $diagnosticReport -Context $context -RunId "bridge-fixture-report" `
    -Mode "Diagnostic" -ExpectedStatus "PASS" | Out-Null
  Assert-CcrAlpha6CandidateBridgeTest $true "fixture-open-diagnostic-report-positive"

  foreach ($case in @(
    @("provider-count", "providerOpenPassCount", 16L, "ALPHA6_FIXTURE_OPEN_REPORT_COUNT_MISMATCH:*"),
    @("extractor-count", "extractorFdOnlyPassCount", 16L, "ALPHA6_FIXTURE_OPEN_REPORT_COUNT_MISMATCH:*"),
    @("write-open", "writeOpenCount", 1L, "ALPHA6_FIXTURE_OPEN_REPORT_ZERO_CONTRACT_MISMATCH:*"),
    @("full-decode", "fullFrameDecodeCount", 1L, "ALPHA6_FIXTURE_OPEN_REPORT_ZERO_CONTRACT_MISMATCH:*")
  )) {
    $badFixtureReport = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
    $badFixtureReport.([string]$case[1]) = [long]$case[2]
    Assert-CcrAlpha6CandidateBridgeThrows {
      Assert-CcrAlpha6FixtureOpenReport `
        -Report $badFixtureReport -Context $context -RunId "bridge-fixture-report" `
        -Mode "Smoke" -ExpectedStatus "PASS" | Out-Null
    } ([string]$case[3]) "fixture-open-smoke-$([string]$case[0])-rejected"
  }

  $fixtureFailureReport = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $fixtureFailureReport.status = "FAIL"
  $fixtureFailureReport.providerOpenPassCount = 0L
  $fixtureFailureReport.fixtures = @()
  $fixtureFailureReport | Add-Member -NotePropertyName failure -NotePropertyValue ([PSCustomObject]@{
    stageCode = "PROVIDER_OPEN_FILE_DESCRIPTOR"
    classification = "PROVIDER_DESCRIPTOR_FAILURE"
    exceptionClass = "FileNotFoundException"
    sanitizedDetail = "synthetic fixture provider open failed"
  })
  Assert-CcrAlpha6FixtureOpenReport `
    -Report $fixtureFailureReport -Context $context -RunId "bridge-fixture-report" `
    -Mode "Smoke" -ExpectedStatus "FAIL" | Out-Null
  Assert-CcrAlpha6CandidateBridgeTest $true "fixture-open-failure-report-identity-preserved"

  $receiveContext = $context | Select-Object *
  $receiveContext | Add-Member -NotePropertyName Serial -NotePropertyValue "FAKE-S24"
  $receiveContext | Add-Member -NotePropertyName Adb -NotePropertyValue "fake-adb"
  $malformedRaw = "{not-json"
  $receiveContext | Add-Member -NotePropertyName AdbInvoker -NotePropertyValue {
    param($Arguments)
    return [PSCustomObject]@{ exitCode = 0; output = $malformedRaw }
  }.GetNewClosure()
  $malformedDirectory = Join-Path $root "fixture-report-malformed"
  [System.IO.Directory]::CreateDirectory($malformedDirectory) | Out-Null
  Assert-CcrAlpha6CandidateBridgeThrows {
    Receive-CcrAlpha6FixtureOpenReport `
      -Context $receiveContext -ReportName "s24-alpha6-fixture-open-smoke-v1.json" `
      -RunId "bridge-fixture-malformed" -Mode "Smoke" `
      -EvidenceDirectory $malformedDirectory | Out-Null
  } "ALPHA6_FIXTURE_OPEN_REPORT_JSON_INVALID:*" "fixture-open-malformed-report-rejected"
  $malformedEvidence = Join-Path $malformedDirectory "s24-alpha6-fixture-open-smoke-v1.json"
  Assert-CcrAlpha6CandidateBridgeTest (
    (Get-Item -LiteralPath $malformedEvidence).IsReadOnly -and
      [System.IO.File]::ReadAllText($malformedEvidence, [System.Text.Encoding]::UTF8) -ceq
        $malformedRaw
  ) "fixture-open-malformed-report-preserved"

  $driftReport = Copy-CcrAlpha6CandidateBridgeValue $fixtureReport
  $driftReport.runId = "bridge-fixture-drift"
  $driftReport.providerOpenPassCount = 16L
  $driftRaw = $driftReport | ConvertTo-Json -Depth 30
  $receiveContext.AdbInvoker = {
    param($Arguments)
    return [PSCustomObject]@{ exitCode = 0; output = $driftRaw }
  }.GetNewClosure()
  $driftDirectory = Join-Path $root "fixture-report-drift"
  [System.IO.Directory]::CreateDirectory($driftDirectory) | Out-Null
  Assert-CcrAlpha6CandidateBridgeThrows {
    Receive-CcrAlpha6FixtureOpenReport `
      -Context $receiveContext -ReportName "s24-alpha6-fixture-open-smoke-v1.json" `
      -RunId "bridge-fixture-drift" -Mode "Smoke" `
      -EvidenceDirectory $driftDirectory | Out-Null
  } "ALPHA6_FIXTURE_OPEN_REPORT_COUNT_MISMATCH:*" "fixture-open-drift-report-rejected"
  $driftEvidence = Join-Path $driftDirectory "s24-alpha6-fixture-open-smoke-v1.json"
  Assert-CcrAlpha6CandidateBridgeTest (
    (Get-Item -LiteralPath $driftEvidence).IsReadOnly -and
      [System.IO.File]::ReadAllText($driftEvidence, [System.Text.Encoding]::UTF8) -ceq $driftRaw
  ) "fixture-open-drift-report-preserved"

  $timeoutContext = $context | Select-Object *
  $timeoutContext | Add-Member -NotePropertyName Serial -NotePropertyValue "FAKE-S24"
  $timeoutContext | Add-Member -NotePropertyName Adb -NotePropertyValue "fake-adb"
  $timeoutContext | Add-Member -NotePropertyName AdbInvoker -NotePropertyValue {
    param($Arguments)
    $line = $Arguments -join " "
    if ($line -match " cat /proc/uptime$") {
      return [PSCustomObject]@{ exitCode = 0; output = "100.0 0.0" }
    }
    if ($line -match " shell am instrument ") {
      return [PSCustomObject]@{ exitCode = 124; output = "ALPHA6_ADB_PROCESS_TIMEOUT" }
    }
    if ($line -match " run-as .+ cat files/s24-alpha6-fixture-open-smoke-v1\.json$") {
      return [PSCustomObject]@{ exitCode = 1; output = "No such file" }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }
  $timeoutDirectory = Join-Path $context.OutputDirectory "bridge-fixture-timeout-attempt"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation `
      -Context $timeoutContext -RunId "bridge-fixture-timeout" `
      -EvidenceDirectory $timeoutDirectory -Mode "Smoke" -SkipInstall | Out-Null
  } "PRIMARY=PINNED_INSTRUMENTATION_FAILED:debugTest; REPORT=ALPHA6_FIXTURE_OPEN_REPORT_PULL_FAILED:*" `
    "fixture-open-timeout-primary-error-preserved"
  $timeoutFailure = @(
    Get-ChildItem -LiteralPath $timeoutDirectory `
      -Filter "failure-alpha6-fixture-open-smoke-v1.json" -File
  )
  $timeoutFailureReport = [System.IO.File]::ReadAllText(
    $timeoutFailure[0].FullName,
    [System.Text.Encoding]::UTF8
  ) | ConvertFrom-Json
  Assert-CcrAlpha6CandidateBridgeTest (
    $timeoutFailure.Count -eq 1 -and
      $timeoutFailure[0].IsReadOnly -and
      [long]$timeoutFailureReport.exitCode -eq 124L -and
      [string]$timeoutFailureReport.output -ceq "ALPHA6_ADB_PROCESS_TIMEOUT"
  ) "fixture-open-timeout-instrumentation-evidence-preserved"

  $validFailureReport = Copy-CcrAlpha6CandidateBridgeValue $fixtureFailureReport
  $validFailureReport.runId = "bridge-fixture-valid-failure"
  $validFailureReport.startedAtElapsedRealtimeNs = 100L
  $validFailureReport.finishedAtElapsedRealtimeNs = 200L
  $validFailureRaw = $validFailureReport | ConvertTo-Json -Depth 30
  $validFailureContext = $context | Select-Object *
  $validFailureContext | Add-Member -NotePropertyName Serial -NotePropertyValue "FAKE-S24"
  $validFailureContext | Add-Member -NotePropertyName Adb -NotePropertyValue "fake-adb"
  $validFailureContext | Add-Member -NotePropertyName AdbInvoker -NotePropertyValue {
    param($Arguments)
    $line = $Arguments -join " "
    if ($line -match " cat /proc/uptime$") {
      return [PSCustomObject]@{ exitCode = 0; output = "0.000000001 0.0" }
    }
    if ($line -match " shell am instrument ") {
      return [PSCustomObject]@{ exitCode = 1; output = "FAILURES!!!" }
    }
    if ($line -match " run-as .+ cat files/s24-alpha6-fixture-open-smoke-v1\.json$") {
      return [PSCustomObject]@{ exitCode = 0; output = $validFailureRaw }
    }
    return [PSCustomObject]@{ exitCode = 0; output = "" }
  }.GetNewClosure()
  $validFailureDirectory = Join-Path $context.OutputDirectory "bridge-fixture-valid-failure-attempt"
  $validFailureResult = Invoke-CcrAlpha6CandidateFixtureOpenInstrumentation `
    -Context $validFailureContext -RunId "bridge-fixture-valid-failure" `
    -EvidenceDirectory $validFailureDirectory -Mode "Smoke" -SkipInstall
  Assert-CcrAlpha6CandidateBridgeTest (
    [string]$validFailureResult.status -ceq "FAIL" -and
      [string]$validFailureResult.failure.classification -ceq "PROVIDER_DESCRIPTOR_FAILURE" -and
      [string]$validFailureResult.instrumentationFailure -ceq
        "PINNED_INSTRUMENTATION_FAILED:debugTest" -and
      (Get-Item -LiteralPath $validFailureResult.reportPath).IsReadOnly
  ) "fixture-open-valid-failure-result-links-report"

  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateDeviceHostPreflight `
      -ArtifactManifest $context.ArtifactSet.ManifestPath `
      -ArtifactManifestSha256 $context.ArtifactSet.ManifestSha256 `
      -OutputDirectory $context.OutputDirectory `
      -RunId "bridge-positive" `
      -RuntimeSourceSha $runtimeSource `
      -HarnessSourceSha $harnessSource `
      -RuntimeInputsTreeSha256 $runtimeTree `
      -ExpectedDebugAppSha256 $debugSha `
      -PreflightOnly $true `
      -BuildCommandCount 0L `
      -ValidationScriptPaths $closedScripts `
      -RepoRoot $repo `
      -AndroidTools $tools `
      -IdentityReader $identityReader `
      -SourceIdentityVerifier $sourceVerifier | Out-Null
  } "PINNED_RUN_ID_DUPLICATE:*" "duplicate-run-id"

  foreach ($revision in @(4, 6)) {
    $bad = Copy-CcrAlpha6CandidateBridgeValue $manifest
    $bad.artifactSetRevision = $revision
    Assert-CcrAlpha6CandidateBridgeThrows {
      Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $bad | Out-Null
    } "CANDIDATE_MANIFEST_REVISION_MISMATCH" "revision-$revision-rejected"
  }
  foreach ($case in @(
    [PSCustomObject]@{ name = "mode"; property = "signingMode"; value = "CI_EPHEMERAL_DEBUG"; error = "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" },
    [PSCustomObject]@{ name = "candidate-false"; property = "candidateSigning"; value = $false; error = "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" },
    [PSCustomObject]@{ name = "lineage"; property = "signingLineage"; value = "other-lineage"; error = "CANDIDATE_MANIFEST_LINEAGE_MISMATCH" },
    [PSCustomObject]@{ name = "fingerprint"; property = "expectedSigningCertificateSha256"; value = $otherCertificate; error = "CANDIDATE_MANIFEST_PUBLIC_POLICY_MISMATCH" }
  )) {
    $bad = Copy-CcrAlpha6CandidateBridgeValue $manifest
    $bad.($case.property) = $case.value
    Assert-CcrAlpha6CandidateBridgeThrows {
      Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $bad | Out-Null
    } $case.error "$($case.name)-rejected"
  }
  $missingMode = Copy-CcrAlpha6CandidateBridgeValue $manifest
  $missingMode.PSObject.Properties.Remove("signingMode")
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $missingMode | Out-Null
  } "PINNED_MANIFEST_PROPERTY_MISSING:signingMode" "missing-signing-mode-rejected"
  $embeddedMismatch = Copy-CcrAlpha6CandidateBridgeValue $manifest
  $embeddedMismatch.embeddedRuntimeSourceSha.debugApp = $otherCertificate.Substring(0, 40)
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $embeddedMismatch | Out-Null
  } "CANDIDATE_MANIFEST_EMBEDDED_RUNTIME_IDENTITY_MISMATCH:debugApp" `
    "manifest-embedded-runtime-mismatch-rejected"
  $missingEmbedded = Copy-CcrAlpha6CandidateBridgeValue $manifest
  $missingEmbedded.PSObject.Properties.Remove("embeddedRuntimeSourceSha")
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Manifest $missingEmbedded | Out-Null
  } "PINNED_MANIFEST_PROPERTY_MISSING:embeddedRuntimeSourceSha" `
    "missing-embedded-runtime-identity-rejected"

  $identityCases = @(
    [PSCustomObject]@{ name = "actual-signer"; role = "debugApp"; property = "signingCertificateSha256"; value = $otherCertificate; error = "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:debugApp" },
    [PSCustomObject]@{ name = "mixed-signer"; role = "macrobenchmarkTest"; property = "signingCertificateSha256"; value = $otherCertificate; error = "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:macrobenchmarkTest" },
    [PSCustomObject]@{ name = "wrong-package"; role = "debugApp"; property = "packageName"; value = "invalid.package"; error = "PINNED_ARTIFACT_PACKAGE_MISMATCH:debugApp" },
    [PSCustomObject]@{ name = "wrong-version"; role = "benchmarkApp"; property = "versionCode"; value = 8; error = "PINNED_ARTIFACT_VERSION_CODE_INSPECTION_MISMATCH:benchmarkApp" },
    [PSCustomObject]@{ name = "wrong-runner"; role = "debugTest"; property = "runner"; value = "invalid.Runner"; error = "PINNED_ARTIFACT_RUNNER_INSPECTION_MISMATCH:debugTest" },
    [PSCustomObject]@{ name = "wrong-target"; role = "macrobenchmarkTest"; property = "targetPackage"; value = "invalid.target"; error = "PINNED_ARTIFACT_TARGET_INSPECTION_MISMATCH:macrobenchmarkTest" }
  )
  foreach ($case in $identityCases) {
    $original = $identities[$case.role].($case.property)
    $identities[$case.role].($case.property) = $case.value
    try {
      Assert-CcrAlpha6CandidateBridgeThrows {
        Invoke-CcrAlpha6CandidateBridgeTestPreflight | Out-Null
      } $case.error "$($case.name)-rejected"
    } finally {
      $identities[$case.role].($case.property) = $original
    }
  }
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -ExpectedDebugSha ("5" * 64) | Out-Null
  } "PINNED_DEBUG_APP_SHA_MISMATCH" "debug-app-expected-sha-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -ExpectedManifestSha ("6" * 64) | Out-Null
  } "ALPHA6_MANIFEST_SHA_MISMATCH" "manifest-sha-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -BuildCommandCount 1L | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COUNT_NOT_ZERO" "build-count-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @() | Out-Null
  } "ALPHA6_VALIDATION_SCRIPT_SET_EMPTY" "closed-script-missing-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @($closedScripts[0], $closedScripts[0]) | Out-Null
  } "ALPHA6_VALIDATION_SCRIPT_DUPLICATE:*" "closed-script-duplicate-rejected"
  Assert-CcrAlpha6CandidateBridgeThrows {
    Invoke-CcrAlpha6CandidateBridgeTestPreflight -Scripts @(
      [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "run-s24-battery-validation.ps1"))
    ) | Out-Null
  } "ALPHA6_DEVICE_VALIDATION_BUILD_COMMAND_FORBIDDEN:*" "validation-build-command-rejected"

  [System.IO.File]::AppendAllText($context.ArtifactSet.ManifestPath, "tamper", [System.Text.UTF8Encoding]::new($false))
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  } "ALPHA6_ARTIFACT_MANIFEST_CHANGED_AFTER_PREFLIGHT" "manifest-tamper-after-preflight"
  Write-CcrAlpha6CandidateBridgeManifest $manifest $context.ArtifactSet.ManifestPath | Out-Null
  [System.IO.File]::AppendAllText($artifacts[0].path, "tamper", [System.Text.UTF8Encoding]::new($false))
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context | Out-Null
  } "ALPHA6_ARTIFACT_CHANGED_AFTER_PREFLIGHT:debugApp" "artifact-tamper-after-preflight"
  [System.IO.File]::WriteAllText(
    $artifacts[0].path,
    [string]$originalArtifactText["debugApp"],
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-CcrAlpha6CandidateBridgeTest (Assert-CcrAlpha6CandidateDeviceIdentityUnchanged $context) "artifact-restored"

  $publicCopy = Join-Path $root "public-policy"
  [System.IO.Directory]::CreateDirectory($publicCopy) | Out-Null
  foreach ($name in @(
    "ccr-internal-pilot-v1-policy.json",
    "ccr-internal-pilot-v1-cert.sha256",
    "ccr-internal-pilot-v1-cert.pem"
  )) {
    [System.IO.File]::Copy((Join-Path $repo "android\signing\$name"), (Join-Path $publicCopy $name), $false)
  }
  $copiedIdentity = Get-CcrAlpha6CandidatePublicSigningIdentity -RepoRoot $repo -SigningDirectory $publicCopy
  $publicContext = [PSCustomObject]@{ PublicSigningIdentity = $copiedIdentity }
  [System.IO.File]::AppendAllText(
    (Join-Path $publicCopy "ccr-internal-pilot-v1-policy.json"),
    " ",
    [System.Text.UTF8Encoding]::new($false)
  )
  Assert-CcrAlpha6CandidateBridgeThrows {
    Assert-CcrAlpha6CandidatePublicSigningIdentityUnchanged $publicContext | Out-Null
  } "ALPHA6_CANDIDATE_PUBLIC_POLICY_CHANGED_AFTER_PREFLIGHT:publicPolicy" "public-policy-drift-rejected"

  $historicalSource = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"),
    [System.Text.Encoding]::UTF8
  )
  $bridgeSource = [System.IO.File]::ReadAllText($bridgePath, [System.Text.Encoding]::UTF8)
  Assert-CcrAlpha6CandidateBridgeTest (
    $historicalSource.Contains('$script:CcrPinnedArtifactSetRevision = 4') -and
      $historicalSource.Contains("Invoke-CcrAlpha6PinnedHostPreflight") -and
      $bridgeSource.Contains("Import-CcrAlpha6CandidateArtifactManifest")
  ) "historical-v4-preserved-active-v5-explicit"
} finally {
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output "Alpha 6 candidate device bridge host tests passed: $passed"
