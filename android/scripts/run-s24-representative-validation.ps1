param(
  [switch]$RunLongMemory,
  [switch]$RunLifecycle,
  [ValidateRange(1, 15)]
  [int]$MemoryMinutes = 15,
  [ValidateRange(1, 1000)]
  [int]$SwitchIterations = 500,
  [ValidateRange(1, 10)]
  [int]$IdleMinutes = 10,
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$androidRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $androidRoot "build\reports\representative-resolution" }
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

function Invoke-CheckedTest {
  param([string]$ClassName, [hashtable]$Arguments = @{})
  $command = @("-s", $serial, "shell", "am", "instrument", "-w", "-r", "-e", "class", $ClassName)
  foreach ($entry in $Arguments.GetEnumerator()) { $command += @("-e", [string]$entry.Key, [string]$entry.Value) }
  $command += $runner
  $output = @(& $adb @command)
  $text = $output -join "`n"
  $output | Write-Output
  if ($LASTEXITCODE -ne 0 -or $text -notmatch "OK \(1 test\)") {
    throw "REPRESENTATIVE_INSTRUMENTATION_FAILED: $ClassName"
  }
}

function Copy-Report {
  param([string]$Name)
  $lines = @(& $adb -s $serial exec-out run-as $appPackage cat "files/$Name")
  if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw "REPRESENTATIVE_REPORT_PULL_FAILED: $Name" }
  $text = $lines -join "`n"
  if ($text -match '[A-Za-z]:\\' -or $text -match '/(?:Users|home)/') {
    throw "REPRESENTATIVE_REPORT_PATH_FOUND: $Name"
  }
  $json = $text | ConvertFrom-Json
  if ($json.syntheticOnly -ne $true -or $json.containsRealMediaMetadata -ne $false) {
    throw "REPRESENTATIVE_REPORT_PRIVACY_MISMATCH: $Name"
  }
  [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $OutputDirectory $Name), $text, [System.Text.UTF8Encoding]::new($false))
}

function Wait-Wakefulness {
  param([ValidateSet("Awake", "NotAwake")][string]$Expected)
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    $power = (& $adb -s $serial shell dumpsys power) -join "`n"
    $isAwake = $power -match "mWakefulness=Awake"
    if (($Expected -eq "Awake" -and $isAwake) -or ($Expected -eq "NotAwake" -and -not $isAwake)) { return }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "WAKEFULNESS_TIMEOUT: $Expected"
}

function Invoke-LifecycleMatrix {
  $method = "com.snowberried.ctcinereviewer.ViewerLifecycleTest#decodeDuringRotationAndRepeatedBackgroundRestorePublishRequestedFrame"
  $runs = 50
  for ($iteration = 1; $iteration -le $runs; $iteration += 1) {
    Invoke-CheckedTest $method
  }

  Wait-Wakefulness "Awake"
  for ($iteration = 1; $iteration -le 30; $iteration += 1) {
    & $adb -s $serial shell input keyevent 26 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SCREEN_OFF_COMMAND_FAILED" }
    Wait-Wakefulness "NotAwake"
    & $adb -s $serial shell input keyevent 26 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SCREEN_ON_COMMAND_FAILED" }
    Wait-Wakefulness "Awake"
  }

  [PSCustomObject]@{
    status = "INCONCLUSIVE_RESOURCE_PLATEAU"
    lifecycleInstrumentationRuns = $runs
    rotations = 100
    rotationCorrectness = "PASS"
    homeResume = 150
    homeResumeCorrectness = "PASS"
    surfaceDetachReattach = 150
    surfaceDetachReattachCorrectness = "PASS"
    screenOffOn = 30
    screenPowerCorrectness = "PASS_POWER_STATE_ONLY"
    resourcePlateau = "INCONCLUSIVE_NO_PER_CYCLE_RESOURCE_REPORT"
    note = "Each lifecycle instrumentation run performs 2 rotations and 3 CREATED-RESUMED Surface detach/reattach cycles. Screen power cycles verify wakefulness only; no resource plateau is claimed."
  }
}

$failure = $null
try {
  Push-Location $androidRoot
  try {
    & .\gradlew.bat assembleInternalDebug assembleInternalDebugAndroidTest
    if ($LASTEXITCODE -ne 0) { throw "REPRESENTATIVE_BUILD_FAILED" }
  } finally { Pop-Location }

  & $adb -s $serial uninstall $testPackage | Out-Null
  & $adb -s $serial install -r $appApk
  if ($LASTEXITCODE -ne 0) { throw "REPRESENTATIVE_APP_INSTALL_FAILED" }
  & $adb -s $serial install -r $testApk
  if ($LASTEXITCODE -ne 0) { throw "REPRESENTATIVE_TEST_INSTALL_FAILED" }

  Invoke-CheckedTest "com.snowberried.ctcinereviewer.gate.S24RepresentativeResolutionAccuracyTest"
  Copy-Report "representative-resolution-exact-report.json"
  Invoke-CheckedTest "com.snowberried.ctcinereviewer.gate.RepresentativeCachePressureTest"
  Copy-Report "representative-cache-pressure-report.json"

  if ($RunLongMemory) {
    Invoke-CheckedTest `
      "com.snowberried.ctcinereviewer.gate.RepresentativeMemoryEnduranceTest#single1080pCachePressureWhenRequested" `
      @{ representativeMemoryMinutes = $MemoryMinutes }
    Copy-Report "representative-memory-report.json"
    Invoke-CheckedTest `
      "com.snowberried.ctcinereviewer.gate.RepresentativeMemoryEnduranceTest#codecSwitchWhenRequested" `
      @{ representativeSwitchIterations = $SwitchIterations }
    Copy-Report "representative-codec-switch-report.json"
    Invoke-CheckedTest `
      "com.snowberried.ctcinereviewer.gate.RepresentativeMemoryEnduranceTest#idleActivityRemainsZeroWhenRequested" `
      @{ representativeIdleMinutes = $IdleMinutes }
    Copy-Report "representative-idle-report.json"
  }
  $lifecycleResult = if ($RunLifecycle) { Invoke-LifecycleMatrix } else { $null }
} catch {
  $failure = $_
} finally {
  & $adb -s $serial uninstall $testPackage | Out-Null
}

if ($failure) { throw $failure }
[PSCustomObject]@{
  status = "PASS"
  model = $model
  exactSubset = "PASS"
  cachePressure = "PASS"
  longMemory = if ($RunLongMemory) { "INCONCLUSIVE - correctness passed; inspect plateau samples" } else { "Pending - not requested" }
  lifecycle = if ($RunLifecycle) { $lifecycleResult } else { "Pending - not requested" }
  reports = $OutputDirectory
  testPackageInstalled = $false
} | ConvertTo-Json
