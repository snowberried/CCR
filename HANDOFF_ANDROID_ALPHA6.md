# CT Cine Reviewer Android Alpha 6 Handoff

## 결론

Android `0.2.0-alpha.6` 제품 runtime의 exactness 수정과 역방향 cache-only 게시·rolling refill 구현은 소스와 원격 Draft PR에 보존됐다. S24 Stage 1 correctness는 최종 후보에서 7/7 통과했지만, 첫 reverse performance 시나리오는 정상적인 `cached probe miss → 동일 요청 actor fallback → 단일 publish`를 macrobenchmark가 금지해 fail-closed했다.

해당 측정기 계약은 제품 runtime을 변경하지 않고 수정해 host 검증과 CI를 통과했다. 다만 수정된 macrobenchmark test APK의 첫 로컬 빌드는 기존 고정 APK와 다른 debug 인증서로 서명돼 폐기 대상이다. 동일 인증서 test APK 재생성, 새 artifact manifest v4, Stage 1 전체 재실행과 Random 250은 아직 Pending이다.

현재 판정은 다음과 같다.

`BLOCKED_FOR_RELEASE — corrected measurement APK, full same-artifact Stage 1, Random 250, and final user smoothness review are pending.`

## Git과 원격 기준

- repository: `snowberried/CCR`
- branch: `codex/android-reverse-refill-smoothing`
- 인수인계 작성 전 HEAD: `85d30f3901973e219eaa416577ca896b7867936a`
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

## 보존된 제품 artifact

읽기 전용 보존 위치:

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

`C:\Users\snowb\.android\debug.keystore`의 `androiddebugkey`는 요구 인증서와 일치한다. 현재 build output은 인증서가 다르므로 manifest에 넣거나 실기기에 설치하지 않는다. 새 APK를 생성한 뒤 `apksigner verify --print-certs`로 `49379c…` 일치를 확인하기 전에는 다음 단계로 넘어가지 않는다.

## 재개 전 필수 preflight

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
- 새 macrobenchmarkTest 인증서가 `49379c…`
- debugApp/debugTest/benchmarkApp SHA가 위 표와 byte-for-byte 동일
- 새 manifest의 `harnessSourceSha`가 재개 시점의 clean HEAD와 동일

새 보존 세트에는 `artifact-manifest-v4.json`, `SHA256SUMS.txt`, `PROVENANCE.txt`를 만들고 전체 파일을 read-only로 설정한다. `PROVENANCE.txt`에는 제품 APK 3개는 재빌드하지 않았고 macrobenchmark test만 측정기 수정으로 교체했다는 사실을 기록한다.

## 실기기 실행 순서

1. 새 artifact 세트로 Stage 1 `-PreflightOnly`
2. 새 runId와 새 출력 디렉터리로 Stage 1 전체 실행
3. correctness 7/7과 performance 10 scenario/30 trace, checkpoint, final summary를 모두 확인
4. Stage 1 hard Gate가 통과한 경우에만 같은 manifest로 Random 250 실행
5. test/benchmark package 제거, 기기 설정 원복과 artifact 사후 hash 확인
6. 사용자 역방향 smoothness 판정

Stage 1 기본 명령:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-stage1.ps1 `
  -ArtifactManifest <new-absolute-manifest-v4.json> `
  -ArtifactManifestSha256 <new-manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <git-rev-parse-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 2d921dfb93aee0d845ad228fd2428336c8e43d31213e0f28b387b32d33b90ea7 `
  -OutputDirectory <new-absolute-stage1-output> `
  -RunId <new-unique-run-id> `
  -MaxMinutes 120
```

Random은 Stage 1 통과 후에만 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\android\scripts\run-s24-alpha6-random.ps1 `
  -ArtifactManifest <same-new-absolute-manifest-v4.json> `
  -ArtifactManifestSha256 <same-new-manifest-sha256> `
  -RuntimeSourceSha c98264f2a10026a908e94c961bb13e4af2d59e60 `
  -HarnessSourceSha <same-clean-head> `
  -RuntimeInputsTreeSha256 3c932cf766d65f6b8dca7bdb4ec0fcf5232d0373d73e07a68bedbbe02b5e9468 `
  -ExpectedDebugAppSha256 2d921dfb93aee0d845ad228fd2428336c8e43d31213e0f28b387b32d33b90ea7 `
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

최종 합격에는 동일 artifact Stage 1, Random 250, exactness·tail hard Gate와 사용자 역방향 smoothness 검수가 모두 필요하다.
