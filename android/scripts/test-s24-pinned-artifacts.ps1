$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")
. (Join-Path $PSScriptRoot "alpha4-baseline-contract.ps1")

$repoRoot = Get-CcrPinnedRepoRoot
$harnessSourceSha = Get-CcrPinnedHarnessSourceSha $repoRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-pinned-artifacts-$([Guid]::NewGuid().ToString('N'))"
$artifactRoot = Join-Path $testRoot "artifacts"
$outputRoot = Join-Path $testRoot "output"
[System.IO.Directory]::CreateDirectory($artifactRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null

$roleFileNames = [ordered]@{
  debugApp = "debug-app.apk"
  debugTest = "debug-test.apk"
  benchmarkApp = "benchmark-app.apk"
  macrobenchmarkTest = "macrobenchmark-test.apk"
}
$roleBytes = [ordered]@{
  debugApp = [byte[]](1, 2, 3, 4, 5)
  debugTest = [byte[]](6, 7, 8, 9)
  benchmarkApp = [byte[]](10, 11, 12, 13, 14, 15)
  macrobenchmarkTest = [byte[]](16, 17, 18)
}
$certificate = "49379c1b2a2fec8a50c320955a7027c515aff10f28483b08ae9c27b3ffcfbef0"
$runner = "androidx.test.runner.AndroidJUnitRunner"
$appPackage = "com.snowberried.ctcinereviewer.internal"
$macroPackage = "com.snowberried.ctcinereviewer.macrobenchmark"

function Reset-TestArtifacts {
  foreach ($role in $roleFileNames.Keys) {
    [System.IO.File]::WriteAllBytes((Join-Path $artifactRoot $roleFileNames[$role]), $roleBytes[$role])
  }
}

function New-TestIdentityTable {
  return @{
    debugApp = [PSCustomObject]@{ packageName = $appPackage; versionName = "0.2.0-alpha.4"; versionCode = 5; signingCertificateSha256 = $certificate; runner = $null; targetPackage = $null }
    debugTest = [PSCustomObject]@{ packageName = "$appPackage.test"; versionName = $null; versionCode = $null; signingCertificateSha256 = $certificate; runner = $runner; targetPackage = $appPackage }
    benchmarkApp = [PSCustomObject]@{ packageName = $appPackage; versionName = "0.2.0-alpha.4"; versionCode = 5; signingCertificateSha256 = $certificate; runner = $null; targetPackage = $null }
    macrobenchmarkTest = [PSCustomObject]@{ packageName = $macroPackage; versionName = $null; versionCode = $null; signingCertificateSha256 = $certificate; runner = $runner; targetPackage = $macroPackage }
  }
}

function New-TestManifest {
  $identity = New-TestIdentityTable
  $artifacts = foreach ($role in $roleFileNames.Keys) {
    $path = Join-Path $artifactRoot $roleFileNames[$role]
    [PSCustomObject][ordered]@{
      role = $role
      path = [System.IO.Path]::GetFullPath($path)
      bytes = (Get-Item -LiteralPath $path).Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
      packageName = $identity[$role].packageName
      versionName = $identity[$role].versionName
      versionCode = $identity[$role].versionCode
      signingCertificateSha256 = $identity[$role].signingCertificateSha256
      runner = $identity[$role].runner
      targetPackage = $identity[$role].targetPackage
    }
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    artifactSetRevision = 2
    runtimeSourceSha = "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e"
    harnessSourceSha = $harnessSourceSha
    runtimeInputsTreeSha256 = "a0a6bff2637b310e63028c4433b80611a9f4d5fe73a03d0394113bd56e9e6941"
    versionName = "0.2.0-alpha.4"
    versionCode = 5
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = @($artifacts)
  }
}

function Copy-TestValue {
  param([object]$Value)
  return (($Value | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
}

function Import-TestScriptFunction {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -ne 0) { throw "test function source parse failed: $Name" }
  $nodes = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  if ($nodes.Count -ne 1) { throw "test function source lookup failed: $Name" }
  return [scriptblock]::Create($nodes[0].Extent.Text)
}

function Save-TestManifest {
  param([object]$Manifest, [string]$Name)
  $path = Join-Path $testRoot "$Name.json"
  [System.IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
  return $path
}

$identityTable = New-TestIdentityTable
$identityReader = {
  param($Artifact, $Tools)
  return $identityTable[[string]$Artifact.role]
}.GetNewClosure()

$adbCalls = [System.Collections.Generic.List[string]]::new()
$fakeAdb = {
  param([string[]]$CommandArguments)
  $line = $CommandArguments -join " "
  $adbCalls.Add($line) | Out-Null
  if ($line -eq "devices") { return [PSCustomObject]@{ exitCode = 0; output = "List of devices attached`nR58VALID device" } }
  if ($line -match "getprop ro.product.model$") { return [PSCustomObject]@{ exitCode = 0; output = "SM-S928N" } }
  if ($line -match "getprop ro.product.manufacturer$") { return [PSCustomObject]@{ exitCode = 0; output = "samsung" } }
  if ($line -match "getprop ro.build.fingerprint$") { return [PSCustomObject]@{ exitCode = 0; output = "samsung/test/fingerprint" } }
  if ($line -match "getprop ro.build.version.security_patch$") { return [PSCustomObject]@{ exitCode = 0; output = "2026-07-01" } }
  if ($line -match "getprop ro.build.version.sdk$") { return [PSCustomObject]@{ exitCode = 0; output = "36" } }
  return [PSCustomObject]@{ exitCode = 0; output = "Success" }
}.GetNewClosure()

$fakeTools = [PSCustomObject]@{ SdkRoot = "fake"; Adb = "fake-adb"; ApkAnalyzer = "fake-apkanalyzer"; ApkSigner = "fake-apksigner" }
Reset-TestArtifacts
$testDebugAppSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $artifactRoot $roleFileNames.debugApp)).Hash.ToLowerInvariant()
$passes = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-HostTest {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body
    $script:passes += 1
    Write-Output "PASS $Name"
  } catch {
    $script:failures.Add("$Name :: $($_.Exception.Message)") | Out-Null
    Write-Output "FAIL $Name :: $($_.Exception.Message)"
  }
}

function Assert-NoAdbBeforeRejection {
  if ($adbCalls.Count -ne 0) { throw "ADB was invoked before manifest rejection: $($adbCalls -join ' | ')" }
}

function Assert-NoMutationCalls {
  $mutations = @($adbCalls | Where-Object { $_ -match "(^| )(install|uninstall|push|settings)( |$)| shell (?:timeout \d+s )?am instrument | shell am force-stop | run-as .+ rm " })
  if ($mutations.Count -ne 0) { throw "device mutation was attempted: $($mutations -join ' | ')" }
}

function Expect-ManifestRejection {
  param([string]$Name, [scriptblock]$Mutate, [string]$ExpectedError)
  Invoke-HostTest $Name {
    Reset-TestArtifacts
    $manifest = New-TestManifest
    & $Mutate $manifest
    $path = Save-TestManifest $manifest $Name
    $adbCalls.Clear()
    $caught = $null
    try {
      Invoke-CcrPinnedPreflight $path $outputRoot $repoRoot $harnessSourceSha $fakeTools $identityReader $fakeAdb $testDebugAppSha256 | Out-Null
    } catch {
      $caught = $_.Exception.Message
    }
    if (-not $caught) { throw "expected rejection did not occur" }
    if ($caught -notmatch [regex]::Escape($ExpectedError)) { throw "unexpected rejection: $caught" }
    Assert-NoAdbBeforeRejection
    Assert-NoMutationCalls
  }.GetNewClosure()
}

