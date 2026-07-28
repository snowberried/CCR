# Android 0.2.0-alpha.6 역방향 refill·random tail 검증 계약

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
- Stage 1은 identity smoke PASS 증거 뒤에만 settings를 변경한다.

실패 artifact
`CCR-Android-0.2.0-alpha.6-274e5f6-20260728-150221`은 signer가 유효한 보존
evidence지만 embedded runtime identity 불일치로 device Gate, Resume와 Random에 사용할
수 없다. 이 closure에서 제품 runtime Kotlin, frozen input 40개와 threshold 변경은 0이다.

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
- Alpha 6 tail contract host test: 36 PASS
- pinned artifact v4 host-negative test: 38 PASS
- Stage 1 runner host-negative test: 72 PASS
- random runner host-negative test: 17 PASS
- Alpha 4·5·6 runtime freeze verifier: PASS
- source/privacy/CI contract: PASS
- revision 5 candidate device bridge host test: 28 PASS
- revision 5 Stage 1 runner host test: 107 PASS
- revision 5 Random runner host test: 24 PASS
- PowerShell parser: 39 scripts PASS

최종 clean build, desktop 회귀, Android lint·APK 4종 build·privacy 검사는 최종 harness commit에서 다시 실행한다.

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

`BLOCKED_FOR_RELEASE — host contracts prepared; final same-artifact S24 correctness, tail performance, random performance, and user smoothness are pending.`

tag, merge, GitHub Release와 binary upload는 수행하지 않는다.
