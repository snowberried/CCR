param(
  [Parameter(Mandatory = $true)][string]$ArtifactManifest,
  [Parameter(Mandatory = $true)][string]$ArtifactManifestSha256,
  [Parameter(Mandatory = $true)][string]$RuntimeSourceSha,
  [Parameter(Mandatory = $true)][string]$HarnessSourceSha,
  [Parameter(Mandatory = $true)][string]$RuntimeInputsTreeSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedDebugAppSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$RunId,
  [ValidateRange(1, 30)][int]$MaxMinutes = 10
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$smokeRunner = Join-Path $PSScriptRoot "run-s24-alpha6-fixture-open-smoke.ps1"
$parameters = @{} + $PSBoundParameters
$parameters["Mode"] = "Diagnostic"
& $smokeRunner @parameters
