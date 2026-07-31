# CT Cine Reviewer Android Alpha 6 Handoff

## 2026-07-31 Android Alpha 6 내부 사용자 합격 closure

최종 제품 판정은 다음과 같다.

`PASS — ANDROID_ALPHA6_INTERNAL_USER_ACCEPTED`

사용자가 S24 Ultra의 실제 제품 화면에서 실제 CCR 영상을 사용해 평가했으며,
`실제 영상 실사용에 큰 문제 없음`으로 확인했다. 아래 APK를 Android Alpha 6 내부
파일럿 기준선으로 사용한다.

| 항목 | 기준선 |
| --- | --- |
| applicationId | `com.snowberried.ctcinereviewer.internal` |
| versionName / versionCode | `0.2.0-alpha.6` / `7` |
| 제품 APK SHA-256 | `b5d7c927518cadaf19309bcbcc0be711db5703b5198a2c57a8056f6e456e907a` |
| signer certificate SHA-256 | `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e` |
| 제품 runtime source SHA | `c98264f2a10026a908e94c961bb13e4af2d59e60` |
| 사용자 합격일 | `2026-07-31 KST` |

이 사용자 acceptance는 자동 Full Stage 1 또는 Random 250의 PASS를 뜻하지 않는다.
Play Store release-ready 또는 의료기기 검증 완료도 뜻하지 않는다. Full Stage 1,
Random 250과 GateActivity/Surface harness 문제는
`DEFERRED_AUTOMATION_QA_DEBT`로 분류하며, 이 자동 QA 부채는 내부 파일럿을 차단하지
않는다. 아래의 자동 검증 실패와 Pending 기록은 삭제하거나 성공으로 바꾸지 않고
historical evidence로 유지한다.

현재 설치 앱은 삭제하거나 재설치하지 않으며 앱 데이터와 SAF grant를 보존한다.
후속 수정은 실제 사용 중 재현되는 제품 결함만 대상으로 삼는다. 별도 다음 버전 범위를
시작하려면 명시적인 승인이 필요하다.

`ONLY_FIX_REPRODUCIBLE_REAL_PRODUCT_DEFECTS_OR_START_AN_EXPLICIT_NEXT_VERSION_SCOPE`

## 2026-07-28 compiled runtime identity blocker와 재개 조건

`a6s1-274e5f6-200204` Stage 1은 제품 runtime이나 decoder 결함이 아니라 candidate
APK의 compiled identity 불일치로 correctness 첫 단계에서 fail-closed됐다. 실패한
debug/benchmark APK의 `BuildConfig.COMMIT_SHA`는 harness HEAD
`274e5f679b635b09424af73577b4e90ec5fd0a4b`였지만, 고정된 제품 runtime source는
`c98264f2a10026a908e94c961bb13e4af2d59e60`이다. CI는 기존부터
`CCR_ANDROID_COMMIT_SHA=c98264f2…`를 사용했으나 local candidate wrapper가 이 값을
Gradle child에 전달하지 않은 것이 원인이다.

실패 artifact
`C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-0.2.0-alpha.6-274e5f6-20260728-150221`
는 `VALID_SIGNED_ARTIFACT_EVIDENCE`이지만
`REJECTED_FOR_DEVICE_GATE_DUE_TO_EMBEDDED_RUNTIME_IDENTITY_MISMATCH`이며 Resume 또는
Random에 사용할 수 없다. manifest, APK, archive와 실패 evidence는 수정하지 않는다.

candidate wrapper는 signingReport와 assemble 모두에 canonical
`CCR_ANDROID_COMMIT_SHA=c98264f2…`를 설정하고 호출자 환경을 `finally`에서 복원한다.
artifact 디렉터리를 만들기 전에 SDK `apkanalyzer dex code`로 debugApp과 benchmarkApp의
실제 `BuildConfig.COMMIT_SHA`를 확인하며, manifest와 PROVENANCE에도 두 embedded identity를
기록한다. `runtimeSourceSha`는 frozen 제품 runtime이고 `harnessSourceSha`는 최종 clean
runner/test/docs commit이므로 두 값이 서로 다른 것이 정상이다.