function New-Alpha4RandomTestReport {
  param([object]$ArtifactSet)
  $categories = @("cache-or-history-hit", "ahead-of-cursor", "same-gop", "adjacent-gop", "far-random")
  $fixtures = 1..5 | ForEach-Object {
    $fixtureNumber = $_
    $targets = 0..49 | ForEach-Object {
      $ordinal = $_
      $category = $categories[[Math]::Floor($ordinal / 10)]
      $categoryOrdinal = $ordinal % 10
      $cacheTargets = @(0, 500, 999, 50, 150, 250, 350, 450, 550, 650)
      $setupIndex = switch ($category) {
        "cache-or-history-hit" { $cacheTargets[$categoryOrdinal] }
        "ahead-of-cursor" { 20 + $categoryOrdinal }
        "same-gop" { 100 + (2 * $categoryOrdinal) }
        "adjacent-gop" { 190 - $categoryOrdinal }
        "far-random" { 300 + $categoryOrdinal }
      }
      $targetIndex = switch ($category) {
        "cache-or-history-hit" { $setupIndex }
        "ahead-of-cursor" { $setupIndex + 16 }
        "same-gop" { $setupIndex - 1 }
        "adjacent-gop" { 200 + $categoryOrdinal }
        "far-random" { $setupIndex + 500 }
      }
      $direction = if ($targetIndex -gt $setupIndex) { "forward" } elseif ($targetIndex -lt $setupIndex) { "reverse" } else { "stationary" }
      $syncIndices = @(0, 200, 400, 600, 800)
      $setupSyncOrdinal = 0
      $targetSyncOrdinal = 0
      for ($syncOrdinal = 0; $syncOrdinal -lt $syncIndices.Count; $syncOrdinal += 1) {
        if ($syncIndices[$syncOrdinal] -le $setupIndex) { $setupSyncOrdinal = $syncOrdinal }
        if ($syncIndices[$syncOrdinal] -le $targetIndex) { $targetSyncOrdinal = $syncOrdinal }
      }
      $acceptedNs = [long](($fixtureNumber * 1000000000L) + ($ordinal * 10000000L))
      [PSCustomObject][ordered]@{
        ordinal = $ordinal
        category = $category
        direction = $direction
        setupFrameIndex = $setupIndex
        targetFrameIndex = $targetIndex
        setupSampleOrdinal = $setupIndex
        targetSampleOrdinal = $targetIndex
        targetPtsUs = [long]$targetIndex * 1000L
        fileGeneration = $fixtureNumber
        requestGeneration = 2 + ($ordinal * 2)
        acceptedElapsedRealtimeNs = $acceptedNs
        publishedElapsedRealtimeNs = $acceptedNs + 500000L
        setupPreviousSyncFrameIndex = $syncIndices[$setupSyncOrdinal]
        targetPreviousSyncFrameIndex = $syncIndices[$targetSyncOrdinal]
        setupSyncOrdinal = $setupSyncOrdinal
        targetSyncOrdinal = $targetSyncOrdinal
        acceptedToFirstDecoderOutputUs = $null
        acceptedToTargetOutputUs = $null
        acceptedToPublicationUs = 500L
        decodedOutputCount = if ($category -eq "cache-or-history-hit") { 0L } else { 3L }
        seekCount = if ($category -eq "cache-or-history-hit") { 0L } else { 1L }
        flushCount = if ($category -eq "cache-or-history-hit") { 0L } else { 1L }
        cacheOrHistoryHit = $category -eq "cache-or-history-hit"
        acceptedDisplayedFrameIndex = $setupIndex
        publishedDisplayedFrameIndex = $targetIndex
        acceptedDisplayedMeasurement = "SETUP_PUBLICATION"
        acceptedRawFrameLag = [Math]::Abs($targetIndex - $setupIndex)
        publishedRawFrameLag = 0
        staleDiscardCount = 0
        nonTargetPublishedCount = 0
      }
    }
    [PSCustomObject][ordered]@{
      fixtureId = "fixture-{0:D2}" -f $fixtureNumber
      frameCount = 1000
      codecComponent = "c2.qti.test.decoder"
      hardwareAccelerated = $true
      fullFrameReadbackCount = 0
      targetCount = 50
      deterministicSeed = 1000L + $fixtureNumber
      syncFrameIndices = @(0, 200, 400, 600, 800)
      syncSamples = @(
        [PSCustomObject][ordered]@{ displayFrameIndex = 0; sampleOrdinal = 0 },
        [PSCustomObject][ordered]@{ displayFrameIndex = 200; sampleOrdinal = 200 },
        [PSCustomObject][ordered]@{ displayFrameIndex = 400; sampleOrdinal = 400 },
        [PSCustomObject][ordered]@{ displayFrameIndex = 600; sampleOrdinal = 600 },
        [PSCustomObject][ordered]@{ displayFrameIndex = 800; sampleOrdinal = 800 }
      )
      targetSetIdentity = ("{0:x64}" -f $fixtureNumber)
      inSessionMemory = [PSCustomObject][ordered]@{
        javaUsedBytes = 16777216L
        nativeAllocatedBytes = 8388608L
        totalPssBytes = 50331648L
      }
      categoryCounts = [PSCustomObject][ordered]@{
        "cache-or-history-hit" = 10
        "ahead-of-cursor" = 10
        "same-gop" = 10
        "adjacent-gop" = 10
        "far-random" = 10
      }
      containsFirstMiddleLast = $true
      containsGopBoundary = $true
      targets = @($targets)
      burst = [PSCustomObject][ordered]@{
        requestCount = 10
        acceptedRequestCount = 10
        acceptedRequestGenerations = @(101, 102, 103, 104, 105, 106, 107, 108, 109, 110)
        finalTargetFrameIndex = 999
        fileGeneration = $fixtureNumber
        requestGeneration = 110
        acceptedElapsedRealtimeNs = [long](($fixtureNumber * 1000000000L) + 900000000L)
        assessmentWindowStartElapsedRealtimeNs = [long](($fixtureNumber * 1000000000L) + 900000000L)
        publishedElapsedRealtimeNs = [long](($fixtureNumber * 1000000000L) + 900500000L)
        acceptedToPublicationUs = 500L
        nonTargetPublishedCount = 0
        nonFinalPublishedAfterFinalAcceptanceCount = 0
        publicationAssessment = "EVENT_TIMESTAMP_AT_OR_AFTER_FINAL_ACCEPTANCE"
        discardedStaleAssessment = "FINAL_GENERATION_ONLY_NO_CALLBACK_TIMESTAMP"
        staleDiscardCount = 9
      }
      cacheBudgetBytes = 67108864L
      cacheBytes = 33554432L
      cacheEntryCount = 8
      peakCacheEntryCount = 12
      cacheEvictionCount = 4
      cacheRejectionCount = 0
      cacheThrashCount = 0
      liveTextureCount = 8
      peakLiveTextureCount = 12
      textureDoubleReleaseCount = 0
      staleBeforeSwapCount = 0
      swapFailureCount = 0
      surfaceInvalidCount = 0
      publicationInvariantViolationCount = 0
    }
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "alpha4-random-source-equivalent-timing-baseline"
    status = "PASS"
    baselineCompleteness = "PENDING_TRACE_MERGE"
    renderMode = "PILOT_SOURCE_EQUIVALENT"
    pixelExactnessEvidence = "SEPARATE_FROZEN_GATES"
    memoryMeasurement = "POST_ACTIVITY_CLEANUP_SNAPSHOT"
    applicationId = "com.snowberried.ctcinereviewer.internal"
    appVersionName = "0.2.0-alpha.4"
    appVersionCode = 5
    appCommitSha = $ArtifactSet.RuntimeSourceSha
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    mediaFileNameIncluded = $false
    mediaUriIncluded = $false
    mediaPathIncluded = $false
    mediaSourceHashIncluded = $false
    metricAvailability = [PSCustomObject][ordered]@{
      acceptedToFirstDecoderOutput = "PENDING_TRACE_MERGE"
      acceptedToTargetOutput = "PENDING_TRACE_MERGE"
      gpu = "UNKNOWN"
      releaseOvershoot = "UNKNOWN"
    }
    gpuMetrics = $null
    memory = [PSCustomObject][ordered]@{ javaUsedBytes = 100; nativeAllocatedBytes = 200; totalPssBytes = 300 }
    fixtures = @($fixtures)
    fixtureCount = 5
    targetCount = 250
    mismatchCount = 0
    writeOpenCount = 0
    runId = "alpha4-random-test"
    startedAtElapsedRealtimeNs = 100L
    finishedAtElapsedRealtimeNs = 200L
    runtimeSourceSha = $ArtifactSet.RuntimeSourceSha
    harnessSourceSha = $ArtifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $ArtifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = 2
    testCount = 1
    instrumentationExpectedTestCount = 1
    appSha256 = $ArtifactSet.Artifacts.debugApp.sha256
    testApkSha256 = $ArtifactSet.Artifacts.debugTest.sha256
  }
}

