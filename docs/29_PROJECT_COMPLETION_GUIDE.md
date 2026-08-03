# CT Cine Reviewer 최종 프로젝트 안내서

## 1. 이 문서의 목적과 최종 상태

이 문서는 CT Cine Reviewer(CCR)를 처음 접한 사람이 프로젝트의 목적, 완성된 제품,
사용법, 코드 구조, 빌드와 검증 방법, 보안 경계와 남은 제한을 한 곳에서 이해하도록 만든
최종 안내서다. 개발 단계마다 사용하던 `HANDOFF_*.md` 문서의 마지막 유효 결론을 이
문서와 기존 정식 설계·검증 문서에 통합했다.

- 프로젝트 상태: **1차 완성 및 종료**
- 완성 결정일: `2026-08-03 KST`
- 데스크톱 안정판: **Windows v0.5.9**
- Android 안정판: **S24 Ultra 내부용 v1.0.0**
- 제품 판정: `PASS — ANDROID_1_0_0_INTERNAL_USER_ACCEPTED`
- Android 추가 자동화: `DEFERRED — REPRESENTATIVE_RESOLUTION_AUTOMATION`
- 저장소: <https://github.com/snowberried/CCR>

여기서 “완성”은 현재 합의된 Windows 로컬 뷰어와 S24 내부 앱의 기능·사용성 기준을
충족했다는 뜻이다. Play Store 공개, 의료기기 인증, PACS/DICOM 연동 또는 모든 장시간
자동 Gate 통과를 뜻하지 않는다.

## 2. CCR이 무엇인가

CCR은 전달받은 CT cine **MP4 동영상**을 정확한 프레임 순서로 검토하기 위한 완전 로컬
보조 뷰어다. 일반 동영상 플레이어처럼 자동 재생하는 도구가 아니라, 한 장씩 앞뒤로
넘기고 확대·이동하며 화면 픽셀을 보정하는 작업에 초점을 둔다.

CCR이 보장하려는 핵심은 다음과 같다.

1. 내부 `frameIndex`와 실제 PTS를 구분해 정확한 프레임을 찾는다.
2. 새 요청이 들어오면 오래된 결과가 화면에 늦게 섞이지 않게 한다.
3. 원본 MP4는 읽기 전용으로 다루며 재인코딩하거나 수정하지 않는다.
4. 영상, 파일명, 경로와 사용 기록을 외부 서버로 전송하지 않는다.
5. MP4 화면 보정을 DICOM의 HU 기반 window처럼 표현하지 않는다.

CCR은 다음 제품이 아니다.

- 의료기기 또는 공식 진단 프로그램
- PACS, DICOM viewer 또는 원본 HU 판독 도구
- AI 판독·병변 탐지 도구
- 클라우드 동기화·협업 서비스
- 동영상 자동 재생·오디오 플레이어

의료적 판단에는 반드시 원본 영상과 정식 판독 환경을 사용해야 한다.

## 3. 완성된 두 제품

| 구분 | Windows 데스크톱 | Android 내부 앱 |
| --- | --- | --- |
| 최종 버전 | `0.5.9` | `1.0.0` / code `8` |
| 대상 | Windows x64 | Galaxy S24 Ultra, Android 14 이상 |
| 배포 신원 | GitHub Latest Release | `ccr-internal-pilot-v1` 서명 후보 |
| 화면 | 데스크톱 다중 패널 | portrait 단일 영상 화면 |
| 정확 탐색 | 1프레임, 빠른 N, 첫/마지막, 직접 입력, 휠 | `-5/-1/+1/+5`, 실제 PTS timeline |
| 확대·이동 | Zoom/Pan/Fit/100%/fullscreen | 두 손가락 pinch, 한 손가락 pan, Fit |
| 화면 보정 | 밝기·명암·감마·선명도·반전·원본 비교 | 같은 RGB 이후 수학 계약 |
| 비교 보기 | 동일 프레임 A/B 비교 | 지원하지 않음 |
| 주석 | 화살표·텍스트·타원·사각형, Undo/Redo | 지원하지 않음 |
| 내보내기 | PNG 저장·clipboard 복사 | 지원하지 않음 |
| 작업 저장 | 세션 RAM만 사용 | 세션 상태만 사용 |

두 앱은 시각 정체성과 프레임·PTS·표시 보정의 의미를 공유하지만, 코드와 UI는 플랫폼별로
분리돼 있다. Android 앱은 데스크톱 UI를 축소 복사하지 않고 세로 휴대폰 조작에 맞게
별도로 설계했다.

## 4. Windows 데스크톱 사용법

### 4.1 설치와 시작

