# CCR Android 1.0.0 Internal Viewer

## 1.0.0 최종 후보 계약

- applicationId: `com.snowberried.ctcinereviewer.internal`
- versionName / versionCode: `1.0.0` / `8`
- signing lineage: `ccr-internal-pilot-v1`
- artifact set revision: `5`
- candidate builder: `scripts/build-s24-v1-candidate.ps1`

1.0.0 후보는 현재 clean Git HEAD를 `runtimeSourceSha`, `harnessSourceSha`와 APK
`BuildConfig.COMMIT_SHA`에 동일하게 기록한다. Android runtime 입력은
`tools/compute-runtime-inputs-v1.mjs`의 canonical SHA-256 tree로 고정한다. candidate
wrapper는 기존 key·공개 인증서·서로 다른 두 backup preflight, `signingReport`, 네 APK의
동일 signer와 package/version/source identity를 모두 확인한 뒤에만 외부 artifact set을
만든다. 기존 Alpha 6 builder와 검증 결과는 historical evidence로 유지한다.

## Historical Alpha 6 내부 사용자 합격 기준선

2026-07-31 KST, 사용자가 S24 Ultra의 실제 제품 화면에서 실제 CCR 영상을 사용해
평가했고 `실제 영상 실사용에 큰 문제 없음`으로 확인했다.

`PASS — ANDROID_ALPHA6_INTERNAL_USER_ACCEPTED`

- applicationId: `com.snowberried.ctcinereviewer.internal`
- versionName / versionCode: `0.2.0-alpha.6` / `7`
- 제품 APK SHA-256:
  `b5d7c927518cadaf19309bcbcc0be711db5703b5198a2c57a8056f6e456e907a`
- signer certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`
- 제품 runtime source SHA:
  `c98264f2a10026a908e94c961bb13e4af2d59e60`

이 APK를 Android Alpha 6 내부 파일럿 기준선으로 사용한다. 사용자 acceptance는 자동
Full Stage 1 또는 Random 250 PASS, Play Store release-ready, 의료기기 검증 완료를
뜻하지 않는다. Full Stage 1, Random 250과 GateActivity/Surface harness 문제는
`DEFERRED_AUTOMATION_QA_DEBT`이며 내부 파일럿을 차단하지 않는다. 기존 자동 검증
실패와 Pending evidence는 historical evidence로 유지한다.

현재 설치 앱은 삭제·재설치하지 않고 앱 데이터와 SAF grant를 보존한다. 후속 수정은
실제 사용 중 재현되는 제품 결함만 대상으로 한다.

`ONLY_FIX_REPRODUCIBLE_REAL_PRODUCT_DEFECTS_OR_START_AN_EXPLICIT_NEXT_VERSION_SCOPE`

## Alpha 6 candidate compiled identity

Alpha 6의 `runtimeSourceSha`와 APK `BuildConfig.COMMIT_SHA`는
`c98264f2a10026a908e94c961bb13e4af2d59e60`으로 고정한다. `harnessSourceSha`는
candidate를 생성하는 최종 clean Git HEAD이며 두 값은 서로 다른 정상 identity다.
`build-s24-alpha6-candidate.ps1`은 signingReport와 assemble에 canonical
`CCR_ANDROID_COMMIT_SHA`를 전달하고 호출자의 기존 값을 항상 복원한다. 복사와 manifest
생성 전에는 SDK `apkanalyzer`로 debugApp과 benchmarkApp에 실제 포함된 값을 확인한다.

full Stage 1 전에는 `run-s24-alpha6-identity-smoke.ps1`로 revision 5 debug app/test의
source, APK SHA, package와 공개 signing identity를 검증한다. identity smoke는 fixture나
frame을 열지 않고 device setting을 변경하지 않는다. 이어
`run-s24-alpha6-fixture-open-smoke.ps1`이 고정 17개 fixture의 asset, provider/PFD,
fd-only extractor, video track/sample과 hardware decoder candidate를 확인한다. 이
smoke는 full-frame decode와 performance를 실행하지 않는다.

단일 `h264-ip`의 pipeline 단계를 더 분리해야 할 때만
`run-s24-alpha6-fixture-open-diagnostic.ps1`을 사용한다. diagnostic은 explicit
offset/range extractor와 codec configure/start까지 확인하지만 input/output buffer를
queue하지 않는다. settings 적용 뒤에는 target readback, wake/display,
configuration/rotation과 잔존 process 0이 500ms 동안 안정된 것을 확인한다. 이어
`run-s24-alpha6-render-open-smoke.ps1`이 current RESUMED Activity의 동일 Surface
generation이 300ms 동안 유지된 상태에서 `h264-ip`의 index, metadata와 정확한 frame
0 publication을 검증한다. Stage 1 순서는 identity → fixture-open smoke → device
settings → settings settle → render-open smoke → correctness → performance이며, 앞
Gate 실패 시 뒤 단계는 fail-closed로 건너뛴다. Debug app/test는 identity 전에 한
세트만 설치하고 이후 단계에서는 설치된 identity를 재검증해 재사용한다.
Full Stage 1 전 Surface 전환만 검증할 때는 `run-s24-alpha6-stage1.ps1`의
`-SurfaceTransitionGateOnly`를 사용한다. 이 모드는 동일 settle 경로와 Debug 설치
1세트를 재사용해 고유 runId render-open smoke 10회만 수행하고
correctness/performance는 실행하지 않는다.

데스크톱과 독립된 Android 내부 파일럿 앱이다. 의료기기나 공식 진단 프로그램이 아니며, 원본 MP4를 SAF 읽기 전용으로 연다. Gate 3 정확 프레임 기준선은 `android-v0.1.0-gate3-pass`로 동결되어 있다.

## 빌드 계약

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- minSdk 34, compileSdk/targetSdk 37
- application ID `com.snowberried.ctcinereviewer.internal`
- versionName `1.0.0`, versionCode `8`
- `internalDebug`는 표준 Android debug key 사용
- GitHub Release와 desktop Latest Release를 만들지 않음

Android SDK Platform 37.0, Build Tools 36.0.0, platform-tools가 필요하다.

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:CCR_ANDROID_COMMIT_SHA = (git rev-parse HEAD)
.\gradlew.bat --version
node .\tools\verify-frame-accuracy.mjs
node .\tools\verify-representative-resolution-fixtures.mjs --manifest-only
node .\tools\verify-source-contract.mjs
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest assembleInternalDebug assembleInternalDebugAndroidTest assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-apk-privacy.ps1
```

