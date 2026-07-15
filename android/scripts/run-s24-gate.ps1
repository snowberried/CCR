param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $androidRoot
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

  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "S24_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "S24_TEST_INSTALL_FAILED" }
  & $adb -s $serial shell run-as $appPackage rm -f "files/s24-frame-accuracy-report.json"
  if ($LASTEXITCODE -ne 0) { throw "S24_STALE_REPORT_CLEAR_FAILED" }

  $instrumentation = @(& $adb -s $serial shell am instrument -w -r -e class $testClass $runner)
  $instrumentationExitCode = $LASTEXITCODE
  $instrumentationText = $instrumentation -join "`n"
  $instrumentation | Write-Output
  $instrumentationPassed = $instrumentationExitCode -eq 0 -and $instrumentationText -match "OK \(1 test\)"

  if (-not $OutputPath) {
    $OutputPath = "android\reports\s24-frame-accuracy-report.json"
  }
  $resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedOutput)) | Out-Null
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

  if (-not $instrumentationPassed) { throw "S24_INSTRUMENTATION_FAILED" }
  if (-not $reportJson -or $reportJson.status -ne "PASS") { throw "S24_REPORT_PULL_FAILED" }
  $gateResult = $resolvedOutput
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
