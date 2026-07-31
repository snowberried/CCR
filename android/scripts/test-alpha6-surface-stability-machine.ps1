$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$machine = Join-Path $repoRoot (
  "android\app\src\androidTest\java\com\snowberried\ctcinereviewer\gate\" +
  "Alpha6SurfaceStabilityMachine.java"
)
$hostTest = Join-Path $repoRoot "android\tools\Alpha6SurfaceStabilityMachineHostTest.java"
foreach ($path in @($machine, $hostTest)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "ALPHA6_SURFACE_STABILITY_HOST_SOURCE_MISSING:$path"
  }
}

$javaHome = [string]$env:JAVA_HOME
$javac = if (-not [string]::IsNullOrWhiteSpace($javaHome) -and
    (Test-Path -LiteralPath (Join-Path $javaHome "bin\javac.exe") -PathType Leaf)) {
  Join-Path $javaHome "bin\javac.exe"
} else {
  [string](Get-Command javac.exe -ErrorAction Stop).Source
}
$java = if (-not [string]::IsNullOrWhiteSpace($javaHome) -and
    (Test-Path -LiteralPath (Join-Path $javaHome "bin\java.exe") -PathType Leaf)) {
  Join-Path $javaHome "bin\java.exe"
} else {
  [string](Get-Command java.exe -ErrorAction Stop).Source
}

$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempParent "ccr-alpha6-surface-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
  & $javac "-encoding" "UTF-8" "-d" $tempRoot $machine $hostTest
  if ($LASTEXITCODE -ne 0) { throw "ALPHA6_SURFACE_STABILITY_JAVAC_FAILED" }
  & $java "-cp" $tempRoot (
    "com.snowberried.ctcinereviewer.gate.Alpha6SurfaceStabilityMachineHostTest"
  )
  if ($LASTEXITCODE -ne 0) { throw "ALPHA6_SURFACE_STABILITY_HOST_TEST_FAILED" }
} finally {
  $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
  if (-not $resolvedTempRoot.StartsWith(
      $tempParent,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "ALPHA6_SURFACE_STABILITY_TEMP_PATH_FORBIDDEN"
  }
  if (Test-Path -LiteralPath $resolvedTempRoot) {
    Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
  }
}
