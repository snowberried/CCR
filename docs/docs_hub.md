# CCR Docs Hub

CT Cine Reviewer 문서 인덱스다. 프로젝트는 2026-08-03 KST에 Windows v0.5.9와 Android
내부용 v1.0.0을 기준으로 1차 완성·종료됐다. 새 문서를 추가하거나 삭제·이동하면 이
인덱스를 같은 작업에서 갱신한다.

## 처음 읽을 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| 최종 프로젝트 안내서 | `29_PROJECT_COMPLETION_GUIDE.md` | 제품, 사용법, 구조, 빌드, 검증, 서명, 제한과 재개 절차의 최종 통합 기준 |
| 프로젝트 개요 | `../README.md` | 처음 보는 사람을 위한 짧은 입구와 빠른 실행 |
| 프로젝트 작업 규칙 | `../AGENTS.md` | 개인정보·의료·서명·검증·실행 안전 규칙 |
| Android 1.0.0 | `../android/README.md` | Android runtime, UI, S24 검증과 최종 candidate 기록 |
| Project Troubleshooting | `troubleshooting.md` | CCR 고유 영상·cache·렌더·배포 문제 해결 기록 |

문서가 충돌하면 `AGENTS.md`의 안전 규칙, 이 최종 안내서, 대상 플랫폼 README, 더 나중
번호의 구현·검증 문서, 초기 기획 문서 순으로 해석한다. 초기 기획에는 구현되지 않은
후보 기능도 있으므로 현재 제품 설명으로 단독 사용하지 않는다.

## 기획과 초기 기술 결정

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| Project Charter | `00_PROJECT_CHARTER.md` | 최초 문제, 사용자, 목표, 비목표와 의료적 한계 |
| Product Requirements | `01_PRODUCT_REQUIREMENTS.md` | 초기 P0/P1/P2 후보와 사용자 흐름 |
| Architecture Options | `02_ARCHITECTURE_OPTIONS.md` | Electron/Tauri/Qt/.NET 비교와 Electron 선택 근거 |
| Technical Spike Plan | `03_TECHNICAL_SPIKE_PLAN.md` | MP4 분석, 프레임·PTS·cache 검증 계획 |
| Data and State Model | `04_DATA_AND_STATE_MODEL.md` | frame, display, view, annotation과 수명 개념 |
| Roadmap | `05_ROADMAP.md` | 과거 Phase별 목적과 완료 조건 |
| Decisions and Open Questions | `06_DECISIONS_AND_OPEN_QUESTIONS.md` | 당시 결정과 미결정 기록; 현재 상태는 최종 안내서 우선 |

## Windows 데스크톱 구현과 검증

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| Phase 1 Spike Results | `07_PHASE1_SPIKE_RESULTS.md` | scaffold, ffprobe와 실제 sample 초기 측정 |
| FFmpeg Distribution | `08_FFMPEG_DISTRIBUTION.md` | 고정 BtbN LGPL 자산, checksum과 라이선스 |
| Frame Decoding and Cache | `09_FRAME_DECODING_AND_CACHE.md` | 정확 프레임 전달과 초기 cache 전략 |
| Phase 2 Minimum Viewer | `10_PHASE2_MINIMUM_VIEWER.md` | 최소 UI, 방향성 RGBA cache와 QA |
| Windows Installer Pilot | `11_PHASE2_1_WINDOWS_INSTALLER.md` | NSIS 설치·제거·재설치와 privacy 검증 |
| Continuous Scan Cache Spike | `12_CONTINUOUS_SCAN_CACHE_SPIKE.md` | I420 full cache, block LRU와 WebGL2 spike |
| Product Cache Integration | `13_PHASE2_3_PRODUCT_CACHE_INTEGRATION.md` | I420 기본 경로와 RGBA rollback 통합 |
| View Transform | `14_PHASE3A_VIEW_TRANSFORM.md` | image 좌표, Zoom/Pan/Fit와 fullscreen |
| Video Display | `15_PHASE3B_VIDEO_DISPLAY.md` | 화면 픽셀 보정과 WebGL/RGBA parity |
| Viewer Controls | `16_POST_PHASE3B_VIEWER_CONTROLS.md` | 10%p zoom, Pan/Zoom 도구와 입력 소유권 |
| Annotation MVP | `17_PHASE4A_FRAME_ANNOTATION.md` | image-pixel 주석, Undo/Redo와 timeline |
| Frame Export | `18_PHASE4B1_FRAME_EXPORT.md` | displayed-frame PNG와 clipboard snapshot |
| Linked Dual View | `19_PHASE5_LINKED_DUAL_VIEW.md` | 동일 frame A/B와 image-space crosshair |
| v0.5.1 UI Polish | `20_V051_UI_POLISH.md` | 명령 계층, 한국어 label과 반응형 QA |
| Navigation Layout | `21_FRAME_NAVIGATION_LAYOUT.md` | PTS timeline, 대칭 탐색과 조정/정보 panel |
| Modern Dark UI | `22_V052_MODERN_DARK_PROFESSIONAL.md` | 최종 데스크톱 시각 체계와 자산 |
| Windows Release Automation | `23_GITHUB_RELEASE_AUTOMATION.md` | 버전 증가 main push의 tag·Release 절차 |

