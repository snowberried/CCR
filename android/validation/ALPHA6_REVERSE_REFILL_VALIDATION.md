# Android 0.2.0-alpha.6 역방향 refill·random tail 검증 계약

이 문서는 Alpha 5에서 확인된 역방향 주기적 끊김과 random seek tail을 줄이기 위한 Alpha 6 구조, 고정 source 경계, 아직 실행하지 않은 S24 Gate를 기록한다. 실제 사용자 영상, 파일명, URI, 경로 또는 source hash는 기록하지 않는다.

## 고정 기준

- 시작 branch/head: `codex/android-bidirectional-navigation` / `e2ef88f40869d8991eeba59f1e79e5a075d572e2`
- Alpha 6 branch: `codex/android-reverse-refill-smoothing`
- runtime source: `c9a7147d39d2d370916f325a108876c0947ddcb8`
- runtime input tree: `0eb249abadab7d89ba42a40772eb9a8610c193c87279c8633bb6275ac828fc0d`
- version: `0.2.0-alpha.6` / versionCode `7`
- artifact set: revision `4`
- applicationId: `com.snowberried.ctcinereviewer.internal`

Alpha 4·5 runtime manifest와 보존된 APK·S24 evidence는 변경하거나 재생성하지 않는다. Alpha 6 runtime manifest는 위 runtime commit의 40개 입력과 현재 worktree가 byte-for-byte 일치할 때만 통과한다.

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

## 호스트 검증

현재 확인된 결과:

- Android JVM: 160/160, failure/error/skip 0
- Android instrumentation Kotlin compile: PASS
- Alpha 6 tail contract host test: 36 PASS
- pinned artifact v4 host-negative test: 38 PASS
- Stage 1 runner host-negative test: 72 PASS
- random runner host-negative test: 17 PASS
- Alpha 4·5·6 runtime freeze verifier: PASS
- source/privacy/CI contract: PASS

최종 clean build, desktop 회귀, Android lint·APK 4종 build·privacy 검사는 최종 harness commit에서 다시 실행한다.

## S24 hard Gate — Pending

실기기 측정은 이번 호스트 작업에서 실행하지 않았다. 따라서 아래 항목은 모두 `Pending — device run deferred`다.

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

최종 clean HEAD에서 APK 4개와 외부 artifact manifest v4를 만든 뒤 manifest 자체 SHA-256까지 고정한다. 실기기 실행 스크립트는 build/assemble을 호출하지 않으며 실행 전후 APK를 다시 해시한다. `<...>` 값은 외부 manifest 생성 후 확정된 절대 경로와 실제 hash로 바꾼다.

두 runner는 ADB 호출 자체를 `MaxMinutes`에 묶고 제한시간에 도달한 process를 bounded cleanup 뒤 종료한다. 이전 작업의 잔존값인 `stay_on_while_plugged_in=15` 또는 `screen_off_timeout=600000`을 발견하면 원래 사용자값을 추측하지 않고 중단한다. 신뢰 가능한 원래값을 확인한 경우에만 `-OriginalStayAwakeSetting` 또는 `-OriginalScreenTimeoutSetting`으로 전달한다. 강제종료 후 `-Resume`에서는 첫 시도의 외부 device-settings preflight JSON에 고정된 복구 기준과 현재 값이 원래값·도구 적용값 조합으로만 이루어진 경우에 한해 먼저 복구하며, 제3의 값이 있으면 사용자 변경 가능성 때문에 fail-closed한다. 관찰값·복구 기준·실행 전 복구 여부는 시도별 외부 JSON에 남긴다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-stage1.ps1 `
  -ArtifactManifest <absolute-manifest-v4.json> `
  -ArtifactManifestSha256 <manifest-sha256> `
  -RuntimeSourceSha c9a7147d39d2d370916f325a108876c0947ddcb8 `
  -HarnessSourceSha <final-clean-head> `
  -RuntimeInputsTreeSha256 0eb249abadab7d89ba42a40772eb9a8610c193c87279c8633bb6275ac828fc0d `
  -ExpectedDebugAppSha256 <debug-apk-sha256> `
  -OutputDirectory <absolute-external-output> `
  -RunId <unique-run-id> `
  -MaxMinutes 120
```

Stage 1 correctness와 tail Gate가 통과한 뒤에만 같은 manifest와 APK로 random Gate를 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-random.ps1 `
  -ArtifactManifest <absolute-manifest-v4.json> `
  -ArtifactManifestSha256 <manifest-sha256> `
  -RuntimeSourceSha c9a7147d39d2d370916f325a108876c0947ddcb8 `
  -HarnessSourceSha <final-clean-head> `
  -RuntimeInputsTreeSha256 0eb249abadab7d89ba42a40772eb9a8610c193c87279c8633bb6275ac828fc0d `
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
