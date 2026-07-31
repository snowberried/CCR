# Android 0.2.0-alpha.6 역방향 refill·random tail 검증 계약

## 2026-07-31 내부 사용자 합격과 자동 QA 부채

사용자가 S24 Ultra의 실제 제품 화면에서 실제 CCR 영상을 사용해 평가한 결과는
`실제 영상 실사용에 큰 문제 없음`이며, 최종 제품 판정은 다음과 같다.

`PASS — ANDROID_ALPHA6_INTERNAL_USER_ACCEPTED`

내부 파일럿 기준선은 applicationId
`com.snowberried.ctcinereviewer.internal`, versionName/versionCode
`0.2.0-alpha.6`/`7`, 제품 APK SHA-256
`b5d7c927518cadaf19309bcbcc0be711db5703b5198a2c57a8056f6e456e907a`, signer
certificate SHA-256
`3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`, 제품 runtime
source SHA `c98264f2a10026a908e94c961bb13e4af2d59e60`이다. 사용자 합격일은
`2026-07-31 KST`다.

사용자 acceptance와 자동 검증 상태는 분리한다. 이 판정은 Full Stage 1 또는 Random
250의 자동 PASS가 아니며 Play Store release-ready 또는 의료기기 검증 완료도 아니다.
Full Stage 1, Random 250과 GateActivity/Surface harness 문제는
`DEFERRED_AUTOMATION_QA_DEBT`다. 이 부채는 내부 파일럿을 차단하지 않으며, 아래의 실패와
Pending 결과는 변경하지 않고 historical evidence로 보존한다.

현재 설치 앱은 삭제·재설치하지 않고 앱 데이터와 SAF grant를 보존한다. 후속 수정은
실제 사용 중 재현되는 제품 결함만 대상으로 한다.

## compiled runtime identity 선행 Gate

실패 run `a6s1-274e5f6-200204`의 candidate APK에는
`BuildConfig.COMMIT_SHA=274e5f679b635b09424af73577b4e90ec5fd0a4b`가 포함됐고,
instrumentation이 요구한 runtime source는
`c98264f2a10026a908e94c961bb13e4af2d59e60`이었다. app Gradle의 해석 순서는
`CCR_ANDROID_COMMIT_SHA`, `GITHUB_SHA`, `git rev-parse HEAD`이며 CI는 이미 첫 값을
frozen runtime으로 설정했다. local candidate wrapper의 전달 누락 때문에 harness HEAD가
APK identity로 들어간 것이 원인이다.

수정 계약은 다음과 같다.

- candidate Gradle child의 `CCR_ANDROID_COMMIT_SHA`는 항상 frozen runtime source다.
- 성공·실패 후 호출자 process 환경을 정확히 복원한다.
- debugApp과 benchmarkApp의 실제 DEX `BuildConfig.COMMIT_SHA`를 artifact 생성 전에
  `apkanalyzer`로 확인한다.
- manifest `runtimeSourceSha`와 embedded 두 값은 frozen runtime이며,
  `harnessSourceSha`만 최종 clean harness commit이다.
- revision 5 importer는 embedded identity가 없거나 다르면 거부한다.
- S24 identity smoke는 `ValidationHarnessV2.requireIdentity`만 실행하고 fixture, decode,
  performance와 settings write를 수행하지 않는다.
- Stage 1은 identity smoke와 17-fixture open smoke PASS 증거 뒤에만 settings를
  변경한다.

실패 artifact
`CCR-Android-0.2.0-alpha.6-274e5f6-20260728-150221`은 signer가 유효한 보존
evidence지만 embedded runtime identity 불일치로 device Gate, Resume와 Random에 사용할
수 없다. 이 closure에서 제품 runtime Kotlin, frozen input 40개와 threshold 변경은 0이다.

## 첫 fixture open 실패의 증거 경계와 선행 Gate

run `a6s1-7482800-234808`은 첫 `h264-ip` fixture에서 indexing error와
`VIDEO_OPEN_FAILED`를 남기고 종료됐다. verified frame은 `0/236`, mismatch는 0이며
performance는 실행하지 않았다. 보존 artifact의 `h264-ip.mp4`는 `26,160 bytes`,
SHA-256
`e84c39f433dbed61bfa3e5c96eff5eb74ffe86c53edc2d055166ce3884c44532`로
golden 입력과 일치한다.