function Write-Alpha4RandomTestTrace {
  param([string]$Path, [object]$Report)
  $lines = [System.Collections.Generic.List[string]]::new()
  $tracePid = 1234
  foreach ($fixture in @($Report.fixtures)) {
    $fixtureId = [string]$fixture.fixtureId
    $fileGeneration = [int]($fixtureId.Substring(($fixtureId.Length - 2)))
    $requestGeneration = 1
    foreach ($target in @($fixture.targets)) {
      $setupFrameIndex = [int]$target.setupFrameIndex
      $targetFrameIndex = [int]$target.targetFrameIndex
      $targetPtsUs = [long]$target.targetPtsUs
      $acceptedUs = [long][Math]::Floor([long]$target.acceptedElapsedRealtimeNs / 1000.0)
      $entries = @(
        [PSCustomObject]@{ Stage = "CCR.request.accept"; FrameIndex = $setupFrameIndex; PtsUs = [long]($setupFrameIndex * 1000L); RequestGeneration = $requestGeneration; TimestampUs = $acceptedUs - 100L },
        [PSCustomObject]@{ Stage = "CCR.request.accept"; FrameIndex = $targetFrameIndex; PtsUs = $targetPtsUs; RequestGeneration = ($requestGeneration + 1); TimestampUs = $acceptedUs }
      )
      foreach ($entry in $entries) {
        $seconds = ([decimal]$entry.TimestampUs / 1000000).ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)
        $lines.Add("trace-$tracePid ( $tracePid) [000] ...1 $seconds`: tracing_mark_write: B|$tracePid|$($entry.Stage) f=$fileGeneration r=$($entry.RequestGeneration) i=$($entry.FrameIndex) p=$($entry.PtsUs)") | Out-Null
      }
      $targetRequestGeneration = $requestGeneration + 1
      if (-not $target.cacheOrHistoryHit) {
        $stageOffsetUs = 100L
        foreach ($stage in @("CCR.output.first", "CCR.output.target")) {
          $seconds = ([decimal]($acceptedUs + $stageOffsetUs) / 1000000).ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)
          $lines.Add("trace-$tracePid ( $tracePid) [000] ...1 $seconds`: tracing_mark_write: B|$tracePid|$stage f=$fileGeneration r=$targetRequestGeneration i=$($target.targetFrameIndex) p=$($target.targetPtsUs)") | Out-Null
          $stageOffsetUs += 100L
        }
      }
      $seconds = ([decimal]($acceptedUs + 300L) / 1000000).ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)
      $lines.Add("trace-$tracePid ( $tracePid) [000] ...1 $seconds`: tracing_mark_write: B|$tracePid|CCR.publish f=$fileGeneration r=$targetRequestGeneration i=$($target.targetFrameIndex) p=$($target.targetPtsUs)") | Out-Null
      $requestGeneration += 2
    }
  }
  [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
}