## 표시 및 수명주기 계약

- 탐색 요청은 `DISCRETE_TAP`, `TIMELINE_SEEK`, `HOLD_TRAVERSAL`로 구분한다. tap과 timeline은 기존 최신 요청 우선 계약을 유지한다.
- ±1/±5 버튼은 짧게 누르면 정확히 한 번 이동한다. 길게 누르면 마지막으로 게시된 프레임에서 stride 1 또는 5인 목표 하나만 만든다. 그 목표가 실제 게시된 뒤 gesture가 아직 유효할 때만 다음 목표를 만든다.
- hold 중 foreground target은 최대 하나다. `requestedFrameIndex`는 in-flight 목표까지만, `displayedFrameIndex`는 성공한 `PublicationEvent` 뒤에만 이동한다. release·cancel·경계 이탈·두 번째 pointer·lifecycle stop·파일/Surface 전환 뒤 새 목표는 만들지 않으며 이미 확정된 마지막 목표의 늦은 게시는 허용한다.
- 같은 파일·codec·Surface에서 앞쪽 +1/+5 목표가 decoder cursor 다음에 있으면 forward sequential 경로를 사용한다. +5의 중간 프레임은 순차 decode하되 게시하지 않는다. 역방향, random/timeline/direct seek, generation 변경, format/codec 오류와 FrameKey 불일치는 기존 exact seek로 즉시 fallback한다.
- 제품 RGBA cache 상한은 `min(64 MiB, Java max heap/4)`로 유지한다. hold 중 speculative prefetch는 0이어야 한다. discrete tap 뒤에만 최대 1~2프레임을 허용하며, 최근 `evictedBeforeUse/completed` 비율이 20%를 넘으면 depth를 줄이고 50%를 넘으면 중단한다.
- 파일 전환·방향 반전·취소·Surface 소실·lifecycle stop은 진행 중 prefetch를 즉시 무효화한다.
- 미리읽기는 화면 draw·EGL swap·PublicationEvent를 만들지 않는다. cache/texture의 현재·peak·제거·거절·thrash와 exact-once 해제를 internal diagnostics에만 기록한다.
- `displayedFrame`은 현재 file/request generation의 `FrameResult.Published`와 성공한 실제 EGL swap 뒤에만 바뀐다. stale, error, unsupported 결과는 표시 프레임을 바꾸지 않는다.
- `ViewerViewModel`이 MediaCodec actor와 EGL render thread를 소유한다. Activity와 Surface가 codec을 직접 호출하지 않는다.
- MainActivity는 portrait로 고정한다. Activity가 재생성돼도 ViewModel, URI, 마지막 requested index를 유지하며 새 Surface에서 해당 프레임이 다시 게시되기 전에는 복구 완료로 표시하지 않는다.
- persistable read permission을 얻은 URI만 process recreation용 `SavedStateHandle`에 보존한다. 권한이 없거나 소실되면 재선택 안내를 표시하며 source를 열지 않는다.
- persistable grant가 없는 URI는 현재 앱 실행에서만 사용한다.
- background 진입 시 현재 요청을 취소하고 displayed frame을 비운다. foreground와 새 Surface가 모두 준비되면 마지막 requested index를 다시 요청한다.
- 사용자가 명시적으로 취소하면 자동 복구를 끄고 그 결정을 SavedState에 보존한다. 새 파일을 열거나 새 프레임을 요청하면 복구가 다시 활성화된다.
- Surface lease는 단조 증가한다. 이전 Activity의 늦은 destroy는 새 Surface나 새 요청을 무효화하지 않는다.
- GL cache는 trim level 5에서 예산의 75%, 10에서 50%, 15 이상(앱 UI hidden 포함)에서 0으로 단계적으로 반환한다.
- 실제 PTS 비례 타임라인을 사용하며 VFR 위치를 평균 FPS로 계산하지 않는다. 드래그 요청은 최신 값으로 합치고 손을 놓으면 최종 정확 프레임을 요청한다.
- 최상위 화면은 portrait 단일 pane이며 `WindowInsets.safeDrawing`을 status bar, navigation bar와 display cutout의 유일한 inset 기준으로 사용한다. adaptive/two-pane/landscape 분기는 두지 않는다.
- internal/debug에서만 `진단 복사`를 제공한다. 앱·기기·codec·frame/cache/prefetch/latency/generation과 비식별 오류 코드만 클립보드에 넣으며 URI, 파일명, 경로, 영상 hash는 포함하지 않는다.
- internalDebug는 StrictMode로 UI thread disk read/write를 코드값으로만 기록한다. media actor나 EGL thread를 UI thread에서 기다리지 않는다.

