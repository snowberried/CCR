# CCR Android 0.2.0-alpha.3 Internal Viewer

데스크톱과 독립된 Android 내부 파일럿 앱이다. 의료기기나 공식 진단 프로그램이 아니며, 원본 MP4를 SAF 읽기 전용으로 연다. Gate 3 정확 프레임 기준선은 `android-v0.1.0-gate3-pass`로 동결되어 있다.

## 빌드 계약

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- minSdk 34, compileSdk/targetSdk 37
- application ID `com.snowberried.ctcinereviewer.internal`
- versionName `0.2.0-alpha.3`, versionCode `4`
- `internalDebug`는 표준 Android debug key 사용
- GitHub Release와 desktop Latest Release를 만들지 않음

Android SDK Platform 37.0, Build Tools 36.0.0, platform-tools가 필요하다.

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew.bat --version
node .\tools\verify-frame-accuracy.mjs
node .\tools\verify-representative-resolution-fixtures.mjs --manifest-only
node .\tools\verify-source-contract.mjs
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest assembleInternalDebug assembleInternalDebugAndroidTest assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-apk-privacy.ps1
```

## 표시 및 수명주기 계약

- `requestedFrameIndex`는 ±1/±5, 처음/마지막, 직접 입력 즉시 갱신되고 연속 입력은 마지막 요청값에서 누적된다.
- ±1/±5 버튼은 짧게 누르면 정확히 한 번 이동한다. 길게 누르면 Android long-press 임계 뒤 50ms 간격으로 고정 step을 반복하며, release·cancel·경계 이탈·두 번째 pointer·lifecycle stop·composable dispose 즉시 gesture generation을 무효화한다. 종료 처리 뒤에는 requested index가 더 변하지 않는다. 자동 가속은 없다.
- 연속 입력 중에는 디코드 요청 하나만 실행하고 최신 requested frame 하나만 대기시킨다. 진행 중 디코드를 입력마다 폐기하지 않는다.
- 제품 RGBA cache 상한은 `min(64 MiB, Java max heap/4)`이다. cache miss 뒤 탐색 방향으로 개념상 최대 12프레임을 cache-only로 준비하되, 게시·목표·renderer/codec 여유 4프레임을 먼저 예약한다. 따라서 720p는 최대 12, 1080p는 최대 4, 1440p 이상은 0일 수 있다.
- 미리읽기는 ±1/±5 방향 입력 뒤 500ms permit 안에서만 수행한다. 최초 열기, 복원, 처음/마지막, 직접 입력과 타임라인 이동은 permit을 열지 않는다. background·파일 전환·취소·Surface 소실·방향 전환은 진행 중 permit을 즉시 무효화한다.
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

# 배터리: Prepare 출력 후 USB를 분리하고, 30분 완료 뒤 다시 연결해 Collect
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-battery-validation.ps1 -Mode Prepare -Scenario idle
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-battery-validation.ps1 -Mode Collect -Scenario idle
```

스크립트는 instrumentation 결과와 비식별 report 계약을 직접 검사한다. 테스트 APK는 성공·실패와 관계없이 제거한다. `run-s24-alpha2-validation.ps1`은 alpha.2 source checkout의 동결 기준선 재현용이며 현재 alpha.3 제품 판정에는 사용하지 않는다. 대표 해상도와 배터리 report는 각각 ignored build output인 `android/build/reports/representative-resolution/`, `android/build/reports/representative-battery/`에 생성한다. lifecycle 자원 plateau와 memory plateau는 표본 분석 전까지 `INCONCLUSIVE`이며 PASS로 과장하지 않는다.

## 대표 해상도 fixture 계약

- 720p H.264 B-frame과 1080p H.264 B-frame/long-GOP, HEVC Main 8, VFR, H.264↔HEVC 전환용 합성 영상 7개를 각각 360프레임으로 고정했다.
- MP4와 전체 golden JSON은 저장소에 넣지 않는다. `android/.generated/testdata/representative-resolution/`에 생성하고 `android/testdata/representative-resolution/manifest.lock.json`의 exact SHA/cache key로만 복원한다.
- 일반 CI는 manifest 계약만 검사한다. S24 exact job은 exact cache key가 없으면 자동 재인코딩하지 않고 Pending으로 중단한다. GitHub Release는 fixture 배포에 사용하지 않는다.
- 60초 hold는 360프레임 경계에서 재배치한 segmented 측정이다. 경계 구간을 PublicationEvent 통계에서 제외하며 단일 연속 hold로 표현하지 않는다.

## Product Macrobenchmark

`internalBenchmark` 대상은 release와 유사한 non-debuggable/profileable 빌드다. 비식별 합성 fixture만 사용하고 full-frame readback과 exactness probe를 끈 PILOT 렌더 모드에서 측정하므로 exactness Gate 지연시간과 섞지 않는다. 성능 합격선은 두지 않는다.

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

실제 비식별 MP4 20-frame 비교가 끝나기 전 Gate 4A 판정은 `자동 게이트 PASS / 수동 파일럿 Pending`이다.

## 개인정보 및 제외 범위

Manifest에는 INTERNET, READ_MEDIA_VIDEO, 광범위 저장소 권한이 없다. 외부 전송·analytics 의존성도 없다. 프로젝트 저장, DICOM/PACS, AI, cloud, 주석, 비교 보기, PNG export, 필터, zoom/pan, Play 배포는 Android 0.2.0-alpha.3 범위 밖이다. 대표 해상도 실기기 검증과 사용자 체감 합격 전에는 `android-v0.2.0-alpha.3` tag를 만들지 않는다.
