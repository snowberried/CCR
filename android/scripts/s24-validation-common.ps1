$script:CcrExpectedVersionName = "0.2.0-alpha.4"
$script:CcrExpectedVersionCode = 5
$script:CcrAppPackage = "com.snowberried.ctcinereviewer.internal"
$script:CcrTestPackage = "$script:CcrAppPackage.test"
$script:CcrRunner = "$script:CcrTestPackage/androidx.test.runner.AndroidJUnitRunner"

function Save-CcrJson {
  param([string]$Path, [object]$Value)
  $directory = Split-Path -Parent $Path
  if ($directory) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
  [System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($Path),
    ($Value | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Get-CcrSetting {
  param([pscustomobject]$Context, [string]$Namespace, [string]$Name)
  $output = @(& $Context.Adb -s $Context.Serial shell settings get $Namespace $Name)
  if ($LASTEXITCODE -ne 0) { throw "S24_SETTING_READ_FAILED: $Namespace/$Name" }
  ($output -join "`n").Trim()
}

function Set-CcrSetting {
  param([pscustomobject]$Context, [string]$Namespace, [string]$Name, [string]$Value)
  if (-not $Value -or $Value -eq "null") {
    & $Context.Adb -s $Context.Serial shell settings delete $Namespace $Name | Out-Null
  } else {
    & $Context.Adb -s $Context.Serial shell settings put $Namespace $Name $Value | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { throw "S24_SETTING_WRITE_FAILED: $Namespace/$Name" }
}

function Get-CcrBatteryState {
  param([pscustomobject]$Context)
  $text = ((& $Context.Adb -s $Context.Serial shell dumpsys battery) -join "`n")
  if ($LASTEXITCODE -ne 0 -or -not $text) { throw "S24_BATTERY_READ_FAILED" }
  $readBoolean = {
    param([string]$Label)
    $match = [regex]::Match($text, "(?m)^\s*" + [regex]::Escape($Label) + ":\s*(true|false)\s*$")
    $match.Success -and $match.Groups[1].Value -eq "true"
  }
  $readInt = {
    param([string]$Label)
    $match = [regex]::Match($text, "(?m)^\s*" + [regex]::Escape($Label) + ":\s*(-?\d+)\s*$")
    if ($match.Success) { [int]$match.Groups[1].Value } else { $null }
  }
  $usb = & $readBoolean "USB powered"
  $ac = & $readBoolean "AC powered"
  $wireless = & $readBoolean "Wireless powered"
  $status = & $readInt "status"
  $level = & $readInt "level"
  if ($null -eq $status -or $null -eq $level) { throw "S24_BATTERY_PARSE_FAILED" }
  [PSCustomObject]@{
    usbPowered = $usb
    acPowered = $ac
    wirelessPowered = $wireless
    batteryStatus = $status
    level = $level
    pluggedOrCharging = [bool]($usb -or $ac -or $wireless -or ($status -in @(2, 5)))
  }
}

function New-CcrS24Context {
  param([string]$Kind, [string]$OutputDirectory)
  $androidRoot = Split-Path -Parent $PSScriptRoot
  $repoRoot = Split-Path -Parent $androidRoot
  if (-not $OutputDirectory) { $OutputDirectory = Join-Path $androidRoot "build\reports\$Kind" }
  $sdkRoot = if ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
  } elseif ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
  } else {
    Join-Path $env:LOCALAPPDATA "Android\Sdk"
  }
  $env:ANDROID_HOME = $sdkRoot
  $env:ANDROID_SDK_ROOT = $sdkRoot
  $adb = Join-Path $sdkRoot "platform-tools\adb.exe"
  if (-not (Test-Path -LiteralPath $adb)) { throw "ADB_NOT_FOUND" }
  $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" })
  if ($devices.Count -ne 1) { throw "EXACTLY_ONE_ANDROID_DEVICE_REQUIRED" }
  $serial = ($devices[0] -split "\s+")[0]
  $model = (& $adb -s $serial shell getprop ro.product.model).Trim()
  if ($LASTEXITCODE -ne 0) { throw "S24_MODEL_READ_FAILED" }
  if ($model -notlike "SM-S928*") { throw "S24_ULTRA_SM_S928_REQUIRED: $model" }
  $dirty = @(& git -C $repoRoot status --porcelain --untracked-files=normal)
  if ($LASTEXITCODE -ne 0) { throw "ANDROID_WORKTREE_STATUS_UNAVAILABLE" }
  if ($dirty.Count -ne 0) { throw "S24_CLEAN_WORKTREE_REQUIRED" }
  $commit = (& git -C $repoRoot rev-parse HEAD).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $commit -notmatch "^[a-f0-9]{40}$") { throw "ANDROID_COMMIT_SHA_UNAVAILABLE" }
  [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
  $context = [PSCustomObject]@{
    Kind = $Kind
    AndroidRoot = $androidRoot
    RepoRoot = $repoRoot
    OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    Adb = $adb
    Serial = $serial
    Model = $model
    CommitSha = $commit
    AppPackage = $script:CcrAppPackage
    TestPackage = $script:CcrTestPackage
    Runner = $script:CcrRunner
    Settings = $null
    BatteryAtStart = $null
    CleanupFailures = [System.Collections.Generic.List[string]]::new()
  }
  $context.BatteryAtStart = Get-CcrBatteryState $context
  return $context
}

function Enter-CcrDeviceState {
  param([pscustomobject]$Context)
  $Context.Settings = [PSCustomObject]@{
    stayAwake = Get-CcrSetting $Context "global" "stay_on_while_plugged_in"
    brightnessMode = Get-CcrSetting $Context "system" "screen_brightness_mode"
    brightness = Get-CcrSetting $Context "system" "screen_brightness"
    screenTimeout = Get-CcrSetting $Context "system" "screen_off_timeout"
    accelerometerRotation = Get-CcrSetting $Context "system" "accelerometer_rotation"
    userRotation = Get-CcrSetting $Context "system" "user_rotation"
  }
  & $Context.Adb -s $Context.Serial shell input keyevent KEYCODE_WAKEUP | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "S24_WAKE_FAILED" }
  & $Context.Adb -s $Context.Serial shell wm dismiss-keyguard | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "S24_KEYGUARD_DISMISS_FAILED" }
  & $Context.Adb -s $Context.Serial shell svc power stayon true | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "S24_STAY_AWAKE_FAILED" }
}

