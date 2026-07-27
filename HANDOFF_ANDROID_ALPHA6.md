# CT Cine Reviewer Android Alpha 6 Handoff

## 결론

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

현재 판정은 다음과 같다.

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

최종 합격에는 동일 artifact Stage 1, Random 250, exactness·tail hard Gate와 사용자 역방향 smoothness 검수가 모두 필요하다.