## S24 Ultra 자동 회귀

연결된 장치가 정확히 한 대이고 모델이 `SM-S928*`일 때만 실행된다. 보안 잠금은 사용자가 먼저 풀어야 한다.

```powershell
# 기존 Exactness Gate 전체
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-gate.ps1

# Pilot readback 0 + navigation hold + adaptive layout + lifecycle/file switch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-regression.ps1 -Repeat 3

# 대표 해상도 exact subset, 64 MiB cache pressure와 선택적 분리 내구성
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-representative-validation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-representative-validation.ps1 -RunLongMemory
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-representative-validation.ps1 -RunLifecycle

# alpha.4 분리 검증: 모두 MaxMinutes와 checkpoint/-Resume 지원
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-navigation-perf.ps1 -MaxMinutes 25
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-navigation-perf.ps1 -ScenarioSet 1080 -ScenarioLimit 2 -MaxMinutes 25
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-navigation-perf.ps1 -MaxMinutes 25 -Resume
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-idle.ps1 -IdleMinutes 10 -MaxMinutes 15
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-codec-switch.ps1 -Iterations 500 -ChunkSize 25 -MaxMinutes 25
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-lifecycle.ps1 -Iterations 50 -MaxMinutes 25
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-battery.ps1 -Scenario idle -Minutes 30 -MaxMinutes 35
```

분리 스크립트는 clean commit만 허용하므로 report의 commit SHA와 실제 APK 소스가 일치한다. build·install·instrumentation을 모두 `MaxMinutes` 안에 제한하고 scenario/chunk 단위 checkpoint를 저장한다. 제한 시간에 도달하면 마지막 안전 checkpoint에서 `Pending`으로 끝나며 `-Resume`은 같은 commit/version과 같은 parameter만 이어받는다. idle과 battery의 단일 장시간 instrumentation은 중간 분할이 불가능해, 중단 시 해당 측정을 처음부터 안전하게 재시작하는 granularity를 명시한다. fresh run은 이전 report·log·trace를 지우고, 성공·실패·시간 제한 모두 생성된 report 산출물을 회수한다. JSON report는 경로·URI·파일명을 거부하지만 Perfetto trace는 Android process/thread label을 포함할 수 있으므로 ignored 로컬 산출물로만 보관하고 외부 전송하지 않는다. 테스트 package 제거와 stay-awake·밝기·화면 timeout·회전 설정 원복 실패도 summary의 `cleanupFailures`로 판정한다. battery는 시작 시 USB 연결 또는 충전 상태이면 build/test 없이 즉시 `NOT_EVALUABLE`이다. navigation trace는 자동 PASS가 아니라 `MEASURED_PENDING_ANALYSIS`, chunked codec과 lifecycle 자원 plateau는 `INCONCLUSIVE`로 기록한다. hold lag 계약은 outstanding target depth `<=1`, +1 raw lag `<=1`, +5 raw lag `<=5`다. `run-s24-alpha2-validation.ps1`은 alpha.2 source checkout의 동결 기준선 재현용이며 현재 alpha.4 제품 판정에는 사용하지 않는다.

## 대표 해상도 fixture 계약

- 720p H.264 B-frame과 1080p H.264 B-frame/long-GOP, HEVC Main 8, VFR, H.264↔HEVC 전환용 합성 영상 7개를 각각 360프레임으로 고정했다.
- 모든 대표 fixture와 golden은 BT.709 limited 색 계약을 사용하고, container·bitstream metadata와 Android MediaFormat 출력이 이 계약과 일치해야 한다.
- MP4와 전체 golden JSON은 저장소에 넣지 않는다. `android/.generated/testdata/representative-resolution/`에 생성하고 `android/testdata/representative-resolution/manifest.lock.json`의 exact SHA/cache key로만 복원한다.
- 일반 CI는 manifest 계약만 검사한다. S24 exact job은 exact cache key가 없으면 자동 재인코딩하지 않고 Pending으로 중단한다. GitHub Release는 fixture 배포에 사용하지 않는다.
- 60초 hold는 360프레임 경계에서 재배치한 segmented 측정이다. 경계 구간을 PublicationEvent 통계에서 제외하며 단일 연속 hold로 표현하지 않는다.

## Product Macrobenchmark

`internalBenchmark` 대상은 release와 유사한 non-debuggable/profileable 빌드다. 비식별 합성 fixture만 사용하고 full-frame readback과 exactness probe를 끈 PILOT 렌더 모드에서 측정하므로 exactness Gate 지연시간과 섞지 않는다. 기기 공통 절대 SLA는 두지 않지만 alpha.4 navigation 판정에는 같은 S24의 alpha.3 대비 상대 개선 Gate를 사용한다.

```powershell
.\gradlew.bat assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark
.\gradlew.bat :macrobenchmark:connectedInternalBenchmarkAndroidTest
```

기존 작은 fixture 15개 시나리오와 대표 해상도 8개 시나리오의 JSON·Perfetto trace는 `macrobenchmark/build/outputs/` 아래 로컬 build output으로 생성된다. 작은 fixture 결과를 720p/1080p SLA로 사용하지 않는다.

