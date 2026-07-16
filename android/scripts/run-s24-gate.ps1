param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $androidRoot
$expectedVersionName = "0.2.0-alpha.4"
$expectedVersionCode = 5
$dirty = @(& git -C $repoRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw "ANDROID_WORKTREE_STATUS_UNAVAILABLE" }
if ($dirty.Count -ne 0) { throw "S24_CLEAN_WORKTREE_REQUIRED" }
$head = (& git -C $repoRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch "^[a-f0-9]{40}$") { throw "ANDROID_COMMIT_SHA_UNAVAILABLE" }
$env:CCR_ANDROID_COMMIT_SHA = $head
$sdkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$adb = Join-Path $sdkRoot "platform-tools\adb.exe"
if (-not (Test-Path -LiteralPath $adb)) { throw "ADB_NOT_FOUND" }

$devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" })
if ($devices.Count -ne 1) { throw "EXACTLY_ONE_ANDROID_DEVICE_REQUIRED" }
$serial = ($devices[0] -split "\s+")[0]
$model = (& $adb -s $serial shell getprop ro.product.model).Trim()
if ($model -notlike "SM-S928*") { throw "S24_ULTRA_SM_S928_REQUIRED: $model" }

$appPackage = "com.snowberried.ctcinereviewer.internal"
$testPackage = "$appPackage.test"
$testClass = "com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest"
$runner = "$testPackage/androidx.test.runner.AndroidJUnitRunner"
$appApk = Join-Path $androidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
$testApk = Join-Path $androidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"

function Assert-Zero([object]$Value, [string]$Failure) {
  if ($null -eq $Value -or [long]$Value -ne 0) { throw $Failure }
}

function Assert-ReportIdentity([object]$Report, [string]$Kind, [string]$AppSha, [string]$TestSha) {
  if (-not $Report -or $Report.status -ne "PASS" -or $Report.kind -ne $Kind) { throw "S24_REPORT_STATUS_MISMATCH: $Kind" }
  if ($Report.syntheticOnly -ne $true -or $Report.containsRealMediaMetadata -ne $false) {
    throw "S24_REPORT_PRIVACY_MISMATCH: $Kind"
  }
  if ($Report.appVersionName -ne $expectedVersionName -or [int]$Report.appVersionCode -ne $expectedVersionCode) {
    throw "S24_REPORT_VERSION_MISMATCH: $Kind"
  }
  if ($Report.appCommitSha -ne $head -or $Report.appSha256 -ne $AppSha -or $Report.testApkSha256 -ne $TestSha) {
    throw "S24_REPORT_ARTIFACT_IDENTITY_MISMATCH: $Kind"
  }
  if ([int]$Report.device.displayWidth -le 0 -or [int]$Report.device.displayHeight -le 0 -or [double]$Report.device.refreshRate -le 0) {
    throw "S24_REPORT_DISPLAY_MISSING: $Kind"
  }
  Assert-Zero $Report.mismatchCount "S24_REPORT_MISMATCH_NONZERO: $Kind"
  Assert-Zero $Report.writeOpenCount "S24_REPORT_WRITE_OPEN_NONZERO: $Kind"
  foreach ($field in @(
    "staleDiscard", "staleBeforeSwap", "swapFailures", "surfaceInvalid",
    "publicationInvariantViolations", "cacheRejectionCount", "cacheThrashCount", "textureDoubleReleaseCount"
  )) {
    Assert-Zero $Report.gateCounters.$field "S24_REPORT_GATE_COUNTER_NONZERO: $Kind/$field"
  }
}

