# Docs Hub

프로젝트 문서를 빠르게 찾기 위한 인덱스이다. 새 문서 파일을 만들거나 문서 위치를 바꾸면 이 파일을 함께 갱신한다.

## 상위 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| 프로젝트 개요 | `../README.md` | CT Cine Reviewer 명칭, 현재 단계, v0.1 범위와 제외 범위 |
| Latest Project Handoff | `../HANDOFF_V058.md` | v0.5.8 5프레임 이동용 묶음 방향성 선읽기 실사용 검증 상태 |
| Phase 1 Handoff | `../HANDOFF_PHASE1.md` | Phase 1~2 구현 과정과 이전 기준선 |
| 프로젝트 작업 지침 | `../AGENTS.md` | 중요한 결정 전 사용자 확인, 의료·보안 경계, 단계별 검증 원칙 |

## 기획 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| Project Charter | `00_PROJECT_CHARTER.md` | 문제, 사용자, 목표, 비목표, 한계와 성공 정의 |
| Product Requirements | `01_PRODUCT_REQUIREMENTS.md` | P0/P1/P2 요구사항, 사용자 흐름, 조작, 오류, 성능 목표 |
| Architecture Options | `02_ARCHITECTURE_OPTIONS.md` | 기술 후보 비교, 1순위 제안과 위험 |
| Technical Spike Plan | `03_TECHNICAL_SPIKE_PLAN.md` | 대표 MP4 분석, 프레임·PTS·캐시 검증 계획과 합격 기준 |
| Data and State Model | `04_DATA_AND_STATE_MODEL.md` | 원본 식별, 프레임, 보정, 주석, preset, 프로젝트 저장 개념 |
| Roadmap | `05_ROADMAP.md` | Phase별 목적, 산출물, 진입·완료 조건과 사용자 승인 |
| Decisions and Open Questions | `06_DECISIONS_AND_OPEN_QUESTIONS.md` | 확정 사항, 제안, 미결정과 Phase 1 승인 체크리스트 |
| Phase 1 Spike Results | `07_PHASE1_SPIKE_RESULTS.md` | Phase 1 scaffold, 테스트, 실제 샘플 측정 결과와 남은 차단 사항 |
| FFmpeg Distribution | `08_FFMPEG_DISTRIBUTION.md` | 고정 BtbN 자산, checksum, buildconf, 라이선스와 취득 절차 |
| Frame Decoding and Cache | `09_FRAME_DECODING_AND_CACHE.md` | Phase 1C 프레임 전달·정확성·캐시 실측과 추천 전략 |
| Phase 2 Minimum Viewer | `10_PHASE2_MINIMUM_VIEWER.md` | 최소 실사용 UI, 방향성 cache, 실제·합성 QA와 메모리 검사 |
| Phase 2.1 Windows Installer Pilot | `11_PHASE2_1_WINDOWS_INSTALLER.md` | 실제 설치·제거·재설치, 경로·프로세스·네트워크 검증과 남은 항목 |
| Phase 2.2 Continuous Scan Cache Spike | `12_CONTINUOUS_SCAN_CACHE_SPIKE.md` | 전체 I420 cache, block LRU, WebGL2, 연속 탐색과 메모리 실측 |
| Phase 2.3 Product Cache Integration | `13_PHASE2_3_PRODUCT_CACHE_INTEGRATION.md` | 제품 mode, 색·fallback, 설치본과 내구 검증 |
| Phase 3A View Transform Foundation | `14_PHASE3A_VIEW_TRANSFORM.md` | 좌표계, Zoom/Pan/Fit, fullscreen과 renderer 공통 transform |
| Phase 3B Video Display Adjustment | `15_PHASE3B_VIDEO_DISPLAY.md` | MP4 Level/Width, Gamma, Inverse, Sharp, preset과 Original 비교 |
| Post-Phase 3B Viewer Controls | `16_POST_PHASE3B_VIEWER_CONTROLS.md` | 고정 10%p zoom, PACS식 Pan/Zoom 도구와 입력 충돌 검증 |
| Phase 4A Frame Annotation MVP | `17_PHASE4A_FRAME_ANNOTATION.md` | image pixel 주석, Undo/Redo, annotated timeline과 렌더링 회귀 |
| Phase 4B-1 Frame Export & Clipboard | `18_PHASE4B1_FRAME_EXPORT.md` | displayed-frame snapshot, 전체/현재 보기 PNG와 OS clipboard |
| Phase 5 Linked Dual View & Crosshair | `19_PHASE5_LINKED_DUAL_VIEW.md` | 동일 frame A/B, pane별 상태, image-space crosshair와 성능 QA |
| v0.5.1 UI Polish | `20_V051_UI_POLISH.md` | Electron 메뉴 제거, 전역 명령 계층, 한국어 label과 반응형 QA |
| Frame Navigation & Right Panel Tabs | `21_FRAME_NAVIGATION_LAYOUT.md` | 프레임 시간 표시, 시각적 타임라인과 조정·정보 탭 패널 |
| v0.5.2 Modern Dark Professional | `22_V052_MODERN_DARK_PROFESSIONAL.md` | 기능 동결을 유지한 Modern Dark UI, SVG 자산, 3:1:3 탐색과 시각 QA |
| GitHub Windows Release Automation | `23_GITHUB_RELEASE_AUTOMATION.md` | main 버전 증가 감지, 자동 태그와 Windows Latest Release 절차 |
| v0.5.2 Design QA | `../design-qa.md` | 최종 시안과 1440×900·720×600 구현 비교 및 판정 |
| v0.5.2 Modern Dark Handoff | `../HANDOFF_V052_MODERN_DARK.md` | 최신 UI·확대율 의미, 검증 결과, 설치본과 후속 작업 상태 |
| v0.5.3 Handoff | `../HANDOFF_V053.md` | 버전 표시, 설정 모달, 수동 업데이트 확인과 검증된 설치본 |
| v0.5.4 Handoff | `../HANDOFF_V054.md` | 앱·바로가기·설치 프로그램 공통 아이콘과 설치 안내 메시지 |
| v0.5.5 Handoff | `../HANDOFF_V055.md` | Electron 배포본 설치, 명시적 GitHub Release와 v0.5.4 실패 기록 |
| v0.5.6 Handoff | `../HANDOFF_V056.md` | 프리셋 제거, 빈 화면 열기, 빠른 이동 간격과 사용자 지정 단축키 |
| v0.5.7 Handoff | `../HANDOFF_V057.md` | 2GiB 초과 영상의 현재 위치 중심 LRU와 방향성 선읽기 |
| v0.5.8 Handoff | `../HANDOFF_V058.md` | 8-block high-water와 최대 4-block 묶음 선읽기 |
| Phase 2.2 Handoff | `../HANDOFF_PHASE2_2.md` | 최종 검증 상태와 제품 통합 전 승인 사항 |
| Phase 2.3 Handoff | `../HANDOFF_PHASE2_3.md` | 제품 통합 최종 상태와 Phase 3 진입 조건 |
| Phase 3A Handoff | `../HANDOFF_PHASE3A.md` | View Transform 최종 상태와 Phase 3B 진입 조건 |
| Phase 3B Handoff | `../HANDOFF_PHASE3B.md` | Video Display 최종 상태와 preset 파일럿 조건 |
| Phase 4A Handoff | `../HANDOFF_PHASE4A.md` | 주석 MVP 최종 상태와 후속 승인 범위 |
| Phase 4B-1 Handoff | `../HANDOFF_PHASE4B1.md` | deterministic export 최종 상태와 후속 승인 범위 |
| Phase 5 Handoff | `../HANDOFF_PHASE5.md` | 비교 뷰 최종 상태, 설치본과 기능 동결 후보 |
| Project Troubleshooting | `troubleshooting.md` | CT Cine Reviewer에서만 발생하는 문제와 검증된 해결 방법 |
| Docs Hub | `docs_hub.md` | 프로젝트 문서 목록과 위치 안내 |