## 내부 파일럿 서명 경계

`internalDebug`의 standard debug key는 IDE 실행과 compile/test 전용 임시 신원이다.
보존 artifact, S24 pinned candidate 또는 장기 파일럿 신원으로 사용하지 않는다.
GitHub CI의 secret 없는 build도 `CI_EPHEMERAL_DEBUG`이며 candidate가 아니다.

새 candidate signing lineage는 `ccr-internal-pilot-v1`, artifact set revision은 `5`다.
1.0.0 candidate APK 네 개는 `build-s24-v1-candidate.ps1`을 통한 명시적 opt-in에서만
만들며 다음 전용 입력을 모두 요구한다. `build-s24-alpha6-candidate.ps1`은 기존 Alpha 6
identity 재현 전용으로 보존하며 1.0.0 후보를 만들거나 승격하는 데 사용하지 않는다.

- `CCR_ANDROID_CANDIDATE_KEYSTORE_PATH`
- `CCR_ANDROID_CANDIDATE_KEYSTORE_PASSWORD`
- `CCR_ANDROID_CANDIDATE_KEY_ALIAS`
- `CCR_ANDROID_CANDIDATE_KEY_PASSWORD`
- `CCR_ANDROID_CANDIDATE_EXPECTED_CERT_SHA256`

v1 wrapper는 `--no-daemon --offline`과 전용 Gradle init script를 사용해 `debugApp`, `debugTest`,
`benchmarkApp`, `macrobenchmarkTest`에 같은 signer를 적용한다. key·공개 인증서·두
backup preflight, `signingReport`, APK signer 일치와 revision 5 manifest 검증 중 하나라도
실패하면 candidate를 만들지 않는다. 실제 key path·password는 tracked 파일에 기록하지
않으며 internal-pilot key를 standard debug 또는 Play production key와 공유하지 않는다.
자세한 정책은 [signing/README.md](signing/README.md)를 따른다.

기존 `CCR_ANDROID_INTERNAL_*`과 `signing.properties`는 historical `internalRelease`
경계이며 candidate build 입력이 아니다.
## 실제 비식별 MP4 수동 파일럿 체크리스트

합성 fixture 자동 게이트와 별도다. 실제 비식별 파일을 저장소에 복사하지 말고, 파일 하나당 아래 표 한 행을 로컬 검증 기록에 작성한다.

| 항목 | 기록값 |
| --- | --- |
| 비식별 alias | 환자·검사 식별정보가 없는 별칭 |
| 로컬 무결성 메모(선택) | 저장소 밖 manifest에만 보관 |
| codec / profile | H.264 8-bit 또는 HEVC Main 8 여부 |
| resolution / rotation | coded 해상도와 회전 |
| frame count / duration | frame 수와 길이 |
| hardware codec component | 실제 MediaCodec component |
| open / index | 성공·실패 |
| first / middle / last | 정확 프레임 비교 결과 |
| random 20 desktop comparison | 불일치 수 |
| +1 / -1 반복 | 결과 |
| +5 / -5 반복 | 결과 |
| rapid burst | stale 게시·오표시 여부 |
| portrait / landscape | 회전 복구 결과 |
| background / foreground | 복구 결과 |
| file A → B | A의 늦은 게시 여부 |
| crash / blank / green / wrong frame | 발생 수와 재현 조건 |
| subjective usability note | 식별정보 없는 사용성 메모 |

금지 사항:

- 실제 원본 영상 commit
- 환자명, 등록번호, 검사번호, 전체 로컬 경로 기록
- 환자 영상 screenshot 또는 screen recording을 저장소에 추가

Alpha 2 시점의 Gate 4A 판정은 실제 비식별 MP4 20-frame 비교와 분리 내구 시험이 끝나기 전 `자동 정확성 Gate PASS / 장기 내구·수동 파일럿 Pending`이었다. 이 문장은 Alpha 6 S24 합격을 뜻하지 않는다.

## 2026-07-16 alpha.3 S24 Ultra 실측 기준선

측정 앱 코드 SHA는 `5887a54b11775770f7005a0ec96320283a402010`이다. Samsung `SM-S928N`에서 기존 17-fixture exact Gate와 대표 7-fixture exact/cache Gate, background 회귀 3회, 대표 Macrobenchmark 8시나리오×3회 및 15분 단일 파일 memory 표본을 실행했다.

- 대표 exact: 선택 프레임 2,017개 mismatch 0, write-open 0, stale/swap failure 0
- hardware codec: `c2.qti.avc.decoder`, `c2.qti.hevc.decoder`
- cache: 64 MiB hard cap 안에서 peak 66,355,200 bytes, rejection/double-release/stale/swap failure 0
- background: 최초 open·ON_STOP·입력 없는 resume에서 speculative prefetch 증가 0, 방향 입력 후 재개
- 길게 누르기 게시 속도: 대표 연속 시나리오 중앙 실행 기준 4.299~6.632 fps. 정확 프레임 오류는 없지만 완전히 부드럽다는 판정은 하지 않는다.
- 15분 memory: cap 위반이나 자원 폭증은 관찰되지 않았지만 plateau는 `INCONCLUSIVE`
- 500회 codec switch, 추가 lifecycle 내구, 10분 idle, USB 분리 배터리와 실제 사용자 파일은 `Pending`