실패 구간 logcat은 보존되지 않아 `LOGCAT_NOT_AVAILABLE`이고, 조사 시점의 기기
cache 파일도 없었다. 기존 open 경로가 하위 예외를 `VIDEO_OPEN_FAILED`로 합쳤으므로
provider/cache/extractor/codec 중 당시 실패 단계를 증명할 수 없다. 역사적 분류는
`UNCLASSIFIED_OPEN_PIPELINE_FAILURE`이며 cache corruption으로 단정하지 않는다.
provider의 existence-only reuse는 `CACHE_FILE_UNVERIFIED_REUSE`라는 구조적 위험이지만
당시 원인의 증거는 아니다. provider는 frozen 40 runtime 입력 중 하나이므로 이번
closure에서 변경하지 않는다.

재발 방지 계약은 다음과 같다.

- 17-fixture smoke PASS는 fixture/asset/provider-cache-PFD/fd-only extractor/video
  track/sample/hardware decoder candidate가 각각 `17/17`이어야 한다.
- smoke의 write-capable provider open, explicit-range extractor, codec
  configure/start, full-frame decode, performance count는 모두 0이어야 한다.
- 단일 `h264-ip` diagnostic은 위 기본 단계가 `1/1`이고 explicit-range extractor와
  codec configure/start도 `1/1`이어야 한다. queued input/output buffer,
  full-frame decode와 performance count는 모두 0이어야 한다.
- provider가 반환한 내용이 고정 asset의 byte 수와 SHA-256에 일치하지 않으면 자동
  복구나 덮어쓰기 없이 fail-closed한다.
- 각 단계의 원시 report를 immutable evidence로 먼저 보존하고, report parsing이나
  contract 검사가 실패해도 원시 파일을 잃지 않는다.
- Stage 1 순서는 identity → fixture-open smoke → settings → settings settle →
  render-open smoke → correctness → performance다. 선행 Gate 실패 시 아직 시작하지
  않은 correctness와 performance는 0이다.

허용된 실기기 closure 순서는 Stage 1 `-PreflightOnly` → Random
`-PreflightOnly` → identity smoke → 필요 시 단일 diagnostic → 17-fixture smoke →
settings settle → 서로 다른 runId의 render-open smoke `10/10`이다.
이 결과가 나오기 전에는 S24 PASS로 기록하지 않는다.
이 제한 검증은 Stage 1 runner의 `-SurfaceTransitionGateOnly`로 같은 settle 구현을
재사용하며, Debug 설치는 1세트이고 correctness/performance 실행 수는 0으로
고정한다. `-Resume`·`-PreflightOnly`와의 조합은 시작 전에 거부한다.

## Stage 1 Surface 전환 Gate

run `a6s1-362001a-104314`에서는 fixture-open smoke `17/17` 뒤 correctness process가
기기의 `DOZE_SUSPEND` 전환과 겹쳤다. 같은 Activity의 Surface가 create 후 약 20ms
만에 destroy됐지만 기존 `GateActivity.awaitSurface()`는 과거 create에서 열린 one-shot
latch 때문에 현재 Surface 소실을 감지하지 못했다. EGL release 뒤 `beginFile()`은
provider/extractor 진입 전에 실패할 수 있고 상위 status는 `VIDEO_OPEN_FAILED`로
축약된다. 최종 분류는
`STAGE1_SURFACE_LIFECYCLE_AND_TRANSITION_RACE` /
`DISPLAY_DOZE_INDUCED_ACTIVITY_STOP + STALE_ONE_SHOT_SURFACE_READINESS`다.

Surface 전환 계약은 다음과 같다.

- debug `GateActivity`는 frozen runtime 입력이므로 수정하지 않는다.
- AndroidTest 공통 helper가 open 직전에 `ActivityScenario`의 현재 RESUMED Activity를
  다시 취득한다.
- holder Surface validity, decoder Surface availability, finishing/destroyed와 Surface
  generation을 함께 확인하고 동일 generation의 300ms 안정 구간을 요구한다.
- open 전 generation 또는 Activity drift는 안정화부터 다시 시작하고, open 전달 뒤
  drift는 재시도로 숨기지 않고 구체적인 failure evidence로 종료한다.
- identity 전 Debug app/test를 한 세트만 설치한다. fixture/render/correctness는 설치된
  APK SHA, package, signer와 runner/target identity를 재검증하고 `install -r` 없이
  진행한다.
- settings 적용 후 250ms 간격 3개 연속 sample에서 6개 target 값, awake/display ON,
  configuration/rotation 안정과 app/debugTest/macrobenchmarkTest process 0을 확인한다.
