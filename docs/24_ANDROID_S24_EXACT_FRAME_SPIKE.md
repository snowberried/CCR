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
- S24 Ultra 연결 상태: Samsung `SM-S928N`, 실기기 Gate `PASS` (2026-07-15)

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
| 3 — golden/S24 | 통과 | Samsung `SM-S928N`에서 16개 fixture 정확성·burst·A→B 전환·읽기 전용 계약 통과 |

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

## 실기기 판정 결과와 제외 범위

- Samsung `SM-S928N`에서 H.264와 HEVC hardware decoder, 전체 frame identity, stale publish 0과 A→B 전환을 검증했다.
- 실기기에서 H.264 Main과 HEVC Main10의 Android profile 숫자 `2` 충돌을 MIME 없이 판정하던 결함을 확인해 MIME별 bit depth 판정과 회귀 test를 추가했다.
- Android의 clockwise rotation과 FFmpeg `-display_rotation`의 counter-clockwise 입력 규약 차이를 반영해 90/270 fixture metadata, SHA와 provenance를 바로잡았다.
- 자동 재생, 오디오, 주석, 비교 보기, 프로젝트 저장, DICOM/PACS, AI, cloud와 Play 배포는 범위 밖이다.

## Gate 3 고정 골든

- `android/testdata/frame-accuracy/`에 비식별 합성 MP4 16개와 schemaVersion 1 JSON을 고정했다.
- fixture는 H.264 IP/B-frame, VFR, long-GOP, nonzero PTS, 1/2 frame, 짧은 마지막 GOP, rotation 90/180/270, HEVC Main8, burst, A/B 전환과 PAR 8:9를 포함한다.
- B-frame fixture만 RTX 4080 SUPER의 `h264_nvenc`로 한 번 생성했다. GPU driver, FFmpeg/FFprobe version과 encoder 인자는 `provenance.json`에 기록했다.
- 모든 frame은 8×8 대형 흑백 cell의 finder pattern, 16-bit ID와 CRC-8을 포함한다. 생성기는 압축된 MP4를 다시 decode해 ID/CRC를 복원한 뒤에만 golden을 기록한다.
- JSON은 source SHA, codec/profile, coded size, inclusive crop, clockwise rotation, PAR, frame count와 frame별 key/sample ordinal/embedded ID/sync/16×16 RGB signature를 포함한다.
- CI는 `verify-frame-accuracy.mjs`로 source SHA와 wire contract만 검증하고 fixture를 재인코딩하지 않는다.

## S24 instrumentation 게이트

- debug APK의 read-only fixture provider는 `ParcelFileDescriptor.MODE_READ_ONLY`만 허용하고 다른 mode를 계수한 뒤 거부한다.
- test는 extractor index 전체, first/middle/last, ±1/±5 의미, random seek, rapid burst와 A→B generation 전환을 검사한다.
- 표시 결과는 FrameKey·texture timestamp·finder/CRC ID가 exact 일치해야 한다. 16×16 signature 허용치는 MAE 6, p99 16, max 40이다.
- 실제 연결 장치의 manufacturer가 Samsung이고 model이 `SM-S928*`일 때만 test를 실행한다.
- report schema는 `s24-report-format.json`, 실행 진입점은 `android/scripts/run-s24-gate.ps1`이다.
- 보고서는 app/fixture SHA, device/build/security patch/display, hardware codec component, latency p50/p95/max, cache/redecode/publication/recreate, Java/native/PSS, thermal과 battery를 기록한다. 성능 합격선은 적용하지 않는다.
- Gate 3의 `Exactness` 모드는 embedded ID/signature 검증을 위해 cache miss마다 full-frame `glReadPixels`를 수행한다. 따라서 아래 latency는 정확성 검증 경로의 측정값이며 `Pilot` 제품 표시 성능이나 성능 합격선으로 사용하지 않는다.
- `Pilot` 모드는 같은 decode, canonical GL texture, byte cache와 swap 경로를 사용하지만 full-frame CPU RGBA readback과 `FrameImageProbe` 생성을 하지 않는다.
- Samsung `SM-S928N` 실기기에서 gate를 실행했고 `PASS` 보고서를 회수했다. 실행 스크립트는 앱과 test APK를 직접 설치해 package 제거 전에 보고서를 복사하며 test APK만 제거한다.

## Gate 3 로컬·실기기 검증 기록

- fixture SHA/wire contract: 16/16 통과
- read-only/no-external-transmission source contract: 통과
- JVM unit test: 15/15 통과
- Android Lint: issue 0
- `assembleInternalDebug`, `assembleInternalDebugAndroidTest`: 통과
- app APK forbidden permission: 0
- app APK SHA-256: `a07b46817d1b52934d2b1d5d63245b61f6738a2cb632ba5357de2cedebd401eb`
- instrumentation APK SHA-256: `1e2ded93b98ecca388afb75e7cdcaf7e97023d79d352b50f44f4ad0a0adf8f6e`
- S24: Samsung `SM-S928N`, Android 16/API 36, build `BP4A.251205.006.S928NKSS6DZF3`, security patch `2026-06-05`, 1440×3120 @ 120 Hz
- hardware codec: `c2.qti.avc.decoder`, `c2.qti.hevc.decoder`; software fallback 없음
- instrumentation: 1/1 통과, fixture 16/16, frame/key/embedded ID/signature mismatch 0, stale publish 0, write open 0, decoder recreate 0
- 측정 latency 235건: p50 `50.244687 ms`, p95 `182.540937 ms`, max `283.309375 ms`; full-frame readback이 포함된 Exactness 측정이며 Pilot 제품 성능값이나 합격선이 아님
- memory snapshot: Java used `21,672,320 bytes`, native heap `15,108,752 bytes`, PSS `192,143 KiB`; thermal status 0, battery 100%
- 보고서: `android/reports/s24-frame-accuracy-report.json`, SHA-256 `04cfe47587106ea3d51b754379d6d1fbcee95cd1848be15c16ddbfddaa2a6bbd`

좌표계의 세부 수학은 `docs/25_ANDROID_CANONICAL_COORDINATES.md`를 따른다.