try {
  Reset-TestArtifacts

  Invoke-HostTest "native-stderr-with-zero-exit-is-not-failure" {
    $result = Invoke-CcrPinnedAdbRaw $env:ComSpec $null @("/d", "/c", "echo pull-progress 1>&2 & exit /b 0")
    if ($result.exitCode -ne 0 -or $result.output -notmatch "pull-progress") {
      throw "native stderr result was not preserved"
    }
  }

  Invoke-HostTest "native-stderr-with-nonzero-exit-is-returned" {
    $result = Invoke-CcrPinnedAdbRaw $env:ComSpec $null @("/d", "/c", "echo pull-failed 1>&2 & exit /b 7")
    if ($result.exitCode -ne 7 -or $result.output -notmatch "pull-failed") {
      throw "native failure exit code or stderr was lost"
    }
  }

  Invoke-HostTest "cleanup-skips-absent-test-packages" {
    $cleanupCalls = [System.Collections.Generic.List[string]]::new()
    $cleanupAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $cleanupCalls.Add($line) | Out-Null
      if ($line -match " shell pm list packages ") { return [PSCustomObject]@{ exitCode = 0; output = "" } }
      if ($line -match " uninstall ") { throw "absent package must not be uninstalled" }
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }.GetNewClosure()
    $cleanupContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $cleanupAdb }
    $cleanupResult = @(Invoke-CcrPinnedCleanup $cleanupContext)
    if ($cleanupResult.Count -ne 0) { throw "unexpected cleanup failure: $($cleanupResult -join ' | ')" }
    if (@($cleanupCalls | Where-Object { $_ -match " uninstall " }).Count -ne 0) { throw "uninstall was invoked for an absent package" }
  }

  Invoke-HostTest "cleanup-removes-present-test-package" {
    $packageState = [PSCustomObject]@{ Installed = $true }
    $cleanupCalls = [System.Collections.Generic.List[string]]::new()
    $cleanupAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $cleanupCalls.Add($line) | Out-Null
      if ($line -match " shell pm list packages .+com\.snowberried\.ctcinereviewer\.internal\.test$") {
        $output = if ($packageState.Installed) { "package:com.snowberried.ctcinereviewer.internal.test" } else { "" }
        return [PSCustomObject]@{ exitCode = 0; output = $output }
      }
      if ($line -match " shell pm list packages ") { return [PSCustomObject]@{ exitCode = 0; output = "" } }
      if ($line -match " uninstall com\.snowberried\.ctcinereviewer\.internal\.test$") {
        $packageState.Installed = $false
        return [PSCustomObject]@{ exitCode = 0; output = "Success" }
      }
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }.GetNewClosure()
    $cleanupContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $cleanupAdb }
    $cleanupResult = @(Invoke-CcrPinnedCleanup $cleanupContext)
    if ($cleanupResult.Count -ne 0 -or $packageState.Installed) { throw "present package was not cleanly removed" }
    if (@($cleanupCalls | Where-Object { $_ -match " uninstall com\.snowberried\.ctcinereviewer\.internal\.test$" }).Count -ne 1) {
      throw "present package uninstall count was not one"
    }
  }

  Invoke-HostTest "cleanup-reports-package-query-failure" {
    $cleanupAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      if ($line -match "internal\.test$") { return [PSCustomObject]@{ exitCode = 2; output = "transport error" } }
      if ($line -match " shell pm list packages ") { return [PSCustomObject]@{ exitCode = 0; output = "" } }
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }
    $cleanupContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $cleanupAdb }
    $cleanupResult = @(Invoke-CcrPinnedCleanup $cleanupContext)
    if (($cleanupResult -join " | ") -notmatch "PACKAGE_QUERY_FAILED:com\.snowberried\.ctcinereviewer\.internal\.test") {
      throw "package query failure was not preserved"
    }
  }

  Invoke-HostTest "stale-report-clear-confirms-absence" {
    $reportCalls = [System.Collections.Generic.List[string]]::new()
    $reportAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $reportCalls.Add($line) | Out-Null
      return [PSCustomObject]@{ exitCode = 0; output = "" }
    }.GetNewClosure()
    $reportContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $reportAdb }
    Clear-CcrPinnedRemoteReport $reportContext $appPackage "frame-report.json"
    if (@($reportCalls | Where-Object { $_ -match " sh -c 'if \[ -e files/frame-report\.json \]" }).Count -ne 1) {
      throw "report absence postcondition was not checked"
    }
  }

  Invoke-HostTest "stale-report-clear-rejects-present-file" {
    $reportAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $exitCode = if ($line -match " sh -c ") { 7 } else { 0 }
      return [PSCustomObject]@{ exitCode = $exitCode; output = "" }
    }
    $reportContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $reportAdb }
    $caught = $null
    try { Clear-CcrPinnedRemoteReport $reportContext $appPackage "frame-report.json" } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_STALE_REPORT_STILL_PRESENT") { throw "present stale report was not rejected: $caught" }
  }

  Invoke-HostTest "stale-report-clear-rejects-unknown-check-error" {
    $reportAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $exitCode = if ($line -match " sh -c ") { 2 } else { 0 }
      return [PSCustomObject]@{ exitCode = $exitCode; output = "transport error" }
    }
    $reportContext = [PSCustomObject]@{ Adb = "fake-adb"; Serial = "R58VALID"; AdbInvoker = $reportAdb }
    $caught = $null
    try { Clear-CcrPinnedRemoteReport $reportContext $appPackage "frame-report.json" } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_STALE_REPORT_ABSENCE_CHECK_FAILED") { throw "unknown report check error was not preserved: $caught" }
  }

  Invoke-HostTest "performance-wrapper-host-contracts" {
    $source = [System.IO.File]::ReadAllText(
      (Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1"),
      [System.Text.Encoding]::UTF8
    )
    if ($source -match '\.Contains\([^\r\n]+StringComparison') {
      throw "Windows PowerShell 5.1 incompatible Contains overload returned"
    }
    foreach ($contract in @(
      'EvidenceScenario = "1080p-hold-plus-one"',
      'EvidenceScenario = "1080p-hold-plus-five"',
      '$scenario.EvidenceScenario',
      'traceArtifactValidation = "PASS"',
      'androidx-profiler-file-set+benchmarkData-3run-counters+nonempty-traces',
      'PINNED_BENCHMARK_DATA_TRACE_FILESET_MISMATCH',
      '$script:CcrPinnedAppPackage/com.snowberried.ctcinereviewer.MainActivity',
      '"start", "-W", "-n"'
    )) {
      if (-not $source.Contains($contract)) { throw "performance wrapper contract missing: $contract" }
    }
  }

  Invoke-HostTest "valid-preflight-is-read-only" {
    Reset-TestArtifacts
    $manifest = New-TestManifest
    $path = Save-TestManifest $manifest "valid"
    $adbCalls.Clear()
    $context = Invoke-CcrPinnedPreflight $path $outputRoot $repoRoot $harnessSourceSha $fakeTools $identityReader $fakeAdb $testDebugAppSha256
    if ($context.Model -ne "SM-S928N" -or $context.Serial -ne "R58VALID") { throw "device identity mismatch" }
    if ($adbCalls.Count -ne 6) { throw "unexpected preflight ADB call count: $($adbCalls.Count)" }
    Assert-NoMutationCalls
  }.GetNewClosure()

  Invoke-HostTest "debug-app-one-byte-mutation" {
    Reset-TestArtifacts
    $manifest = New-TestManifest
    $path = Save-TestManifest $manifest "debug-app-mutated"
    $appPath = @($manifest.artifacts | Where-Object role -eq "debugApp")[0].path
    $stream = [System.IO.File]::Open($appPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.WriteByte(255) } finally { $stream.Dispose() }
    $adbCalls.Clear()
    $caught = $null
    try { Invoke-CcrPinnedPreflight $path $outputRoot $repoRoot $harnessSourceSha $fakeTools $identityReader $fakeAdb $testDebugAppSha256 | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_ARTIFACT_BYTE_SIZE_MISMATCH:debugApp") { throw "unexpected rejection: $caught" }
    Assert-NoAdbBeforeRejection
  }.GetNewClosure()

  Invoke-HostTest "debug-test-one-byte-mutation" {
    Reset-TestArtifacts
    $manifest = New-TestManifest
    $path = Save-TestManifest $manifest "debug-test-mutated"
    $testPath = @($manifest.artifacts | Where-Object role -eq "debugTest")[0].path
    $bytes = [System.IO.File]::ReadAllBytes($testPath)
    $bytes[0] = $bytes[0] -bxor 1
    [System.IO.File]::WriteAllBytes($testPath, $bytes)
    $adbCalls.Clear()
    $caught = $null
    try { Invoke-CcrPinnedPreflight $path $outputRoot $repoRoot $harnessSourceSha $fakeTools $identityReader $fakeAdb $testDebugAppSha256 | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_ARTIFACT_SHA_MISMATCH:debugTest") { throw "unexpected rejection: $caught" }
    Assert-NoAdbBeforeRejection
  }.GetNewClosure()

  Expect-ManifestRejection "sha-mismatch" { param($m) $m.artifacts[2].sha256 = "0" * 64 } "PINNED_ARTIFACT_SHA_MISMATCH:benchmarkApp"
  Expect-ManifestRejection "byte-size-mismatch" { param($m) $m.artifacts[2].bytes = [long]$m.artifacts[2].bytes + 1 } "PINNED_ARTIFACT_BYTE_SIZE_MISMATCH:benchmarkApp"
  Expect-ManifestRejection "runtime-source-mismatch" { param($m) $m.runtimeSourceSha = "0" * 40 } "PINNED_MANIFEST_RUNTIME_SOURCE_MISMATCH"
  Expect-ManifestRejection "runtime-tree-mismatch" { param($m) $m.runtimeInputsTreeSha256 = "0" * 64 } "PINNED_MANIFEST_RUNTIME_TREE_MISMATCH"
  Expect-ManifestRejection "version-mismatch" { param($m) $m.artifacts[0].versionCode = 6 } "PINNED_ARTIFACT_VERSION_CODE_INSPECTION_MISMATCH:debugApp"
  Expect-ManifestRejection "package-mismatch" { param($m) $m.artifacts[1].packageName = "invalid.package" } "PINNED_ARTIFACT_PACKAGE_MISMATCH:debugTest"
  Expect-ManifestRejection "certificate-mismatch" { param($m) $m.artifacts[3].signingCertificateSha256 = "0" * 64 } "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:macrobenchmarkTest"
  Expect-ManifestRejection "runner-mismatch" { param($m) $m.artifacts[1].runner = "invalid.Runner" } "PINNED_ARTIFACT_RUNNER_INSPECTION_MISMATCH:debugTest"
  Expect-ManifestRejection "artifact-role-duplicate" {
    param($m)
    $copy = Copy-TestValue $m.artifacts[0]
    $m.artifacts = @($m.artifacts[0], $m.artifacts[1], $m.artifacts[2], $copy)
  } "PINNED_ARTIFACT_ROLE_DUPLICATE:debugApp"
  Expect-ManifestRejection "debug-test-artifact-missing" { param($m) $m.artifacts[1].path = Join-Path $artifactRoot "missing-debug-test.apk" } "PINNED_ARTIFACT_MISSING:debugTest"
  Expect-ManifestRejection "benchmark-app-artifact-missing" { param($m) $m.artifacts[2].path = Join-Path $artifactRoot "missing-benchmark-app.apk" } "PINNED_ARTIFACT_MISSING:benchmarkApp"
  Expect-ManifestRejection "macrobenchmark-test-artifact-missing" { param($m) $m.artifacts[3].path = Join-Path $artifactRoot "missing-macrobenchmark-test.apk" } "PINNED_ARTIFACT_MISSING:macrobenchmarkTest"
  Expect-ManifestRejection "physical-path-duplicate" { param($m) $m.artifacts[3].path = $m.artifacts[1].path; $m.artifacts[3].bytes = $m.artifacts[1].bytes; $m.artifacts[3].sha256 = $m.artifacts[1].sha256 } "PINNED_ARTIFACT_PHYSICAL_PATH_DUPLICATE:macrobenchmarkTest"

  Invoke-HostTest "run-id-missing" {
    $adbCalls.Clear()
    $caught = $null
    try { Assert-CcrPinnedRunId "" | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_RUN_ID_INVALID") { throw "unexpected rejection: $caught" }
    Assert-NoAdbBeforeRejection
  }

  Invoke-HostTest "run-id-duplicate" {
    $ledger = Join-Path $testRoot "run-ledger"
    $runId = "duplicate-12345678"
    Reserve-CcrPinnedRunId $ledger $runId | Out-Null
    $caught = $null
    try { Reserve-CcrPinnedRunId $ledger $runId | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_RUN_ID_DUPLICATE") { throw "unexpected rejection: $caught" }
  }

  Reset-TestArtifacts
  $validManifest = New-TestManifest
  $validPath = Save-TestManifest $validManifest "report-fixture"
  $artifactSet = Import-CcrPinnedArtifactManifest $validPath $repoRoot $harnessSourceSha $fakeTools $identityReader $testDebugAppSha256
  . (Import-TestScriptFunction (Join-Path $PSScriptRoot "run-s24-alpha4-navigation-baseline.ps1") `
    "Assert-CcrAlpha4NavigationCheckpointIdentity")
  . (Import-TestScriptFunction (Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1") `
    "Assert-CcrPerfCheckpointIdentity")
  . (Import-TestScriptFunction (Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1") `
    "Write-CcrPerfJson")
  . (Import-TestScriptFunction (Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1") `
    "Save-CcrPerfFailureArtifacts")
  . (Import-TestScriptFunction (Join-Path $PSScriptRoot "run-s24-alpha4-random-baseline.ps1") `
    "Assert-CcrAlpha4RandomFileIdentity")

  $resumeContext = [PSCustomObject]@{
    ArtifactSet = $artifactSet
    Serial = "R58VALID"
    Fingerprint = "samsung/test/fingerprint"
  }
  $resumeCheckpoint = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "s24-alpha4-navigation-baseline-checkpoint"
    status = "PASS"
    artifactManifestSha256 = $artifactSet.ManifestSha256
    artifactSetRevision = 2
    runtimeSourceSha = $artifactSet.RuntimeSourceSha
    harnessSourceSha = $artifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $artifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = $artifactSet.Artifacts.debugApp.sha256
    debugTestApkSha256 = $artifactSet.Artifacts.debugTest.sha256
    benchmarkAppSha256 = $artifactSet.Artifacts.benchmarkApp.sha256
    macrobenchmarkTestSha256 = $artifactSet.Artifacts.macrobenchmarkTest.sha256
    device = [PSCustomObject]@{ serial = "R58VALID"; fingerprint = "samsung/test/fingerprint" }
    serial = "R58VALID"
    fingerprint = "samsung/test/fingerprint"
    scenarioProfile = "Alpha4Reverse"
    maxMinutes = 25
    runtimeIdentityMode = "same-manifest-runtime-source-and-input-tree; benchmarkApp-is-not-byte-identical-to-fixed-debugApp"
  }
  $randomSessionCheckpoint = [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = "s24-alpha4-random-session-checkpoint"
    status = "PASS"
    completedStage = "session-settings-captured"
    artifactManifestSha256 = $artifactSet.ManifestSha256
    artifactSetRevision = 2
    runtimeSourceSha = $artifactSet.RuntimeSourceSha
    harnessSourceSha = $artifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $artifactSet.RuntimeInputsTreeSha256
    debugAppSha256 = $artifactSet.Artifacts.debugApp.sha256
    debugTestApkSha256 = $artifactSet.Artifacts.debugTest.sha256
    device = [PSCustomObject]@{ serial = "R58VALID"; fingerprint = "samsung/test/fingerprint" }
    parameters = [PSCustomObject]@{
      maxMinutes = 25
      testClass = "example.RandomTest#baseline"
      reportName = "random-report.json"
      resumeGranularity = "whole-instrumentation-restart; complete-pass-evidence-only-reuse"
    }
    savedSettings = [PSCustomObject]@{
      stayAwake = "0"; brightnessMode = "1"; brightness = "128"; screenTimeout = "30000"
      accelerometerRotation = "1"; userRotation = "0"
    }
  }

  Invoke-HostTest "alpha4-resume-checkpoint-identities-valid" {
    Assert-CcrAlpha4NavigationCheckpointIdentity $resumeCheckpoint $resumeContext 25
    $perfCheckpoint = Copy-TestValue $resumeCheckpoint
    $perfCheckpoint.kind = "s24-navigation-perf-session-checkpoint"
    Assert-CcrPerfCheckpointIdentity $perfCheckpoint $resumeContext `
      "s24-navigation-perf-session-checkpoint" "Alpha4Reverse" 25
  }

  Invoke-HostTest "alpha4-random-resume-session-valid" {
    Assert-CcrAlpha4RandomSessionCheckpointIdentity $randomSessionCheckpoint $resumeContext 25 `
      "example.RandomTest#baseline" "random-report.json" | Out-Null
  }

  Invoke-HostTest "alpha4-random-resume-evidence-file-valid" {
    $path = Join-Path $outputRoot "random-resume-evidence.json"
    [System.IO.File]::WriteAllText($path, '{"syntheticOnly":true}', [System.Text.UTF8Encoding]::new($false))
    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    Assert-CcrAlpha4RandomFileIdentity $path $sha256 $outputRoot "EXPECTED_FAILURE" | Out-Null
  }

  Invoke-HostTest "alpha4-random-resume-evidence-hash-mismatch" {
    $path = Join-Path $outputRoot "random-resume-evidence-mismatch.json"
    [System.IO.File]::WriteAllText($path, '{"syntheticOnly":true}', [System.Text.UTF8Encoding]::new($false))
    $caught = $null
    try { Assert-CcrAlpha4RandomFileIdentity $path ("0" * 64) $outputRoot "RANDOM_RESUME_HASH_MISMATCH" } catch {
      $caught = $_.Exception.Message
    }
    if ($caught -cne "RANDOM_RESUME_HASH_MISMATCH") { throw "unexpected rejection: $caught" }
  }

  foreach ($case in @(
    @("alpha4-random-resume-session-manifest", { param($c) $c.artifactManifestSha256 = "0" * 64 }),
    @("alpha4-random-resume-session-device", { param($c) $c.device.serial = "OTHER" }),
    @("alpha4-random-resume-session-parameter", { param($c) $c.parameters.maxMinutes = 24 }),
    @("alpha4-random-resume-session-saved-setting", { param($c) $c.savedSettings.PSObject.Properties.Remove("screenTimeout") })
  )) {
    $caseName = [string]$case[0]
    $mutate = [scriptblock]$case[1]
    Invoke-HostTest $caseName {
      $checkpoint = Copy-TestValue $randomSessionCheckpoint
      & $mutate $checkpoint
      $caught = $null
      try {
        Assert-CcrAlpha4RandomSessionCheckpointIdentity $checkpoint $resumeContext 25 `
          "example.RandomTest#baseline" "random-report.json" | Out-Null
      } catch { $caught = $_.Exception.Message }
      if ($caught -notmatch "ALPHA4_RANDOM_RESUME_") { throw "unexpected rejection: $caught" }
    }.GetNewClosure()
  }

  foreach ($case in @(
    @("alpha4-resume-manifest-mismatch", { param($c) $c.artifactManifestSha256 = "0" * 64 }),
    @("alpha4-resume-device-mismatch", { param($c) $c.device.fingerprint = "different" }),
    @("alpha4-resume-parameter-mismatch", { param($c) $c.maxMinutes = 24 })
  )) {
    $caseName = [string]$case[0]
    $mutate = [scriptblock]$case[1]
    Invoke-HostTest $caseName {
      $checkpoint = Copy-TestValue $resumeCheckpoint
      & $mutate $checkpoint
      $caught = $null
      try { Assert-CcrAlpha4NavigationCheckpointIdentity $checkpoint $resumeContext 25 } catch { $caught = $_.Exception.Message }
      if ($caught -notmatch "ALPHA4_BASELINE_RESUME_CHECKPOINT_IDENTITY_MISMATCH") { throw "unexpected rejection: $caught" }
    }.GetNewClosure()
  }

  Invoke-HostTest "alpha4-perf-resume-profile-mismatch" {
    $checkpoint = Copy-TestValue $resumeCheckpoint
    $checkpoint.kind = "s24-navigation-perf-session-checkpoint"
    $caught = $null
    try {
      Assert-CcrPerfCheckpointIdentity $checkpoint $resumeContext `
        "s24-navigation-perf-session-checkpoint" "Forward" 25
    } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_PERF_RESUME_CHECKPOINT_IDENTITY_MISMATCH") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "alpha4-perf-failure-artifacts-recovered-and-hashed" {
    $recoveryAdb = {
      param([string[]]$CommandArguments)
      $destination = [string]$CommandArguments[-1]
      [System.IO.File]::WriteAllBytes((Join-Path $destination "partial.perfetto-trace"), [byte[]](1, 2, 3, 4))
      return [PSCustomObject]@{ exitCode = 0; output = "pulled" }
    }
    $recoveryContext = [PSCustomObject]@{ Adb = "fake-adb"; AdbInvoker = $recoveryAdb; Serial = "R58VALID" }
    $attempt = [PSCustomObject]@{
      scenario = "hold1080MinusOneAlpha4Baseline"
      runId = "failure-recovery-12345678"
      remoteDirectory = "/sdcard/Android/media/test/failure-recovery-12345678"
    }
    $result = Save-CcrPerfFailureArtifacts $recoveryContext $attempt $outputRoot
    if ($result.status -cne "RECOVERED" -or $result.recoveredFileCount -ne 1 -or
        $result.manifestSha256 -notmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $result.manifest -PathType Leaf)) {
      throw "failure artifacts were not recovered and hashed"
    }
  }

  Invoke-HostTest "alpha4-perf-failure-artifacts-pull-failure-recorded" {
    $recoveryAdb = { param([string[]]$CommandArguments); [PSCustomObject]@{ exitCode = 1; output = "failed" } }
    $recoveryContext = [PSCustomObject]@{ Adb = "fake-adb"; AdbInvoker = $recoveryAdb; Serial = "R58VALID" }
    $attempt = [PSCustomObject]@{
      scenario = "hold1080MinusFiveAlpha4Baseline"
      runId = "failure-record-12345678"
      remoteDirectory = "/sdcard/Android/media/test/failure-record-12345678"
    }
    $result = Save-CcrPerfFailureArtifacts $recoveryContext $attempt $outputRoot
    if ($result.status -cne "RECOVERY_FAILED" -or $result.recoveredFileCount -ne 0 -or
        $result.recoveryFailure -cne "adb-pull-exit-1" -or $result.manifestSha256 -notmatch '^[0-9a-f]{64}$') {
      throw "failure artifact pull failure was not preserved"
    }
  }

  Invoke-HostTest "alpha4-timed-instrumentation-valid" {
    $timedCalls = [System.Collections.Generic.List[string]]::new()
    $timedAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      $timedCalls.Add($line) | Out-Null
      if ($line -match " shell cat /proc/uptime$") {
        return [PSCustomObject]@{ exitCode = 0; output = "10.000 20.000" }
      }
      if ($line -match " shell timeout \d+s am instrument ") {
        return [PSCustomObject]@{ exitCode = 0; output = "OK (1 test)" }
      }
      return [PSCustomObject]@{ exitCode = 2; output = "unexpected" }
    }.GetNewClosure()
    $timedContext = [PSCustomObject]@{
      Adb = "fake-adb"
      AdbInvoker = $timedAdb
      Serial = "R58VALID"
      ArtifactSet = $artifactSet
    }
    $result = Invoke-CcrAlpha4TimedInstrumentation `
      -Context $timedContext -TestRole "debugTest" -ClassName "example.Test" `
      -RunId "timed-valid-12345678" -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMinutes(1))
    if ($result.Output -cne "OK (1 test)" -or $result.MinimumStartedAtElapsedRealtimeNs -ne 10000000000L) {
      throw "timed instrumentation result mismatch"
    }
    $command = @($timedCalls | Where-Object { $_ -match " shell timeout " })
    if ($command.Count -ne 1 -or $command[0] -notmatch "runtimeSourceSha $($artifactSet.RuntimeSourceSha)" -or
        $command[0] -notmatch "expectedAppSha256 $($artifactSet.Artifacts.debugApp.sha256)") {
      throw "timed instrumentation pinned arguments missing"
    }
  }

  Invoke-HostTest "alpha4-timed-instrumentation-timeout-fails-closed" {
    $timeoutAdb = {
      param([string[]]$CommandArguments)
      $line = $CommandArguments -join " "
      if ($line -match " shell cat /proc/uptime$") { return [PSCustomObject]@{ exitCode = 0; output = "10.0 20.0" } }
      return [PSCustomObject]@{ exitCode = 124; output = "" }
    }
    $timedContext = [PSCustomObject]@{ Adb = "fake-adb"; AdbInvoker = $timeoutAdb; Serial = "R58VALID"; ArtifactSet = $artifactSet }
    $caught = $null
    try {
      Invoke-CcrAlpha4TimedInstrumentation `
        -Context $timedContext -TestRole "debugTest" -ClassName "example.Test" `
        -RunId "timed-timeout-12345678" -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMinutes(1)) | Out-Null
    } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "ALPHA4_BASELINE_INSTRUMENTATION_TIMEOUT:debugTest") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "alpha4-expired-deadline-rejects-before-adb" {
    $deadlineCalls = [System.Collections.Generic.List[string]]::new()
    $deadlineAdb = {
      param([string[]]$CommandArguments)
      $deadlineCalls.Add(($CommandArguments -join " ")) | Out-Null
      return [PSCustomObject]@{ exitCode = 0; output = "unexpected" }
    }.GetNewClosure()
    $timedContext = [PSCustomObject]@{ Adb = "fake-adb"; AdbInvoker = $deadlineAdb; Serial = "R58VALID"; ArtifactSet = $artifactSet }
    $caught = $null
    try {
      Invoke-CcrAlpha4TimedInstrumentation `
        -Context $timedContext -TestRole "debugTest" -ClassName "example.Test" `
        -RunId "timed-expired-12345678" -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(-1)) | Out-Null
    } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "ALPHA4_BASELINE_MAX_MINUTES_EXCEEDED" -or $deadlineCalls.Count -ne 0) {
      throw "expired deadline was not fail-closed before ADB: $caught"
    }
  }
  $runId = "report-12345678"
  $baseReport = [PSCustomObject][ordered]@{
    kind = "frame-accuracy-exact"
    status = "PASS"
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    runId = $runId
    startedAtElapsedRealtimeNs = 200L
    finishedAtElapsedRealtimeNs = 300L
    runtimeSourceSha = $artifactSet.RuntimeSourceSha
    harnessSourceSha = $artifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $artifactSet.RuntimeInputsTreeSha256
    artifactSetRevision = 2
    testCount = 1
    instrumentationExpectedTestCount = 2
    appSha256 = $artifactSet.Artifacts.debugApp.sha256
    testApkSha256 = $artifactSet.Artifacts.debugTest.sha256
  }

  Invoke-HostTest "report-run-id-mismatch" {
    $report = Copy-TestValue $baseReport
    $report.runId = "different-12345678"
    $caught = $null
    try { Assert-CcrPinnedReport $report $artifactSet $runId "debugApp" "debugTest" 100 "frame-accuracy-exact" | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_REPORT_RUN_ID_MISMATCH") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "stale-report" {
    $report = Copy-TestValue $baseReport
    $report.startedAtElapsedRealtimeNs = 99L
    $caught = $null
    try { Assert-CcrPinnedReport $report $artifactSet $runId "debugApp" "debugTest" 100 "frame-accuracy-exact" | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_REPORT_STALE_OR_TIME_INVALID") { throw "unexpected rejection: $caught" }
  }

  foreach ($case in @(
    @("report-runtime-source-mismatch", { param($r) $r.runtimeSourceSha = "0" * 40 }, "PINNED_REPORT_SOURCE_IDENTITY_MISMATCH"),
    @("report-runtime-tree-mismatch", { param($r) $r.runtimeInputsTreeSha256 = "0" * 64 }, "PINNED_REPORT_SOURCE_IDENTITY_MISMATCH"),
    @("report-app-artifact-mismatch", { param($r) $r.appSha256 = "0" * 64 }, "PINNED_REPORT_ARTIFACT_IDENTITY_MISMATCH"),
    @("report-test-artifact-mismatch", { param($r) $r.testApkSha256 = "0" * 64 }, "PINNED_REPORT_ARTIFACT_IDENTITY_MISMATCH")
  )) {
    $caseName = [string]$case[0]
    $mutate = [scriptblock]$case[1]
    $expectedFailure = [string]$case[2]
    Invoke-HostTest $caseName {
      $report = Copy-TestValue $baseReport
      & $mutate $report
      $caught = $null
      try {
        Assert-CcrPinnedReport $report $artifactSet $runId "debugApp" "debugTest" 100 "frame-accuracy-exact" 1 2 | Out-Null
      } catch { $caught = $_.Exception.Message }
      if ($caught -notmatch [regex]::Escape($expectedFailure)) { throw "unexpected rejection: $caught" }
    }.GetNewClosure()
  }

  $baseIterations = 1..3 | ForEach-Object {
    [PSCustomObject][ordered]@{
      runIteration = $_
      traceIdentity = "benchmark-12345678.scenario.$_"
      counterComplete = $true
      activeMs = 10000
      published = 7
      publishedFps = 7.0
      publicationIntervalP50Us = 100000
      publicationIntervalP95Us = 150000
      publicationIntervalMaxUs = 175000
      rawLagP50 = 1
      rawLagP95 = 1
      rawLagMax = 1
      outstandingForegroundTargetDepthMax = 1
      acceptedTargetCount = 7
      releaseAfterAcceptedTargetCount = 0
      holdPrefetchStarted = 0
      holdPrefetchCompleted = 0
      publicationGapMaxUs = 175000
      foregroundDecoded = 70
      issuedRequestCount = 7
      coalescedRequestCount = 0
      prefetchHitCount = 0
      cacheEvictionCount = 3
      seekCount = 7
      flushCount = 7
      sequentialEntryCount = 0
      sequentialFallbackCount = 0
      sequentialOutputCount = 0
      swapFailureCount = 0
      codecComponent = "c2.qti.avc.decoder"
      hardwareAccelerated = $true
      canonicalFrameBytes = 8294400
      cacheBudgetBytes = 67108864
      cacheBytes = 58060800
      cacheEntryCount = 7
      peakCacheEntryCount = 8
      cacheRejectionCount = 0
      cacheThrashCount = 0
      liveTextureCount = 7
      peakLiveTextureCount = 8
      textureDoubleReleaseCount = 0
      staleDiscardCount = 0
      staleBeforeSwapCount = 0
      surfaceInvalidCount = 0
      publicationInvariantViolationCount = 0
      decoderRecreateCount = 0
      javaUsedBytes = 1000000
      nativeAllocatedBytes = 2000000
      totalPssBytes = 3000000
      gpuMetricAvailability = "UNKNOWN"
    }
  }
  $baseEvidence = [PSCustomObject][ordered]@{
    schemaVersion = 1
    reportKind = "ccr-benchmark-harness-v2"
    artifactSetRevision = 2
    runId = "benchmark-12345678"
    runtimeSourceSha = $artifactSet.RuntimeSourceSha
    harnessSourceSha = $artifactSet.HarnessSourceSha
    runtimeInputsTreeSha256 = $artifactSet.RuntimeInputsTreeSha256
    scenario = "hold1080PlusOne"
    measurementDescription = "source-equivalent pinned benchmark measurement build"
    expectedTraceCount = 3
    traceIdentityCount = 3
    traceArtifactValidation = "PENDING_HOST"
    iterations = @($baseIterations)
  }

  Invoke-HostTest "benchmark-counter-missing" {
    $evidence = Copy-TestValue $baseEvidence
    $evidence.iterations[1].PSObject.Properties.Remove("holdPrefetchCompleted")
    $caught = $null
    try { Assert-CcrPinnedBenchmarkEvidence $evidence $artifactSet "benchmark-12345678" "hold1080PlusOne" 3 | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_BENCHMARK_COUNTER_MISSING") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "benchmark-trace-missing" {
    $evidence = Copy-TestValue $baseEvidence
    $caught = $null
    try { Assert-CcrPinnedBenchmarkEvidence $evidence $artifactSet "benchmark-12345678" "hold1080PlusOne" 2 | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "PINNED_BENCHMARK_TRACE_COUNT_MISMATCH") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "alpha4-reverse-baseline-evidence-valid" {
    Assert-CcrAlpha4ReverseBaselineEvidence $baseEvidence | Out-Null
  }

  Invoke-HostTest "alpha4-reverse-baseline-resource-invariant" {
    $evidence = Copy-TestValue $baseEvidence
    $evidence.iterations[0].cacheBytes = $evidence.iterations[0].cacheBudgetBytes + 1
    $caught = $null
    try { Assert-CcrAlpha4ReverseBaselineEvidence $evidence | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "ALPHA4_REVERSE_BASELINE_RESOURCE_COUNTER_INVALID") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "alpha4-reverse-baseline-duration-minimum" {
    $evidence = Copy-TestValue $baseEvidence
    $evidence.iterations[0].activeMs = 9999
    $evidence.iterations[0].published = 99
    $caught = $null
    try { Assert-CcrAlpha4ReverseBaselineEvidence $evidence | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "ALPHA4_REVERSE_BASELINE_DURATION_TOO_SHORT") { throw "unexpected rejection: $caught" }
  }

  $alpha4Report = New-Alpha4RandomTestReport $artifactSet
  Invoke-HostTest "alpha4-random-report-valid" {
    Assert-CcrAlpha4RandomBaselineReport $alpha4Report $artifactSet.RuntimeSourceSha `
      $artifactSet.RuntimeInputsTreeSha256 $artifactSet.HarnessSourceSha `
      $artifactSet.Artifacts.debugApp.sha256 $artifactSet.Artifacts.debugTest.sha256 | Out-Null
  }

  foreach ($case in @(
    @("alpha4-random-mismatch", { param($r) $r.mismatchCount = 1 }, "ALPHA4_RANDOM_BASELINE_TOTALS_MISMATCH"),
    @("alpha4-random-write-open", { param($r) $r.writeOpenCount = 1 }, "ALPHA4_RANDOM_BASELINE_TOTALS_MISMATCH"),
    @("alpha4-random-version", { param($r) $r.appVersionName = "0.2.0-alpha.5" }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-runtime", { param($r) $r.appCommitSha = "0" * 40 }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-app-hash", { param($r) $r.appSha256 = "0" * 64 }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-render-mode", { param($r) $r.renderMode = "EXACTNESS_PROBE" }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-pixel-evidence", { param($r) $r.pixelExactnessEvidence = "PASS" }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-memory-measurement", { param($r) $r.memoryMeasurement = "UNKNOWN" }, "ALPHA4_RANDOM_BASELINE_ARTIFACT_IDENTITY_MISMATCH"),
    @("alpha4-random-full-readback", { param($r) $r.fixtures[0].fullFrameReadbackCount = 1 }, "ALPHA4_RANDOM_BASELINE_FIXTURE_CONTRACT_MISMATCH"),
    @("alpha4-random-in-session-java-memory", { param($r) $r.fixtures[0].inSessionMemory.javaUsedBytes = -1 }, "ALPHA4_RANDOM_BASELINE_IN_SESSION_MEMORY_INVALID"),
    @("alpha4-random-in-session-pss", { param($r) $r.fixtures[0].inSessionMemory.totalPssBytes = 0 }, "ALPHA4_RANDOM_BASELINE_IN_SESSION_MEMORY_INVALID"),
    @("alpha4-random-burst-publish", { param($r) $r.fixtures[0].burst.nonTargetPublishedCount = 1 }, "ALPHA4_RANDOM_BASELINE_BURST_CONTRACT_MISMATCH"),
    @("alpha4-random-stale-before-swap", { param($r) $r.fixtures[0].staleBeforeSwapCount = 1 }, "ALPHA4_RANDOM_BASELINE_SAFETY_COUNTER_NONZERO"),
    @("alpha4-random-swap-failure", { param($r) $r.fixtures[0].swapFailureCount = 1 }, "ALPHA4_RANDOM_BASELINE_SAFETY_COUNTER_NONZERO"),
    @("alpha4-random-surface-invalid", { param($r) $r.fixtures[0].surfaceInvalidCount = 1 }, "ALPHA4_RANDOM_BASELINE_SAFETY_COUNTER_NONZERO"),
    @("alpha4-random-publication-invariant", { param($r) $r.fixtures[0].publicationInvariantViolationCount = 1 }, "ALPHA4_RANDOM_BASELINE_SAFETY_COUNTER_NONZERO"),
    @("alpha4-random-metric-pretended", { param($r) $r.fixtures[0].targets[10].acceptedToFirstDecoderOutputUs = 99 }, "ALPHA4_RANDOM_BASELINE_UNAVAILABLE_METRIC_NOT_NULL"),
    @("alpha4-random-direction-drift", { param($r) $r.fixtures[0].targets[10].direction = "reverse" }, "ALPHA4_RANDOM_BASELINE_DIRECTION_MISMATCH"),
    @("alpha4-random-previous-sync-drift", { param($r) $r.fixtures[0].targets[10].targetSampleOrdinal = 250 }, "ALPHA4_RANDOM_BASELINE_PREVIOUS_SYNC_MISMATCH"),
    @("alpha4-random-published-displayed-drift", { param($r) $r.fixtures[0].targets[10].publishedDisplayedFrameIndex += 1 }, "ALPHA4_RANDOM_BASELINE_TARGET_CONTRACT_MISMATCH"),
    @("alpha4-random-accepted-measurement-drift", { param($r) $r.fixtures[0].targets[10].acceptedDisplayedMeasurement = "CURRENT_STATE" }, "ALPHA4_RANDOM_BASELINE_TARGET_CONTRACT_MISMATCH"),
    @("alpha4-random-sync-sample-drift", { param($r) $r.fixtures[0].syncSamples[1].sampleOrdinal = 201 }, "ALPHA4_RANDOM_BASELINE_PREVIOUS_SYNC_MISMATCH"),
    @("alpha4-random-target-file-generation", { param($r) $r.fixtures[0].targets[25].fileGeneration += 1 }, "ALPHA4_RANDOM_BASELINE_TARGET_GENERATION_MISMATCH"),
    @("alpha4-random-target-request-generation", { param($r) $r.fixtures[0].targets[25].requestGeneration = $r.fixtures[0].targets[24].requestGeneration }, "ALPHA4_RANDOM_BASELINE_TARGET_GENERATION_MISMATCH"),
    @("alpha4-random-burst-accepted-count", { param($r) $r.fixtures[0].burst.acceptedRequestCount = 9 }, "ALPHA4_RANDOM_BASELINE_BURST_CONTRACT_MISMATCH"),
    @("alpha4-random-burst-generation-order", { param($r) $r.fixtures[0].burst.acceptedRequestGenerations[5] = 54 }, "ALPHA4_RANDOM_BASELINE_BURST_GENERATION_MISMATCH"),
    @("alpha4-random-burst-file-generation", { param($r) $r.fixtures[0].burst.fileGeneration += 1 }, "ALPHA4_RANDOM_BASELINE_BURST_FILE_GENERATION_MISMATCH"),
    @("alpha4-random-burst-after-measured-generation", { param($r) $r.fixtures[0].burst.acceptedRequestGenerations = @(91,92,93,94,95,96,97,98,99,100); $r.fixtures[0].burst.requestGeneration = 100 }, "ALPHA4_RANDOM_BASELINE_BURST_FINAL_GENERATION_MISMATCH"),
    @("alpha4-random-burst-window", { param($r) $r.fixtures[0].burst.assessmentWindowStartElapsedRealtimeNs -= 1 }, "ALPHA4_RANDOM_BASELINE_BURST_CONTRACT_MISMATCH"),
    @("alpha4-random-burst-post-final-publish", { param($r) $r.fixtures[0].burst.nonFinalPublishedAfterFinalAcceptanceCount = 1 }, "ALPHA4_RANDOM_BASELINE_BURST_CONTRACT_MISMATCH"),
    @("alpha4-random-uri-leak", { param($r) $r | Add-Member -NotePropertyName contentUri -NotePropertyValue "content://private/video" }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"),
    @("alpha4-random-video-uri-leak", { param($r) $r | Add-Member -NotePropertyName videoUri -NotePropertyValue "file://private/video" }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"),
    @("alpha4-random-source-hash-leak", { param($r) $r | Add-Member -NotePropertyName sourceHash -NotePropertyValue ("a" * 64) }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"),
    @("alpha4-random-path-leak", { param($r) $r | Add-Member -NotePropertyName leaked -NotePropertyValue "C:\\private\\video.mp4" }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"),
    @("alpha4-random-display-name-leak", { param($r) $r | Add-Member -NotePropertyName displayName -NotePropertyValue "private" }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT"),
    @("alpha4-random-android-data-path-leak", { param($r) $r | Add-Member -NotePropertyName leaked -NotePropertyValue "/data/user/0/private/video.mkv" }, "ALPHA4_RANDOM_BASELINE_MEDIA_IDENTIFIER_PRESENT")
  )) {
    $caseName = [string]$case[0]
    $mutate = [scriptblock]$case[1]
    $expectedFailure = [string]$case[2]
    Invoke-HostTest $caseName {
      $report = Copy-TestValue $alpha4Report
      & $mutate $report
      $caught = $null
      try {
        Assert-CcrAlpha4RandomBaselineReport $report $artifactSet.RuntimeSourceSha `
          $artifactSet.RuntimeInputsTreeSha256 $artifactSet.HarnessSourceSha `
          $artifactSet.Artifacts.debugApp.sha256 $artifactSet.Artifacts.debugTest.sha256 | Out-Null
      } catch { $caught = $_.Exception.Message }
      if ($caught -notmatch [regex]::Escape($expectedFailure)) { throw "unexpected rejection: $caught" }
    }.GetNewClosure()
  }

  Invoke-HostTest "alpha4-random-trace-valid" {
    $tracePath = Join-Path $testRoot "alpha4-random-valid.atrace"
    Write-Alpha4RandomTestTrace $tracePath $alpha4Report
    $timings = @(Get-CcrAlpha4TraceStageTiming $tracePath $alpha4Report)
    if ($timings.Count -ne 250 -or @($timings | Where-Object { $_.decoderStageStatus -eq "MEASURED" }).Count -ne 200 -or
        @($timings | Where-Object { $_.decoderStageStatus -eq "NOT_APPLICABLE_CACHE_HIT" }).Count -ne 50) {
      throw "unexpected trace timing counts"
    }
    $traceSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $tracePath).Hash.ToLowerInvariant()
    $merged = Merge-CcrAlpha4TraceStageTiming $alpha4Report $timings $traceSha
    Assert-CcrAlpha4MergedBaselineReport $merged | Out-Null
    if ($merged.baselineCompleteness -cne "COMPLETE_TRACE_MERGED" -or
        $merged.successfulPublicationTimingSource -cne "PublicationEvent.elapsedRealtimeNs" -or
        $merged.publishTraceMarkerMeaning -cne "section-start-only; not used as successful-publication timestamp" -or
        [long]$merged.fixtures[0].targets[10].acceptedToFirstDecoderOutputUs -ne 100L -or
        [long]$merged.fixtures[0].targets[10].acceptedToTargetOutputUs -ne 200L) {
      throw "trace merge did not materialize decoder stage metrics"
    }
  }

  Invoke-HostTest "alpha4-random-trace-missing-target-stage" {
    $tracePath = Join-Path $testRoot "alpha4-random-missing-stage.atrace"
    Write-Alpha4RandomTestTrace $tracePath $alpha4Report
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($tracePath)) {
      if ($line -match 'CCR\.output\.target f=1 r=22 ') { continue }
      $lines.Add($line) | Out-Null
    }
    [System.IO.File]::WriteAllLines($tracePath, [string[]]$lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
    $caught = $null
    try { Get-CcrAlpha4TraceStageTiming $tracePath $alpha4Report | Out-Null } catch { $caught = $_.Exception.Message }
    if ($caught -notmatch "ALPHA4_RANDOM_BASELINE_TRACE_DECODER_STAGE_MISMATCH") { throw "unexpected rejection: $caught" }
  }

  Invoke-HostTest "alpha4-baseline-script-parser-and-contracts" {
    foreach ($fileName in @(
      "alpha4-baseline-contract.ps1", "run-s24-alpha4-random-baseline.ps1",
      "run-s24-alpha4-navigation-baseline.ps1", "run-s24-navigation-perf.ps1"
    )) {
      $parseErrors = $null
      [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $fileName), [ref]$null, [ref]$parseErrors
      ) | Out-Null
      if (@($parseErrors).Count -ne 0) { throw "PowerShell parse failed: $fileName :: $($parseErrors -join ' | ')" }
    }
    $randomSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha4-random-baseline.ps1"))
    $combinedSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-alpha4-navigation-baseline.ps1"))
    $perfSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-s24-navigation-perf.ps1"))
    foreach ($contract in @(
      'Invoke-CcrPinnedPreflight', 'Install-CcrPinnedArtifactSet $context "Debug"',
      'Start-CcrAlpha4RandomTrace', 'Stop-CcrAlpha4RandomTrace', 'Get-CcrAlpha4TraceStageTiming',
      'Invoke-CcrPinnedCleanup', 'Assert-CcrAlpha4RandomSettingsRestored', 'PENDING_BLOCKS_ALPHA5',
      'Invoke-CcrAlpha4TimedInstrumentation', 'MaxMinutes', 'COMPLETE_TRACE_MERGED',
      'Invoke-CcrAlpha4NodeReportValidation', 'deterministicNodeContractValidation',
      'deterministicPilotRandomSeekAlpha4Baseline',
      'alpha4-random-source-equivalent-timing-baseline',
      'alpha4-random-source-equivalent-timing-stage-timing',
      'memoryMeasurement', 'inSessionMemory', 'timingBaselineOnly', '$Resume',
      'checkpoint-alpha4-random-00-session.json', 'savedSettings',
      'WHOLE_INSTRUMENTATION_NEW_RUN_ID', 'COMPLETE_PASS_AND_ALL_EVIDENCE_SHA_REVALIDATED',
      'prior-incomplete-pass', 'prior-incomplete'
    )) { if (-not $randomSource.Contains($contract)) { throw "random baseline contract missing: $contract" } }
    foreach ($contract in @(
      'checkpoint-00-preflight.json', 'checkpoint-01-random-pass.json', 'checkpoint-02-reverse-pass.json',
      'checkpoint-failed.json', 'MaxMinutes', '$Resume',
      'whole-instrumentation-restart; complete-pass-evidence-only-reuse',
      'checkpoint-alpha4-random-00-session.json', 'Assert-CcrAlpha4BaselineFile',
      'randomMemoryMeasurement', 'randomInSessionMemory'
    )) {
      if (-not $combinedSource.Contains($contract)) { throw "combined baseline contract missing: $contract" }
    }
    foreach ($contract in @(
      'Alpha4Reverse', 'hold1080MinusOneAlpha4Baseline', 'hold1080MinusFiveAlpha4Baseline',
      'MEASURED_NOT_GATED', 'Invoke-CcrAlpha4TimedInstrumentation', 'requestStageTraceMetrics',
      '$Resume', 'COMPLETE_THREE_ITERATIONS_ONLY', 'Assert-CcrPerfFileIdentity',
      'Save-CcrPerfFailureArtifacts', 'failureArtifacts', 'failureCheckpoint', 'failedAttemptSuccessCounted'
    )) {
      if (-not $perfSource.Contains($contract)) { throw "reverse baseline contract missing: $contract" }
    }
    foreach ($forbidden in @('gradlew', 'assemble', 'bundleInternal', 'connectedAndroidTest')) {
      if ($randomSource -match [regex]::Escape($forbidden) -or $combinedSource -match [regex]::Escape($forbidden) -or
          $perfSource -match [regex]::Escape($forbidden)) {
        throw "baseline wrapper contains forbidden build command: $forbidden"
      }
    }
  }
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
  throw "S24 pinned artifact host tests failed ($($failures.Count)): $($failures -join ' || ')"
}
Write-Output "S24 pinned artifact host tests passed: $passes"