function Restore-CcrDeviceState {
  param([pscustomobject]$Context)
  if ($null -eq $Context.Settings) { return }
  $settings = @(
    [PSCustomObject]@{ Namespace = "global"; Name = "stay_on_while_plugged_in"; Value = $Context.Settings.stayAwake }
    [PSCustomObject]@{ Namespace = "system"; Name = "screen_brightness_mode"; Value = $Context.Settings.brightnessMode }
    [PSCustomObject]@{ Namespace = "system"; Name = "screen_brightness"; Value = $Context.Settings.brightness }
    [PSCustomObject]@{ Namespace = "system"; Name = "screen_off_timeout"; Value = $Context.Settings.screenTimeout }
    [PSCustomObject]@{ Namespace = "system"; Name = "accelerometer_rotation"; Value = $Context.Settings.accelerometerRotation }
    [PSCustomObject]@{ Namespace = "system"; Name = "user_rotation"; Value = $Context.Settings.userRotation }
  )
  foreach ($setting in $settings) {
    try {
      Set-CcrSetting $Context $setting.Namespace $setting.Name $setting.Value
    } catch {
      $Context.CleanupFailures.Add("RESTORE_FAILED:$($setting.Namespace)/$($setting.Name)") | Out-Null
    }
  }
}

function Remove-CcrTestPackages {
  param([pscustomobject]$Context, [string[]]$AdditionalPackages = @())
  foreach ($packageName in @($Context.TestPackage, $Context.AppPackage)) {
    & $Context.Adb -s $Context.Serial shell am force-stop $packageName | Out-Null
    if ($LASTEXITCODE -ne 0) { $Context.CleanupFailures.Add("FORCE_STOP_FAILED:$packageName") | Out-Null }
  }
  foreach ($packageName in @($Context.TestPackage) + $AdditionalPackages) {
    $installed = @(& $Context.Adb -s $Context.Serial shell pm list packages --user 0 $packageName)
    if ($LASTEXITCODE -ne 0) {
      $Context.CleanupFailures.Add("PACKAGE_QUERY_FAILED:$packageName") | Out-Null
      continue
    }
    if ($installed | Where-Object { $_.Trim() -eq "package:$packageName" }) {
      & $Context.Adb -s $Context.Serial uninstall $packageName | Out-Null
      if ($LASTEXITCODE -ne 0) { $Context.CleanupFailures.Add("UNINSTALL_FAILED:$packageName") | Out-Null }
    }
  }
}

