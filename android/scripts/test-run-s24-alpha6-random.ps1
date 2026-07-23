$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runnerPath = Join-Path $PSScriptRoot "run-s24-alpha6-random.ps1"
$alpha6PinnedPath = Join-Path $PSScriptRoot "s24-alpha6-pinned-artifacts.ps1"
. $alpha6PinnedPath

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
  "Assert-CcrAlpha6RandomTrace"
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
    "Invoke-CcrAlpha6PinnedHostPreflight", "Assert-CcrAlpha6ArtifactSetUnchanged",
    "ArtifactManifestSha256", "ExpectedDebugAppSha256", "OutputDirectory", "PreflightOnly", "Resume",
    "MaxMinutes", "checkpoint-alpha6-random-exactness", "checkpoint-alpha6-random-performance",
    "correctnessFailureBlocksPerformance", "BuildCommandCount 0L", "preRunArtifactRehash",
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
    "Assert-CcrAlpha6RandomCompletedSummary"
  )) {
    if (-not $source.Contains($marker)) { throw "RUNNER_MARKER_MISSING:$marker" }
  }
  foreach ($forbidden in @(
    "Alpha5RandomSeekExactnessTest#", "Alpha5RandomSeekPerformanceTest#",
    'alpha5-cost-aware-random-exactness', 'alpha5-cost-aware-random-performance'
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

if ($failures.Count -gt 0) {
  throw "Alpha6 random runner host tests failed ($($failures.Count)): $($failures -join ' || ')"
}
Write-Output "Alpha6 random runner host tests passed: $passes"
