param(
  [ValidateRange(1, 20)]
  [int]$LifecycleRepeat = 20,
  [switch]$RunEndurance,
  [ValidateRange(1, 30)]
  [int]$EnduranceMinutes = 30,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $androidRoot
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $androidRoot "build\reports\s24-alpha2"
}
if ($RunEndurance -and $EnduranceMinutes -ne 30) {
  throw "ALPHA2_ENDURANCE_REQUIRES_30_MINUTES"
}

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
$runner = "$testPackage/androidx.test.runner.AndroidJUnitRunner"
$appApk = Join-Path $androidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
$testApk = Join-Path $androidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"
$runNonce = [Guid]::NewGuid().ToString("N")
$expectedCommit = (& git -C $repoRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $expectedCommit -notmatch "^[a-f0-9]{40}$") {
  throw "ANDROID_COMMIT_SHA_UNAVAILABLE"
}
$privacyMarker = "SYNTHETIC_FIXTURES_ONLY_NO_SOURCE_IDENTIFIERS"
$expectedVersionName = "0.2.0-alpha.2"
$expectedVersionCode = 3

function Invoke-CheckedInstrumentation {
  param(
    [string]$ClassName,
    [string]$ExpectedOk,
    [hashtable]$Arguments = @{}
  )

  & $adb -s $serial shell am force-stop $appPackage | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "S24_ALPHA2_APP_PROCESS_RESET_FAILED: $ClassName"
  }
  $commandArguments = @("-s", $serial, "shell", "am", "instrument", "-w", "-r", "-e", "class", $ClassName)
  foreach ($entry in $Arguments.GetEnumerator()) {
    $commandArguments += @("-e", [string]$entry.Key, [string]$entry.Value)
  }
  $commandArguments += $runner
  $output = @(& $adb @commandArguments)
  $exitCode = $LASTEXITCODE
  $text = $output -join "`n"
  $output | Write-Output
  if ($exitCode -ne 0 -or $text -notmatch [regex]::Escape($ExpectedOk)) {
    throw "S24_ALPHA2_INSTRUMENTATION_FAILED: $ClassName"
  }
}

function Copy-SanitizedReport {
  param(
    [string]$AppFileName,
    [string]$ExpectedKind
  )

  $content = @(& $adb -s $serial exec-out run-as $appPackage cat "files/$AppFileName")
  if ($LASTEXITCODE -ne 0 -or $content.Count -eq 0) {
    throw "S24_ALPHA2_REPORT_PULL_FAILED: $AppFileName"
  }
  $text = $content -join "`n"
  $report = $text | ConvertFrom-Json
  if ($report.schemaVersion -ne 1) { throw "S24_ALPHA2_REPORT_SCHEMA_MISMATCH: $AppFileName" }
  if ($report.kind -ne $ExpectedKind) { throw "S24_ALPHA2_REPORT_KIND_MISMATCH: $AppFileName" }
  if ($report.status -ne "PASS") { throw "S24_ALPHA2_REPORT_STATUS_MISMATCH: $AppFileName" }
  if ($report.privacyMarker -ne $privacyMarker -or $report.containsRealMediaMetadata -ne $false) {
    throw "S24_ALPHA2_REPORT_PRIVACY_MISMATCH: $AppFileName"
  }
  if ($report.runNonce -ne $runNonce) { throw "S24_ALPHA2_REPORT_NONCE_MISMATCH: $AppFileName" }
  if ([string]$report.appCommitSha -eq "" -or ([string]$report.appCommitSha).ToLowerInvariant() -ne $expectedCommit) {
    throw "S24_ALPHA2_REPORT_COMMIT_MISMATCH: $AppFileName"
  }
  if ($report.appVersionName -ne $expectedVersionName -or [long]$report.appVersionCode -ne $expectedVersionCode) {
    throw "S24_ALPHA2_REPORT_VERSION_MISMATCH: $AppFileName"
  }
  if ([string]$report.appApkSha256 -eq "" -or ([string]$report.appApkSha256).ToLowerInvariant() -ne $appApkSha256) {
    throw "S24_ALPHA2_REPORT_APK_MISMATCH: $AppFileName"
  }
  if (
    $text -match '[A-Za-z]:\\' -or
    $text -match '/(?:Users|home)/' -or
    $text -match '"(?:fileName|path|sourceSha256|sourceHash)"\s*:'
  ) {
    throw "S24_ALPHA2_REPORT_SOURCE_IDENTIFIER_FOUND: $AppFileName"
  }
  $target = Join-Path $OutputDirectory $AppFileName
  [System.IO.File]::WriteAllText($target, $text, [System.Text.UTF8Encoding]::new($false))
  return [System.IO.Path]::GetFileName($target)
}