새 revision 5 artifact의 full Stage 1 전에는
`run-s24-alpha6-identity-smoke.ps1`을 실행한다. 이 gate는
`ValidationHarnessV2.requireIdentity`를 재사용하며 fixture, frame decode, performance와
device setting 변경 없이 설치 APK/test SHA와 source identity를 확인한다. Stage 1 runner도
같은 smoke PASS를 settings 초기화보다 먼저 요구한다. 제품 runtime Kotlin, frozen 40개
입력과 performance threshold 변경은 0이다.

## 2026-07-29 첫 fixture open 실패 조사와 재개 조건

run `a6s1-7482800-234808`은 첫 fixture `h264-ip`를 여는 동안
`VIDEO_OPEN_FAILED`로 중단됐다. indexing error 뒤 verified frame은 `0/236`,
frame mismatch는 0이었고 performance는 시작하지 않았다.

보존된 실패 evidence와 artifact를 다시 해시하고 APK 안의 `h264-ip.mp4`를 직접
검사했다. APK asset은 `26,160 bytes`, SHA-256
`e84c39f433dbed61bfa3e5c96eff5eb74ffe86c53edc2d055166ce3884c44532`로
고정 fixture와 일치했다. 조사 시점에는 기기 cache 파일이 이미 없었고, 실패 시각
logcat 구간도 rollover되어 `LOGCAT_NOT_AVAILABLE`이었다. 기존
`ExactFrameSession`이 하위 예외를 `VIDEO_OPEN_FAILED`로 합쳤으므로 당시 실패가
provider, cache materialization, fd-only extractor, explicit range extractor 또는
codec 중 어느 단계였는지는 소급 판정할 수 없다.

따라서 역사적 근본 원인은 `UNCLASSIFIED_OPEN_PIPELINE_FAILURE`로 고정한다.
`CACHE_FILE_UNVERIFIED_REUSE`는 provider 구조에서 확인된 재발 위험일 뿐 당시 cache
손상 증거가 아니다. frozen runtime 입력에 포함된 provider와 제품 runtime Kotlin은
변경하지 않았다.

재발 시 단계를 잃지 않도록 AndroidTest에 단일 `h264-ip` 진단 probe와 17-fixture
open smoke를 추가했다. smoke는 asset → provider/PFD → fd-only extractor →
video track/sample → hardware decoder candidate까지만 확인하며 full-frame decode와
performance는 0이다. 진단 probe만 explicit offset/range extractor와 codec
configure/start를 추가로 확인하되 input/output buffer를 queue하지 않는다.
Stage 1 순서는 identity → fixture-open smoke → settings → settings settle →
render-open smoke → correctness → performance로 고정했으며 앞 Gate가 실패하면 뒤
단계는 실행하지 않는다.

현재 판정은
`FIXTURE_OPEN_DIAGNOSTIC_AND_SMOKE_HOST_READY; S24 DIAGNOSTIC/SMOKE PENDING`이다.
이번 closure에서는 Stage 1/Random `-PreflightOnly`, identity smoke, 필요 시 단일
diagnostic, 17-fixture smoke까지만 새 signed revision 5 artifact로 실행한다. Full
Stage 1과 Random 250은 그 다음 작업으로 남긴다.

## 2026-07-29 Stage 1 Surface 전환 race와 재개 조건

후속 run `a6s1-362001a-104314`은 identity와 fixture-open smoke `17/17` 뒤
correctness의 첫 `h264-ip` open에서 `VIDEO_OPEN_FAILED`로 중단됐다. 보존된 시간
순서에서는 correctness process 시작 직전 기기가 `DOZE_SUSPEND`였고, 같은
`GateActivity`가 resume 직후 pause/stop되면서 Surface가 create 후 약 20ms 만에
destroy됐다. 기존 `awaitSurface()`의 one-shot latch는 과거 create 성공을 현재
readiness로 재사용했다. EGL release 뒤 `beginFile()`이 provider/extractor 전에
실패할 수 있는 코드 경로와 실제 provider/extractor 진입 0도 일치한다.

최종 root cause는
`STAGE1_SURFACE_LIFECYCLE_AND_TRANSITION_RACE`이며 세부 분류는
`DISPLAY_DOZE_INDUCED_ACTIVITY_STOP + STALE_ONE_SHOT_SURFACE_READINESS`다.
제품 runtime, decoder, cache, reverse refill과 fixture 결함은 아니다.