상세 수치와 제한은 `docs/26_ANDROID_REPRESENTATIVE_RESOLUTION_VALIDATION.md`에 기록한다. 실기기 report는 ignored `android/build/reports/`에만 유지한다.

## 2026-07-16 alpha.4 S24 확인

- pre-final 측정 APK의 기존 17-fixture exact Gate: PASS; 최종 clean commit APK 재실행은 `Pending`
- 별도 pre-final 측정 APK의 forward-sequential Gate: H.264 B-frame·long-GOP·VFR의 `+1/+5` 전 구간 PASS
- mismatch, write-open, stale/swap/publication, cache rejection/thrash, double release: 0
- JVM deterministic simulation의 completion-driven outstanding depth p95/max: 1
- 1080p 성능 비교: trace 회수 실패와 `+5` 제한시간 중단으로 `Pending`; 부드러움 개선 완료를 주장하지 않는다.
- 상세 계약과 APK checksum은 `docs/28_ANDROID_ALPHA4_SEQUENTIAL_NAVIGATION.md`에 기록한다.

## 개인정보 및 제외 범위

Manifest에는 INTERNET, READ_MEDIA_VIDEO, 광범위 저장소 권한이 없다. 외부 전송·analytics 의존성도 없다. Android 1.0.0 화면에는 RGB 이후 화면 보정과 pinch zoom/pan/Fit을 포함한다. 프로젝트 저장, DICOM/PACS, AI, cloud, 펜·주석, 비교 보기, PNG export와 Play 배포는 범위 밖이다. 이번 최종 후보 검증에서는 tag, merge, GitHub Release와 binary upload를 수행하지 않는다.

## Alpha 6 자동 검증 상태와 내부 사용자 합격의 구분

renderer cache-hit 게시와 single-decoder rolling reverse refill, random 최종 실행 plan 진단,
historical pinned artifact v4 host runner를 구현했다. v4의 `49379c…` signer private key는
복구되지 않았고 historical evidence로만 보존한다. 새 candidate는
`ccr-internal-pilot-v1`과 revision 5를 사용한다. primary와 두 backup, 공개 policy 검증은
완료됐고 certificate SHA-256은
`3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`다.
시작 HEAD `1ce42c1…`에서 signed candidate APK 네 개와 revision 5 artifact set 생성은
성공했다. 기존 Stage 1/Random이 historical revision 4 importer와 identity에 고정된 문제는
`s24-alpha6-candidate-device-artifacts.ps1` bridge로 수정했다. 두 active runner는 공개
policy·fingerprint·PEM hash와 실제 APK 4종 signer까지 checkpoint/resume/failure identity에
고정하며 revision 4를 거부한다. pre-bridge set은 유효한 build evidence로 보존하지만 새
bridge HEAD의 S24 Gate에는 사용할 수 없으므로 APK 4종을 새 clean HEAD에서 다시 만든다.
기존 S24 exactness·tail·random·장기 Gate의 실패와 Pending 상태는 historical evidence로
유지한다. Full Stage 1, Random 250과 GateActivity/Surface harness 문제는
`DEFERRED_AUTOMATION_QA_DEBT`이며 자동 PASS로 바꾸지 않는다. 이 상태와 별개로 실제
제품 사용자 평가는 `PASS — ANDROID_ALPHA6_INTERNAL_USER_ACCEPTED`다. 이는 내부
파일럿 합격이며 Play Store release-ready 또는 의료기기 검증 완료가 아니다. 구조와
동일-artifact 자동 실행 계약은
[ALPHA6_REVERSE_REFILL_VALIDATION.md](validation/ALPHA6_REVERSE_REFILL_VALIDATION.md)에 기록한다.

## 2026-08-02 portrait UI redesign 로컬 검증

이 항목은 기존 Alpha 6 S24 합격 기록을 수정하지 않고, UI redesign 작업 트리에서 새로
수행한 로컬·에뮬레이터·S24 smoke 검증만 기록한다. 기준 branch와 HEAD는
`main` / `126d3b709c000a94e296accabeeb5b3e98025f06`이며 version bump, tag, push,
release와 candidate 승격은 수행하지 않았다.

### 구현 범위

- CCR desktop `src/styles.css` 토큰과 제공 SVG를 portrait Compose 화면에 옮겼다.
- 파일 미선택 화면에는 로고, 제목, overflow, 파일 열기 안내만 남겼다. 파일을 열면
  파일명, contain-fit 영상, 대칭 `-5/-1/현재·전체/+1/+5`, 실제 PTS timeline과
  inline 화면 보정 행을 표시한다.
- 중앙 프레임 카드는 성공한 EGL swap 뒤의 `displayedFrameIndex + 1`만 보여 주는
  display-only 영역이다. 직접 입력, IME, jump dialog와 click semantics는 없다.
- pinch anchor zoom, zoom 상태의 한 손가락 pan, 빈 공간 방지 clamp, viewport resize
  clamp와 Fit reset을 desktop View Transform 의미로 구현했다.
- level/width/gamma/sharp/invert, hold-to-original과 reset을 RGB 이후 desktop 수식으로
  구현했다. 패널은 영상 위를 덮지 않고 내부만 scroll하며, 접어도 값과 파란 상태 점을
  유지하고 새 파일 또는 앱 재실행 때 기본값으로 돌아간다.
