$ErrorActionPreference = "Stop"

$assetName = "ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip"
$releaseTag = "autobuild-2026-06-30-13-34"
$expectedSha256 = "27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da"
$downloadUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$releaseTag/$assetName"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tempRoot = Join-Path $repoRoot "temp"
$archivePath = Join-Path $tempRoot $assetName
$extractPath = Join-Path $tempRoot "ffmpeg-extract"
$destinationPath = Join-Path $repoRoot "tools\ffmpeg"

function Reset-RepoDirectory([string]$Path) {
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoPrefix = $repoRoot.TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a directory outside the repository."
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
}

function Invoke-CapturedProcess([string]$FilePath, [string]$Arguments) {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $Arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start $FilePath."
  }
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "$FilePath exited with code $($process.ExitCode)."
  }
  return ($stdout + $stderr).TrimEnd()
}

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$archiveValid = $false
if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
  $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
  $archiveValid = $existingHash -eq $expectedSha256
}

if (-not $archiveValid) {
  Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
  & curl.exe -L --fail --silent --show-error --output $archivePath $downloadUrl
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to download the pinned FFmpeg archive."
  }
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
  throw "FFmpeg archive checksum mismatch. The archive was not extracted."
}

Reset-RepoDirectory $extractPath
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath

$archiveRoot = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
if (-not $archiveRoot) {
  throw "The FFmpeg archive has no root directory."
}

$sourceBin = Join-Path $archiveRoot.FullName "bin"
$sourceLicense = Join-Path $archiveRoot.FullName "LICENSE.txt"
$requiredFiles = @("ffmpeg.exe", "ffprobe.exe")
foreach ($fileName in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $sourceBin $fileName) -PathType Leaf)) {
    throw "The FFmpeg archive is missing $fileName."
  }
}
if (-not (Test-Path -LiteralPath $sourceLicense -PathType Leaf)) {
  throw "The FFmpeg archive is missing LICENSE.txt."
}

Reset-RepoDirectory $destinationPath
$destinationBin = Join-Path $destinationPath "bin"
$destinationLicenses = Join-Path $destinationPath "licenses"
New-Item -ItemType Directory -Force -Path $destinationBin, $destinationLicenses | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceBin "ffmpeg.exe") -Destination $destinationBin
Copy-Item -LiteralPath (Join-Path $sourceBin "ffprobe.exe") -Destination $destinationBin
Get-ChildItem -LiteralPath $sourceBin -Filter "*.dll" -File | Copy-Item -Destination $destinationBin
Copy-Item -LiteralPath $sourceLicense -Destination (Join-Path $destinationLicenses "LICENSE.txt")

$ffmpegPath = Join-Path $destinationBin "ffmpeg.exe"
$ffprobePath = Join-Path $destinationBin "ffprobe.exe"
$ffmpegVersion = Invoke-CapturedProcess $ffmpegPath "-version"
$ffprobeVersion = Invoke-CapturedProcess $ffprobePath "-version"
$buildConfiguration = Invoke-CapturedProcess $ffmpegPath "-buildconf"
$binFiles = Get-ChildItem -LiteralPath $destinationBin -File | Sort-Object Name | Select-Object -ExpandProperty Name

$versionLines = @(
  "# Local FFmpeg Version",
  "",
  "- Release tag: $releaseTag",
  "- Asset: $assetName",
  "- Upstream: $downloadUrl",
  "- Archive SHA-256: $expectedSha256",
  "- Variant: Windows x64, LGPL shared",
  "- FFmpeg version: n8.1.2-21-gce3c09c101-20260630"
)
$versionLines | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destinationPath "VERSION.md")

"$expectedSha256  $assetName" | Set-Content -Encoding ASCII -LiteralPath (Join-Path $destinationPath "SHA256SUMS.txt")

$buildInfoLines = @("# Local FFmpeg Build Information", "", "## Included runtime files", "")
$buildInfoLines += $binFiles | ForEach-Object { "- $_" }
$buildInfoLines += @(
  "",
  "## ffmpeg -version",
  "",
  '```text',
  $ffmpegVersion,
  '```',
  "",
  "## ffprobe -version",
  "",
  '```text',
  $ffprobeVersion,
  '```',
  "",
  "## ffmpeg -buildconf",
  "",
  '```text',
  $buildConfiguration,
  '```'
)
$buildInfoLines | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destinationPath "BUILDINFO.md")

Write-Output "Pinned FFmpeg setup completed and checksum verified."