$stayAwakeBefore = $null
$stayAwakeChanged = $false
$validationFailure = $null
$cleanupFailure = $null
$reports = @()
$startedAt = Get-Date
try {
  Push-Location $androidRoot
  try {
    & .\gradlew.bat assembleInternalDebug assembleInternalDebugAndroidTest
    if ($LASTEXITCODE -ne 0) { throw "S24_ALPHA2_BUILD_FAILED" }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $appApk) -or -not (Test-Path -LiteralPath $testApk)) {
    throw "S24_ALPHA2_APK_NOT_FOUND"
  }
  $appApkSha256 = (Get-FileHash -LiteralPath $appApk -Algorithm SHA256).Hash.ToLowerInvariant()
  $testApkSha256 = (Get-FileHash -LiteralPath $testApk -Algorithm SHA256).Hash.ToLowerInvariant()

  New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
  $stayAwakeBefore = (& $adb -s $serial shell settings get global stay_on_while_plugged_in).Trim()
  $stayAwakeChanged = $true
  & $adb -s $serial shell input keyevent KEYCODE_WAKEUP | Out-Null
  & $adb -s $serial shell wm dismiss-keyguard | Out-Null
  & $adb -s $serial shell svc power stayon true | Out-Null
  & $adb -s $serial uninstall $testPackage | Out-Null
  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "S24_ALPHA2_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "S24_ALPHA2_TEST_INSTALL_FAILED" }
  foreach ($reportName in @("alpha2-file-switch-report.json", "alpha2-endurance-report.json")) {
    & $adb -s $serial shell run-as $appPackage rm -f "files/$reportName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "S24_ALPHA2_STALE_REPORT_CLEAR_FAILED: $reportName" }
  }

  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.NavigationRepeatTest" `
    -ExpectedOk "OK (8 tests)"
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest" `
    -ExpectedOk "OK (3 tests)"
  1..$LifecycleRepeat | ForEach-Object {
    Invoke-CheckedInstrumentation `
      -ClassName "com.snowberried.ctcinereviewer.ViewerLifecycleTest" `
      -ExpectedOk "OK (4 tests)"
  }
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.gate.PilotRenderingTest" `
    -ExpectedOk "OK (1 test)"
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.gate.Alpha2FileSwitchMatrixTest" `
    -ExpectedOk "OK (1 test)" `
    -Arguments @{ switchIterations = 20; runNonce = $runNonce }
  $reports += Copy-SanitizedReport `
    -AppFileName "alpha2-file-switch-report.json" `
    -ExpectedKind "file-switch-matrix"

  if ($RunEndurance) {
    Invoke-CheckedInstrumentation `
      -ClassName "com.snowberried.ctcinereviewer.gate.Alpha2EnduranceTest" `
      -ExpectedOk "OK (1 test)" `
      -Arguments @{ enduranceMinutes = $EnduranceMinutes; runNonce = $runNonce }
    $reports += Copy-SanitizedReport `
      -AppFileName "alpha2-endurance-report.json" `
      -ExpectedKind "product-pilot-endurance"
  }

  # A secure keyguard cannot be bypassed by the test runner. Exercise the physical
  # power cycle only after all Surface-based validation so it cannot hide the app.
  & $adb -s $serial shell input keyevent KEYCODE_SLEEP | Out-Null
  Start-Sleep -Seconds 1
  & $adb -s $serial shell input keyevent KEYCODE_WAKEUP | Out-Null
  Start-Sleep -Seconds 1
  $powerState = (& $adb -s $serial shell dumpsys power) -join "`n"
  if ($powerState -notmatch "mWakefulness=Awake") {
    throw "S24_ALPHA2_SCREEN_WAKE_FAILED"
  }

  $packageInfo = (& $adb -s $serial shell dumpsys package $appPackage) -join "`n"
  if ($packageInfo -notmatch "versionName=0\.2\.0-alpha\.2" -or $packageInfo -notmatch "versionCode=3\b") {
    throw "S24_ALPHA2_INSTALLED_VERSION_MISMATCH"
  }
} catch {
  $validationFailure = $_
} finally {
  & $adb -s $serial uninstall $testPackage | Out-Null
  $remainingTestPackages = @(& $adb -s $serial shell pm list packages --user 0 $testPackage)
  if ($LASTEXITCODE -ne 0) {
    $cleanupFailure = "S24_ALPHA2_TEST_PACKAGE_CLEANUP_QUERY_FAILED"
  } elseif ($remainingTestPackages | Where-Object { $_.Trim() -eq "package:$testPackage" }) {
    $cleanupFailure = "S24_ALPHA2_TEST_PACKAGE_CLEANUP_FAILED"
  }
  if ($stayAwakeChanged) {
    if ($stayAwakeBefore -match "^\d+$") {
      & $adb -s $serial shell settings put global stay_on_while_plugged_in $stayAwakeBefore | Out-Null
    } else {
      & $adb -s $serial shell svc power stayon false | Out-Null
    }
  }
}

if ($cleanupFailure) {
  if ($validationFailure) { throw "$cleanupFailure; PRIMARY=$($validationFailure.Exception.Message)" }
  throw $cleanupFailure
}
if ($validationFailure) { throw $validationFailure }

& $adb -s $serial shell am start -W -n "$appPackage/com.snowberried.ctcinereviewer.MainActivity" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "S24_ALPHA2_INTERNAL_APP_LAUNCH_FAILED" }

[PSCustomObject]@{
  status = "PASS"
  model = $model
  versionName = $expectedVersionName
  versionCode = $expectedVersionCode
  commitSha = $expectedCommit
  runNonce = $runNonce
  appApkSha256 = $appApkSha256
  testApkSha256 = $testApkSha256
  strictGestureRuns = 1
  navigationHoldRuns = 1
  lifecycleRuns = $LifecycleRepeat
  screenPowerCycleRuns = 1
  fileSwitchIterationsPerScenario = 20
  fileSwitchScenarioCount = 6
  enduranceMinutes = if ($RunEndurance) { $EnduranceMinutes } else { 0 }
  enduranceStatus = if ($RunEndurance) { "PASS" } else { "Pending - not requested" }
  reports = $reports
  elapsedMinutes = [Math]::Round(((Get-Date) - $startedAt).TotalMinutes, 2)
  testPackageInstalled = $false
  internalAppLeftInstalled = $true
} | ConvertTo-Json -Depth 3
