$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "s24-pinned-artifacts.ps1")

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
  $mutations = @($adbCalls | Where-Object { $_ -match "(^| )(install|uninstall|push|settings)( |$)| shell am instrument | shell am force-stop | run-as .+ rm " })
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

  $baseIterations = 1..3 | ForEach-Object {
    [PSCustomObject][ordered]@{
      runIteration = $_
      traceIdentity = "benchmark-12345678.scenario.$_"
      counterComplete = $true
      activeMs = 1000
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
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
  throw "S24 pinned artifact host tests failed ($($failures.Count)): $($failures -join ' || ')"
}
Write-Output "S24 pinned artifact host tests passed: $passes"