debug `GateActivity`는 frozen 40개 runtime 입력에 포함되므로 직접 변경하지 않는다.
대신 AndroidTest 공통 helper가 open 직전에 `ActivityScenario`의 현재 RESUMED
Activity를 다시 취득하고 holder validity, decoder availability,
finishing/destroyed와 Surface generation을 함께 검사한다. 같은 generation의 300ms
안정 구간을 통과한 동일 인스턴스에만 open을 전달한다. dispatch 전 drift만 안정화부터
다시 시작하고 dispatch 뒤 drift는 즉시 구체적 failure로 남긴다.

Stage 1은 Debug app/test를 identity 전에 한 세트만 설치한다. fixture smoke,
render-open smoke와 correctness는 설치된 artifact identity를 다시 확인해 재사용한다.
settings 적용 뒤에는 250ms 간격 3개 연속 sample에서 6개 target 값, awake/display,
configuration/rotation과 관련 process 0을 확인한다. 이어 단일 `h264-ip` render-open
smoke가 index, metadata와 정확한 frame 0을 확인해야 correctness가 시작된다.

이 closure의 실기기 범위는 새 signed revision 5 artifact의 Stage 1/Random
`-PreflightOnly`, identity, fixture `17/17`, settings settle, 서로 다른 runId의
render-open smoke `10/10`과 cleanup까지다. Full Stage 1, Resume와 Random 250은
실행하지 않는다. 위 제한 검증이 모두 통과한 뒤의 다음 고정 작업은
`RUN_FRESH_FULL_STAGE1_WITH_THE_SURFACE_STABLE_REV5_ARTIFACT_SET`이다.
동일 Stage 1 settle 경로를 재사용하는 공개 제한 모드
`-SurfaceTransitionGateOnly`가 Debug 설치 1세트 뒤 render-open smoke를 고정 10회
수행하고 correctness/performance는 0회로 종료한다. 이 모드는 `-Resume` 또는
`-PreflightOnly`와 함께 사용할 수 없다.
settings settle은 app, debugTest, macrobenchmarkTest 세 패키지의 process 0을
검증한다. 각 render-open 회차 뒤에도 세 패키지를 force-stop하고 process 0을 확인한
immutable attempt cleanup을 해당 회차 checkpoint에 포함한다.

local host 검증은 candidate bridge `54`, render-open runner `15`, 실제 Surface 상태 머신
`19`, Stage 1 `178`,
전체 기존 host regression, PowerShell parser 47개, source contract, frozen runtime
`40/40`과 CI 동일 Android lint/unit/assemble까지 통과했다. CI, 새 signed revision 5
artifact와 S24 제한 검증은 Pending이다.

## 2026-07-29 자동 검증 시점 결론 (historical evidence)

Android `0.2.0-alpha.6` 제품 runtime의 exactness 수정과 역방향 cache-only 게시·rolling refill 구현은 소스와 원격 Draft PR에 보존됐다. S24 Stage 1 correctness는 최종 후보에서 7/7 통과했지만, 첫 reverse performance 시나리오는 정상적인 `cached probe miss → 동일 요청 actor fallback → 단일 publish`를 macrobenchmark가 금지해 fail-closed했다.

해당 측정기 계약은 제품 runtime을 변경하지 않고 수정해 host 검증과 CI를 통과했다.
후속 조사에서 기존 `49379c…` 인증서의 private key를 복구하지 못했으며, 자동 생성
debug key를 장기 candidate identity로 사용한 구조가 반복 blocker의 원인으로 확정됐다.
revision 4는 historical evidence로만 보존하고, 새 candidate는 전용
`ccr-internal-pilot-v1`과 artifact set revision 5를 사용한다. 2026-07-28 KST에 primary와
두 backup, 공개 certificate·policy 검증을 완료했다. 시작 HEAD `1ce42c1…`에서 signed
candidate APK 4종과 revision 5 artifact set 생성도 성공했다. 이후 확인된 active
Stage 1/Random의 historical revision 4 결합은 제품 runtime을 바꾸지 않는 전용 revision 5
device bridge로 제거했다. bridge를 포함하는 새 clean HEAD에서 APK 4종과 artifact set을
다시 생성해야 하며 S24 PreflightOnly, Stage 1, Random 250과 사용자 smoothness는 Pending이다.