- timeline과 보정 slider는 progress semantics를 유지하면서 2dp track, 12dp 원형 thumb,
  tick/stop 미표시로 경량화했다. 탐색 버튼의 semantic click은 한 번만 이동하고 pointer
  long-press cadence는 유지한다. Original 비교는 semantic click에도 유한 preview를 제공한다.
- 보정 행 chevron은 사용자가 확인한 다음 동작 방향을 따른다. 접힘 상태는 위(펼치기),
  펼침 상태는 아래(접기)이며 접근성 설명은 “화면 보정 펼치기/접기”를 유지한다.
- 기존 candidate package를 보존하기 위해 별도 `internalRedesign` build type을 추가했다.
  개발 앱은 `com.snowberried.ctcinereviewer.internal.redesign`, label `CCR Redesign Dev`,
  Android debug signer를 사용하며 기존 `internalDebug`와 candidate identity는 그대로다.
- 펜, 자유선, S Pen, annotation model/overlay, undo/redo/clear와 비교 보기 코드는
  추가하지 않았다.
- `EglFrameRenderer`는 transform·보정 uniform/shader와 Surface resize redraw에만
  확장했다. `ExactFrameSession`, frame-index 생성, publication gate, cache,
  stale-result 폐기, Surface lease, 파일 전환·background 보호 및
  `CompletionDrivenHoldController`/`NavigationCadencePolicy` 의미는 바꾸지 않았다.

### 검증 결과

- `lintInternalDebug testInternalDebugUnitTest assembleInternalDebug assembleInternalDebugAndroidTest assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark assembleInternalRedesign --offline --no-daemon`:
  화살표 피드백 반영 후 최종 재실행 `BUILD SUCCESSFUL in 56s`, 205 tasks.
  JVM XML 32 suites / 174 tests,
  failure 0, error 0, skip 0.
- lint: error 0, warning 5. 고정 portrait 관련 2건은 제품 계약상 의도적이며 나머지는
  기존 Composable naming, data extraction rules, application icon 경고다.
- API 36 emulator의 UI/navigation/lifecycle/shader/screenshot 선택 instrumentation:
  `BUILD SUCCESSFUL in 1m 17s`. JUnit XML 기준 24 tests 중 pass 21, skip 3,
  failure/error 0. 세 skip은 S24 물리 기기 전용 lifecycle/cache 검증이다.
- 격리 screenshot instrumentation: 1/1 pass. 모든 상태에서 status/navigation bar
  visibility와 양의 top/bottom inset을 확인했다.
- 탐색·접근성·UI 계약·screenshot focused instrumentation: 15/15 pass. 격리 screenshot
  instrumentation도 1/1 pass로 최종 세 상태를 다시 생성했다.
- privacy preflight: 기존 applicationId `com.snowberried.ctcinereviewer.internal`와 개발용
  `com.snowberried.ctcinereviewer.internal.redesign` 모두 version `0.2.0-alpha.6` / code 7,
  forbidden permission 0.
- signing host test: 29 passed. 실제 candidate signing preflight는 secret과 명시적
  opt-in이 필요한 별도 경계이므로 실행하지 않았다.

### 생성 APK

| 역할 | 경로 | SHA-256 |
| --- | --- | --- |
| internal debug app | `app/build/outputs/apk/internal/debug/app-internal-debug.apk` | `ffded38ea3cae43ef7b6f8a118fc428d0a49fddc13ab511899286e66baa4005a` |
| internal debug test | `app/build/outputs/apk/androidTest/internal/debug/app-internal-debug-androidTest.apk` | `b7f0f71da7be081c2c7e0c3d9d94e85da377a0ee422e32174322c25a199b754f` |
| internal benchmark app | `app/build/outputs/apk/internal/benchmark/app-internal-benchmark.apk` | `b6ebc04787b64d29151c92ec159f824226159e2cbd36c1449641250ca3200af2` |
| macrobenchmark test | `macrobenchmark/build/outputs/apk/internal/benchmark/macrobenchmark-internal-benchmark.apk` | `4b05125ad1a20eb420f6f948a57f5f1f1e965bede045cf2ab3c7d5375a0b046c` |
| redesign dev app | `app/build/outputs/apk/internal/redesign/app-internal-redesign.apk` | `f0710f816303338b902acb5aa8e8d47a5f41058a975bbfd239681dd3fe8396cc` |

### 화면 근거와 실기기 결과

- `validation/ui-redesign-screenshots/01-correction-collapsed-default.png`
- `validation/ui-redesign-screenshots/02-correction-expanded.png`
- `validation/ui-redesign-screenshots/03-correction-collapsed-adjusted.png`
- `validation/ui-redesign-screenshots/s24-01-correction-collapsed-default.png`
- `validation/ui-redesign-screenshots/s24-02-correction-expanded.png`
- `validation/ui-redesign-screenshots/s24-03-correction-collapsed-adjusted.png`

