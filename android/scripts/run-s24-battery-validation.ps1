param(
  [ValidateSet("Prepare", "Collect")]
  [string]$Mode,
  [ValidateSet("idle", "navigation")]
  [string]$Scenario = "idle",
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $androidRoot "build\reports\representative-battery" }
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
$reportName = "representative-battery-$Scenario-report.json"

if ($Mode -eq "Prepare") {
  Push-Location $androidRoot
  try {
    & .\gradlew.bat assembleInternalDebug assembleInternalDebugAndroidTest
    if ($LASTEXITCODE -ne 0) { throw "BATTERY_BUILD_FAILED" }
  } finally { Pop-Location }
  $appApk = Join-Path $androidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
  $testApk = Join-Path $androidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"
  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "BATTERY_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "BATTERY_TEST_INSTALL_FAILED" }
  & $adb -s $serial shell run-as $appPackage rm -f "files/$reportName" | Out-Null
  [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
  $stdout = Join-Path $OutputDirectory "battery-$Scenario.instrumentation.log"
  $stderr = Join-Path $OutputDirectory "battery-$Scenario.instrumentation.err.log"
  $arguments = @(
    "-s", $serial, "shell", "am", "instrument", "-w", "-r",
    "-e", "class", "com.snowberried.ctcinereviewer.gate.RepresentativeBatteryValidationTest",
    "-e", "batteryScenario", $Scenario,
    "-e", "batteryMinutes", "30",
    $runner
  )
  $process = Start-Process -FilePath $adb -ArgumentList $arguments -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
  [PSCustomObject]@{
    status = "READY_TO_UNPLUG"
    processId = $process.Id
    instruction = "At 80-90% battery, unplug USB. The app waits up to 5 minutes, then measures for 30 minutes. Reconnect USB and run -Mode Collect."
    scenario = $Scenario
    drainPassClaimed = $false
  } | ConvertTo-Json
  exit 0
}

$lines = @(& $adb -s $serial exec-out run-as $appPackage cat "files/$reportName")
if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw "BATTERY_REPORT_NOT_READY: $reportName" }
$text = $lines -join "`n"
if ($text -match '[A-Za-z]:\\' -or $text -match '/(?:Users|home)/') { throw "BATTERY_REPORT_PATH_FOUND" }
$report = $text | ConvertFrom-Json
if ($report.status -notin @("EVALUABLE", "NOT_EVALUABLE", "FAIL")) { throw "BATTERY_REPORT_STATUS_INVALID" }
if ($report.syntheticOnly -ne $true -or $report.containsRealMediaMetadata -ne $false) {
  throw "BATTERY_REPORT_PRIVACY_MISMATCH"
}
if ($report.body.drainPassClaimed -ne $false) { throw "BATTERY_DRAIN_PASS_FORBIDDEN" }
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory $reportName), $text, [System.Text.UTF8Encoding]::new($false))
& $adb -s $serial uninstall $testPackage | Out-Null
[PSCustomObject]@{
  status = $report.status
  reason = $report.body.reason
  startBatteryPercent = $report.body.startBatteryPercent
  endBatteryPercent = $report.body.endBatteryPercent
  scenario = $Scenario
  report = (Join-Path $OutputDirectory $reportName)
  drainPassClaimed = $false
  testPackageInstalled = $false
} | ConvertTo-Json