- render-open smoke는 `h264-ip` 하나에서 index, metadata, hardware decoder와 정확한
  frame 0 FrameKey/texture timestamp/image probe를 확인한다. full 17 fixture,
  236-frame correctness와 performance는 실행하지 않는다.
- 제한 10회 검증은 각 회차 뒤 세 validation 패키지를 force-stop하고 process 0인
  immutable attempt cleanup evidence를 남긴다.
- 이 closure에서는 Full Stage 1, Resume와 Random 250을 실행하지 않는다.

local host 기준으로 candidate bridge `54`, render-open runner `15`, 실제 Surface 상태 머신
`19`, Stage 1 `178`,
전체 기존 host regression, PowerShell parser 47개, source contract, frozen runtime
`40/40`과 CI 동일 Android lint/unit/assemble가 통과했다. CI와 새 signed artifact 및
S24 제한 검증은 아직 Pending이다.

이 문서는 Alpha 5에서 확인된 역방향 주기적 끊김과 random seek tail을 줄이기 위한 Alpha 6 구조, 고정 source 경계, 아직 실행하지 않은 S24 Gate를 기록한다. 실제 사용자 영상, 파일명, URI, 경로 또는 source hash는 기록하지 않는다.

## 고정 기준

- 시작 branch/head: `codex/android-bidirectional-navigation` / `e2ef88f40869d8991eeba59f1e79e5a075d572e2`
- Alpha 6 branch: `codex/android-reverse-refill-smoothing`
- runtime source: `c98264f2a10026a908e94c961bb13e4af2d59e60`
- runtime input tree: `3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468`
- version: `0.2.0-alpha.6` / versionCode `7`
- historical artifact set: revision `4`
- new signed candidate policy: revision `5`, signing lineage `ccr-internal-pilot-v1`
- signing baseline: `READY`, certificate SHA-256
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`
- applicationId: `com.snowberried.ctcinereviewer.internal`

Alpha 4·5 runtime manifest와 보존된 APK·S24 evidence는 변경하거나 재생성하지 않는다. Alpha 6 runtime manifest는 위 runtime commit의 40개 입력과 현재 worktree가 byte-for-byte 일치할 때만 통과한다.

## revision 5 device runner bridge

시작 HEAD `1ce42c1fad00da4d97a9ba8a9d61096c767a84f9`에서 signed candidate APK 4종과
artifact revision 5 생성은 성공했다. 이 세트는
`VALID_SIGNED_CANDIDATE_BUILD_EVIDENCE — SUPERSEDED_FOR_DEVICE_GATE_BY_REV5_RUNNER_BRIDGE`로
보존한다. manifest SHA-256은
`72b964403c21021a3ef2db7df149e7131c96b991aff38ce033b2f52fdf9c3023`, archive SHA-256은
`3a8bc9563202bdd72e58934da211369d92cc46f2be620df7a612a067dadeac4f`다.

기존 active runner가 `s24-alpha6-pinned-artifacts.ps1`의 revision 4 importer와 literal
revision 4 identity를 사용하던 문제는 전용 candidate device bridge로 수정했다. historical
helper는 그대로 유지한다. 새 bridge는 strict revision 5 importer, repository public
policy·fingerprint·PEM, 실제 APK 4종 signer를 결합하며 이 identity를 모든 checkpoint,
resume, failure, summary와 실행 후 rehash에 사용한다. 검증 APK 내부 revision 식별 상수만
5로 맞췄고 제품 runtime과 metric·threshold는 변경하지 않았다.

bridge commit 뒤 기존 manifest의 harness source는 stale이므로 최종 device Gate 분류는
`NOT_ELIGIBLE_FOR_FINAL_DEVICE_GATE_AFTER_HARNESS_HEAD_CHANGE`다. 새 clean bridge HEAD에서
네 APK와 revision 5 artifact set을 모두 다시 만들어야 한다.

## Alpha 5 관찰 기준선

Alpha 5 S24 실측에서 +1/-1/+5/-5 평균 처리량은 각각 약 14.62/14.31/11.84/11.68 FPS였다. 평균 대칭성은 충족했지만 -1 interval CV는 약 37~38%, 150 ms 초과 interval은 run당 14~15회였고 약 1.8~1.9초마다 평균 약 192 ms gap이 나타났다. 긴 gap 44/44는 reverse-window build·seek·flush·refill과 겹쳤다.

random 250 target은 전체 p50/p95/max 44.054/175.039/406.783 ms, same-GOP p95 342.769 ms, far-random p95 304.191 ms였다. 실제 `SAME_GOP_CURSOR` p95는 약 80.5 ms, `PREVIOUS_SYNC` p95는 약 304.2 ms였다. 이 값은 Alpha 6 합격 결과가 아니라 비교 기준이다.

## Alpha 6 구조

- exact texture cache hit은 renderer/EGL thread의 cached-navigation lane에서 게시한다. codec actor, extractor 위치, codec cursor와 refill cursor를 변경하지 않는다.
- PublicationGate가 file/surface/request generation을 수락하고 swap 직전에 다시 검사한다. stale texture는 소비할 수 있지만 swap하지 않는다.
- cache miss만 기존 single codec actor의 exact seek/decode 경로로 내려간다.
- reverse refill은 같은 generation에서 previous-sync seek/flush를 최대 한 번 수행하고 slice 사이에 cursor와 duplicate ordinal 상태를 보존한다.
- low-water에서 refill을 시작하고 exact texture 한 장마다 ordered partial append한다. staged key도 eviction 보호 집합에 포함하며 64 MiB hard cap을 유지한다.
- EGL/actor consume과 refill completion은 같은 depletion tracker로 직렬화하여 순간적인 window depletion을 놓치지 않는다.
- refill 최초 seek가 예외를 내도 generation과 실제 seek/flush delta, `CODEC_ERROR` 취소 증거가 남는다.
- random report는 requested category, attempted/final selected plan, fallback reason, cursor/previous-sync frame, 예상/실제 output 수, seek/flush와 auxiliary 사용 여부를 분리한다. sequential continuation이 실행 중 exact seek로 fallback하면 최종 plan을 `PREVIOUS_SYNC`로 갱신한다.
- auxiliary decoder는 구현하지 않았다. Stage 1 S24 tail Gate와 사용자 smoothness가 실패하기 전에는 추가하지 않는다.

## 1차 동일-artifact S24 실패와 최소 수정

첫 candidate runtime `c9a7147d39d2d370916f325a108876c0947ddcb8`, harness
`6337853248f05b36b5c6d50f09c16fdf8a4a3e84`로 Stage 1 correctness를 실행했다. 17 fixture
236 frame과 대표 7 fixture는 mismatch·write-open 0으로 통과했지만, forward HEVC Main8 12-frame
fixture의 +1에서 `sequentialEntryCount == 0`이어서 correctness가 fail-closed했다. 마지막 frame의
expected/actual FrameKey는 `(11, 916666, 0)`, texture timestamp는 `916666000 ns`로 일치했으며
performance와 random은 실행하지 않았다.

동일 APK를 재빌드하지 않은 단일 atrace 재현에서 HEVC frame 0의 첫 output 전에 정확히 13개
`CCR.codec.feed` section이 확인됐다. 이는 12 sample과 입력 EOS가 모두 먼저 queue됐음을 뜻한다.
기존 상태는 입력 EOS queue를 출력 EOS 도달로 취급해 buffered output continuation을 거부했다.
runtime `c98264f2a10026a908e94c961bb13e4af2d59e60`은 입력 EOS와 실제 target output EOS를 분리하고,
입력 EOS 이후에는 새 input을 넣지 않은 채 이미 queue된 output만 순차 drain한다. 새 동일-artifact
Stage 1 재실행은 Pending이다. 첫 candidate APK·manifest·실패 보고서·atrace는 외부 보존 위치에
그대로 유지한다.

## 호스트 검증

현재 확인된 결과:

- Android JVM: 162/162, failure/error/skip 0
- Android instrumentation Kotlin compile: PASS
- Android lint와 app/test APK 4종 assemble: PASS
- desktop test 106/106와 production build: PASS
- pinned artifact host tests: 124 PASS
- Alpha 5 pinned artifact host tests: 98 PASS
- Alpha 6 revision 4 host tests: 39 PASS
- Alpha 6 tail contract host tests: 56 PASS
- pilot signing host tests: 29 PASS
- revision 5 candidate device bridge host tests: 47 PASS
- identity smoke runner host tests: 19 PASS
- fixture-open smoke runner host tests: 20 PASS
- revision 5 Stage 1 runner host tests: 127 PASS
- revision 5 Random runner host test: 24 PASS
- PowerShell parser: 44 scripts PASS
- Alpha 4·5·6 runtime freeze verifier: 32/37/40 PASS
- Alpha 6 runtime input tree:
  `3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468`
- source/privacy/CI contract와 debug/benchmark APK privacy: PASS
- 제품 runtime Kotlin, frozen provider와 40개 runtime input 변경: 0

커밋 뒤 같은 검증을 CI에서 다시 확인한다.

## S24 hard Gate — Pending

첫 candidate correctness는 위 HEVC 순차 mechanism 오류로 중단됐다. 아래 항목은 새 runtime
동일-artifact 재실행 전까지 `Pending — corrected artifact not yet run`이다.

- 기존 17 fixture와 대표 7 fixture exactness
- forward +1/+5 및 reverse -1/-5 exactness
- H.264 B-frame, long-GOP, HEVC Main8, VFR reverse -1/-5 각 30초 × 3
- direction reversal, Surface replacement, lifecycle stop/resume
- interval CV, p99, p99.5, max와 1.5×/2× cadence gap
- refill/build 연관 long gap 0
- generation당 seek/flush 최대 1
- reverse FPS가 capped forward FPS의 80% 이상
- random exact 250/250, same-GOP 허용 plan 95%, category별 p95
- 사용자 역방향 smoothness 판정
- codec switch 500회, lifecycle 50회, idle 10분, close 후 RAM, USB 분리 battery 30분

정확성·identity·privacy·trace·cache hard contract가 실패하면 성능 단계는 실행하지 않는다. 기술 Gate가 모두 통과해도 사용자 smoothness는 자동 PASS로 바꾸지 않는다.

## 동일 artifact 실행 순서

revision 4와 `49379c…` signer는 historical evidence로만 보존한다. 새 candidate는 최종
clean HEAD에서 전용 wrapper가 APK 4개에 `ccr-internal-pilot-v1` signer를 적용하고 외부
artifact manifest v5를 만든 뒤 manifest 자체 SHA-256까지 고정한다. 일반 debug와
`CI_EPHEMERAL_DEBUG` APK는 candidate로 허용하지 않는다. 실기기 실행 스크립트는
build/assemble을 호출하지 않으며 실행 전후 APK를 다시 해시한다.

아래 명령은 새 clean bridge HEAD에서 다시 생성한 revision 5 artifact set에만 사용한다.
revision 4 historical manifest는 active runner가 명확히 거부한다.

두 runner는 ADB 호출 자체를 `MaxMinutes`에 묶고 제한시간에 도달한 process를 bounded cleanup 뒤 종료한다. 이전 작업의 잔존값인 `stay_on_while_plugged_in=15` 또는 `screen_off_timeout=600000`을 발견하면 원래 사용자값을 추측하지 않고 중단한다. 신뢰 가능한 원래값을 확인한 경우에만 `-OriginalStayAwakeSetting` 또는 `-OriginalScreenTimeoutSetting`으로 전달한다. 강제종료 후 `-Resume`에서는 첫 시도의 외부 device-settings preflight JSON에 고정된 복구 기준과 현재 값이 원래값·도구 적용값 조합으로만 이루어진 경우에 한해 먼저 복구하며, 제3의 값이 있으면 사용자 변경 가능성 때문에 fail-closed한다. 관찰값·복구 기준·실행 전 복구 여부는 시도별 외부 JSON에 남긴다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-stage1.ps1 `
  -ArtifactManifest <absolute-manifest-v5.json> `
  -ArtifactManifestSha256 <manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <final-clean-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 <debug-apk-sha256> `
  -OutputDirectory <absolute-external-output> `
  -RunId <unique-run-id> `
  -MaxMinutes 120
```

Stage 1 correctness와 tail Gate가 통과한 뒤에만 같은 manifest와 APK로 random Gate를 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-random.ps1 `
  -ArtifactManifest <absolute-manifest-v5.json> `
  -ArtifactManifestSha256 <manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <final-clean-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 <debug-apk-sha256> `
  -OutputDirectory <absolute-external-output> `
  -RunId <unique-run-id> `
  -MaxMinutes 25 `
  -DecoderStage Stage1
```

`Stage2`는 auxiliary decoder가 구현되지 않았으므로 현재 runner가 fail-closed로 거부한다. Stage 1 S24 tail Gate와 사용자 smoothness 실패 전에는 이를 해제하지 않는다.

## 현재 판정

`PASS — ANDROID_ALPHA6_INTERNAL_USER_ACCEPTED`

Full Stage 1, Random 250과 GateActivity/Surface harness 문제는
`DEFERRED_AUTOMATION_QA_DEBT`이며 자동 PASS로 간주하지 않는다. 이 내부 사용자 합격은
Play Store release-ready 또는 의료기기 검증 완료를 뜻하지 않는다.

tag, merge, GitHub Release와 binary upload는 수행하지 않는다.