## 현재 단계

- Phase 0 기획은 완료됐다.
- Phase 1 기술 스파이크와 Phase 2 최소 실사용 뷰어를 완료했다.
- Phase 2.1 NSIS 패키징, unpacked smoke test와 실제 설치·제거·재설치를 완료했다.
- 실제 Explorer drag/drop, Windows 제거 등록 확인과 사용자 파일럿 피드백은 남아 있다.
- Phase 2.2 연속 탐색·대용량 RAM cache 기술 스파이크의 구현·실샘플·30분 내구 검증과 문서화를 완료했다.
- Phase 2.3에서 검증된 I420 cache를 제품 기본 경로로 통합하고 NSIS·실제 설치 앱 검증을 완료했다.
- Phase 3A View Transform과 Phase 3B 플랫폼 중립 Video Display를 통합하고 설치 검증을 완료했다.
- Phase 3B 승인 후 고정 10%p zoom과 PACS식 Pan/Zoom 도구 막대를 추가하고 WebGL/RGBA 회귀를 완료했다.
- 2GiB dynamic soft cap의 I420 full/LRU를 기본 사용하며, 초과 영상의 LRU는 현재 위치 중심 warmup과 8-block high-water·최대 4-block 묶음 선읽기를 사용한다. 72MiB 방향성 cache는 RGBA rollback으로 유지한다.
- Phase 4A 세션 전용 주석과 annotated timeline을 구현하고 WebGL/RGBA·cached navigation 회귀를 완료했다.
- Phase 4B-1 displayed-frame PNG 저장과 clipboard 복사를 구현하고 양 renderer·privacy 회귀를 완료했다.
- Phase 5에서 같은 frame/pixels를 공유하는 View A/B 비교 뷰와 image-space linked crosshair를 구현했다.
- v0.5.1에서 기능 의미를 유지한 채 Electron 기본 메뉴, toolbar 계층과 한국어 표시 명칭을 정리했다.
- 프레임 시간 표시와 시각적 타임라인, 기본 조정 상태의 조정·정보 탭 패널을 추가했다. 동영상 자동 재생은 사용자 결정으로 폐기했다.
- v0.5.2에서 Modern Dark Professional 리디자인, 제공 SVG 아이콘과 3:1:3 대칭 프레임 탐색을 적용했다.
- 확대율 셀은 원본 픽셀 기준 현재 `%`를 표시하고 Fit·50~200% 선택과 실제 배율 10%p step을 제공한다.
- v0.5.3에서 상단 버전 표시, 조정 패널의 구분선 UI와 독립 설정창·수동 업데이트 확인을 추가하고 NSIS 설치본을 검증했다.
- v0.5.4에서 앱·바탕화면 바로가기·설치/제거 프로그램의 아이콘을 통일하고 설치 시작 안내 페이지를 추가했다.
- `main`에서 앱 버전이 증가하면 Windows 설치본과 업데이트 메타데이터를 검증한 뒤 태그와 GitHub Latest Release를 자동 생성한다.
- v0.5.5에서 깨끗한 GitHub Windows 러너의 Electron 배포본 설치와 명시적 publish 경로를 보완했다.
- v0.5.6에서 화면 보정 프리셋을 제거하고 빈 화면 파일 열기, 빠른 이동 간격과 사용자 지정 단축키를 추가했다.
- v0.5.7에서 2GiB 초과 영상의 LRU를 현재 위치 중심 warmup과 최대 4-block 방향성 선읽기로 보완했다.
- v0.5.8에서 5프레임 연속 이동 중 남은 foreground 재디코드를 줄이기 위해 최대 4-block 단일-process refill을 추가했다.
- 사용자 승인 전 프로젝트 저장, 마스크와 DICOM/PACS를 시작하지 않는다.

## 갱신 규칙

- 새 문서를 추가하면 위 표에 문서 이름, 위치, 용도를 기록한다.
- 문서가 삭제되거나 이동하면 이 인덱스도 같은 작업에서 수정한다.
- 중요한 결정이나 운영 원칙은 먼저 `../AGENTS.md`에 맞는지 확인한다.