function Invoke-CcrTimedProcess {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [DateTime]$Deadline,
    [string]$Stdout,
    [string]$Stderr,
    [string]$SuccessPattern = "",
    [string]$WorkingDirectory = ""
  )
  if ([DateTime]::UtcNow -ge $Deadline) {
    return [PSCustomObject]@{ status = "TIME_LIMIT"; exitCode = $null; stdout = $Stdout; stderr = $Stderr }
  }
  foreach ($path in @($Stdout, $Stderr)) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
  }
  $start = @{
    FilePath = $FilePath
    ArgumentList = $ArgumentList
    RedirectStandardOutput = $Stdout
    RedirectStandardError = $Stderr
    WindowStyle = "Hidden"
    PassThru = $true
  }
  if ($WorkingDirectory) { $start["WorkingDirectory"] = $WorkingDirectory }
  # Some sandboxed Windows shells inject both Path and PATH. Start-Process rejects that pair.
  $processPath = [Environment]::GetEnvironmentVariable("Path", "Process")
  if ($processPath) {
    [Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    [Environment]::SetEnvironmentVariable("Path", $processPath, "Process")
  }
  try {
    $process = Start-Process @start
  } catch {
    return [PSCustomObject]@{ status = "FAIL"; exitCode = $null; stdout = $Stdout; stderr = $Stderr }
  }
  while (-not $process.HasExited -and [DateTime]::UtcNow -lt $Deadline) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
  }
  if (-not $process.HasExited) {
    & (Join-Path $env:SystemRoot "System32\taskkill.exe") /PID $process.Id /T /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    return [PSCustomObject]@{ status = "TIME_LIMIT"; exitCode = $null; stdout = $Stdout; stderr = $Stderr }
  }
  $process.WaitForExit()
  $text = if (Test-Path -LiteralPath $Stdout) { Get-Content -Raw -Encoding UTF8 -LiteralPath $Stdout } else { "" }
  $success = $process.ExitCode -eq 0 -or
    ($null -eq $process.ExitCode -and $SuccessPattern -and $text -match $SuccessPattern)
  [PSCustomObject]@{
    status = if ($success) { "PASS" } else { "FAIL" }
    exitCode = $process.ExitCode
    stdout = $Stdout
    stderr = $Stderr
  }
}

