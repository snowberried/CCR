# Android S24 Ultra Exact-Frame Spike

## 결론

데스크톱 v0.5.9 안정판 commit `92f26ddb3fcbfd125986cf85f21560fb9a5655b2`에서 `codex/android-s24-spike` 브랜치를 시작한다. 전체 모바일 제품을 만들지 않고 Gate 0~3의 정확 frameIndex·PTS·표시 세대 검증만 수행한다.

## 환경 기준선

- JDK 17.0.19
- Android SDK Platform API 37.0 revision 2
- Build Tools 36.0.0
- platform-tools / ADB 37.0.0
- AGP 9.3.0, Gradle Wrapper 9.5.0
- minSdk 34, compileSdk/targetSdk 37
- S24 Ultra 연결 상태: 없음, 실기기 Gate `Pending`

## 프로젝트 경계

- Android 구현은 저장소 `android/` 아래 독립 Gradle 프로젝트다.
- 데스크톱 decoder/cache/navigation hot path와 폴더를 이동하거나 공통화하지 않는다.
- 공통 의미는 골든 JSON, frame key, PTS 정수 변환과 좌표 계약으로만 검증한다.
- SAF 읽기 전용 MP4, SDR 8-bit H.264와 HEVC Main 8만 초기 대상으로 한다.
- INTERNET와 광범위 저장소 권한, 원격 분석, 프로젝트 저장, DICOM/PACS, AI와 클라우드는 제외한다.

## Gate 상태

| Gate | 상태 | 판정 |
| --- | --- | --- |
| 0 — v0.5.9 동결 | 통과 | tag/Latest Release와 artifact 확인 |
| 1 — Android 환경/프로젝트 | 통과 | local/Windows CI build와 privacy 검사 통과 |
| 2 — exact decode/render | 통과 | JVM 계약·Lint·APK 검증 통과, 실기기 판정은 Gate 3에서 수행 |
| 3 — golden/S24 | 진행 전 | 연결 기기 없음, 최종 상태는 `Pending` 유지 |

## Gate 1 검증 기록

- 독립 `android/` 단일 app module과 Gradle Wrapper 9.5.0을 사용한다.
- `internalDebug` 설치 ID는 `com.snowberried.ctcinereviewer.internal`이다.
- Windows Android CI run `29394192564`에서 wrapper 검증, Lint, JVM test, APK와 privacy 검사가 통과했다.
- Android workflow는 APK와 test report만 Actions artifact로 보관하며 tag나 GitHub Release를 만들지 않는다.

## Gate 2 구현 계약

- `ACTION_OPEN_DOCUMENT`로 받은 URI를 `openFileDescriptor(uri, "r")`로만 연다. persistable 권한도 read flag만 요청하고 실패하면 현재 session에서만 사용한다.
- `ccr-media-actor` HandlerThread 하나가 `MediaExtractor`와 `MediaCodec`의 생성, seek, input/output과 폐기를 독점한다.
- extractor sample 순서의 `(sampleOrdinal, ptsUs, sync)`를 수집하고 `(ptsUs, sampleOrdinal)` stable sort로 0-based display frame과 duplicate ordinal을 만든다. FPS로 frame index를 역산하지 않는다.
- 역방향과 random seek는 이전 sync로 이동해 목표까지 순방향 decode한다. 목표 이전 output은 `render=false`, 목표 한 장만 decoder Surface에 release한다.
- `ccr-egl-render` thread 하나가 SurfaceTexture/EGL/GL texture cache를 독점한다. decoder가 목표를 release하기 전에 pending target 한 칸을 예약하고 `onFrameAvailable`의 texture timestamp와 request generation을 확인한다.
- 요청 또는 파일 전환과 `eglSwapBuffers` 직전 검사를 같은 `PublicationGate` lock으로 직렬화한다. stale texture는 소비하지만 swap하지 않는다.
- OES target은 inclusive crop, pixel aspect ratio와 clockwise rotation을 적용한 canonical RGBA8 texture로 복사한다. cache 상한은 `min(128 MiB, Java max heap/4)` byte budget이다.
- cache는 탐색 방향 반대편의 먼 frame부터 제거하고 파일 generation이 바뀌면 GL texture를 모두 폐기한다.
- SDR 8-bit H.264와 HEVC Main 8의 hardware decoder만 허용한다. Main10, HDR/HLG/PQ, Dolby Vision, 그 밖의 codec과 software-only decoder는 명시적 unsupported 상태다.
- 화면에는 읽기 전용 파일 열기, metadata, 0-based index·PTS, 처음/마지막, ±1/±5, 직접 입력, 취소·파일 전환과 진단값만 둔다.

## Gate 2 로컬 검증 기록

- `testInternalDebugUnitTest`: 12/12 통과
- `lintInternalDebug`: issue 0
- `assembleInternalDebug`: 통과
- merged manifest: minSdk 34, targetSdk 37, version `0.1.0`, INTERNET·media/storage permission 0
- APK privacy script: forbidden permission 0
- `internalDebug` APK SHA-256: `17fab2d8a8d4d3a58c365947fc6af3accc8049d7897735b84d33d4e98e998f16`

## 아직 판정하지 않은 항목

- S24 Ultra가 연결되지 않아 hardware codec component, 실제 frame identity, stale publish 0과 A/B 전환은 아직 검증하지 않았다.
- Gate 3에서 비식별 합성 fixture, golden JSON, instrumentation runner와 report 형식을 추가한 뒤 Samsung `SM-S928*`에서만 S24 합격 여부를 판정한다.
- 자동 재생, 오디오, 주석, 비교 보기, 프로젝트 저장, DICOM/PACS, AI, cloud와 Play 배포는 범위 밖이다.