## Android 설계와 검증

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| S24 Exact-Frame Spike | `24_ANDROID_S24_EXACT_FRAME_SPIKE.md` | 17개 fixture와 Gate 0~3 정확성 기준선 |
| Canonical Coordinates | `25_ANDROID_CANONICAL_COORDINATES.md` | crop, PAR, rotation과 EGL 물리 pixel 계약 |
| Representative Resolution | `26_ANDROID_REPRESENTATIVE_RESOLUTION_VALIDATION.md` | 720p/1080p exact/cache/smoothness 검증 계약 |
| Reverse Window Spike | `27_ANDROID_REVERSE_WINDOW_SPIKE.md` | 역방향 window, exact fallback과 generation |
| Sequential Navigation | `28_ANDROID_ALPHA4_SEQUENTIAL_NAVIGATION.md` | completion-driven hold와 forward sequential |
| Android 제품 README | `../android/README.md` | 1.0.0 최종 상태와 과거 Alpha 검증 구분 |
| Alpha 5 Validation | `../android/validation/ALPHA5_BIDIRECTIONAL_VALIDATION.md` | bidirectional 구조와 S24 검증 |
| Alpha 6 Validation | `../android/validation/ALPHA6_REVERSE_REFILL_VALIDATION.md` | reverse refill, historical failure와 deferred debt |
| S24 Gate 3 Evidence | `evidence/android/s24/README.md` | 비식별 Gate 3 PASS 요약 |
| S24 Device Baseline | `../android/validation/device-baselines/sm-s928n-android16-2026-07-15/README.md` | sanitized device report와 checksum |
| Android Signing | `../android/signing/README.md` | `ccr-internal-pilot-v1` 공개 정책과 candidate 경계 |
| Signing Recovery | `../android/signing/SIGNING_RECOVERY_RUNBOOK.md` | key 손실·복구와 새 lineage 절차 |
| Signing Incident | `../android/signing/SIGNING_INCIDENT_2026-07-27.md` | 과거 debug signing 문제의 historical evidence |

## 샘플·디자인·지원 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| Local Sample Pilot | `../local-samples/README.md` | 실제 파일을 추적하지 않는 비식별 검증 규칙 |
| Android Frame Accuracy Fixtures | `../android/testdata/frame-accuracy/README.md` | 합성 정확성 fixture 계약 |
| Representative Fixtures | `../android/testdata/representative-resolution/README.md` | 외부 exact cache와 lock 계약 |
| Latest Design QA | `../design-qa.md` | Android portrait redesign과 데스크톱 시각 QA |
| Docs Hub | `docs_hub.md` | 현재 문서 인덱스 |

## 최종 상태 요약

- Windows v0.5.9은 공개 Latest Release 안정판이다.
- Android v1.0.0은 S24 Ultra 내부 사용자 합격 안정판이다.
- Android 대표 해상도 Full Stage 1과 Random 250은 `DEFERRED`이며 PASS가 아니다.
- 원본 MP4, 환자 식별정보, 실제 파일명·경로와 private signing secret은 Git에 없다.
- DICOM/PACS, AI, cloud, autoplay/audio와 프로젝트 저장은 현재 범위가 아니다.
- 임시 `HANDOFF_*.md` 18개는 유효 결론을 최종 안내서와 정식 문서에 통합한 뒤 제거했다.
- 새 제품 작업은 재현 가능한 결함 또는 명시적으로 승인된 다음 버전 범위에서만 시작한다.