당시 자동 검증 판정은 다음과 같다.

`BLOCKED_FOR_RELEASE — ALPHA6_REV5_DEVICE_RUNNER_BRIDGE_READY; CLEAN_HEAD CANDIDATE REBUILD, S24 STAGE 1, RANDOM 250, AND USER SMOOTHNESS REVIEW PENDING`

## Git과 원격 기준

- repository: `snowberried/CCR`
- branch: `codex/android-reverse-refill-smoothing`
- revision 5 bridge 시작 HEAD: `1ce42c1fad00da4d97a9ba8a9d61096c767a84f9`
- runtime source: `c98264f2a10026a908e94c961bb13e4af2d59e60`
- runtime input tree: `3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468`
- version: `0.2.0-alpha.6` / versionCode `7`
- applicationId: `com.snowberried.ctcinereviewer.internal`
- Draft PR: <https://github.com/snowberried/CCR/pull/3>
- PR base/head: `codex/android-bidirectional-navigation` ← `codex/android-reverse-refill-smoothing`
- PR 상태: Draft / Open / merge state Clean
- Android CI:
  - <https://github.com/snowberried/CCR/actions/runs/30209863856> — success
  - <https://github.com/snowberried/CCR/actions/runs/30209862124> — success
- `android-v0.2.0-alpha.6` tag: 없음
- merge, GitHub Release, binary upload: 미수행

이 문서를 포함하는 새 커밋이 생성되면 다음 artifact manifest의 `harnessSourceSha`는 `git rev-parse HEAD`의 새 값을 사용한다. runtime source와 runtime input tree는 바꾸지 않는다.

## 구현 상태

- exact texture cache hit은 renderer/EGL thread에서 게시하며 MediaCodec actor를 우회한다.
- cache miss만 동일 `FrameRequest`를 기존 actor exact 경로로 fallback한다.
- foreground accepted target은 최대 1개이며 PublicationGate가 swap 직전에 generation을 재검사한다.
- reverse refill은 partial append와 low-water trigger를 사용하고 64 MiB hard cap을 유지한다.
- 동일 refill generation의 previous-sync seek/flush 최대 1회 계약과 관련 진단이 있다.
- random planner는 requested category, attempted/final plan, fallback reason과 실제 output 비용을 분리한다.
- auxiliary decoder는 구현하지 않았다. Stage 1과 사용자 smoothness가 실패하기 전에는 추가하지 않는다.
- 제품 runtime, debugApp, benchmarkApp과 실제 사용자용 APK는 이번 측정기 수정에서 변경하지 않았다.

구조와 Gate의 상세 계약은 `android/validation/ALPHA6_REVERSE_REFILL_VALIDATION.md`를 따른다.

## Host 검증

`09af185f8d6f2047fd767fc6b1bbfbf2338aade0`에서 다음을 통과했다.

- desktop test: 106/106
- desktop production build: PASS
- package/privacy/update metadata: PASS
- Android runtime/source/fixture freeze: PASS
- Alpha 6 pinned artifact host tests: 39 PASS
- Alpha 6 tail contract tests: 56 PASS
- Stage 1 host tests: 97 PASS
- Random host tests: 19 PASS
- PowerShell parser checks: 31 PASS
- `git diff --check`: PASS

측정기 수정 커밋 `85d30f3901973e219eaa416577ca896b7867936a`에서 추가로 다음을 확인했다.

- Stage 1 host tests: 102 PASS
- `:macrobenchmark:assembleInternalBenchmark`: PASS
- Android CI 두 실행: PASS
- 제품 runtime 입력: 변경 없음

revision 5 device bridge closure에서는 다음 host 계약을 확인했다.

- candidate device bridge tests: 28 PASS
- Stage 1 host tests: 107 PASS
- Random host tests: 24 PASS
- PowerShell parser: 39 scripts PASS
- Alpha 4/5와 Alpha 6 revision 4 historical verifier: 보존
- Alpha 6 runtime freeze: 40/40 PASS
- 제품 runtime Kotlin과 40개 frozen input: 변경 없음

2026-07-29 fixture-open closure의 최종 local 검증 결과:

- desktop test: 106/106, production build PASS
- Android JVM: 162/162, failure/error/skip 0
- Android lint와 app/test APK 4종 assemble: PASS
- historical pinned host tests: 124 + 98 + 39 PASS
- candidate bridge/signing/tail: 47 + 29 + 56 PASS
- identity/fixture-open/Stage 1/Random runner: 19 + 20 + 127 + 24 PASS
- PowerShell parser: 44 scripts PASS
- fixed fixture 17개, source/privacy/CI contract와 APK privacy: PASS
- Alpha 4/5/6 runtime freeze: 32/37/40 PASS
- Alpha 6 runtime input tree:
  `3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468`
- 제품 runtime Kotlin, frozen provider와 40개 runtime input: 변경 없음

## revision 5 runner bridge와 pre-bridge artifact

`s24-alpha6-candidate-device-artifacts.ps1`이 historical Alpha 6 device primitive를
재사용하되 strict `Import-CcrAlpha6CandidateArtifactManifest`만 active 진입점으로 사용한다.
Stage 1과 Random은 revision 5, `SIGNED_CANDIDATE`, candidate flag, lineage, 공개 policy,
fingerprint·PEM hash와 실제 APK 4종 signer를 하나의 identity로 checkpoint, resume,
failure, final summary와 post-run rehash에 고정한다. revision 4 manifest는 active
runner에서 fail-closed하며 historical verifier에서는 계속 검증할 수 있다.

보존된 pre-bridge artifact set:

- path:
  `C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-0.2.0-alpha.6-1ce42c1-20260728-011441`
- manifest SHA-256:
  `72b964403c21021a3ef2db7df149e7131c96b991aff38ce033b2f52fdf9c3023`
- archive SHA-256:
  `3a8bc9563202bdd72e58934da211369d92cc46f2be620df7a612a067dadeac4f`
- 분류:
  `VALID_SIGNED_CANDIDATE_BUILD_EVIDENCE — SUPERSEDED_FOR_DEVICE_GATE_BY_REV5_RUNNER_BRIDGE`
- device gate:
  `NOT_ELIGIBLE_FOR_FINAL_DEVICE_GATE_AFTER_HARNESS_HEAD_CHANGE`

이 세트는 정상 생성된 signed build evidence이며 수정·삭제·덮어쓰지 않는다. 다만 manifest의
`harnessSourceSha=1ce42c1fad00da4d97a9ba8a9d61096c767a84f9`가 bridge commit 이전 HEAD를
가리키므로 다음 S24 실행에는 새 clean bridge HEAD에서 wrapper를 처음부터 다시 실행한다.

## historical revision 4 제품 artifact 기록

과거 읽기 전용 보존 위치였으나 현재 해당 `C:\tmp` 디렉터리는 존재하지 않는다. 추가 검색이나
복구를 시도하지 않으며 아래 값은 historical evidence 식별자로만 유지한다.

`C:\tmp\CCR-Android-0.2.0-alpha.6-09af185f8d6f-20260727-003105`

manifest:

- 파일: `artifact-manifest-v4.json`
- SHA-256: `9054fb0c42fe1429fff69dc92905d68c8b6109db7e732b1c863c08dd3cc64708`
- artifact set revision: `4`
- 이 manifest는 이전 harness `09af185…`용이므로 새 Stage 1 실행에 재사용하지 않는다.

| 역할 | SHA-256 |
| --- | --- |
| debugApp | `2d921dfb93aee0d845ad228fd2428336c8e43d31213e0f28b387b32d33b90ea7` |
| debugTest | `c1815419c8d2253bd200152c4bbc955ad620d79fe2368e25acbcd61d3c8887c7` |
| benchmarkApp | `5a18c885070b8ac92c59f08b01e5a80fc0bb38698876bef5eebd5f65738039b9` |
| 이전 macrobenchmarkTest | `11bdfcb0d57ea21ca817f0dc972993206c6bf1dd694855c51f40289da7817256` |

기존 보존 디렉터리와 파일을 수정하거나 덮어쓰지 않는다. 새 test APK는 새 외부 디렉터리에 기존 3개 APK의 byte-identical 복사본과 함께 보존한다.

## 최종 후보 Stage 1 실행 결과