공개 안정판은 GitHub의 [v0.5.9 Release](https://github.com/snowberried/CCR/releases/tag/v0.5.9)다.
설치 파일은 `CT-Cine-Reviewer-Setup-0.5.9.exe`이며 현재 사용자 범위로 설치되고 관리자
권한을 요구하지 않는다. Windows 코드 서명이 없으므로 게시자 경고가 나타날 수 있다.

공개 설치 파일 SHA-256:

```text
d489c82b6badc8b81cda81a79f8deea139c8216c7d94206245e098c6e94bc06e
```

### 4.2 기본 검토 흐름

1. `파일 열기`, 빈 영상 영역 또는 `Ctrl+O`로 MP4를 연다.
2. 분석과 첫 프레임 표시가 끝날 때까지 기다린다.
3. `←/→`로 한 프레임, `↓/↑`로 설정된 N프레임만큼 이동한다.
4. `Home/End`로 첫·마지막 프레임에 이동한다.
5. 마우스 휠은 프레임 이동, `Ctrl+휠`은 확대·축소에 사용한다.
6. Pan/Zoom/Fit 상태를 유지한 채 다른 프레임을 검토한다.
7. 필요한 경우 화면 보정, 주석, PNG 저장 또는 clipboard 복사를 사용한다.

### 4.3 비교 보기

비교 보기는 같은 파일의 **같은 프레임과 같은 decoded pixels**를 왼쪽과 오른쪽에 동시에
그린다. 두 영역의 확대·이동과 화면 보정은 독립적이다. 연결 십자선은 같은 image pixel을
두 화면에 대응시킬 뿐 DICOM registration이나 서로 다른 영상 정합 기능이 아니다.

### 4.4 캐시 RAM 설정

기본값은 `자동 (최대 2 GiB)`다. PC 전체 RAM에 따라 2/4/6/8 GiB 수동 상한이 제한적으로
표시된다. 수동값은 미리 예약되는 메모리가 아니라 cache가 커질 수 있는 최대치다.

```text
실제 수동 상한 = min(선택값, 전체 RAM의 25%, 현재 여유 RAM의 50%)
```

2 GiB보다 큰 영상은 제한 block LRU를 사용한다. 현재 위치와 이동 방향을 중심으로
준비하고 최대 네 block을 한 FFmpeg process에서 미리 읽는다. 비정상 색·layout이나
명시적 `CCR_FORCE_RGBA=1`에서는 기존 72 MiB RGBA cache 경로로 돌아간다.

### 4.5 데스크톱에서 저장되는 것

- 빠른 이동 간격과 사용자 단축키 같은 로컬 설정은 저장된다.
- 주석, 비교 보기 상태와 화면 작업 상태는 현재 세션 RAM에만 있다.
- 프로젝트 저장 파일은 구현하지 않았다.
- 사용자가 명시적으로 저장한 PNG 외에 영상 프레임을 디스크에 남기지 않는다.

## 5. Android 1.0.0 사용법

### 5.1 제품 신원

- 앱 이름: `CT Cine Reviewer`
- applicationId: `com.snowberried.ctcinereviewer.internal`
- 버전: `1.0.0` / code `8`
- 방향: portrait 전용
- 최소 SDK: 34
- 서명 lineage: `ccr-internal-pilot-v1`

이 앱은 현재 S24 내부 파일럿용 완성본이다. Play Store용 production release가 아니며
일반 Android debug key를 후보 신원으로 사용하지 않는다.

### 5.2 기본 검토 흐름

1. `파일 열기`로 Android Storage Access Framework에서 MP4를 선택한다.
2. 파일이 열리면 영상, 대칭 프레임 버튼, PTS timeline과 `화면 보정` 행이 나타난다.
3. `-5`, `-1`, `+1`, `+5`를 짧게 누르면 정확히 한 번 이동한다.
4. 같은 버튼을 길게 누르면 기존 completion-driven cadence로 연속 이동한다.
5. 중앙 `현재 / 전체` 카드는 표시 전용이며 눌러도 아무 동작을 하지 않는다.
6. timeline은 평균 FPS가 아닌 실제 PTS 비율을 사용한다.
7. 영상에서 두 손가락 pinch로 확대·축소하고, 확대된 상태에서 한 손가락으로 이동한다.
8. Fit을 벗어났을 때 나타나는 버튼으로 zoom 1·중앙 contain-fit 상태로 돌아간다.
9. `화면 보정` 행을 눌러 inline 패널을 열고 값을 조절한다.

### 5.3 화면 보정

| 항목 | 기본값 | 최소 | 최대 | 간격 |
| --- | ---: | ---: | ---: | ---: |
| 밝기(level) | 0.50 | 0.00 | 1.00 | 0.01 |
| 명암(width) | 1.00 | 0.02 | 2.00 | 0.01 |
| 감마(gamma) | 1.00 | 0.25 | 4.00 | 0.05 |
| 선명도(sharp) | 0.00 | 0.00 | 1.00 | 0.05 |
| 반전 | 꺼짐 | - | - | toggle |

`원본 비교`는 누르는 동안만 보정을 끄고 손을 떼거나 취소하면 즉시 설정값으로 돌아온다.
`초기화`는 위 기본값으로 복귀한다. 값은 프레임 이동과 패널 접기 중 유지되며 새 파일이나
앱 재실행 때 초기화된다.

### 5.4 Android에 의도적으로 없는 기능

- landscape·adaptive two-pane·비교 보기
- 펜, 자유선, S Pen, 주석, Undo/Redo, 전체 지우기
- 직접 프레임 입력, 키보드·IME jump dialog
- 영상 swipe 프레임 이동과 double tap zoom
- 햅틱
- PNG export와 프로젝트 저장
- 일반 화면의 버전·codec·PTS·cache·decoder 진단 문자열

내부 진단 계측은 삭제하지 않았고 overflow의 진단 경로에서만 접근한다.

## 6. 반드시 알아야 하는 핵심 개념

### 6.1 frameIndex와 PTS

- 내부 `frameIndex`는 0부터 시작하는 연속 순서다.
- 사용자 화면의 프레임 번호는 `frameIndex + 1`로 1부터 표시한다.
- PTS(Presentation Timestamp)는 컨테이너 시간축에서 해당 프레임이 표시될 시각이다.
- VFR 영상에서는 `frameIndex / 평균 FPS`로 시간을 추정하면 안 된다.
- 프레임 탐색과 timeline은 실제 frame index–PTS 표를 기준으로 한다.

Android 중앙 프레임 카드는 요청한 값이 아니라 실제 EGL swap에 성공한
`displayedFrameIndex + 1`만 보여 준다. 요청이 먼저 도착했다는 이유로 표시 숫자를 앞당기지
않는다.

### 6.2 최신 요청 우선과 stale-result 폐기

프레임 요청에는 파일·요청·Surface generation이 연결된다. 사용자가 빠르게 이동하거나
파일을 바꾸고, 앱이 background로 가거나 Surface가 재생성되면 이전 generation의 늦은
결과는 화면에 게시하지 않는다. 이 계약이 “다른 파일의 프레임이 잠깐 보임”이나 “이전
요청이 나중에 덮어씀”을 막는다.

Android hold 탐색은 동시에 foreground target을 하나만 유지한다. 실제 게시가 끝난 뒤
gesture가 여전히 유효할 때만 다음 목표를 만든다. release·cancel·경계·두 번째 pointer·
lifecycle stop 뒤에는 새 목표를 생성하지 않는다.

### 6.3 View Transform

View Transform은 원본 image pixel 공간과 화면 viewport를 연결한다.

- 초기 상태: contain Fit, 중앙
- 확대 anchor: pinch 또는 cursor 아래 image point가 확대 전후 같은 화면 위치에 남음
- 작은 축: viewport보다 영상이 작으면 중앙 고정
- 큰 축: 검은 바깥 공간이 노출되지 않도록 pan clamp
- resize: 의미 있는 zoom/pan을 유지한 채 새 viewport에 맞게 clamp

데스크톱의 순수 수학은 `src/domain/viewTransform.ts`, Android port는
`android/app/src/main/java/com/snowberried/ctcinereviewer/render/ViewTransform.kt`에 있다.

### 6.4 화면 보정

CCR의 보정은 디코딩된 RGB의 luminance에 적용되는 화면 픽셀 연산이다.

```text
luminance = 0.299R + 0.587G + 0.114B
lower = level - width / 2
windowed = clamp((luminance - lower) / width, 0, 1)
gammaMapped = pow(windowed, 1 / gamma)
result = invert ? 1 - gammaMapped : gammaMapped
```

보정된 luminance와 원래 luminance의 차이를 기존 RGB에 더해 색차를 유지한다. 선명도는
중앙과 상·하·좌·우 luminance를 사용하는 unsharp 계약이다. Android는 OES/RGB texture의
RGB 변환 이후 부분만 사용하고 데스크톱 I420 변환 전체를 복사하지 않는다.

### 6.5 캐시와 rollback

데스크톱 기본 경로는 I420 full cache 또는 block LRU다. WebGL2가 BT.601 limited 표시를
담당하고 안전하지 않은 색·layout 또는 `CCR_FORCE_RGBA=1`에서는 기존 RGBA segment
cache로 fallback한다.

Android는 64 MiB 이하의 방향성 RGBA cache, hardware MediaCodec과 single-decoder
navigation을 사용한다. cache hit 게시, miss fallback, cancellation, exact-once release와
Surface lease 의미는 UI와 분리돼 있다.

## 7. 전체 아키텍처

### 7.1 저장소 상위 구조

```text
CCR/
├─ src/                         Windows renderer UI와 플랫폼 중립 domain/application
│  ├─ domain/                  프레임·캐시·좌표·보정·주석·비교 보기 순수 규칙
│  ├─ application/             request coordinator와 platform port
│  ├─ ui/                      WebGL, timeline, annotation, 단축키와 export UI
│  ├─ assets/icons/            CCR SVG 자산
│  ├─ App.tsx                  데스크톱 화면과 상태 조립
│  └─ styles.css               데스크톱 CCR 디자인 토큰
├─ electron/                    권한이 필요한 Windows main process 계층
│  ├─ adapters/                ffprobe/FFmpeg decode와 frame index
│  ├─ cache/                   I420 full/LRU session
│  ├─ frameIpc.ts              RGBA rollback frame 경로
│  ├─ exportIpc.ts             PNG 저장과 clipboard
│  ├─ updateIpc.ts             사용자 요청 기반 GitHub update
│  ├─ preload.cts              좁은 타입 IPC bridge
│  └─ main.ts                  BrowserWindow와 자원 수명주기
├─ android/                     독립 Android Gradle 프로젝트
│  ├─ app/src/main/            Compose UI, ViewModel, MediaCodec/EGL runtime
│  ├─ app/src/test/            JVM 계약 테스트
│  ├─ app/src/androidTest/     기기·UI·정확성 instrumentation
│  ├─ macrobenchmark/          성능 측정 전용 APK
│  ├─ scripts/                 S24 Gate와 candidate build/검증
│  ├─ signing/                 공개 인증서·fingerprint·정책만 추적
│  ├─ testdata/                비식별 합성 fixture 계약
│  └─ validation/              검증 기록과 screenshot
├─ docs/                        영구 기획·설계·검증·완료 문서
├─ scripts/                     데스크톱 QA, packaging과 FFmpeg setup
├─ tests/                       데스크톱 Node 단위·통합 테스트
├─ .github/workflows/           desktop CI, Android CI, Windows Release
├─ AGENTS.md                    향후 변경 작업의 안전 규칙
└─ README.md                    처음 보는 사람을 위한 짧은 입구
```

### 7.2 Windows 실행 흐름

```text
React UI
  → sandboxed preload IPC
  → Electron main process
  → ffprobe로 stream/frame/PTS index 생성
  → FFmpeg I420 sequential/full 또는 block LRU decode
  → renderer에 typed pixel buffer 반환
  → WebGL2 화면 보정·View Transform·annotation overlay
  → 선택적으로 deterministic PNG/clipboard export
```

Electron renderer는 `nodeIntegration: false`, `contextIsolation: true`, `sandbox: true`다.
임의 파일 시스템 접근을 renderer에 노출하지 않고 `preload.cts`의 제한된 API만 사용한다.
종료 전 활성 ffprobe/FFmpeg와 cache session을 정리한다.

### 7.3 Android 실행 흐름

```text
Compose MainActivity
  → ViewerViewModel
  → 단일 MediaCodec request actor / ExactFrameSession
  → frame index와 exact seek 또는 sequential navigation
  → DirectionalByteCache
  → EGL render thread / EglFrameRenderer
  → 실제 swap 성공
  → PublicationEvent와 displayedFrameIndex 갱신
```

Activity와 Surface가 codec을 직접 호출하지 않는다. ViewModel이 media actor와 EGL thread를
소유한다. `SurfaceLeaseTracker`, request generation과 publication gate가 이전 Activity나
파일의 늦은 결과를 차단한다.

### 7.4 공통 의미와 플랫폼 분리

두 플랫폼 사이에 실행 코드를 억지로 공유하지 않는다. 대신 다음 의미를 동일하게 유지한다.

- 0 기반 frameIndex와 실제 PTS
- 원본 image pixel 좌표와 contain Fit
- zoom anchor, pan clamp와 reset
- RGB 이후 luminance 보정과 unsharp
- 최신 요청 우선, stale-result 폐기와 원본 읽기 전용

데스크톱 비교 보기·주석·내보내기는 Android 1.0 범위에 포함하지 않는다. Android의 lifecycle,
Surface와 hardware codec 계약도 데스크톱에 역으로 끌어오지 않는다.

## 8. 변경 시 절대 보존할 계약

### 데스크톱

- `src/domain`에 Electron IPC, 파일 시스템 또는 UI 의존성을 넣지 않는다.
- hot path에 불필요한 process 재실행, JSON 직렬화와 IPC 왕복을 추가하지 않는다.
- `CCR_FORCE_RGBA=1` rollback을 검증 없이 삭제하지 않는다.
- 두 비교 pane의 decoder/cache/navigation/annotation store/timeline은 각각 하나다.
- export는 실제 displayed frame snapshot만 사용한다.

### Android

다음 파일·메서드의 의미와 cadence는 UI 작업을 이유로 바꾸면 안 된다.

- `ExactFrameSession`
- frame-index 생성, `PublicationGate`, cache와 stale-result 폐기
- Surface lease, 파일 전환·background·Surface generation 보호
- `ViewerViewModel.requestFrameInternal`
- `submitFrameRequest`, `submitPendingFrameRequest`, `driveHoldTraversal`
- `CompletionDrivenHoldController`, `NavigationCadencePolicy`

`EglFrameRenderer`는 현재 zoom/pan transform, 화면 보정 uniform과 resize redraw를 포함한다.
decoder나 탐색 engine 변경이 필요해 보이면 먼저 재현·검증 계획과 사용자 승인을 받아야 한다.

## 9. 개발 환경과 빌드

### 9.1 Windows 데스크톱

주요 기술:

- Electron 43
- React 18
- TypeScript 5.7
- Vite 6
- electron-builder 26
- BtbN Windows x64 LGPL shared FFmpeg/ffprobe 고정 자산

처음 준비할 때:

```powershell
npm.cmd install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1
npm.cmd test
npm.cmd run build
```

개발 실행:

```powershell
npm.cmd start
```

Windows 설치 파일 생성과 검증:

```powershell
npm.cmd run package:win
npm.cmd run verify:package
```

`scripts/setup-ffmpeg.ps1`은 승인된 archive와 SHA-256을 검증한 뒤 `tools/ffmpeg/`에
배치한다. FFmpeg binary, 실제 영상과 `artifacts/` 결과는 Git에 넣지 않는다.

### 9.2 Android

필수 환경:

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- Android SDK Platform 37
- Build Tools 36.0.0
- platform-tools

기본 host 검증:

```powershell
cd android
$env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$env:CCR_ANDROID_COMMIT_SHA = (git rev-parse HEAD)
.\gradlew.bat --version
node .\tools\verify-frame-accuracy.mjs
node .\tools\verify-representative-resolution-fixtures.mjs --manifest-only
node .\tools\verify-source-contract.mjs
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest `
  assembleInternalDebug assembleInternalDebugAndroidTest `
  assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\verify-apk-privacy.ps1
```

주요 variant:

| variant | 용도 | signer |
| --- | --- | --- |
| `internalDebug` | IDE·host test용 비후보 빌드 | standard debug |
| `internalRedesign` | 기존 후보와 병렬 설치하는 개발 앱 | standard debug |
| `internalBenchmark` | non-debuggable/profileable 성능 측정 | standard debug, 비후보 |
| v1 candidate wrapper 결과 | S24 장기 내부 신원 | `ccr-internal-pilot-v1` |

candidate는 `android/scripts/build-s24-v1-candidate.ps1`의 명시적 opt-in으로만 만든다.
private key와 password는 저장소·문서·채팅·명령행·로그에 남기지 않는다. standard debug나
CI artifact를 candidate로 승격하면 안 된다.

## 10. 최종 산출물과 서명

### 10.1 Windows v0.5.9

- 기준 commit: `92f26ddb3fcbfd125986cf85f21560fb9a5655b2`
- tag: `v0.5.9`
- Release: <https://github.com/snowberried/CCR/releases/tag/v0.5.9>
- 공개 EXE SHA-256:
  `d489c82b6badc8b81cda81a79f8deea139c8216c7d94206245e098c6e94bc06e`
- 공개 자산: installer, SHA-256, blockmap, `latest.yml`

로컬 합격 설치 파일과 GitHub Windows runner가 다시 만든 파일은 PE/NSIS 생성 시각 때문에
byte-identical하지 않을 수 있다. 공개 파일은 공개 checksum을 사용한다.

### 10.2 Android v1.0.0

최종 runtime/harness source:

```text
f4d2ec16e555d938380b46f422ed3f9c9ea32b94
```

최종 artifact set은 작업 당시 다음 저장소 밖 경로에 생성했다. 이 경로는 현재 개발 PC의
보존 위치이며 다른 컴퓨터에는 자동으로 존재하지 않는다.

```text
C:\Users\snowb\Documents\CCR-Artifacts\CCR-Android-1.0.0-f4d2ec1-20260803-093150
```

| 역할 | 파일 SHA-256 |
| --- | --- |
| debug app | `622f7cd85ca50a49b2aba4c9d1ab499e4a78f072ccc61d959041444572d81c93` |
| debug test | `b1a22e62d43f2a67d37d15abe89226923447e889d5bb538b7843926f335855a6` |
| benchmark app | `67028c124ccdcd20271aa64cfd0309c6fce90e8d65794258d7e5a57f649d675e` |
| macrobenchmark test | `59028e57186cc06ad0f06576b36dfcb9b02ae6721275eac61f1d83f5949c421e` |

- manifest: `artifact-manifest-v5.json`
- manifest SHA-256:
  `4f17e0fe25012630d87c8ef520f6c034e0b96d0ad324607f880977ac8aa1df66`
- runtime input tree SHA-256:
  `13bfb8f7452a24f14de1ca541acc38dca0c9e77dc374b28c4b5118eb96a79414`
- signer certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`

S24에 설치된 `base.apk` hash가 위 debug app과 정확히 일치했고, 기존 package를 삭제하지
않는 `install -r`로 앱 데이터와 signing lineage를 유지했다.

## 11. 검증 결과

### 11.1 데스크톱 기준선

v0.5.9 기준으로 다음을 완료했다.

- 자동 테스트 `106/106`
- TypeScript, Electron TypeScript와 Vite production build
- NSIS x64 package와 unpacked 91개 파일
- 개인정보·checksum·update metadata 검증
- 실제 Sample A~K의 frameIndex/PTS/fingerprint 정확성
- WebGL2 BT.601 limited와 RGBA rollback
- 5프레임 정·역방향 전체 이동 foreground 재디코드 0 사용자 확인
- 2/4/6/8 GiB 수동 cache 상한과 여유 RAM 50% 안전 제한 사용자 확인

과거 단계별 수치와 설치 checksum은 `docs/07`부터 `docs/23`까지의 영구 문서에 보존한다.

### 11.2 Android 1.0.0 host·emulator

- 최종 JVM: 175 tests, failure/error/skip 0
- lint: error 0, 알려진 warning 5
- 최종 build: `BUILD SUCCESSFUL in 1m 19s`, 91 tasks
- API 36 emulator 선택 instrumentation: 24 tests 중 21 pass, S24 전용 3 skip
- UI/navigation/accessibility focused instrumentation: 15/15 pass
- 격리 screenshot instrumentation: 1/1 pass
- candidate builder/signing/device bridge/Stage 1·Random host 계약: PASS
- APK privacy: forbidden permission 0

### 11.3 Android S24 Ultra

- 기존 17-fixture exact Gate: PASS
- mismatch, write-open, EGL swap, invalid Surface와 publication invariant 오류: 0
- portrait rotation 0과 safe content/navigation inset 침범 없음
- 파일 미선택 control 숨김과 표시 전용 frame card 확인
- `+1` tap, `+5` hold와 실제 PTS timeline 확인
- 화면 보정 panel, 값 유지, reset, 상태 점과 Original 비교 확인
- pinch/pan/Fit과 viewport resize clamp 확인
- chevron: 접힘 상태 위, 펼침 상태 아래 확인
- 최종 app drawer 이름 `CT Cine Reviewer`와 CCR icon 확인
- 최종 candidate cold launch: `Status: ok`, `LaunchState: COLD`, 651 ms

세 상태 screenshot:

1. [보정 접힘·기본값](../android/validation/ui-redesign-screenshots/s24-01-correction-collapsed-default.png)
2. [보정 펼침](../android/validation/ui-redesign-screenshots/s24-02-correction-expanded.png)
3. [보정 적용 후 접힘·상태 점](../android/validation/ui-redesign-screenshots/s24-03-correction-collapsed-adjusted.png)

### 11.4 실행하지 않았거나 이월한 검증

Android representative-resolution fixture의 exact cache를 현재 환경에서 복원하지 못해
Full Stage 1과 Random 250 전체는 실행하지 않았다. 사용자는 이 영상 자산이 제품 APK의
필수 구성요소가 아닌 추가 자동 회귀 자산임을 확인하고 이 Gate를 이월했다.

```text
DEFERRED — REPRESENTATIVE_RESOLUTION_AUTOMATION
```

이를 PASS로 기록하지 않는다. Play Store release-ready, 모든 장기 내구 검증 완료 또는
의료기기 검증 완료를 의미하지도 않는다. 자세한 historical evidence는
[Android Alpha 6 Reverse Refill Validation](../android/validation/ALPHA6_REVERSE_REFILL_VALIDATION.md)과
[Android README](../android/README.md)에 있다.

## 12. 개인정보·보안·의료 경계

### 공통 원칙

- 원본 MP4는 읽기 전용이다.
- 환자 영상, 실제 파일명, 전체 경로와 사용 기록을 commit·문서·외부 서비스에 남기지 않는다.
- 실제 샘플은 `local-samples/`처럼 Git에서 제외된 컴퓨터별 위치에서만 사용한다.
- 측정 결과는 `Sample A` 같은 비식별 alias로 기록한다.
- MP4 보정에 HU, Window Center/Width 또는 진단 보장 표현을 붙이지 않는다.
- DICOM, PACS, AI와 cloud는 명시적 새 범위 승인 없이 추가하지 않는다.

### 데스크톱 네트워크

영상 처리 자체는 로컬이다. 유일한 제품 네트워크 기능은 설정창에서 사용자가 직접 누르는
GitHub Release 확인·다운로드다. 자동 확인, telemetry, 외부 오류 보고와 강제 업데이트는
없다. 업데이트 요청에도 영상·파일명·사용 기록을 포함하지 않는다.

### Android 권한

Android Manifest에는 `INTERNET`, `READ_MEDIA_VIDEO`와 광범위 storage 권한이 없다.
Storage Access Framework URI를 읽기 전용으로 사용한다. persistable permission이 있는
URI만 process recreation 복구에 보존하고 권한이 없거나 소실되면 사용자가 다시 선택해야
한다. 내부 진단 clipboard에는 URI, 파일명, 경로와 영상 hash를 넣지 않는다.

### Android 서명

저장소에는 공개 certificate, SHA-256 fingerprint와 policy만 있다. private key와 password는
저장소 밖에 있으며 서로 다른 두 backup을 갖는다. key를 잃어버렸을 때 새 debug key로
기존 신원을 가장하지 말고 `android/signing/SIGNING_RECOVERY_RUNBOOK.md`를 따른다.

## 13. CI와 배포 동작

| workflow | 역할 |
| --- | --- |
| `.github/workflows/desktop-ci.yml` | 데스크톱 테스트와 build |
| `.github/workflows/android-ci.yml` | Android host/JVM/lint/APK와 privacy 검증 |
| `.github/workflows/release-windows.yml` | 데스크톱 버전 증가 시 Windows Release |

`main` push에서 `package.json` 버전이 그대로면 Windows Release workflow는 version detection
뒤 package와 공개 Release를 건너뛴다. 버전이 증가했을 때만 테스트·package·privacy·
checksum을 통과한 뒤 `vX.Y.Z` tag와 Latest Release를 만든다.

Android CI 결과는 `CI_EPHEMERAL_DEBUG`이며 S24 candidate가 아니다. GitHub Actions가 만든
debug APK를 장기 파일럿 artifact로 승격하면 안 된다. Android candidate는 외부 private
signing preflight가 필요한 로컬 명시 작업이다.

## 14. 알려진 제한과 의도적으로 남긴 항목

### 데스크톱

- Windows x64만 공식 검증했다.
- HEVC Main10, HDR와 Dolby Vision은 보장 범위가 아니다.
- Explorer cross-window drag/drop의 마지막 수동 파일럿은 historical 이월 항목이다.
- 코드 서명이 없어 Windows 게시자 경고가 나타날 수 있다.
- annotation과 작업 상태는 앱을 종료하면 사라진다.
- 프로젝트 저장, 개인정보 mask, JPEG, clip/batch export와 autoplay는 없다.

### Android

- 현재 완성본은 S24 내부 사용용이며 Play Store 공개 앱이 아니다.
- landscape, 비교 보기, 주석, export와 직접 frame 입력은 없다.
- 대표 해상도 Full Stage 1과 Random 250은 `DEFERRED`다.
- 기기에 `CCR Redesign Dev` 병렬 개발 앱이 남아 있을 수 있다. package와 데이터가 독립이며
  필요할 때 `com.snowberried.ctcinereviewer.internal.redesign`만 별도로 제거한다.

이 목록은 누락된 몰래 구현할 기능 목록이 아니다. 새 기능은 별도 제품 범위와 검증 계획을
승인받은 뒤 시작한다.

## 15. 문제 해결 순서

1. 사용자 영상이나 파일명을 출력하지 말고 증상과 재현 동작만 기록한다.
2. 환경·Windows·권한·sandbox 문제면 공용 troubleshooting 문서를 먼저 본다.
3. CCR 고유 decoder/cache/render 문제면 [프로젝트 troubleshooting](troubleshooting.md)을 본다.
4. Android signer 문제면 [Android signing 안내](../android/signing/README.md)와
   [복구 runbook](../android/signing/SIGNING_RECOVERY_RUNBOOK.md)을 본다.
5. 가설과 검증된 원인을 구분하고 같은 실패 명령을 무한 재시도하지 않는다.
6. 원본 MP4와 기존 signed artifact를 수정하거나 덮어쓰지 않는다.

## 16. 프로젝트를 다시 열어야 할 때

현재 프로젝트는 종료 상태다. 다시 작업하는 정상적인 경우는 두 가지다.

1. 실제 사용 중 재현 가능한 제품 결함을 수정한다.
2. 사용자가 다음 버전의 범위와 성공 기준을 명시적으로 승인한다.

새 작업자는 다음 순서로 시작한다.

1. `AGENTS.md`
2. 이 `docs/29_PROJECT_COMPLETION_GUIDE.md`
3. 루트 `README.md`
4. 대상 플랫폼의 `android/README.md` 또는 데스크톱 관련 정식 설계 문서
5. `docs/docs_hub.md`
6. `git branch --show-current`, `git rev-parse HEAD`, `git status --short`

미커밋 사용자 변경이 있으면 수정·삭제·stash·reset하지 않는다. 기능 변경 전에는 동결 영역,
변경 파일과 검증 계획을 먼저 보고한다.

## 17. 정식 문서 지도

모든 문서의 인덱스는 [Docs Hub](docs_hub.md)에 있다. 빠른 선택 기준은 다음과 같다.

| 알고 싶은 것 | 먼저 읽을 문서 |
| --- | --- |
| 프로젝트 전체와 최종 상태 | 이 문서 |
| 최초 목표와 비목표 | `00_PROJECT_CHARTER.md`, `01_PRODUCT_REQUIREMENTS.md` |
| 데스크톱 구조 선택 | `02_ARCHITECTURE_OPTIONS.md` |
| FFmpeg 배포 | `08_FFMPEG_DISTRIBUTION.md` |
| 정확 프레임과 cache | `09`, `10`, `12`, `13` |
| Zoom/Pan/Fit | `14_PHASE3A_VIEW_TRANSFORM.md` |
| 화면 보정 | `15_PHASE3B_VIDEO_DISPLAY.md` |
| 주석·내보내기 | `17`, `18` |
| 비교 보기 | `19_PHASE5_LINKED_DUAL_VIEW.md` |
| 데스크톱 최종 UI | `20`, `21`, `22` |
| Windows 자동 Release | `23_GITHUB_RELEASE_AUTOMATION.md` |
| Android 정확성·좌표·성능 | `24`~`28`, `android/validation/` |
| Android 최종 1.0 | `android/README.md` |
| Android signer | `android/signing/` |

`docs/00`~`06`에는 구현 전 제안과 당시 미결정 사항도 포함된다. 현재 제품 동작과 충돌하면
이 최종 안내서, 플랫폼 README, 후속 번호의 구현·검증 문서를 우선한다.

## 18. 용어 정리

| 용어 | 뜻 |
| --- | --- |
| CCR | CT Cine Reviewer |
| cine | 여러 CT 화면이 동영상처럼 이어진 입력 |
| frameIndex | 내부 0 기반 프레임 순서 |
| PTS | 실제 표시 시간축 timestamp |
| VFR | 프레임 간 시간 간격이 일정하지 않은 영상 |
| I420 | Y/U/V plane을 갖는 4:2:0 pixel layout |
| RGBA rollback | WebGL/I420 경로가 안전하지 않을 때 유지하는 기존 표시 경로 |
| LRU | 제한된 RAM에서 덜 최근에 사용한 block을 제거하는 cache 정책 |
| stale result | 새 요청·파일·Surface 뒤 늦게 도착해 폐기해야 하는 과거 결과 |
| publication | 실제 화면 swap 성공 뒤 displayed frame을 확정하는 사건 |
| Surface lease | Android의 현재 유효 Surface 세대를 구분하는 단조 증가 신원 |
| candidate | 공개 debug가 아닌 검증된 서명·source·artifact identity를 가진 내부 후보 |
| fixture | 실제 환자 자료가 아닌 비식별 합성 검증 영상 |

## 19. 최종 결론

CCR은 다음 상태로 종료한다.

- Windows v0.5.9: 공개 안정판
- Android v1.0.0: S24 내부 사용자 합격 안정판
- 원본·개인정보 외부 전송 없음
- 정확 프레임, cache, cancellation, 최신 요청 우선과 lifecycle 보호 유지
- 데스크톱과 Android의 합의된 UI·기능 범위 완성
- 대표 해상도 추가 자동화는 이월 상태로 정직하게 보존
- 새 기능은 명시적 다음 버전 승인 전 시작하지 않음

최종 Android 제품 runtime source는 `f4d2ec16e555d938380b46f422ed3f9c9ea32b94`다.
프로젝트 종료 문서 작업의 직전 Git 기준선은
`main` / `7e014cc87bd500dd9b6b840745dcc7924ffbd1d5`이며, 실제 종료 커밋은 이 문서를
포함하는 `main` 커밋이다.
