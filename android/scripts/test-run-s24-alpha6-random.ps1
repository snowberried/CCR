$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = Join-Path $PSScriptRoot "run-s24-alpha6-random.ps1"
$candidateBridgePath = Join-Path $PSScriptRoot "s24-alpha6-candidate-device-artifacts.ps1"
. $candidateBridgePath

$script:CcrAlpha6FrozenTargetSetIdentities = [ordered]@{
  "fixture-01" = "e27c3831f54e977f8cbe66221fd8cbf636b255cbfbd06cbd31119ea2d5ec6da6"
  "fixture-02" = "e32cb87230d992d8e7b596b0c45f7ecb22d39d915808eaf5c626324e12295b83"
  "fixture-03" = "2e6ca49bd7c674bb8da39a459dc008d94b3c2550e44b964f86d07024893545ee"
  "fixture-04" = "10f5e83b3a0fa02669cbb846962d5441016fef533612edb00031e6acf049dbe9"
  "fixture-05" = "79481a4a5d9defe58d2e9baf16a00943bb0519b513877c2ba4433d8b343eb0a4"
}

function Get-CcrAlpha6RandomTestFunctionDefinition {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    [System.IO.Path]::GetFullPath($Path),
    [ref]$tokens,
    [ref]$errors
  )
  if (@($errors).Count -ne 0) { throw "TEST_RUNNER_PARSE_FAILED:$Name" }
  $definition = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  if ($definition.Count -ne 1) { throw "TEST_RUNNER_FUNCTION_NOT_FOUND:$Name" }
  return $definition[0].Extent.Text
}

foreach ($name in @(
  "Assert-CcrAlpha6RandomNonNegativeInteger",
  "Assert-CcrAlpha6RandomReport",
  "Assert-CcrAlpha6RandomCompletedSummary",
  "Assert-CcrAlpha6RandomPreflightSummary",
  "Get-CcrAlpha6RandomNearestRankPercentile",
  "Get-CcrAlpha6RandomFlattenedTargets",
  "Assert-CcrAlpha6RandomGate",
  "Get-CcrAlpha6RandomFileRecord",
  "Assert-CcrAlpha6RandomTrace",
  "Assert-CcrAlpha6RandomSettingsRestored"
)) { Invoke-Expression (Get-CcrAlpha6RandomTestFunctionDefinition $runnerPath $name) }

$passes = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-CcrAlpha6RandomHostTest {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
  try {
    & $Body
    $script:passes += 1
  } catch {
    $script:failures.Add("$Name -> $($_.Exception.Message)") | Out-Null
  }
}

function Assert-CcrAlpha6RandomThrows {
  param([Parameter(Mandatory = $true)][string]$Expected, [Parameter(Mandatory = $true)][scriptblock]$Body)
  $caught = $null
  try { & $Body } catch { $caught = $_.Exception.Message }
  if ($null -eq $caught -or -not $caught.Contains($Expected)) {
    throw "EXPECTED_FAILURE_NOT_OBSERVED:$Expected; ACTUAL=$caught"
  }
}

