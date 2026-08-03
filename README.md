# CT Cine Reviewer

**CCR — CT cine MP4를 정확한 프레임 단위로 검토하는 완전 로컬 보조 뷰어**

> 프로젝트 상태: **1차 완성 및 종료** (`2026-08-03 KST`)

프로젝트를 처음 보는 사람은 먼저
[최종 프로젝트 안내서](docs/29_PROJECT_COMPLETION_GUIDE.md)를 읽으면 된다. 제품 목적,
Windows와 Android의 차이, 사용법, 코드 구조, 빌드, 검증, 서명, 제한과 재개 절차를 한
문서에 정리했다.

CCR은 의료기기나 공식 진단·PACS·DICOM 프로그램이 아니다. 원본 MP4에서 사라진 HU와
의료 정보를 복원하지 않으며 정식 판독 환경을 대체하지 않는다.

## 완성된 제품

| 제품 | 상태 | 주요 용도 |
| --- | --- | --- |
| Windows desktop `v0.5.9` | 공개 안정판 | 정확 프레임 탐색, Zoom/Pan, 화면 보정, 비교 보기, 주석, PNG/clipboard |
| Android `v1.0.0` | S24 내부 사용자 합격 | portrait 단일 영상, `-5/-1/+1/+5`, PTS timeline, pinch/pan/Fit, 화면 보정 |

Windows 공개 설치본은
[GitHub v0.5.9 Release](https://github.com/snowberried/CCR/releases/tag/v0.5.9)에서 받을 수
있다. Android 1.0.0은 Play Store 배포본이 아니라 검증된 내부 파일럿 서명 앱이다.

## 핵심 원칙

- 내부 0 기반 `frameIndex`와 실제 PTS를 구분한다.
- VFR 프레임 위치를 평균 FPS로 추정하지 않는다.
- 원본 영상은 읽기 전용이며 재인코딩하거나 수정하지 않는다.
- 영상·파일명·경로와 사용 기록을 외부로 전송하지 않는다.
- MP4 밝기·명암 보정은 화면 픽셀 연산이며 DICOM HU window가 아니다.
- 오래된 요청, 이전 파일과 이전 Surface 결과를 화면에 게시하지 않는다.

## 빠른 개발 시작

### Windows desktop

```powershell
npm.cmd install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1
npm.cmd test
npm.cmd run build
npm.cmd start
```

설치 파일 생성:

```powershell
npm.cmd run package:win
npm.cmd run verify:package
```

### Android

JDK 17, Android SDK Platform 37, Build Tools 36.0.0과 platform-tools가 필요하다.

```powershell
cd android
$env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$env:CCR_ANDROID_COMMIT_SHA = (git rev-parse HEAD)
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest `
  assembleInternalDebug assembleInternalDebugAndroidTest `
  assembleInternalBenchmark :macrobenchmark:assembleInternalBenchmark
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\verify-apk-privacy.ps1
```

일반 debug APK는 장기 S24 candidate가 아니다. Android 서명 정책은
[android/signing/README.md](android/signing/README.md)를 따른다.

## 문서

- [최종 프로젝트 안내서](docs/29_PROJECT_COMPLETION_GUIDE.md)
- [전체 Docs Hub](docs/docs_hub.md)
- [Android 1.0.0 안내와 최종 검증](android/README.md)
- [프로젝트 작업 규칙](AGENTS.md)
- [프로젝트 troubleshooting](docs/troubleshooting.md)

단계별 설계와 검증 근거는 `docs/00`~`docs/28`, Android 검증 기록은
`android/validation/`에 보존한다. 과거 임시 `HANDOFF_*.md` 문서는 최종 안내서와 정식
문서에 내용을 통합한 뒤 제거했다.

## 프로젝트 재개 조건

현재는 종료 상태다. 실제 사용 중 재현 가능한 결함을 수정하거나 사용자가 다음 버전의
범위와 성공 기준을 명시적으로 승인할 때만 새 제품 작업을 시작한다. 작업 전에는
`AGENTS.md`와 최종 안내서를 읽고 branch, HEAD와 미커밋 변경을 먼저 확인한다.
