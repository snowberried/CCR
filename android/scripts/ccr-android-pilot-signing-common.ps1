$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:CcrCandidateSigningLineage = "ccr-internal-pilot-v1"
$script:CcrCandidateSigningPurpose = "CCR Android internal pilot only"
$script:CcrCandidateSigningAlias = "ccr-internal-pilot-v1"
$script:CcrCandidateArtifactSetRevision = 5
$script:CcrCandidateEnvironmentNames = @(
  "CCR_ANDROID_CANDIDATE_KEYSTORE_PATH",
  "CCR_ANDROID_CANDIDATE_KEYSTORE_PASSWORD",
  "CCR_ANDROID_CANDIDATE_KEY_ALIAS",
  "CCR_ANDROID_CANDIDATE_KEY_PASSWORD",
  "CCR_ANDROID_CANDIDATE_EXPECTED_CERT_SHA256"
)

function Get-CcrCandidateRepoRoot {
  return [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-CcrCandidateSigningDirectory {
  return Join-Path (Get-CcrCandidateRepoRoot) "android\signing"
}

function Get-CcrCandidateDefaultKeyStorePath {
  return Join-Path $env:USERPROFILE "CCR-Secrets\Android\ccr-internal-pilot-v1.jks"
}

function Test-CcrCandidateSha256 {
  param([object]$Value)
  return $null -ne $Value -and ([string]$Value) -cmatch "^[a-f0-9]{64}$"
}

function ConvertFrom-CcrCandidateSecureString {
  param([Parameter(Mandatory = $true)][Security.SecureString]$Value)
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Get-CcrCandidateEnvironmentInputs {
  $values = @{}
  foreach ($name in $script:CcrCandidateEnvironmentNames) {
    $values[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  }
  $configured = @($script:CcrCandidateEnvironmentNames | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$values[$_])
  })
  if ($configured.Count -eq 0) { throw "CANDIDATE_SIGNING_NOT_READY" }
  if ($configured.Count -ne $script:CcrCandidateEnvironmentNames.Count) {
    throw "CANDIDATE_SIGNING_INPUT_INCOMPLETE"
  }
  $expected = ([string]$values["CCR_ANDROID_CANDIDATE_EXPECTED_CERT_SHA256"]).ToLowerInvariant()
  if (-not (Test-CcrCandidateSha256 $expected) -or $expected -ceq ("0" * 64)) {
    throw "CANDIDATE_EXPECTED_CERT_INVALID"
  }
  return [PSCustomObject][ordered]@{
    KeyStorePath = [System.IO.Path]::GetFullPath([string]$values["CCR_ANDROID_CANDIDATE_KEYSTORE_PATH"])
    StorePassword = [string]$values["CCR_ANDROID_CANDIDATE_KEYSTORE_PASSWORD"]
    Alias = [string]$values["CCR_ANDROID_CANDIDATE_KEY_ALIAS"]
    KeyPassword = [string]$values["CCR_ANDROID_CANDIDATE_KEY_PASSWORD"]
    ExpectedCertificateSha256 = $expected
  }
}

function Get-CcrCandidateKeyToolPath {
  $candidates = @()
  if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME "bin\keytool.exe") }
  $candidates += "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe"
  $command = Get-Command keytool.exe -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  foreach ($candidate in $candidates | Select-Object -Unique) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  throw "CANDIDATE_KEYTOOL_MISSING"
}

