param(
  [string]$KeyStorePath = "",
  [string]$BackupDirectory1 = "",
  [string]$BackupDirectory2 = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1")

function Test-CcrInitializerPathWithin {
  param([string]$Candidate, [string]$Root)
  $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  return $candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $candidateFull.StartsWith(
      $rootFull + [System.IO.Path]::DirectorySeparatorChar,
      [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Invoke-CcrAndroidPilotSigningInitializer {
  param(
    [string]$KeyStorePath = (Get-CcrCandidateDefaultKeyStorePath),
    [string]$BackupDirectory1 = "",
    [string]$BackupDirectory2 = ""
  )
  $repo = Get-CcrCandidateRepoRoot
  $signingDirectory = Get-CcrCandidateSigningDirectory
  $primary = [System.IO.Path]::GetFullPath($KeyStorePath)
  if (-not $BackupDirectory1) { $BackupDirectory1 = Read-Host "Absolute path for backup directory 1" }
  if (-not $BackupDirectory2) { $BackupDirectory2 = Read-Host "Absolute path for backup directory 2" }
  if (-not [System.IO.Path]::IsPathRooted($BackupDirectory1) -or
      -not [System.IO.Path]::IsPathRooted($BackupDirectory2)) {
    throw "CANDIDATE_BACKUP_PATH_NOT_ABSOLUTE"
  }
  $backupRoots = @(
    [System.IO.Path]::GetFullPath($BackupDirectory1),
    [System.IO.Path]::GetFullPath($BackupDirectory2)
  )
  if ($backupRoots[0].Equals($backupRoots[1], [System.StringComparison]::OrdinalIgnoreCase) -or
      (Test-CcrInitializerPathWithin $primary $repo) -or
      (Test-CcrInitializerPathWithin $primary "C:\tmp") -or
      (Test-CcrInitializerPathWithin $backupRoots[0] $repo) -or
      (Test-CcrInitializerPathWithin $backupRoots[1] $repo) -or
      (Test-CcrInitializerPathWithin $backupRoots[0] "C:\tmp") -or
      (Test-CcrInitializerPathWithin $backupRoots[1] "C:\tmp")) {
    throw "CANDIDATE_SIGNING_STORAGE_POLICY_VIOLATION"
  }

  $backupTargets = @($backupRoots | ForEach-Object {
    Join-Path $_ ([System.IO.Path]::GetFileName($primary))
  })
  $certificatePath = Join-Path $signingDirectory "ccr-internal-pilot-v1-cert.pem"
  $fingerprintPath = Join-Path $signingDirectory "ccr-internal-pilot-v1-cert.sha256"
  $policyPath = Join-Path $signingDirectory "ccr-internal-pilot-v1-policy.json"
  foreach ($path in @($primary) + $backupTargets + @($certificatePath, $fingerprintPath, $policyPath)) {
    if (Test-Path -LiteralPath $path) { throw "CANDIDATE_SIGNING_TARGET_ALREADY_EXISTS" }
  }

  $storeSecret = Read-Host "New keystore password (minimum 8 characters)" -AsSecureString
  if ($storeSecret.Length -lt 8) { throw "CANDIDATE_PASSWORD_TOO_SHORT" }
  $samePassword = (Read-Host "Use the same password for the key? (y/N)") -cmatch "^(?i:y|yes)$"
  $keySecret = if ($samePassword) {
    $storeSecret
  } else {
    $value = Read-Host "New key password (minimum 16 characters)" -AsSecureString
    if ($value.Length -lt 16) { throw "CANDIDATE_PASSWORD_TOO_SHORT" }
    $value
  }
  $storePassword = ConvertFrom-CcrCandidateSecureString $storeSecret
  $keyPassword = ConvertFrom-CcrCandidateSecureString $keySecret
  $keyTool = Get-CcrCandidateKeyToolPath
  $createdFinals = [System.Collections.Generic.List[string]]::new()
  $temporaryFiles = [System.Collections.Generic.List[string]]::new()
  try {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($primary)) | Out-Null
    foreach ($root in $backupRoots) { [System.IO.Directory]::CreateDirectory($root) | Out-Null }
    $token = [Guid]::NewGuid().ToString("N")
    $primaryTemp = "$primary.$token.tmp"
    $pemTemp = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-pilot-$token.pem"
    $derTemp = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-pilot-$token.der"
    foreach ($path in @($primaryTemp, $pemTemp, $derTemp)) { $temporaryFiles.Add($path) | Out-Null }

    $secretEnvironment = @{
      CCR_CANDIDATE_INIT_STORE_PASSWORD = $storePassword
      CCR_CANDIDATE_INIT_KEY_PASSWORD = $keyPassword
    }
    $generated = Invoke-CcrCandidateProcess -FilePath $keyTool -Arguments @(
      "-genkeypair",
      "-alias", $script:CcrCandidateSigningAlias,
      "-keyalg", "RSA",
      "-keysize", "4096",
      "-sigalg", "SHA256withRSA",
      "-validity", "3650",
      "-dname", "CN=CCR Android Internal Pilot v1, OU=Internal Pilot, O=CT Cine Reviewer, C=KR",
      "-keystore", $primaryTemp,
      "-storetype", "JKS",
      "-storepass:env", "CCR_CANDIDATE_INIT_STORE_PASSWORD",
      "-keypass:env", "CCR_CANDIDATE_INIT_KEY_PASSWORD",
      "-noprompt"
    ) -SecretEnvironment $secretEnvironment
    if ($generated.exitCode -ne 0) { throw "CANDIDATE_KEY_GENERATION_FAILED" }

    foreach ($export in @(
      [PSCustomObject]@{ path = $pemTemp; rfc = $true },
      [PSCustomObject]@{ path = $derTemp; rfc = $false }
    )) {
      $arguments = @(
        "-exportcert",
        "-alias", $script:CcrCandidateSigningAlias,
        "-keystore", $primaryTemp,
        "-storepass:env", "CCR_CANDIDATE_INIT_STORE_PASSWORD",
        "-file", $export.path
      )
      if ($export.rfc) { $arguments += "-rfc" }
      $result = Invoke-CcrCandidateProcess -FilePath $keyTool -Arguments $arguments -SecretEnvironment $secretEnvironment
      if ($result.exitCode -ne 0) { throw "CANDIDATE_PUBLIC_CERT_EXPORT_FAILED" }
    }

    $identity = Get-CcrCandidateKeyStoreIdentity `
      -KeyStorePath $primaryTemp `
      -Alias $script:CcrCandidateSigningAlias `
      -StorePassword $storePassword `
      -KeyPassword $keyPassword `
      -KeyToolPath $keyTool
    $certificateSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $derTemp).Hash.ToLowerInvariant()
    if ([string]$identity.certificateSha256 -cne $certificateSha) {
      throw "CANDIDATE_CERT_MISMATCH"
    }
    $jksHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $primaryTemp).Hash.ToLowerInvariant()
    $jksBytes = (Get-Item -LiteralPath $primaryTemp).Length
    $backupTemps = @()
    for ($index = 0; $index -lt $backupTargets.Count; $index += 1) {
      $backupTemp = "$($backupTargets[$index]).$token.tmp"
      $temporaryFiles.Add($backupTemp) | Out-Null
      [System.IO.File]::Copy($primaryTemp, $backupTemp, $false)
      $backupTemps += $backupTemp
      if ((Get-Item -LiteralPath $backupTemp).Length -ne $jksBytes -or
          (Get-FileHash -Algorithm SHA256 -LiteralPath $backupTemp).Hash.ToLowerInvariant() -cne $jksHash) {
        throw "CANDIDATE_BACKUP_HASH_MISMATCH"
      }
      $backupIdentity = Get-CcrCandidateKeyStoreIdentity `
        -KeyStorePath $backupTemp `
        -Alias $script:CcrCandidateSigningAlias `
        -StorePassword $storePassword `
        -KeyPassword $keyPassword `
        -KeyToolPath $keyTool
      if ([string]$backupIdentity.certificateSha256 -cne $certificateSha) {
        throw "CANDIDATE_BACKUP_HASH_MISMATCH"
      }
    }

    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($derTemp)
    $policy = [PSCustomObject][ordered]@{
      schemaVersion = 1
      status = "SIGNING_BASELINE_READY"
      purpose = $script:CcrCandidateSigningPurpose
      signingLineage = $script:CcrCandidateSigningLineage
      signingMode = "SIGNED_CANDIDATE"
      artifactSetRevision = $script:CcrCandidateArtifactSetRevision
      alias = $script:CcrCandidateSigningAlias
      certificateSha256 = $certificateSha
      expectedSigningCertificateSha256 = $certificateSha
      subject = $certificate.Subject
      keyAlgorithm = "RSA-4096"
      createdAtUtc = [DateTime]::UtcNow.ToString("o")
      certificateNotBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString("o")
      certificateNotAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString("o")
      productionOrPlayKeyShared = $false
      standardDebugKeyShared = $false
      rotationRequiresExplicitMigration = $true
    }

    [System.IO.File]::Move($primaryTemp, $primary)
    $createdFinals.Add($primary) | Out-Null
    for ($index = 0; $index -lt $backupTargets.Count; $index += 1) {
      [System.IO.File]::Move($backupTemps[$index], $backupTargets[$index])
      $createdFinals.Add($backupTargets[$index]) | Out-Null
    }
    [System.IO.File]::Copy($pemTemp, $certificatePath, $false)
    $createdFinals.Add($certificatePath) | Out-Null
    [System.IO.File]::WriteAllText(
      $fingerprintPath,
      "$certificateSha  ccr-internal-pilot-v1-cert.pem`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    $createdFinals.Add($fingerprintPath) | Out-Null
    [System.IO.File]::WriteAllText(
      $policyPath,
      (($policy | ConvertTo-Json -Depth 5) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    $createdFinals.Add($policyPath) | Out-Null

    Write-Output "PASS - INTERNAL_PILOT_SIGNING_BASELINE_V1_READY"
    Write-Output "lineage=$($script:CcrCandidateSigningLineage)"
    Write-Output "certificateSha256=$certificateSha"
    Write-Output "jksSha256=$jksHash"
    Write-Output "verifiedBackups=2"
  } catch {
    foreach ($path in $createdFinals) {
      if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    throw
  } finally {
    foreach ($path in $temporaryFiles) {
      if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    $storePassword = $null
    $keyPassword = $null
  }
}

if ($MyInvocation.InvocationName -ne ".") {
  if (-not $KeyStorePath) { $KeyStorePath = Get-CcrCandidateDefaultKeyStorePath }
  try {
    Invoke-CcrAndroidPilotSigningInitializer `
      -KeyStorePath $KeyStorePath `
      -BackupDirectory1 $BackupDirectory1 `
      -BackupDirectory2 $BackupDirectory2
  } catch {
    Write-Error $_.Exception.Message
    exit 1
  }
}
