param(
  [string]$Apk = "$PSScriptRoot\..\app\build\outputs\apk\internal\debug\app-internal-debug.apk"
)

$ErrorActionPreference = "Stop"
$resolvedApk = [System.IO.Path]::GetFullPath($Apk)
if (-not (Test-Path -LiteralPath $resolvedApk)) {
  throw "APK not found: $resolvedApk"
}

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$analyzer = Get-ChildItem -LiteralPath (Join-Path $sdk "cmdline-tools") -Recurse -Filter apkanalyzer.bat -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $analyzer) {
  throw "apkanalyzer.bat was not found below the Android SDK"
}

$permissions = & $analyzer manifest permissions $resolvedApk
if ($LASTEXITCODE -ne 0) {
  throw "Failed to inspect APK permissions"
}

$forbidden = @(
  "android.permission.INTERNET",
  "android.permission.READ_MEDIA_VIDEO",
  "android.permission.READ_EXTERNAL_STORAGE",
  "android.permission.WRITE_EXTERNAL_STORAGE",
  "android.permission.MANAGE_EXTERNAL_STORAGE"
)
$found = @($forbidden | Where-Object { $permissions -contains $_ })
if ($found.Count -gt 0) {
  throw "Forbidden APK permissions: $($found -join ', ')"
}

[PSCustomObject]@{
  apk = $resolvedApk
  forbiddenPermissionCount = 0
  declaredPermissions = @($permissions)
} | ConvertTo-Json -Depth 3