S24 Ultra의 기존 `CCR Android Internal Pilot v1` 후보 서명 앱은 삭제·덮어쓰기 없이
보존했다. 별도 `CCR Redesign Dev`를 debug signer와 suffix applicationId로 병렬 설치했다.
S24 Ultra에서 rotation 0, app safe content `[0,129][1440,2940]`, navigation 영역
`[0,2940][1440,3120]`을 확인했고 상태·하단 navigation·cutout 침범은 없었다.
파일 미선택 controls 숨김, 표시 전용 frame card, `+1` 단일 이동, `+5` hold, 실제 PTS
drag, inline 보정 panel scroll, 값 유지·reset·상태 점, Original 비교, HOT background 복귀를
smoke했다. pinch/pan/Fit과 최종 chevron 방향(접힘 위/펼침 아래)은 사용자가 실기기에서
정상 확인했다. 비식별 fixture와 device 임시 XML·screenshot은 검증 후 삭제했고,
두 앱과 독립 앱 데이터는 유지했다.
Full Stage 1, Random 250, candidate 승격과 release Gate는 이 기록에서 PASS로 판정하지 않는다.

## 2026-08-03 Android 1.0.0 서명 후보 검증과 내부 사용자 승인

`PASS — ANDROID_1_0_0_INTERNAL_USER_ACCEPTED`

`DEFERRED — REPRESENTATIVE_RESOLUTION_AUTOMATION`

이번 결과는 위 Alpha 6 및 portrait UI redesign 기록을 수정하지 않는 별도 1.0.0 후보
검증이다. 시작 branch는 `main`, 최초 사용자 승인 후보 source는
`aa75f44023473ea1e16c47e3132dbd5d83a549b9`이며 versionName/versionCode는
`1.0.0` / `8`이다. candidate signing lineage는 기존
`ccr-internal-pilot-v1`을 유지했고 일반 debug APK를 승격하지 않았다.

사용자는 S24 실제 사용 결과와 기존 17-fixture exact Gate를 근거로 이 후보를 1.0.0
내부 안정판으로 승인했다. representative-resolution fixture는 APK 제품 런타임이나
사용자 영상 열기에 필요한 구성요소가 아니라 추가 자동 검증 자산이므로 현재 제품
승인을 차단하지 않고 이월한다. 이 결정은 Full Stage 1 또는 Random 250을 PASS로
바꾸는 것이 아니며 해당 자동 Gate의 미실행·중단 evidence는 그대로 보존한다.

### 선행 후보 아티팩트 (브랜딩 보완으로 대체됨)

- artifact set:
  `C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-1.0.0-aa75f44-20260803-023901`
- manifest:
  `C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-1.0.0-aa75f44-20260803-023901\artifact-manifest-v5.json`
- manifest SHA-256:
  `76f164c1286fbe9e4ed5558b2124ba34398ea812fe49e2f87d4d6d25cc1815fa`
- runtime/harness source:
  `aa75f44023473ea1e16c47e3132dbd5d83a549b9`
- runtime inputs tree SHA-256:
  `9060666cf1fe2f885155662db05ab2c09da52a47a6222518fab39f485ce78b12`

| 역할 | SHA-256 |
| --- | --- |
| debug app | `884f4d0f89ca46291c3ea359ad7c7672800b953c97d423f53fa7ce053dd095a5` |
| debug test | `6cd89ab5a52203d4c43d98c6d7cc48a29d95ff1ba612a2929670d6c56f8e4082` |
| benchmark app | `8fa6b80e74dda6220a2fb1c6626ee6fc4704d0f446754cf4deababb9b54619d8` |
| macrobenchmark test | `59028e57186cc06ad0f06576b36dfcb9b02ae6721275eac61f1d83f5949c421e` |

candidate wrapper는 private 입력을 기록하지 않고 key·두 backup·공개 policy,
`signingReport`, package/version/source/tree와 APK 네 개의 동일 signer를 검증한 뒤
revision 5 artifact set을 만들었다. S24의 기존 package는 삭제하지 않고 같은 signer의
versionCode 8 APK로 `install -r` 업데이트했다. 앱 데이터와 signing lineage를 유지했으며
push, tag, release와 binary upload는 수행하지 않았다.

### host 및 S24 결과

- v1 candidate builder host 17, signing host 29, candidate device bridge 55,
  Stage 1 host 188, Random host 24 검사는 모두 PASS다.
- `lintInternalDebug testInternalDebugUnitTest assembleInternalDebug
  assembleInternalDebugAndroidTest assembleInternalBenchmark
  :macrobenchmark:assembleInternalBenchmark`는 `BUILD SUCCESSFUL in 1m 13s`,
  167 tasks다. JVM은 174 tests, failure/error/skip 0이다.
- lint는 error 0, warning 5이고 APK privacy preflight는 forbidden permission 0이다.
- standalone source-contract 실행은 Windows watchdog argv 직렬화 문제로 두 번
  시작하지 못했으므로 PASS로 기록하지 않는다. Gradle gate와 candidate source/tree/APK
  identity 검증은 별도로 통과했다.
- S24에서 identity smoke, 17-fixture open smoke, device settings, settings settle와
  render-open smoke가 PASS했다. 이어 기존 17-fixture exact Gate도 PASS했고 mismatch,
  write-open, swap failure, surface invalid와 publication invariant violation은 0이다.
- 다음 representative-resolution exact 단계는
  `representative-resolution/720p-h264-bframes.json`이 APK에 없어 fail-closed로
  중단됐다. correctness 전체와 performance를 PASS로 판정하지 않는다.
- Random 250은 화면이 Dozing이던 첫 시도에서 Surface 생성 전에 중단됐다. 사용자가
  화면을 열고 `Awake`를 확인한 fresh run은 Surface를 통과했지만 같은 representative
  fixture 부재로 정확성 첫 fixture에서 중단됐다. exact 250/250과 performance 250은
  실행되지 않았고 두 fresh run 모두 cleanup failure 0이다.
