param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $androidRoot
$adb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path -LiteralPath $adb)) { throw "ADB_NOT_FOUND" }

$devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" })
if ($devices.Count -ne 1) { throw "EXACTLY_ONE_ANDROID_DEVICE_REQUIRED" }
$serial = ($devices[0] -split "\s+")[0]
$model = (& $adb -s $serial shell getprop ro.product.model).Trim()
if ($model -notlike "SM-S928*") { throw "S24_ULTRA_SM_S928_REQUIRED: $model" }

Push-Location $androidRoot
try {
  & .\gradlew.bat connectedInternalDebugAndroidTest `
    "-Pandroid.testInstrumentationRunnerArguments.class=com.snowberried.ctcinereviewer.gate.S24FrameAccuracyTest"
  if ($LASTEXITCODE -ne 0) { throw "S24_INSTRUMENTATION_FAILED" }
} finally {
  Pop-Location
}

if (-not $OutputPath) {
  $OutputPath = "android\reports\s24-frame-accuracy-report.json"
}
$resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedOutput)) | Out-Null
$report = & $adb -s $serial exec-out run-as com.snowberried.ctcinereviewer.internal `
  cat "files/s24-frame-accuracy-report.json"
if ($LASTEXITCODE -ne 0 -or -not $report) { throw "S24_REPORT_PULL_FAILED" }
[System.IO.File]::WriteAllLines($resolvedOutput, $report, [System.Text.UTF8Encoding]::new($false))
Write-Output $resolvedOutput