function Invoke-CcrCandidateProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [hashtable]$SecretEnvironment = @{}
  )
  foreach ($argument in $Arguments) {
    if ([string]$argument -match '"') { throw "CANDIDATE_TOOL_ARGUMENT_QUOTE_FORBIDDEN" }
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = [System.Diagnostics.ProcessStartInfo]@{
    FileName = [System.IO.Path]::GetFullPath($FilePath)
    Arguments = (@($Arguments | ForEach-Object { '"' + [string]$_ + '"' }) -join " ")
    UseShellExecute = $false
    RedirectStandardOutput = $true
    RedirectStandardError = $true
    CreateNoWindow = $true
  }
  foreach ($entry in $SecretEnvironment.GetEnumerator()) {
    $process.StartInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
  }
  try {
    if (-not $process.Start()) { throw "CANDIDATE_TOOL_START_FAILED" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [PSCustomObject]@{
      exitCode = [int]$process.ExitCode
      output = (($stdout.Result + "`n" + $stderr.Result).Trim())
    }
  } finally {
    $process.Dispose()
  }
}

function Get-CcrCandidateCertificateShaFromText {
  param([Parameter(Mandatory = $true)][string]$Text)
  $match = [regex]::Match($Text, "(?im)\bSHA256:\s*([0-9a-f:]{64,95})")
  if (-not $match.Success) { throw "CANDIDATE_CERTIFICATE_PARSE_FAILED" }
  $sha = $match.Groups[1].Value.Replace(":", "").ToLowerInvariant()
  if (-not (Test-CcrCandidateSha256 $sha)) { throw "CANDIDATE_CERTIFICATE_PARSE_FAILED" }
  return $sha
}

function Get-CcrCandidateKeyStoreIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$KeyStorePath,
    [Parameter(Mandatory = $true)][string]$Alias,
    [Parameter(Mandatory = $true)][string]$StorePassword,
    [Parameter(Mandatory = $true)][string]$KeyPassword,
    [string]$KeyToolPath = (Get-CcrCandidateKeyToolPath)
  )
  if (-not (Test-Path -LiteralPath $KeyStorePath -PathType Leaf)) {
    throw "CANDIDATE_KEYSTORE_MISSING"
  }
  $result = Invoke-CcrCandidateProcess -FilePath $KeyToolPath -Arguments @(
    "-list", "-v",
    "-keystore", $KeyStorePath,
    "-alias", $Alias,
    "-storepass:env", "CCR_CANDIDATE_KEYTOOL_STORE_PASSWORD"
  ) -SecretEnvironment @{
    CCR_CANDIDATE_KEYTOOL_STORE_PASSWORD = $StorePassword
  }
  if ($result.exitCode -ne 0) { throw "CANDIDATE_ALIAS_MISSING" }
  if ($result.output -notmatch "PrivateKeyEntry") { throw "CANDIDATE_PRIVATE_KEY_UNAVAILABLE" }
  $certificateRequest = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) "ccr-candidate-certreq-$PID-$([Guid]::NewGuid().ToString('N')).csr"
  try {
    $privateKeyCheck = Invoke-CcrCandidateProcess -FilePath $KeyToolPath -Arguments @(
      "-certreq",
      "-alias", $Alias,
      "-file", $certificateRequest,
      "-keystore", $KeyStorePath,
      "-storepass:env", "CCR_CANDIDATE_KEYTOOL_STORE_PASSWORD",
      "-keypass:env", "CCR_CANDIDATE_KEYTOOL_KEY_PASSWORD"
    ) -SecretEnvironment @{
      CCR_CANDIDATE_KEYTOOL_STORE_PASSWORD = $StorePassword
      CCR_CANDIDATE_KEYTOOL_KEY_PASSWORD = $KeyPassword
    }
    if ($privateKeyCheck.exitCode -ne 0 -or
        -not (Test-Path -LiteralPath $certificateRequest -PathType Leaf) -or
        (Get-Item -LiteralPath $certificateRequest).Length -le 0) {
      throw "CANDIDATE_PRIVATE_KEY_UNAVAILABLE"
    }
  } finally {
    if (Test-Path -LiteralPath $certificateRequest -PathType Leaf) {
      Remove-Item -LiteralPath $certificateRequest -Force
    }
  }
  return [PSCustomObject][ordered]@{
    aliasPresent = $true
    privateKeyAccessible = $true
    certificateSha256 = Get-CcrCandidateCertificateShaFromText $result.output
  }
}

function Get-CcrCandidatePublicCertificateSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [string]$KeyToolPath = (Get-CcrCandidateKeyToolPath)
  )
  if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    throw "CANDIDATE_SIGNING_NOT_READY"
  }
  $result = Invoke-CcrCandidateProcess -FilePath $KeyToolPath -Arguments @(
    "-printcert", "-v", "-file", $CertificatePath
  )
  if ($result.exitCode -ne 0) { throw "CANDIDATE_PUBLIC_CERT_MISMATCH" }
  return Get-CcrCandidateCertificateShaFromText $result.output
}

function Get-CcrCandidatePublicPolicyFingerprint {
  param([string]$FingerprintPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.sha256"))
  if (-not (Test-Path -LiteralPath $FingerprintPath -PathType Leaf)) {
    throw "CANDIDATE_SIGNING_NOT_READY"
  }
  $line = ([System.IO.File]::ReadAllText($FingerprintPath, [System.Text.Encoding]::UTF8)).Trim()
  $match = [regex]::Match($line, "^([a-f0-9]{64})(?:\s+.+)?$")
  if (-not $match.Success -or $match.Groups[1].Value -ceq ("0" * 64)) {
    throw "CANDIDATE_PUBLIC_CERT_MISMATCH"
  }
  return $match.Groups[1].Value
}