- 사용자는 같은 S24에서 portrait/inset, frame tap/hold, 실제 PTS timeline,
  보정 panel과 값 유지·reset·Original 비교, zoom/pan/Fit 및 chevron 방향을 확인했고
  현재 사용 경험을 만족스럽다고 판정했다. 세 상태 S24 screenshot은
  `validation/ui-redesign-screenshots/s24-01-correction-collapsed-default.png`,
  `s24-02-correction-expanded.png`,
  `s24-03-correction-collapsed-adjusted.png`에 유지한다.

### 최종 브랜딩 후보 (S24 갱신 전)

선행 `aa75f44` 후보는 S24 제품 동작 승인 evidence로 보존하지만 launcher icon이 없는
artifact이므로 최종 설치·배포 대상에서는 대체한다. 정식 앱 이름과 adaptive/round/themed
launcher icon을 추가한 최종 브랜딩 후보 source는
`f4d2ec16e555d938380b46f422ed3f9c9ea32b94`다. 개발용 병렬 variant 이름
`CCR Redesign Dev`와 원래 candidate package/signing lineage는 그대로 유지한다.

- artifact set:
  `C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-1.0.0-f4d2ec1-20260803-093150`
- manifest:
  `C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-1.0.0-f4d2ec1-20260803-093150\artifact-manifest-v5.json`
- manifest SHA-256:
  `4f17e0fe25012630d87c8ef520f6c034e0b96d0ad324607f880977ac8aa1df66`
- runtime/harness source:
  `f4d2ec16e555d938380b46f422ed3f9c9ea32b94`
- runtime inputs tree SHA-256:
  `13bfb8f7452a24f14de1ca541acc38dca0c9e77dc374b28c4b5118eb96a79414`
- signer certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`

| 역할 | 파일 | SHA-256 |
| --- | --- | --- |
| debug app | `app-internal-debug.apk` | `622f7cd85ca50a49b2aba4c9d1ab499e4a78f072ccc61d959041444572d81c93` |
| debug test | `app-internal-debug-androidTest.apk` | `b1a22e62d43f2a67d37d15abe89226923447e889d5bb538b7843926f335855a6` |
| benchmark app | `app-internal-benchmark.apk` | `67028c124ccdcd20271aa64cfd0309c6fce90e8d65794258d7e5a57f649d675e` |
| macrobenchmark test | `macrobenchmark-internal-benchmark.apk` | `59028e57186cc06ad0f06576b36dfcb9b02ae6721275eac61f1d83f5949c421e` |

- candidate wrapper의 key·backup·public policy, package/version/source/tree와 네 APK의
  동일 signer 검증은 PASS다.
- AAPT2로 debug app의 package
  `com.snowberried.ctcinereviewer.internal`, `1.0.0` / `8`, label
  `CT Cine Reviewer`와 `res/mipmap-anydpi-v26/ic_launcher.xml`을 확인했다.
- `lintInternalDebug testInternalDebugUnitTest assembleInternalDebug
  assembleInternalDebugAndroidTest assembleInternalBenchmark
  :macrobenchmark:assembleInternalBenchmark`는 `BUILD SUCCESSFUL in 1m 19s`, 91 tasks
  (34 executed, 57 up-to-date)다. JVM은 175 tests, failure/error/skip 0이고 lint는
  error 0, warning 5다.
- `aa75f44..f4d2ec1` 변경 파일은 README, manifest, launcher resource와
  `ProjectContractTest`뿐이다. decoder/navigation/rendering 의미 변경은 없다.
- 동일 signer `install -r`와 S24 앱 서랍의 정식 이름·아이콘 확인은 아직 실행하지
  않았으므로 PASS로 기록하지 않는다. 기존 candidate 앱은 삭제하지 않는다.

### 이월한 자동 검증과 선택적 재개 조건

필요한 exact cache key는
`ccr-representative-resolution-v1-ada531a0ccebaafebe49accb3065bebc7c3d2cea31e7b669a5e6975420d4dafb`다.
저장소 generated 경로, 로컬 CCR 작업공간·검증·아티팩트 폴더, Downloads/Desktop와
연결된 GitHub Actions cache에서 exact key를 찾지 못했다. 이 노트북의 FFmpeg는 고정
버전과 일치하지만 `nvidia-smi`가 없고 고정 RTX 4080 SUPER/NVENC host가 아니므로
임의 재생성과 lock 갱신은 금지한다.

향후 대표 해상도 자동 회귀 증거가 필요해질 때만 신뢰할 수 있는 immutable cache를
exact key로 복원하고 full fixture verifier를 통과시킨다. 그때 같은 clean source에서
APK 네 개를 다시 candidate 서명하고 Full Stage 1과 Random 250을 처음부터 실행한다.
그 전까지 두 자동 Gate는 `DEFERRED`이며 1.0.0 내부 사용자 승인을 차단하지 않는다.
이 이월 항목은 decoder/navigation 제품 회귀 증거가 아니며 `ExactFrameSession`,
frame-index/publication/cache/stale-result/Surface lease와 `ViewerViewModel`
navigation/hold cadence 의미는 이번 후보 identity 및 harness 수정에서 변경하지 않았다.
Play 배포, 의료기기 검증 완료 또는 모든 자동 Gate PASS를 뜻하지 않는다.