function Copy-CcrAlpha6RandomTestValue {
  param([Parameter(Mandatory = $true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json
}

function New-CcrAlpha6RandomTarget {
  param([int]$Ordinal)
  $categories = @("cache-or-history-hit", "ahead-of-cursor", "same-gop", "adjacent-gop", "far-random")
  $category = $categories[[Math]::Floor($Ordinal / 10)]
  $plan = switch ($category) {
    "cache-or-history-hit" { "CACHE_HIT" }
    "ahead-of-cursor" { "SEQUENTIAL_AHEAD" }
    "same-gop" { "SAME_GOP_CURSOR" }
    default { "PREVIOUS_SYNC" }
  }
  return [PSCustomObject][ordered]@{
    ordinal = $Ordinal
    requestedCategory = $category
    selectedPlan = $plan
    fallbackReason = $null
    decoderCursorFrame = 10
    previousSyncFrame = 0
    estimatedOutputCount = 2
    actualOutputCount = 2
    seekCount = $(if ($plan -ceq "PREVIOUS_SYNC") { 1 } else { 0 })
    flushCount = $(if ($plan -ceq "PREVIOUS_SYNC") { 1 } else { 0 })
    auxiliaryUsed = $false
    setupFrameIndex = $Ordinal
    targetFrameIndex = $Ordinal + 1
    targetPtsUs = [long]($Ordinal + 1) * 41667L
    publishedDisplayedFrameIndex = $Ordinal + 1
    acceptedToPublicationUs = 100000L
    staleDiscardCount = 0L
    nonTargetPublishedCount = 0L
  }
}

function New-CcrAlpha6RandomReport {
  param([Parameter(Mandatory = $true)][string]$Kind)
  $fixtures = @()
  for ($fixtureIndex = 1; $fixtureIndex -le 5; $fixtureIndex += 1) {
    $targets = @(0..49 | ForEach-Object { New-CcrAlpha6RandomTarget $_ })
    $fixtures += [PSCustomObject][ordered]@{
      fixtureId = "fixture-0$fixtureIndex"
      targetSetIdentity = @(
        "e27c3831f54e977f8cbe66221fd8cbf636b255cbfbd06cbd31119ea2d5ec6da6",
        "e32cb87230d992d8e7b596b0c45f7ecb22d39d915808eaf5c626324e12295b83",
        "2e6ca49bd7c674bb8da39a459dc008d94b3c2550e44b964f86d07024893545ee",
        "10f5e83b3a0fa02669cbb846962d5441016fef533612edb00031e6acf049dbe9",
        "79481a4a5d9defe58d2e9baf16a00943bb0519b513877c2ba4433d8b343eb0a4"
      )[$fixtureIndex - 1]
      targetCount = 50
      mismatchCount = 0L
      targets = $targets
      burst = [PSCustomObject][ordered]@{
        requestCount = 10
        acceptedRequestCount = 10
        acceptedToPublicationUs = 100000L
        nonTargetPublishedCount = 0L
        nonFinalPublishedAfterFinalAcceptanceCount = 0L
        staleDiscardCount = 0L
      }
      cacheRejectionCount = 0L
      cacheThrashCount = 0L
      textureDoubleReleaseCount = 0L
      staleBeforeSwapCount = 0L
      swapFailureCount = 0L
      surfaceInvalidCount = 0L
      publicationInvariantViolationCount = 0L
    }
  }
  return [PSCustomObject][ordered]@{
    schemaVersion = 1
    kind = $Kind
    status = "PASS"
    applicationId = "com.snowberried.ctcinereviewer.internal"
    appVersionName = "0.2.0-alpha.6"
    appVersionCode = 7
    appCommitSha = "a" * 40
    fixtureCount = 5
    targetCount = 250
    mismatchCount = 0L
    writeOpenCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    mediaFileNameIncluded = $false
    mediaUriIncluded = $false
    mediaPathIncluded = $false
    mediaSourceHashIncluded = $false
    fixtures = $fixtures
  }
}

$context = [PSCustomObject]@{
  ArtifactSet = [PSCustomObject]@{ RuntimeSourceSha = "a" * 40 }
}
$exactKind = "alpha6-cost-aware-random-exactness"
$performanceKind = "alpha6-cost-aware-random-performance"
$validExact = New-CcrAlpha6RandomReport $exactKind
$validPerformance = New-CcrAlpha6RandomReport $performanceKind

Invoke-CcrAlpha6RandomHostTest "valid-stage1-contract" {
  Assert-CcrAlpha6RandomReport $validExact $exactKind $context "Stage1" | Out-Null
  Assert-CcrAlpha6RandomReport $validPerformance $performanceKind $context "Stage1" | Out-Null
  $gate = Assert-CcrAlpha6RandomGate $validExact $validPerformance "Stage1"
  if ([string]$gate.status -cne "PASS" -or [int]$gate.exactMatches -ne 250 -or
      [long]$gate.overallP95Us -ne 100000L -or [double]$gate.sameGopAllowedPlanPercent -ne 100.0) {
    throw "VALID_GATE_RESULT_MISMATCH"
  }
}

Invoke-CcrAlpha6RandomHostTest "missing-canonical-wire-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $report.fixtures[0].targets[0].PSObject.Properties.Remove("requestedCategory")
  Assert-CcrAlpha6RandomThrows "PINNED_MANIFEST_PROPERTY_MISSING:requestedCategory" {
    Assert-CcrAlpha6RandomReport $report $performanceKind $context "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "exact-mismatch-fails-closed" {
  $report = Copy-CcrAlpha6RandomTestValue $validExact
  $report.mismatchCount = 1
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_REPORT_CONTRACT_MISMATCH" {
    Assert-CcrAlpha6RandomReport $report $exactKind $context "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "same-gop-plan-ratio-below-95-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $same = @($report.fixtures | ForEach-Object { $_.targets } | Where-Object { $_.requestedCategory -ceq "same-gop" })
  0..2 | ForEach-Object { $same[$_].selectedPlan = "PREVIOUS_SYNC" }
  Assert-CcrAlpha6RandomReport $report $performanceKind $context "Stage1" | Out-Null
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_SAME_GOP_ALLOWED_PLAN_RATIO_BELOW_95" {
    Assert-CcrAlpha6RandomGate $validExact $report "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "prepared-auxiliary-stage1-forbidden-stage2-wire-validated" {
  $exact = Copy-CcrAlpha6RandomTestValue $validExact
  $performance = Copy-CcrAlpha6RandomTestValue $validPerformance
  foreach ($report in @($exact, $performance)) {
    $target = @($report.fixtures | ForEach-Object { $_.targets } | Where-Object { $_.requestedCategory -ceq "same-gop" })[0]
    $target.selectedPlan = "PREPARED_AUXILIARY"
    $target.auxiliaryUsed = $true
  }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_STAGE1_AUXILIARY_FORBIDDEN" {
    Assert-CcrAlpha6RandomReport $performance $performanceKind $context "Stage1" | Out-Null
  }
  Assert-CcrAlpha6RandomReport $exact $exactKind $context "Stage2" | Out-Null
  Assert-CcrAlpha6RandomReport $performance $performanceKind $context "Stage2" | Out-Null
  Assert-CcrAlpha6RandomGate $exact $performance "Stage2" | Out-Null
}

Invoke-CcrAlpha6RandomHostTest "target-set-identity-fails-closed" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $report.fixtures[0].targetSetIdentity = "0" * 64
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_TARGET_SET_IDENTITY_MISMATCH" {
    Assert-CcrAlpha6RandomReport $report $performanceKind $context "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "ordinal-set-fails-closed" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $report.fixtures[0].targets[49].ordinal = 50
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_TARGET_ORDINAL_SET_MISMATCH" {
    Assert-CcrAlpha6RandomReport $report $performanceKind $context "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "same-gop-p95-threshold-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  @($report.fixtures | ForEach-Object { $_.targets } | Where-Object { $_.requestedCategory -ceq "same-gop" }) |
    ForEach-Object { $_.acceptedToPublicationUs = 150001L }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_SAME_GOP_P95_EXCEEDED" {
    Assert-CcrAlpha6RandomGate $validExact $report "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "far-p95-threshold-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  @($report.fixtures | ForEach-Object { $_.targets } | Where-Object { $_.requestedCategory -ceq "far-random" }) |
    ForEach-Object { $_.acceptedToPublicationUs = 300001L }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_FAR_P95_EXCEEDED" {
    Assert-CcrAlpha6RandomGate $validExact $report "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "overall-p95-threshold-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  @($report.fixtures | ForEach-Object { $_.targets } | Where-Object {
    $_.requestedCategory -cnotin @("same-gop", "far-random")
  }) | ForEach-Object { $_.acceptedToPublicationUs = 150001L }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_OVERALL_P95_EXCEEDED" {
    Assert-CcrAlpha6RandomGate $validExact $report "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "alpha5-max-regression-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $report.fixtures[0].targets[0].acceptedToPublicationUs = 406784L
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_MAX_REGRESSION" {
    Assert-CcrAlpha6RandomGate $validExact $report "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "completed-summary-checkpoints-and-fixed-fields-fail-closed" {
  $exact = [PSCustomObject][ordered]@{ status = "PASS"; stage = "Exactness" }
  $performance = [PSCustomObject][ordered]@{ status = "PASS"; stage = "Performance" }
  $summary = [PSCustomObject][ordered]@{
    kind = "alpha6-cost-aware-random-gate"
    status = "PASS"
    maxMinutes = 25
    exactness = $exact
    performance = $performance
    exactness250Of250 = $true
    correctnessFailureBlocksPerformance = $true
    traceRequiredForSuccess = $true
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Assert-CcrAlpha6RandomCompletedSummary $summary $exact $performance 25 | Out-Null
  $summary.exactness = [PSCustomObject]@{ status = "PASS"; stage = "Tampered" }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_RESUME_COMPLETED_CHECKPOINT_MISMATCH" {
    Assert-CcrAlpha6RandomCompletedSummary $summary $exact $performance 25 | Out-Null
  }
  $summary.exactness = $exact
  $summary.traceRequiredForSuccess = $false
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_RESUME_SUMMARY_CONTRACT_MISMATCH" {
    Assert-CcrAlpha6RandomCompletedSummary $summary $exact $performance 25 | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "preflight-summary-fixed-fields-fail-closed" {
  $artifactRecords = @([PSCustomObject][ordered]@{ role = "debugApp"; sha256 = "a" * 64 })
  $summary = [PSCustomObject][ordered]@{
    kind = "alpha6-random-preflight"
    status = "PREFLIGHT_PASS"
    maxMinutes = 25
    exactnessTargetCount = 250
    performanceTargetCount = 250
    sameGopAllowedPlanPercentMinimum = 95
    sameGopP95MaximumUs = 150000L
    farRandomP95MaximumUs = 300000L
    overallP95MaximumUs = 150000L
    correctnessFailureBlocksPerformance = $true
    deviceMutationCount = 0L
    preRunArtifactRehash = $artifactRecords
    postRunArtifactRehash = $artifactRecords
    buildCommandCount = 0L
    syntheticOnly = $true
    containsRealMediaMetadata = $false
  }
  Assert-CcrAlpha6RandomPreflightSummary $summary 25 $artifactRecords | Out-Null
  $summary.deviceMutationCount = 1L
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_RESUME_PREFLIGHT_SUMMARY_CONTRACT_MISMATCH" {
    Assert-CcrAlpha6RandomPreflightSummary $summary 25 $artifactRecords | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "burst-nonfinal-publication-fails" {
  $report = Copy-CcrAlpha6RandomTestValue $validPerformance
  $report.fixtures[0].burst.nonFinalPublishedAfterFinalAcceptanceCount = 1
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_BURST_FINAL_ONLY_VIOLATION" {
    Assert-CcrAlpha6RandomReport $report $performanceKind $context "Stage1" | Out-Null
  }
}

Invoke-CcrAlpha6RandomHostTest "automatic-brightness-raw-drift-is-accepted" {
  $actualSettings = @{
    "global/stay_on_while_plugged_in" = "15"
    "system/screen_brightness_mode" = "1"
    "system/screen_brightness" = "40"
    "system/screen_off_timeout" = "600000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }
  function Get-CcrPinnedDeviceSetting {
    param([object]$Context, [string]$Namespace, [string]$Name)
    return [string]$actualSettings["$Namespace/$Name"]
  }
  $settingsContext = [PSCustomObject]@{
    SavedSettings = [PSCustomObject]@{
      stayAwake = "15"
      brightnessMode = "1"
      brightness = "29"
      screenTimeout = "600000"
      accelerometerRotation = "0"
      userRotation = "0"
    }
  }
  Assert-CcrAlpha6RandomSettingsRestored $settingsContext | Out-Null
}

Invoke-CcrAlpha6RandomHostTest "manual-brightness-raw-mismatch-fails" {
  $actualSettings = @{
    "global/stay_on_while_plugged_in" = "15"
    "system/screen_brightness_mode" = "0"
    "system/screen_brightness" = "40"
    "system/screen_off_timeout" = "600000"
    "system/accelerometer_rotation" = "0"
    "system/user_rotation" = "0"
  }
  function Get-CcrPinnedDeviceSetting {
    param([object]$Context, [string]$Namespace, [string]$Name)
    return [string]$actualSettings["$Namespace/$Name"]
  }
  $settingsContext = [PSCustomObject]@{
    SavedSettings = [PSCustomObject]@{
      stayAwake = "15"
      brightnessMode = "0"
      brightness = "29"
      screenTimeout = "600000"
      accelerometerRotation = "0"
      userRotation = "0"
    }
  }
  Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_SETTING_RESTORE_MISMATCH:system/screen_brightness" {
    Assert-CcrAlpha6RandomSettingsRestored $settingsContext | Out-Null
  }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-random-host-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
  Invoke-CcrAlpha6RandomHostTest "valid-trace-contract" {
    $trace = Join-Path $testRoot "valid.atrace"
    $body = "TRACE:`n" + ("padding" * 64) + "`nCCR.request.accept`nCCR.publish`nCCR.swap`n"
    [System.IO.File]::WriteAllText($trace, $body, [System.Text.UTF8Encoding]::new($false))
    $record = Assert-CcrAlpha6RandomTrace $trace
    if ([long]$record.bytes -le 256L -or [string]$record.sha256 -notmatch '^[a-f0-9]{64}$') {
      throw "TRACE_RECORD_INVALID"
    }
  }

  Invoke-CcrAlpha6RandomHostTest "missing-trace-marker-fails" {
    $trace = Join-Path $testRoot "invalid.atrace"
    [System.IO.File]::WriteAllText(
      $trace,
      ("TRACE:`n" + ("padding" * 64) + "`nCCR.request.accept`nCCR.publish`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_TRACE_MARKER_MISSING:CCR.swap" {
      Assert-CcrAlpha6RandomTrace $trace | Out-Null
    }
  }
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -Recurse -Force -LiteralPath $testRoot }
}

Invoke-CcrAlpha6RandomHostTest "runner-static-same-artifact-contract" {
  $source = [System.IO.File]::ReadAllText($runnerPath, [System.Text.Encoding]::UTF8)
  foreach ($marker in @(
    "Invoke-CcrAlpha6CandidateDeviceHostPreflight", "Assert-CcrAlpha6CandidateDeviceIdentityUnchanged",
    "ArtifactManifestSha256", "ExpectedDebugAppSha256", "OutputDirectory", "PreflightOnly", "Resume",
    "MaxMinutes", "checkpoint-alpha6-random-exactness", "checkpoint-alpha6-random-performance",
    "correctnessFailureBlocksPerformance", "BuildCommandCount = 0L", "preRunArtifactRehash",
    "postRunArtifactRehash", "Initialize-CcrAlpha6PinnedDeviceSettings", "Invoke-CcrPinnedCleanup",
    "Assert-CcrAlpha6RandomSettingsRestored", "Alpha6RandomSeekExactnessTest",
    "Alpha6RandomSeekPerformanceTest", "s24-alpha6-random-exactness-v1.json",
    "s24-alpha6-random-performance-v1.json", "alpha6-cost-aware-random-exactness",
    "alpha6-cost-aware-random-performance", "Assert-CcrAlpha6RandomTrace",
    'performanceCountedAsSuccess = $false', "PREPARED_AUXILIARY",
    "ALPHA6_RANDOM_STAGE2_NOT_IMPLEMENTED", "ALPHA6_RANDOM_MAX_REGRESSION",
    "ALPHA6_RANDOM_TARGET_SET_IDENTITY_MISMATCH", "New-CcrAlpha6TimedAdbInvoker",
    "Initialize-CcrAlpha6PinnedDeviceSettings", "deviceSettingsPreflight",
    'checkpoint-alpha6-random-device-settings-$hostPreflightRunId.json',
    "Assert-CcrAlpha6RandomCompletedSummary", "signingMode", "signingLineage",
    "expectedSigningCertificateSha256", "publicSigningPolicySha256"
  )) {
    if (-not $source.Contains($marker)) { throw "RUNNER_MARKER_MISSING:$marker" }
  }
  foreach ($forbidden in @(
    "Alpha5RandomSeekExactnessTest#", "Alpha5RandomSeekPerformanceTest#",
    'alpha5-cost-aware-random-exactness', 'alpha5-cost-aware-random-performance',
    'artifactSetRevision = 4'
  )) {
    if ($source.Contains($forbidden)) { throw "ALPHA5_EXECUTION_IDENTITY_LEAK:$forbidden" }
  }
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -ne 0) { throw "RUNNER_PARSE_FAILED" }
  foreach ($command in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $name = [string]$command.GetCommandName()
    if ([System.IO.Path]::GetFileName($name) -cmatch '(?i)^(gradlew(?:\.bat)?|gradle(?:\.bat)?|msbuild(?:\.exe)?|mvnw?(?:\.cmd)?|cargo(?:\.exe)?)$') {
      throw "BUILD_COMMAND_FOUND:$name"
    }
  }
}

$runnerRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccr-alpha6-random-runner-$PID-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($runnerRoot) | Out-Null
$previousRandomTestMode = $env:CCR_ALPHA6_RANDOM_TEST_MODE
$env:CCR_ALPHA6_RANDOM_TEST_MODE = "1"
try {
  $runnerRuntimeSource = "1" * 40
  $runnerHarnessSource = "2" * 40
  $runnerRuntimeTree = "3" * 64
  $runnerCertificate = Get-CcrCandidatePublicPolicyFingerprint
  $runnerOtherCertificate = "4" * 64
  $runnerRoles = @(
    [PSCustomObject]@{ role = "debugApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "debugTest"; package = $script:CcrPinnedDebugTestPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedAppPackage },
    [PSCustomObject]@{ role = "benchmarkApp"; package = $script:CcrPinnedAppPackage; versionName = "0.2.0-alpha.6"; versionCode = 7; runner = $null; target = $null },
    [PSCustomObject]@{ role = "macrobenchmarkTest"; package = $script:CcrPinnedMacrobenchmarkPackage; versionName = $null; versionCode = $null; runner = $script:CcrPinnedRunner; target = $script:CcrPinnedMacrobenchmarkPackage }
  )
  $runnerArtifacts = [System.Collections.Generic.List[object]]::new()
  $runnerIdentities = @{}
  $runnerArtifactBodies = @{}
  foreach ($role in $runnerRoles) {
    $path = Join-Path $runnerRoot "$($role.role).apk"
    $body = "random-candidate-$($role.role)"
    $runnerArtifactBodies[$role.role] = $body
    [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    $runnerArtifacts.Add([PSCustomObject][ordered]@{
      role = $role.role
      path = $path
      bytes = (Get-Item -LiteralPath $path).Length
      sha256 = $sha
      packageName = $role.package
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $runnerCertificate
      runner = $role.runner
      targetPackage = $role.target
    }) | Out-Null
    $runnerIdentities[$role.role] = [PSCustomObject]@{
      packageName = $role.package
      versionName = $role.versionName
      versionCode = $role.versionCode
      signingCertificateSha256 = $runnerCertificate
      runner = $role.runner
      targetPackage = $role.target
    }
  }
  $runnerManifest = [PSCustomObject][ordered]@{
    schemaVersion = 1
    artifactSetRevision = 5
    signingLineage = $script:CcrCandidateSigningLineage
    signingMode = "SIGNED_CANDIDATE"
    candidateSigning = $true
    expectedSigningCertificateSha256 = $runnerCertificate
    runtimeSourceSha = $runnerRuntimeSource
    harnessSourceSha = $runnerHarnessSource
    runtimeInputsTreeSha256 = $runnerRuntimeTree
    versionName = "0.2.0-alpha.6"
    versionCode = 7
    syntheticOnly = $true
    containsRealMediaMetadata = $false
    artifacts = $runnerArtifacts.ToArray()
  }
  function Write-CcrAlpha6RandomRunnerManifest {
    param(
      [Parameter(Mandatory = $true)][object]$Value,
      [Parameter(Mandatory = $true)][string]$Path
    )
    [System.IO.File]::WriteAllText(
      $Path,
      (($Value | ConvertTo-Json -Depth 15) + "`n"),
      [System.Text.UTF8Encoding]::new($false)
    )
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
  $runnerManifestPath = Join-Path $runnerRoot "artifact-manifest-v5.json"
  $runnerManifestSha = Write-CcrAlpha6RandomRunnerManifest $runnerManifest $runnerManifestPath
  $runnerIdentityReader = {
    param($Artifact, $Tools)
    return $runnerIdentities[[string]$Artifact.role]
  }.GetNewClosure()
  $runnerSourceVerifier = { param($Repo, $Runtime, $Harness) return $true }
  $runnerAdbState = [PSCustomObject]@{ Count = 0 }
  $runnerForbiddenAdb = {
    param($Arguments)
    $runnerAdbState.Count += 1
    throw "ADB_MUST_NOT_RUN_DURING_RANDOM_HOST_PREFLIGHT"
  }.GetNewClosure()
  $runnerTools = [PSCustomObject]@{ Adb = "fake-adb"; ApkAnalyzer = "fake"; ApkSigner = "fake" }
  $runnerPreflightArgs = @{
    ArtifactManifest = $runnerManifestPath
    ArtifactManifestSha256 = $runnerManifestSha
    RuntimeSourceSha = $runnerRuntimeSource
    HarnessSourceSha = $runnerHarnessSource
    RuntimeInputsTreeSha256 = $runnerRuntimeTree
    ExpectedDebugAppSha256 = [string]$runnerArtifacts[0].sha256
    OutputDirectory = Join-Path $runnerRoot "positive-output"
    RunId = "alpha6-random-v5"
    MaxMinutes = 25
    DecoderStage = "Stage1"
    PreflightOnly = $true
    TestOnlyAndroidTools = $runnerTools
    TestOnlyIdentityReader = $runnerIdentityReader
    TestOnlySourceIdentityVerifier = $runnerSourceVerifier
    TestOnlyAdbInvoker = $runnerForbiddenAdb
  }

  Invoke-CcrAlpha6RandomHostTest "revision5-runner-preflight-and-resume" {
    & $runnerPath @runnerPreflightArgs | Out-Null
    if ($runnerAdbState.Count -ne 0) { throw "RANDOM_PREFLIGHT_TOUCHED_ADB" }
    $summaryPath = Join-Path $runnerPreflightArgs.OutputDirectory "alpha6-random-summary-alpha6-random-v5.json"
    $summary = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$summary.status -cne "PREFLIGHT_PASS" -or
        [int]$summary.identity.artifactSetRevision -ne 5 -or
        [string]$summary.identity.signingMode -cne "SIGNED_CANDIDATE" -or
        $summary.identity.candidateSigning -ne $true -or
        [string]$summary.identity.signingLineage -cne "ccr-internal-pilot-v1" -or
        [string]$summary.identity.expectedSigningCertificateSha256 -cne $runnerCertificate -or
        [string]$summary.identity.publicSigningPolicySha256 -notmatch "^[a-f0-9]{64}$" -or
        @($summary.identity.closedValidationScripts).Count -ne 6 -or
        @($summary.preRunArtifactRehash).Count -ne 4 -or
        @($summary.postRunArtifactRehash).Count -ne 4 -or
        [long]$summary.buildCommandCount -ne 0L) {
      throw "RANDOM_REV5_PREFLIGHT_IDENTITY_MISMATCH"
    }
    $resume = @{} + $runnerPreflightArgs
    $resume.Resume = $true
    & $runnerPath @resume | Out-Null
    if ($runnerAdbState.Count -ne 0) { throw "RANDOM_PREFLIGHT_RESUME_TOUCHED_ADB" }
  }

  Invoke-CcrAlpha6RandomHostTest "revision4-and-signing-mutants-rejected" {
    $cases = @(
      [PSCustomObject]@{ name = "revision4"; property = "artifactSetRevision"; value = 4; error = "CANDIDATE_MANIFEST_REVISION_MISMATCH" },
      [PSCustomObject]@{ name = "mode"; property = "signingMode"; value = "CI_EPHEMERAL_DEBUG"; error = "CANDIDATE_MANIFEST_SIGNING_MODE_MISMATCH" },
      [PSCustomObject]@{ name = "lineage"; property = "signingLineage"; value = "other"; error = "CANDIDATE_MANIFEST_LINEAGE_MISMATCH" },
      [PSCustomObject]@{ name = "fingerprint"; property = "expectedSigningCertificateSha256"; value = $runnerOtherCertificate; error = "CANDIDATE_MANIFEST_PUBLIC_POLICY_MISMATCH" }
    )
    $caseIndex = 0
    foreach ($case in $cases) {
      $caseIndex += 1
      $bad = Copy-CcrAlpha6RandomTestValue $runnerManifest
      $bad.($case.property) = $case.value
      $path = Join-Path $runnerRoot "manifest-$($case.name).json"
      $sha = Write-CcrAlpha6RandomRunnerManifest $bad $path
      $caseArgs = @{} + $runnerPreflightArgs
      $caseArgs.ArtifactManifest = $path
      $caseArgs.ArtifactManifestSha256 = $sha
      $caseArgs.OutputDirectory = Join-Path $runnerRoot "output-$($case.name)"
      $caseArgs.RunId = "random-case-$caseIndex"
      Assert-CcrAlpha6RandomThrows $case.error { & $runnerPath @caseArgs | Out-Null }
    }
  }

  Invoke-CcrAlpha6RandomHostTest "mixed-signer-and-wrong-artifact-sha-rejected" {
    $runnerIdentities["macrobenchmarkTest"].signingCertificateSha256 = $runnerOtherCertificate
    try {
      $mixedArgs = @{} + $runnerPreflightArgs
      $mixedArgs.OutputDirectory = Join-Path $runnerRoot "mixed-output"
      $mixedArgs.RunId = "random-mixed"
      Assert-CcrAlpha6RandomThrows "PINNED_ARTIFACT_CERTIFICATE_MISMATCH:macrobenchmarkTest" {
        & $runnerPath @mixedArgs | Out-Null
      }
    } finally {
      $runnerIdentities["macrobenchmarkTest"].signingCertificateSha256 = $runnerCertificate
    }
    $wrongSha = Copy-CcrAlpha6RandomTestValue $runnerManifest
    $wrongSha.artifacts[0].sha256 = "5" * 64
    $wrongPath = Join-Path $runnerRoot "manifest-wrong-sha.json"
    $wrongManifestSha = Write-CcrAlpha6RandomRunnerManifest $wrongSha $wrongPath
    $wrongArgs = @{} + $runnerPreflightArgs
    $wrongArgs.ArtifactManifest = $wrongPath
    $wrongArgs.ArtifactManifestSha256 = $wrongManifestSha
    $wrongArgs.OutputDirectory = Join-Path $runnerRoot "wrong-sha-output"
    $wrongArgs.RunId = "random-wrong-sha"
    Assert-CcrAlpha6RandomThrows "PINNED_ARTIFACT_SHA_MISMATCH:debugApp" {
      & $runnerPath @wrongArgs | Out-Null
    }
  }

  Invoke-CcrAlpha6RandomHostTest "manifest-hash-artifact-and-resume-identity-drift-rejected" {
    $staleArgs = @{} + $runnerPreflightArgs
    $staleArgs.OutputDirectory = Join-Path $runnerRoot "stale-manifest-output"
    $staleArgs.RunId = "random-stale-manifest"
    $staleArgs.ArtifactManifestSha256 = "6" * 64
    Assert-CcrAlpha6RandomThrows "ALPHA6_MANIFEST_SHA_MISMATCH" {
      & $runnerPath @staleArgs | Out-Null
    }

    $resume = @{} + $runnerPreflightArgs
    $resume.Resume = $true
    $sessionPath = Join-Path $runnerPreflightArgs.OutputDirectory "checkpoint-alpha6-random-session-alpha6-random-v5.json"
    $sessionRaw = [System.IO.File]::ReadAllText($sessionPath, [System.Text.Encoding]::UTF8)
    (Get-Item -LiteralPath $sessionPath).IsReadOnly = $false
    $revision4 = $sessionRaw | ConvertFrom-Json
    $revision4.identity.artifactSetRevision = 4
    [System.IO.File]::WriteAllText($sessionPath, ($revision4 | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
    Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_RESUME_IDENTITY_MISMATCH" {
      & $runnerPath @resume | Out-Null
    }
    $policyDrift = $sessionRaw | ConvertFrom-Json
    $policyDrift.identity.publicSigningPolicySha256 = "0" * 64
    [System.IO.File]::WriteAllText($sessionPath, ($policyDrift | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
    Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_RESUME_IDENTITY_MISMATCH" {
      & $runnerPath @resume | Out-Null
    }
    [System.IO.File]::WriteAllText($sessionPath, $sessionRaw, [System.Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $sessionPath).IsReadOnly = $true

    [System.IO.File]::AppendAllText($runnerArtifacts[0].path, "tamper", [System.Text.UTF8Encoding]::new($false))
    try {
      Assert-CcrAlpha6RandomThrows "PINNED_ARTIFACT_BYTE_SIZE_MISMATCH:debugApp" {
        & $runnerPath @resume | Out-Null
      }
    } finally {
      [System.IO.File]::WriteAllText(
        $runnerArtifacts[0].path,
        [string]$runnerArtifactBodies["debugApp"],
        [System.Text.UTF8Encoding]::new($false)
      )
    }
  }

  Invoke-CcrAlpha6RandomHostTest "stage2-remains-rejected" {
    $stage2 = @{} + $runnerPreflightArgs
    $stage2.DecoderStage = "Stage2"
    $stage2.OutputDirectory = Join-Path $runnerRoot "stage2-output"
    $stage2.RunId = "random-stage2"
    Assert-CcrAlpha6RandomThrows "ALPHA6_RANDOM_STAGE2_NOT_IMPLEMENTED" {
      & $runnerPath @stage2 | Out-Null
    }
  }
} finally {
  $env:CCR_ALPHA6_RANDOM_TEST_MODE = $previousRandomTestMode
  if (Test-Path -LiteralPath $runnerRoot) {
    Get-ChildItem -LiteralPath $runnerRoot -Recurse -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $runnerRoot -Recurse -Force
  }
}

if ($failures.Count -gt 0) {
  throw "Alpha6 random runner host tests failed ($($failures.Count)): $($failures -join ' || ')"
}
Write-Output "Alpha6 random runner host tests passed: $passes"
