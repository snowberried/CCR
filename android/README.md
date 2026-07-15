# CCR Android 0.1.1 Internal Viewer

데스크톱과 독립된 Android 내부 파일럿 앱이다. 의료기기나 공식 진단 프로그램이 아니며, 원본 MP4를 SAF 읽기 전용으로 연다. Gate 3 정확 프레임 기준선은 `android-v0.1.0-gate3-pass`로 동결되어 있다.

## 빌드 계약

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- minSdk 34, compileSdk/targetSdk 37
- application ID `com.snowberried.ctcinereviewer.internal`
- versionName `0.1.1`, versionCode `2`
- `internalDebug`는 표준 Android debug key 사용
- GitHub Release와 desktop Latest Release를 만들지 않음

Android SDK Platform 37.0, Build Tools 36.0.0, platform-tools가 필요하다.

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew.bat --version
node .\tools\verify-frame-accuracy.mjs
node .\tools\verify-source-contract.mjs
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest assembleInternalDebug assembleInternalDebugAndroidTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-apk-privacy.ps1
```

## 표시 및 수명주기 계약

- `requestedFrameIndex`는 ±1/±5, 처음/마지막, 직접 입력 즉시 갱신되고 연속 입력은 마지막 요청값에서 누적된다.
- ±1/±5 버튼은 짧게 누르면 정확히 한 번 이동한다. 길게 누르면 Android long-press 임계 뒤 80ms 간격으로 고정 step을 반복하며, release·cancel·경계·Surface 소실 즉시 중단한다. 자동 가속은 없다.
- `displayedFrame`은 현재 file/request generation의 `FrameResult.Published`와 성공한 실제 EGL swap 뒤에만 바뀐다. stale, error, unsupported 결과는 표시 프레임을 바꾸지 않는다.
- `ViewerViewModel`이 MediaCodec actor와 EGL render thread를 소유한다. Activity와 Surface가 codec을 직접 호출하지 않는다.
- 화면 회전 시 ViewModel, URI, 마지막 requested index를 유지한다. 새 Surface에서 해당 프레임이 다시 게시되기 전에는 복구 완료로 표시하지 않는다.
- persistable read permission을 얻은 URI만 process recreation용 `SavedStateHandle`에 보존한다. 권한이 없거나 소실되면 재선택 안내를 표시하며 source를 열지 않는다.
- persistable grant가 없는 URI는 현재 앱 실행에서만 사용한다.
- background 진입 시 현재 요청을 취소하고 displayed frame을 비운다. foreground와 새 Surface가 모두 준비되면 마지막 requested index를 다시 요청한다.
- 사용자가 명시적으로 취소하면 자동 복구를 끄고 그 결정을 SavedState에 보존한다. 새 파일을 열거나 새 프레임을 요청하면 복구가 다시 활성화된다.
- Surface lease는 단조 증가한다. 이전 Activity의 늦은 destroy는 새 Surface나 새 요청을 무효화하지 않는다.
- GL cache는 trim level 5에서 예산의 75%, 10에서 50%, 15 이상(앱 UI hidden 포함)에서 0으로 단계적으로 반환한다.
- 가로 화면에서는 영상과 컨트롤을 좌우로 배치해 영상 Surface가 0px이 되지 않게 한다.

## S24 Ultra 자동 회귀

연결된 장치가 정확히 한 대이고 모델이 `SM-S928*`일 때만 실행된다. 보안 잠금은 사용자가 먼저 풀어야 한다.

```powershell
# 기존 Exactness Gate 전체
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-gate.ps1

# Pilot readback 0 + navigation hold + lifecycle 3회
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-s24-regression.ps1 -Repeat 3
```

두 스크립트 모두 instrumentation 출력의 `OK (...)`를 직접 검사한다. 테스트 APK는 성공·실패와 관계없이 제거한다. 회귀 성공 뒤에는 0.1.1 internal 앱만 설치·실행 상태로 남긴다.

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
| SHA-256 | 파일 hash |
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

Manifest에는 INTERNET, READ_MEDIA_VIDEO, 광범위 저장소 권한이 없다. 외부 전송·analytics 의존성도 없다. 프로젝트 저장, DICOM/PACS, AI, cloud, 주석, 비교 보기, PNG export, 필터, timeline, zoom/pan, Play 배포는 Android 0.1.1 범위 밖이다.