function Install-CcrDebugTestApks {
  param([pscustomobject]$Context, [DateTime]$Deadline)
  $build = Invoke-CcrTimedProcess `
    (Join-Path $Context.AndroidRoot "gradlew.bat") `
    @("assembleInternalDebug", "assembleInternalDebugAndroidTest", "--no-daemon") `
    $Deadline `
    (Join-Path $Context.OutputDirectory "build.gradle.log") `
    (Join-Path $Context.OutputDirectory "build.gradle.err.log") `
    "(?m)^BUILD SUCCESSFUL" `
    $Context.AndroidRoot
  if ($build.status -eq "TIME_LIMIT") { throw "S24_MAX_MINUTES_REACHED_DURING_BUILD" }
  if ($build.status -ne "PASS") { throw "S24_BUILD_FAILED" }
  $appApk = Join-Path $Context.AndroidRoot "app\build\outputs\apk\internal\debug\app-internal-debug.apk"
  $testApk = Join-Path $Context.AndroidRoot "app\build\outputs\apk\androidTest\internal\debug\app-internal-debug-androidTest.apk"
  $installed = @(& $Context.Adb -s $Context.Serial shell pm list packages --user 0 $Context.TestPackage)
  if ($LASTEXITCODE -ne 0) { throw "S24_TEST_PACKAGE_QUERY_FAILED" }
  if ($installed | Where-Object { $_.Trim() -eq "package:$($Context.TestPackage)" }) {
    & $Context.Adb -s $Context.Serial uninstall $Context.TestPackage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "S24_TEST_PACKAGE_REMOVE_FAILED" }
  }
  $apks = @(
    [PSCustomObject]@{ Stem = "app"; Path = $appApk; Failure = "S24_APP_INSTALL_FAILED" }
    [PSCustomObject]@{ Stem = "test"; Path = $testApk; Failure = "S24_TEST_INSTALL_FAILED" }
  )
  foreach ($apk in $apks) {
    $install = Invoke-CcrTimedProcess `
      $Context.Adb `
      @("-s", $Context.Serial, "install", "-r", $apk.Path) `
      $Deadline `
      (Join-Path $Context.OutputDirectory "install-$($apk.Stem).adb.log") `
      (Join-Path $Context.OutputDirectory "install-$($apk.Stem).adb.err.log") `
      "(?m)^Success\s*$"
    if ($install.status -eq "TIME_LIMIT") { throw "S24_MAX_MINUTES_REACHED_DURING_INSTALL" }
    if ($install.status -ne "PASS") { throw $apk.Failure }
  }
}

function Clear-CcrAppReport {
  param([pscustomobject]$Context, [string]$Name)
  & $Context.Adb -s $Context.Serial shell run-as $Context.AppPackage rm -f "files/$Name" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "S24_STALE_REPORT_CLEAR_FAILED: $Name" }
}

function Copy-CcrAppReport {
  param([pscustomobject]$Context, [string]$Name, [string]$TargetName = $Name)
  $lines = @(& $Context.Adb -s $Context.Serial exec-out run-as $Context.AppPackage cat "files/$Name")
  if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return $false }
  $text = $lines -join "`n"
  if ($text -match '[A-Za-z]:\\' -or $text -match '/(?:Users|home)/') {
    throw "S24_REPORT_SOURCE_IDENTIFIER_FOUND: $Name"
  }
  [System.IO.File]::WriteAllText(
    (Join-Path $Context.OutputDirectory $TargetName),
    $text,
    [System.Text.UTF8Encoding]::new($false)
  )
  return $true
}