if (-not $OutputPath) {
  $OutputPath = "android\reports\s24-frame-accuracy-report.json"
}
$resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
$reportDirectory = Split-Path -Parent $resolvedOutput
$sequentialOutput = Join-Path $reportDirectory "s24-forward-sequential-report.json"
$summaryOutput = Join-Path $reportDirectory "s24-gate-summary.json"
[System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
foreach ($staleOutput in @($resolvedOutput, $sequentialOutput, $summaryOutput)) {
  if (Test-Path -LiteralPath $staleOutput) { Remove-Item -LiteralPath $staleOutput -Force }
}

$gateFailure = $null
$cleanupFailure = $null
$gateResult = $null
try {
  Push-Location $androidRoot
  try {
    & .\gradlew.bat assembleInternalDebug assembleInternalDebugAndroidTest
    if ($LASTEXITCODE -ne 0) { throw "S24_BUILD_FAILED" }
  } finally {
    Pop-Location
  }
  if (-not (Test-Path -LiteralPath $appApk) -or -not (Test-Path -LiteralPath $testApk)) {
    throw "S24_APK_OUTPUT_MISSING"
  }
  $appApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $appApk).Hash.ToLowerInvariant()
  $testApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $testApk).Hash.ToLowerInvariant()

  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "S24_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "S24_TEST_INSTALL_FAILED" }
  & $adb -s $serial shell run-as $appPackage rm -f "files/s24-frame-accuracy-report.json"
  if ($LASTEXITCODE -ne 0) { throw "S24_STALE_REPORT_CLEAR_FAILED" }
  & $adb -s $serial shell run-as $appPackage rm -f "files/s24-forward-sequential-report.json"
  if ($LASTEXITCODE -ne 0) { throw "S24_STALE_SEQUENTIAL_REPORT_CLEAR_FAILED" }

  $instrumentation = @(& $adb -s $serial shell am instrument -w -r -e class $testClass $runner)
  $instrumentationExitCode = $LASTEXITCODE
  $instrumentationText = $instrumentation -join "`n"
  $instrumentation | Write-Output
  $instrumentationPassed = $instrumentationExitCode -eq 0 -and $instrumentationText -match "OK \([1-9][0-9]* tests?\)"

  $reportLines = @(& $adb -s $serial exec-out run-as $appPackage cat "files/s24-frame-accuracy-report.json")
  $reportExitCode = $LASTEXITCODE
  $reportText = $reportLines -join "`n"
  $reportJson = if ($reportExitCode -eq 0 -and $reportText) {
    try { $reportText | ConvertFrom-Json } catch { $null }
  } else {
    $null
  }
  if ($reportJson) {
    [System.IO.File]::WriteAllText($resolvedOutput, $reportText, [System.Text.UTF8Encoding]::new($false))
  }

  $sequentialLines = @(& $adb -s $serial exec-out run-as $appPackage cat "files/s24-forward-sequential-report.json")
  $sequentialExitCode = $LASTEXITCODE
  $sequentialText = $sequentialLines -join "`n"
  $sequentialJson = if ($sequentialExitCode -eq 0 -and $sequentialText) {
    try { $sequentialText | ConvertFrom-Json } catch { $null }
  } else {
    $null
  }
  if ($sequentialJson) {
    [System.IO.File]::WriteAllText($sequentialOutput, $sequentialText, [System.Text.UTF8Encoding]::new($false))
  }

  if (-not $instrumentationPassed) { throw "S24_INSTRUMENTATION_FAILED" }
  if (-not $reportJson) { throw "S24_REPORT_PULL_FAILED" }
  if (-not $sequentialJson) { throw "S24_SEQUENTIAL_REPORT_PULL_FAILED" }
  Assert-ReportIdentity $reportJson "frame-accuracy-exact" $appApkSha256 $testApkSha256
  Assert-ReportIdentity $sequentialJson "forward-sequential-exact" $appApkSha256 $testApkSha256

  $fullFixtures = @($reportJson.fixtures)
  $fullFrameCount = [long](($fullFixtures | Measure-Object -Property frameCount -Sum).Sum)
  if ($fullFixtures.Count -ne 17 -or $fullFrameCount -ne 236) {
    throw "S24_FULL_FIXTURE_COUNT_MISMATCH"
  }
  foreach ($fixture in $fullFixtures) {
    if ($fixture.sourceSha256 -notmatch "^[a-f0-9]{64}$" -or -not $fixture.codec -or
        -not $fixture.profile -or -not $fixture.codecComponent -or $fixture.hardwareAccelerated -ne $true) {
      throw "S24_FULL_FIXTURE_METADATA_MISMATCH"
    }
  }

  $sequentialFixtures = @($sequentialJson.fixtures)
  $sequentialFrameCount = [long](($sequentialFixtures | Measure-Object -Property frameCount -Sum).Sum)
  if ($sequentialFixtures.Count -ne 3 -or $sequentialFrameCount -ne 68) {
    throw "S24_SEQUENTIAL_FIXTURE_COUNT_MISMATCH"
  }
  foreach ($fixture in $sequentialFixtures) {
    if ($fixture.sourceSha256 -notmatch "^[a-f0-9]{64}$" -or -not $fixture.codec -or
        -not $fixture.profile -or -not $fixture.codecComponent -or $fixture.hardwareAccelerated -ne $true) {
      throw "S24_SEQUENTIAL_FIXTURE_METADATA_MISMATCH"
    }
  }

  $sequentialRuns = @($sequentialJson.forwardSequentialRuns)
  $sequentialTargetCount = [long](($sequentialRuns | Measure-Object -Property requestCount -Sum).Sum)
  $actualRunKeys = ($sequentialRuns | ForEach-Object { "$($_.fixture):$([int]$_.stride)" } | Sort-Object) -join ","
  $expectedRunKeys = @(
    "h264-bframes.mp4:1", "h264-bframes.mp4:5", "long-gop.mp4:1",
    "long-gop.mp4:5", "vfr.mp4:1", "vfr.mp4:5"
  ) | Sort-Object
  if ($sequentialRuns.Count -ne 6 -or $sequentialTargetCount -ne 77 -or $actualRunKeys -ne ($expectedRunKeys -join ",")) {
    throw "S24_SEQUENTIAL_RUN_COUNT_MISMATCH"
  }
  foreach ($run in $sequentialRuns) {
    Assert-Zero $run.mismatchCount "S24_SEQUENTIAL_RUN_MISMATCH_NONZERO"
    if ([long]$run.sequentialEntryCount -le 0 -or [long]$run.sequentialOutputCount -le 0) {
      throw "S24_SEQUENTIAL_PATH_NOT_EXERCISED"
    }
  }

  $summary = [ordered]@{
    schemaVersion = 1
    status = "PASS"
    model = $model
    commitSha = $head
    versionName = $expectedVersionName
    versionCode = $expectedVersionCode
    appApkSha256 = $appApkSha256
    testApkSha256 = $testApkSha256
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    fullFixtureCount = $fullFixtures.Count
    fullFrameCount = $fullFrameCount
    sequentialRunCount = $sequentialRuns.Count
    sequentialTargetCount = $sequentialTargetCount
    reports = @([System.IO.Path]::GetFileName($resolvedOutput), [System.IO.Path]::GetFileName($sequentialOutput))
  }
  [System.IO.File]::WriteAllText(
    $summaryOutput,
    ($summary | ConvertTo-Json -Depth 4),
    [System.Text.UTF8Encoding]::new($false)
  )
  $gateResult = @($resolvedOutput, $sequentialOutput, $summaryOutput)
} catch {
  $gateFailure = $_
} finally {
  & $adb -s $serial uninstall $testPackage | Out-Null
  $remainingTestPackages = @(& $adb -s $serial shell pm list packages --user 0 $testPackage)
  if ($LASTEXITCODE -ne 0) {
    $cleanupFailure = "S24_TEST_PACKAGE_CLEANUP_QUERY_FAILED"
  } elseif ($remainingTestPackages | Where-Object { $_.Trim() -eq "package:$testPackage" }) {
    $cleanupFailure = "S24_TEST_PACKAGE_CLEANUP_FAILED"
  }
}

if ($cleanupFailure) {
  if ($gateFailure) { throw "$cleanupFailure; PRIMARY=$($gateFailure.Exception.Message)" }
  throw $cleanupFailure
}
if ($gateFailure) { throw $gateFailure }
Write-Output $gateResult
