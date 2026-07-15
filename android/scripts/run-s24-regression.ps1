param(
  [ValidateRange(1, 20)]
  [int]$Repeat = 3
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
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

function Invoke-CheckedInstrumentation {
  param(
    [string]$ClassName,
    [string]$ExpectedOk
  )

  $output = @(& $adb -s $serial shell am instrument -w -r -e class $ClassName $runner)
  $exitCode = $LASTEXITCODE
  $text = $output -join "`n"
  $output | Write-Output
  if ($exitCode -ne 0 -or $text -notmatch [regex]::Escape($ExpectedOk)) {
    throw "S24_REGRESSION_INSTRUMENTATION_FAILED: $ClassName"
  }
}

$stayAwakeBefore = $null
$stayAwakeChanged = $false
$regressionFailure = $null
$cleanupFailure = $null
try {
  Push-Location $androidRoot
  try {
    & .\gradlew.bat assembleInternalDebug assembleInternalDebugAndroidTest
    if ($LASTEXITCODE -ne 0) { throw "S24_REGRESSION_BUILD_FAILED" }
  } finally {
    Pop-Location
  }

  $stayAwakeBefore = (& $adb -s $serial shell settings get global stay_on_while_plugged_in).Trim()
  $stayAwakeChanged = $true
  & $adb -s $serial shell input keyevent KEYCODE_WAKEUP | Out-Null
  & $adb -s $serial shell wm dismiss-keyguard | Out-Null
  & $adb -s $serial shell svc power stayon true | Out-Null
  & $adb -s $serial uninstall $testPackage | Out-Null
  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "S24_REGRESSION_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "S24_REGRESSION_TEST_INSTALL_FAILED" }

  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.gate.PilotRenderingTest" `
    -ExpectedOk "OK (1 test)"
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.NavigationRepeatTest" `
    -ExpectedOk "OK (8 tests)"
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.NavigationHoldIntegrationTest" `
    -ExpectedOk "OK (3 tests)"
  Invoke-CheckedInstrumentation `
    -ClassName "com.snowberried.ctcinereviewer.AdaptiveLayoutTest" `
    -ExpectedOk "OK (1 test)"
  1..$Repeat | ForEach-Object {
    Invoke-CheckedInstrumentation `
      -ClassName "com.snowberried.ctcinereviewer.ViewerLifecycleTest" `
      -ExpectedOk "OK (4 tests)"
  }

  $packageInfo = (& $adb -s $serial shell dumpsys package $appPackage) -join "`n"
  if ($packageInfo -notmatch "versionName=0\.2\.0-alpha\.2" -or $packageInfo -notmatch "versionCode=3\b") {
    throw "S24_REGRESSION_INSTALLED_VERSION_MISMATCH"
  }
} catch {
  $regressionFailure = $_
} finally {
  & $adb -s $serial uninstall $testPackage | Out-Null
  $remainingTestPackages = @(& $adb -s $serial shell pm list packages --user 0 $testPackage)
  if ($LASTEXITCODE -ne 0) {
    $cleanupFailure = "S24_TEST_PACKAGE_CLEANUP_QUERY_FAILED"
  } elseif ($remainingTestPackages | Where-Object { $_.Trim() -eq "package:$testPackage" }) {
    $cleanupFailure = "S24_TEST_PACKAGE_CLEANUP_FAILED"
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
  if ($regressionFailure) { throw "$cleanupFailure; PRIMARY=$($regressionFailure.Exception.Message)" }
  throw $cleanupFailure
}
if ($regressionFailure) { throw $regressionFailure }
& $adb -s $serial shell am start -W -n "$appPackage/com.snowberried.ctcinereviewer.MainActivity" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "S24_INTERNAL_APP_LAUNCH_FAILED" }

[PSCustomObject]@{
  status = "PASS"
  model = $model
  versionName = "0.2.0-alpha.2"
  versionCode = 3
  pilotReadbackGateRuns = 1
  navigationRepeatRuns = 1
  navigationHoldIntegrationRuns = 1
  adaptiveLayoutRuns = 1
  lifecycleRuns = $Repeat
  testPackageInstalled = $false
  internalAppLeftInstalled = $true
} | ConvertTo-Json