function Invoke-CcrInstrumentation {
  param(
    [pscustomobject]$Context,
    [string]$ClassName,
    [hashtable]$Arguments,
    [string]$LogStem,
    [DateTime]$Deadline
  )
  $stdout = Join-Path $Context.OutputDirectory "$LogStem.instrumentation.log"
  $stderr = Join-Path $Context.OutputDirectory "$LogStem.instrumentation.err.log"
  $command = @("-s", $Context.Serial, "shell", "am", "instrument", "-w", "-r", "-e", "class", $ClassName)
  foreach ($entry in $Arguments.GetEnumerator()) { $command += @("-e", [string]$entry.Key, [string]$entry.Value) }
  $command += $Context.Runner
  $process = Start-Process -FilePath $Context.Adb -ArgumentList $command -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
  while (-not $process.HasExited -and [DateTime]::UtcNow -lt $Deadline) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
  }
  if (-not $process.HasExited) {
    & (Join-Path $env:SystemRoot "System32\taskkill.exe") /PID $process.Id /T /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    & $Context.Adb -s $Context.Serial shell am force-stop $Context.TestPackage | Out-Null
    return [PSCustomObject]@{ status = "TIME_LIMIT"; exitCode = $null; stdout = $stdout; stderr = $stderr }
  }
  $process.WaitForExit()
  $text = if (Test-Path -LiteralPath $stdout) { Get-Content -Raw -Encoding UTF8 -LiteralPath $stdout } else { "" }
  $exitAccepted = $process.ExitCode -eq 0 -or $null -eq $process.ExitCode
  [PSCustomObject]@{
    status = if ($exitAccepted -and $text -match "OK \(1 test\)") { "PASS" } else { "FAIL" }
    exitCode = $process.ExitCode
    stdout = $stdout
    stderr = $stderr
  }
}

function Get-CcrBatteryStateSafe {
  param([pscustomobject]$Context)
  try {
    Get-CcrBatteryState $Context
  } catch {
    $Context.CleanupFailures.Add("BATTERY_END_READ_FAILED") | Out-Null
    $null
  }
}

function Complete-CcrCleanup {
  param([pscustomobject]$Context, [string[]]$AdditionalPackages = @())
  Remove-CcrTestPackages $Context $AdditionalPackages
  Restore-CcrDeviceState $Context
  @($Context.CleanupFailures)
}

function Get-CcrCheckpoint {
  param([pscustomobject]$Context, [switch]$Resume)
  $path = Join-Path $Context.OutputDirectory "checkpoint.json"
  if ($Resume) {
    if (-not (Test-Path -LiteralPath $path)) { throw "S24_CHECKPOINT_NOT_FOUND" }
    $value = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    if ($value.kind -ne $Context.Kind -or $value.commitSha -ne $Context.CommitSha -or
        $value.versionName -ne $script:CcrExpectedVersionName -or [int]$value.versionCode -ne $script:CcrExpectedVersionCode) {
      throw "S24_CHECKPOINT_IDENTITY_MISMATCH"
    }
    return $value
  }
  [PSCustomObject]@{
    schemaVersion = 1
    kind = $Context.Kind
    status = "Pending"
    commitSha = $Context.CommitSha
    versionName = $script:CcrExpectedVersionName
    versionCode = $script:CcrExpectedVersionCode
    runNonce = [Guid]::NewGuid().ToString("N")
    completedIterations = 0
    nextIteration = 0
  }
}

function Save-CcrCheckpoint {
  param([pscustomobject]$Context, [object]$Checkpoint)
  Save-CcrJson (Join-Path $Context.OutputDirectory "checkpoint.json") $Checkpoint
}

function Clear-CcrRunArtifacts {
  param(
    [pscustomobject]$Context,
    [string[]]$Names = @(),
    [string[]]$Patterns = @()
  )
  foreach ($name in @("checkpoint.json", "build.gradle.log", "build.gradle.err.log", "install-app.adb.log", "install-app.adb.err.log", "install-test.adb.log", "install-test.adb.err.log") + $Names) {
    $path = Join-Path $Context.OutputDirectory $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  foreach ($pattern in $Patterns) {
    Get-ChildItem -File -LiteralPath $Context.OutputDirectory -Filter $pattern -ErrorAction SilentlyContinue |
      Remove-Item -Force
  }
}

function Test-CcrInstrumentationContract {
  param([string]$SourcePath, [string]$ClassName, [string]$MethodName)
  if (-not (Test-Path -LiteralPath $SourcePath)) { return $false }
  $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $SourcePath
  return $source.Contains("class $ClassName") -and $source.Contains("fun $MethodName(")
}
