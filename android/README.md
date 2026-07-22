# CCR Android 0.2.0-alpha.6 Internal Viewer

데스크톱과 독립된 Android 내부 파일럿 앱이다. 의료기기나 공식 진단 프로그램이 아니며, 원본 MP4를 SAF 읽기 전용으로 연다. Gate 3 정확 프레임 기준선은 `android-v0.1.0-gate3-pass`로 동결되어 있다.

## 빌드 계약

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- minSdk 34, compileSdk/targetSdk 37
- application ID `com.snowberried.ctcinereviewer.internal`
- versionName `0.2.0-alpha.6`, versionCode `7`
- `internalDebug`는 표준 Android debug key 사용
- GitHub Release와 desktop Latest Release를 만들지 않음

Android SDK Platform 37.0, Build Tools 36.0.0, platform-tools가 필요하다.

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:CCR_ANDROID_COMMIT_SHA = "c98264f2a10026a908e94c961bb13e4af2d59e60"
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
- 화면 회전 시 ViewModel, URI, 마지막 requested index를 유지한다. 새 Surface에서 해당 프레임이 다시 게시되기 전에는 복구 완료로 표시하지 않는다.
- persistable read permission을 얻은 URI만 process recreation용 `SavedStateHandle`에 보존한다. 권한이 없거나 소실되면 재선택 안내를 표시하며 source를 열지 않는다.
- persistable grant가 없는 URI는 현재 앱 실행에서만 사용한다.
- background 진입 시 현재 요청을 취소하고 displayed frame을 비운다. foreground와 새 Surface가 모두 준비되면 마지막 requested index를 다시 요청한다.
- 사용자가 명시적으로 취소하면 자동 복구를 끄고 그 결정을 SavedState에 보존한다. 새 파일을 열거나 새 프레임을 요청하면 복구가 다시 활성화된다.
- Surface lease는 단조 증가한다. 이전 Activity의 늦은 destroy는 새 Surface나 새 요청을 무효화하지 않는다.
- GL cache는 trim level 5에서 예산의 75%, 10에서 50%, 15 이상(앱 UI hidden 포함)에서 0으로 단계적으로 반환한다.
- 실제 PTS 비례 타임라인을 사용하며 VFR 위치를 평균 FPS로 계산하지 않는다. 드래그 요청은 최신 값으로 합치고 손을 놓으면 최종 정확 프레임을 요청한다.
- 권장 adaptive WindowSizeClass의 medium width 이상에서는 영상과 컨트롤을 좌우로 배치한다. 그보다 좁으면 위아래 단일 pane을 사용한다.
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

`internalDebug`의 debug key는 생산 키가 아니다. 장기 파일럿용 `internalRelease`는 무시되는 `signing.properties` 또는 아래 환경변수 네 개를 모두 제공한 경우에만 서명된다.

- `CCR_ANDROID_INTERNAL_KEYSTORE_PATH`
- `CCR_ANDROID_INTERNAL_KEYSTORE_PASSWORD`
- `CCR_ANDROID_INTERNAL_KEY_ALIAS`
- `CCR_ANDROID_INTERNAL_KEY_PASSWORD`

로컬 property 이름은 `signing.properties.example`을 따른다. 값이 일부만 있으면 비밀값을 출력하지 않고 빌드를 중단한다. internal key와 Play production key를 공유하지 않으며, 이번 단계에서는 Play App Signing·AAB 업로드를 하지 않는다. `*.jks`, `*.keystore`, `signing.properties`는 Git에서 재귀적으로 제외된다.

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

Manifest에는 INTERNET, READ_MEDIA_VIDEO, 광범위 저장소 권한이 없다. 외부 전송·analytics 의존성도 없다. 프로젝트 저장, DICOM/PACS, AI, cloud, 주석, 비교 보기, PNG export, 필터, zoom/pan, Play 배포는 Android 0.2.0-alpha.6 범위 밖이다. alpha.6 정확성·성능 Gate와 사용자 체감 합격 전에는 tag를 만들지 않는다.

## Alpha 6 검증 상태

renderer cache-hit 게시와 single-decoder rolling reverse refill, random 최종 실행 plan 진단, pinned artifact v4 host runner를 구현했다. 실기기 측정은 보류 상태이므로 S24 exactness·tail·random·사용자 smoothness와 장기 Gate는 모두 Pending이며 release 합격으로 간주하지 않는다. 구조와 동일-artifact 실행 순서는 [ALPHA6_REVERSE_REFILL_VALIDATION.md](validation/ALPHA6_REVERSE_REFILL_VALIDATION.md)에 기록한다.