- runId: `a6s1-09af-0727-0041`
- 출력: `C:\tmp\a6s1-09af-0727-0041`
- failure report:
  `C:\tmp\a6s1-09af-0727-0041\failure-alpha6-stage1-a6s1-09af-0727-0041-380aeb3db648428dbb80deaa5db5cb41.json`
- recovered trace:
  `C:\tmp\a6s1-09af-0727-0041\failure-trace-recovery\a6s1-09af-0727-0041-a6-bf-m1\CcrProductMacrobenchmark_hold1080MinusOne_iter000_2026-07-26-15-51-33.perfetto-trace`
- recovered trace SHA-256:
  `ee65a9274a98d1cc343fd64a887bccb040c648209b3758b9a713a9e69d2f4ffd`

Correctness:

- 7/7 scenario PASS
- 17 fixture 전체 236 frame mismatch 0
- representative, forward, reverse, release/cancel, direction, lifecycle PASS
- write-open, stale publication, swap, surface, cache hard-cap 위반 0

Performance:

- forward +1/+5 완료
- trace 6/30 생성
- 첫 reverse `hold1080MinusOne` iteration 000에서 macrobenchmark가 중단
- performance checkpoint와 최종 summary는 생성되지 않음
- Random은 정확성 우선 순서에 따라 실행하지 않음

## 실패 원인과 측정기 수정

실패 trace의 434개 성공 게시를 분류하면 다음과 같다.

- actor-only: 8
- cache-only: 424
- cached probe miss 후 actor fallback: 2
- 실행 시작 경로 없음: 0
- publication mismatch: 0

두 fallback은 cached-navigation section이 끝난 뒤 동일 request key의 actor decode가 시작되고 한 번만 게시됐다. runtime의 `cached_navigation_attempt=426`, `actor_bypass=424`, `miss_fallback=2`와 정확히 일치한다. 앱의 중복 수락·중복 게시·generation race 증거가 아니다.

기존 `CcrRequestStageMetric`은 actor start와 cached-navigation start가 반드시 XOR이어야 한다고 잘못 가정했고, fallback까지 cache-only로 중복 집계했다. `85d30f3…`은 다음과 같이 수정했다.

- actor/cached start 중 최소 하나를 요구
- both이면 cached start가 actor start보다 앞선 정상 fallback으로 허용
- cache-only는 `cached != null && actor == null`로 제한
- cache-only에만 decoder output 부재를 요구
- actor rows에는 fallback을 포함해 기존 host 합계 의미를 유지

관련 파일:

- `android/macrobenchmark/src/main/java/com/snowberried/ctcinereviewer/macrobenchmark/CcrProductMacrobenchmark.kt`
- `android/scripts/test-run-s24-alpha6-stage1.ps1`

## 폐기 대상 test APK

수정 후 생성된 로컬 macrobenchmark test APK:

- 위치:
  `android/macrobenchmark/build/outputs/apk/internal/benchmark/macrobenchmark-internal-benchmark.apk`
- SHA-256:
  `6e840c7714a4fbda527abaf73ea8c41d729e3bd3aa798b8429fb5c954b5826b5`
- 크기: `46,478,028 bytes`
- 서명 인증서 SHA-256: `4122e9cf0db971a79165db7ae7d14d0499a6d89846a33f75c47c7844630dbda0`

요구 인증서:

`49379c1b2a2fec8a50c320955a7027c515aff10f28483b08ae9c27b3ffcfbef0`

후속 읽기 전용 검사에서 현재 사용자 standard debug keystore의 인증서는
`db0a604f8d02d5d82cf9a4f0d89f1ba31400578cb36ec50869214a698be414b0`으로 확인돼
`49379c…`와 일치하지 않았다. `49379c…`, 현재 `db0a604f…`, 폐기 APK의 `4122e9cf…`는
새 candidate signer로 사용하지 않는다. 상세 내용은
`android/signing/SIGNING_INCIDENT_2026-07-27.md`를 따른다.

## 새 candidate 재개 전 필수 preflight

```powershell
git branch --show-current
git rev-parse HEAD
git status --short
git diff --check
```

필수 조건:

- branch가 `codex/android-reverse-refill-smoothing`
- worktree와 index가 clean
- runtime source가 `c98264f…`
- runtime input tree가 `3c932c…`
- `ccr-internal-pilot-v1` primary와 두 backup 검증 완료
- 공개 인증서·fingerprint·policy와 JKS 인증서 일치
- 공개 certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`
- 네 APK 모두 같은 새 signer 사용
- artifact set revision 5와 `signingLineage=ccr-internal-pilot-v1`
- 새 manifest의 `harnessSourceSha`가 재개 시점의 clean HEAD와 동일

새 보존 세트에는 `artifact-manifest-v5.json`, `SHA256SUMS.txt`, `PROVENANCE.txt`를 만들고
전체 파일을 read-only로 설정한다. `PROVENANCE.txt`에는
`signingMode=SIGNED_CANDIDATE`, lineage와 revision을 기록한다. `C:\tmp`는 사용하지 않는다.

## revision 5 active 실기기 명령

아래 명령은 새 clean bridge HEAD에서 다시 생성한 revision 5 manifest와 APK 4종에만
사용한다. private key가 없는 historical `49379c…` signer나 revision 4 manifest는 active
runner가 거부한다.

이번 fixture-open closure의 실행 순서는 다음과 같다.

1. 새 artifact 세트로 Stage 1 `-PreflightOnly`
2. 같은 artifact 세트로 Random `-PreflightOnly`
3. identity smoke
4. 필요할 때만 단일 `h264-ip` fixture-open diagnostic
5. 17-fixture open smoke
6. test/benchmark package 제거, 기기 설정 불변과 artifact 사후 hash 확인

Full Stage 1은 위 smoke가 통과한 뒤의 다음 필수 작업이다. Stage 1 correctness와
performance가 모두 통과하기 전에는 Random 250과 사용자 smoothness 판정을 실행하지
않는다.

Stage 1 기본 명령:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-stage1.ps1 `
  -ArtifactManifest <new-absolute-manifest-v5.json> `
  -ArtifactManifestSha256 <new-manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <git-rev-parse-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 <new-debug-app-sha256> `
  -OutputDirectory <new-absolute-stage1-output> `
  -RunId <new-unique-run-id> `
  -MaxMinutes 120
```

Random은 Stage 1 통과 후에만 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-random.ps1 `
  -ArtifactManifest <same-new-absolute-manifest-v5.json> `
  -ArtifactManifestSha256 <same-new-manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <same-clean-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 <same-new-debug-app-sha256> `
  -OutputDirectory <new-absolute-random-output> `
  -RunId <new-unique-run-id> `
  -MaxMinutes 25 `
  -DecoderStage Stage1
```

이전 Stage 1 실패 시 기기 `/data/local/tmp`에 두었던 진단 파일은 마지막 정리 시 기기가 ADB에서 사라져 삭제 여부를 확인하지 못했다. 재연결 후 아래 네 정확한 이름만 제거하고 광범위 삭제를 하지 않는다.

- `ccr_tp_09af`
- `ccr_a6_fail_m1.trace`
- `ccr_request_stage_xor.sql`
- `ccr_cached_nav_counters.sql`

## 금지 사항과 합격 조건

- desktop v0.5.9 runtime, tag, Latest Release를 변경하지 않는다.
- Alpha 4·5 runtime, artifact와 S24 evidence를 변경하지 않는다.
- 기존 Alpha 6 보존 디렉터리를 덮어쓰지 않는다.
- 제품 앱 APK를 측정기 서명 문제 때문에 재빌드하지 않는다.
- Stage 1 실패 상태에서 Random 또는 장기 Gate를 실행하지 않는다.
- 측정하지 않은 성능이나 사용자 smoothness를 PASS로 기록하지 않는다.
- 사용자 승인 전 tag, merge, GitHub Release, binary upload를 수행하지 않는다.
- DICOM/PACS, AI, cloud, 프로젝트 저장과 Play 배포로 범위를 넓히지 않는다.

동일 artifact Stage 1, Random 250과 GateActivity/Surface harness 문제는 2026-07-31
내부 사용자 합격 closure에서 `DEFERRED_AUTOMATION_QA_DEBT`로 분리됐다. 이 항목을
PASS로 바꾼 것은 아니며 Play Store 또는 의료기기 검증 기준으로 사용하지 않는다.
