param(
  [string]$BackupDirectory1 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_1,
  [string]$BackupDirectory2 = $env:CCR_ANDROID_CANDIDATE_BACKUP_DIRECTORY_2,
  [string]$EvidenceDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1")

function Invoke-CcrAndroidPilotSigningPreflight {
  param(
    [object]$Inputs = $null,
    [string]$BackupDirectory1 = "",
    [string]$BackupDirectory2 = "",
    [string]$FingerprintPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.sha256"),
    [string]$CertificatePath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-cert.pem"),
    [string]$PolicyPath = (Join-Path (Get-CcrCandidateSigningDirectory) "ccr-internal-pilot-v1-policy.json"),
    [scriptblock]$KeyStoreInspector = $null,
    [scriptblock]$PublicCertificateInspector = $null
  )
  if ($null -eq $Inputs) { $Inputs = Get-CcrCandidateEnvironmentInputs }
  foreach ($property in @("KeyStorePath", "StorePassword", "Alias", "KeyPassword", "ExpectedCertificateSha256")) {
    if ($null -eq $Inputs.PSObject.Properties[$property] -or
        [string]::IsNullOrWhiteSpace([string]$Inputs.$property)) {
      throw "CANDIDATE_SIGNING_INPUT_INCOMPLETE"
    }
  }
  if (-not (Test-CcrCandidateSha256 ([string]$Inputs.ExpectedCertificateSha256))) {
    throw "CANDIDATE_EXPECTED_CERT_INVALID"
  }
  if (-not (Test-Path -LiteralPath ([string]$Inputs.KeyStorePath) -PathType Leaf)) {
    throw "CANDIDATE_KEYSTORE_MISSING"
  }
  if ([string]$Inputs.Alias -cne $script:CcrCandidateSigningAlias) {
    throw "CANDIDATE_ALIAS_MISSING"
  }
  if ([string]::IsNullOrWhiteSpace($BackupDirectory1) -or
      [string]::IsNullOrWhiteSpace($BackupDirectory2)) {
    throw "CANDIDATE_BACKUP_MISSING"
  }
  $backupRoots = @(
    [System.IO.Path]::GetFullPath($BackupDirectory1),
    [System.IO.Path]::GetFullPath($BackupDirectory2)
  )
  if ($backupRoots[0].Equals($backupRoots[1], [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "CANDIDATE_BACKUP_HASH_MISMATCH"
  }

  $policyFingerprint = Get-CcrCandidatePublicPolicyFingerprint $FingerprintPath
  if ($policyFingerprint -cne ([string]$Inputs.ExpectedCertificateSha256).ToLowerInvariant()) {
    throw "CANDIDATE_CERT_MISMATCH"
  }
  if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    throw "CANDIDATE_SIGNING_NOT_READY"
  }
  try {
    $policy = [System.IO.File]::ReadAllText($PolicyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "CANDIDATE_SIGNING_NOT_READY"
  }
  if ([string]$policy.signingLineage -cne $script:CcrCandidateSigningLineage -or
      [string]$policy.signingMode -cne "SIGNED_CANDIDATE" -or
      [int]$policy.artifactSetRevision -ne $script:CcrCandidateArtifactSetRevision -or
      [string]$policy.purpose -cne $script:CcrCandidateSigningPurpose -or
      [string]$policy.alias -cne $script:CcrCandidateSigningAlias -or
      [string]$policy.certificateSha256 -cne $policyFingerprint -or
      [string]$policy.expectedSigningCertificateSha256 -cne $policyFingerprint -or
      [string]::IsNullOrWhiteSpace([string]$policy.subject) -or
      [string]::IsNullOrWhiteSpace([string]$policy.keyAlgorithm)) {
    throw "CANDIDATE_SIGNING_NOT_READY"
  }

  if ($null -eq $PublicCertificateInspector) {
    $PublicCertificateInspector = { param($Path) Get-CcrCandidatePublicCertificateSha256 $Path }
  }
  $publicCertificateSha = [string](& $PublicCertificateInspector $CertificatePath)
  if ($publicCertificateSha -cne $policyFingerprint) {
    throw "CANDIDATE_PUBLIC_CERT_MISMATCH"
  }
  if ($null -eq $KeyStoreInspector) {
    $KeyStoreInspector = {
      param($Path, $Alias, $StorePassword, $KeyPassword)
      Get-CcrCandidateKeyStoreIdentity `
        -KeyStorePath $Path `
        -Alias $Alias `
        -StorePassword $StorePassword `
        -KeyPassword $KeyPassword
    }
  }
  $primaryIdentity = & $KeyStoreInspector `
    ([string]$Inputs.KeyStorePath) `
    ([string]$Inputs.Alias) `
    ([string]$Inputs.StorePassword) `
    ([string]$Inputs.KeyPassword)
  if ($null -eq $primaryIdentity -or $primaryIdentity.aliasPresent -ne $true -or
      $primaryIdentity.privateKeyAccessible -ne $true) {
    throw "CANDIDATE_ALIAS_MISSING"
  }
  if ([string]$primaryIdentity.certificateSha256 -cne $policyFingerprint) {
    throw "CANDIDATE_CERT_MISMATCH"
  }

  $primaryItem = Get-Item -LiteralPath ([string]$Inputs.KeyStorePath)
  $primaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $primaryItem.FullName).Hash.ToLowerInvariant()
  $backupRecords = [System.Collections.Generic.List[object]]::new()
  foreach ($backupRoot in $backupRoots) {
    $backupPath = Join-Path $backupRoot $primaryItem.Name
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
      throw "CANDIDATE_BACKUP_MISSING"
    }
    $backupItem = Get-Item -LiteralPath $backupPath
    $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash.ToLowerInvariant()
    if ($backupItem.Length -ne $primaryItem.Length -or $backupHash -cne $primaryHash) {
      throw "CANDIDATE_BACKUP_HASH_MISMATCH"
    }
    $backupIdentity = & $KeyStoreInspector `
      $backupPath `
      ([string]$Inputs.Alias) `
      ([string]$Inputs.StorePassword) `
      ([string]$Inputs.KeyPassword)
    if ($null -eq $backupIdentity -or $backupIdentity.aliasPresent -ne $true -or
        $backupIdentity.privateKeyAccessible -ne $true -or
        [string]$backupIdentity.certificateSha256 -cne $policyFingerprint) {
      throw "CANDIDATE_BACKUP_HASH_MISMATCH"
    }
    $backupRecords.Add([PSCustomObject][ordered]@{
      bytes = [long]$backupItem.Length
      jksSha256 = $backupHash
      privateKeyAccessible = $true
      certificateSha256 = [string]$backupIdentity.certificateSha256
    }) | Out-Null
  }
  return [PSCustomObject][ordered]@{
    status = "SIGNING_BASELINE_READY"
    lineage = $script:CcrCandidateSigningLineage
    alias = $script:CcrCandidateSigningAlias
    certificateSha256 = $policyFingerprint
    primaryBytes = [long]$primaryItem.Length
    primaryJksSha256 = $primaryHash
    primaryPrivateKeyAccessible = $true
    verifiedBackupCount = $backupRecords.Count
    backups = $backupRecords.ToArray()
  }
}

if ($MyInvocation.InvocationName -ne ".") {
  $inputs = $null
  $storePassword = $null
  $keyPassword = $null
  try {
    $configuredCount = @($script:CcrCandidateEnvironmentNames | Where-Object {
      -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, "Process"))
    }).Count
    if ($configuredCount -eq 0) {
      if (-not $BackupDirectory1) {
        $BackupDirectory1 = Read-Host "Absolute path for backup directory 1"
      }
      if (-not $BackupDirectory2) {
        $BackupDirectory2 = Read-Host "Absolute path for backup directory 2"
      }
      $storeSecret = Read-Host "Keystore password" -AsSecureString
      $samePassword = (Read-Host "Use the same password for the key? (y/N)") -cmatch "^(?i:y|yes)$"
      $keySecret = if ($samePassword) {
        $storeSecret
      } else {
        Read-Host "Key password" -AsSecureString
      }
      $storePassword = ConvertFrom-CcrCandidateSecureString $storeSecret
      $keyPassword = ConvertFrom-CcrCandidateSecureString $keySecret
      $inputs = [PSCustomObject][ordered]@{
        KeyStorePath = Get-CcrCandidateDefaultKeyStorePath
        StorePassword = $storePassword
        Alias = $script:CcrCandidateSigningAlias
        KeyPassword = $keyPassword
        ExpectedCertificateSha256 = Get-CcrCandidatePublicPolicyFingerprint
      }
    } elseif ($configuredCount -eq $script:CcrCandidateEnvironmentNames.Count) {
      $inputs = Get-CcrCandidateEnvironmentInputs
    } else {
      throw "CANDIDATE_SIGNING_INPUT_INCOMPLETE"
    }
    $result = Invoke-CcrAndroidPilotSigningPreflight `
      -Inputs $inputs `
      -BackupDirectory1 $BackupDirectory1 `
      -BackupDirectory2 $BackupDirectory2
    if (-not $EvidenceDirectory) {
      $EvidenceDirectory = Join-Path $env:USERPROFILE "Documents\CCR-Evidence\signing"
    }
    $evidenceRoot = [System.IO.Path]::GetFullPath($EvidenceDirectory)
    [System.IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    $evidencePath = Join-Path $evidenceRoot "ccr-internal-pilot-v1-readiness.json"
    $evidenceShaPath = "$evidencePath.sha256"
    if ((Test-Path -LiteralPath $evidencePath) -or (Test-Path -LiteralPath $evidenceShaPath)) {
      throw "CANDIDATE_READINESS_EVIDENCE_ALREADY_EXISTS"
    }
    $signingDirectory = Get-CcrCandidateSigningDirectory
    $evidence = [PSCustomObject][ordered]@{
      schemaVersion = 1
      kind = "ccr-android-signing-baseline-verification"
      status = "PASS"
      generatedAtUtc = [DateTime]::UtcNow.ToString("o")
      signingLineage = $result.lineage
      signingMode = "SIGNED_CANDIDATE"
      artifactSetRevision = $script:CcrCandidateArtifactSetRevision
      alias = $result.alias
      expectedSigningCertificateSha256 = $result.certificateSha256
      primaryBytes = $result.primaryBytes
      primaryJksSha256 = $result.primaryJksSha256
      primaryPrivateKeyAccessible = $result.primaryPrivateKeyAccessible
      verifiedBackupCount = $result.verifiedBackupCount
      backups = $result.backups
      publicCertificateFileSha256 = (
        Get-FileHash -Algorithm SHA256 -LiteralPath (
          Join-Path $signingDirectory "ccr-internal-pilot-v1-cert.pem"
        )
      ).Hash.ToLowerInvariant()
      publicPolicyFileSha256 = (
        Get-FileHash -Algorithm SHA256 -LiteralPath (
          Join-Path $signingDirectory "ccr-internal-pilot-v1-policy.json"
        )
      ).Hash.ToLowerInvariant()
      verifierSourceSha256 = (
        Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath
      ).Hash.ToLowerInvariant()
      commonSourceSha256 = (
        Get-FileHash -Algorithm SHA256 -LiteralPath (
          Join-Path $PSScriptRoot "ccr-android-pilot-signing-common.ps1"
        )
      ).Hash.ToLowerInvariant()
      passwordExposed = $false
      privateKeyMaterialExposed = $false
    }
    [System.IO.File]::WriteAllText(
      $evidencePath,
      (($evidence | ConvertTo-Json -Depth 8) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    $evidenceSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
      $evidenceShaPath,
      "$evidenceSha  $([System.IO.Path]::GetFileName($evidencePath))`n",
      [System.Text.UTF8Encoding]::new($false)
    )
    Write-Output "PASS - INTERNAL_PILOT_SIGNING_BASELINE_V1_VERIFIED"
    Write-Output "evidence=$evidencePath"
  } catch {
    Write-Error $_.Exception.Message
    exit 1
  } finally {
    $storePassword = $null
    $keyPassword = $null
  }
}
