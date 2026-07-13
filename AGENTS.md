# 프로젝트 작업 지침

이 파일은 이 프로젝트에서 작업할 때 우선 확인해야 하는 상위 지침이다.

## 핵심 원칙

- 중요한 결정은 Codex가 독단으로 하지 않는다.
- 요구사항 해석이 여러 가지일 때는 가능한 해석을 밝히고 사용자에게 확인한다.
- 구현 방향, 데이터 구조, 외부 의존성 추가, 큰 리팩토링, 삭제 작업처럼 되돌리기 어렵거나 영향 범위가 큰 선택은 먼저 사용자 동의를 받는다.
- 단순하고 되돌리기 쉬운 변경은 기존 요청 범위 안에서 최소 변경으로 진행한다.
- 이 앱은 전달받은 CT 동영상 검토를 돕는 보조 뷰어이며 의료기기나 공식 진단 프로그램으로 표현하지 않는다.
- MP4의 화면 픽셀 보정과 DICOM의 HU 기반 window를 혼동하지 않는다. MP4 preset에는 HU 값을 붙이지 않는다.
- 원본 영상은 읽기 전용으로 취급하고, 환자 영상·파일명·사용 정보를 외부로 전송하지 않는다.
- 사용자가 명시적으로 승인하기 전 DICOM, PACS, AI 또는 클라우드 기능으로 범위를 넓히지 않는다.
- 향후 모바일 앱을 개발할 계획이 있으므로 핵심 기능의 의미와 데이터 모델은 데스크탑과 모바일에서 공유 가능하게 설계한다.
- 데스크탑과 모바일의 화면 구성·조작 방식은 크게 달라질 수 있으므로 UI 구현은 플랫폼별로 분리하고, 공통 로직을 특정 UI나 Electron에 묶지 않는다.
- 공통화는 데이터 모델, 검증 규칙, 좌표계, 프로젝트 schema처럼 의미가 같아야 하는 영역에 우선 적용한다.
- 데스크탑 프레임 이동의 hot path에는 불필요한 IPC, JSON 직렬화, 프로세스 재실행, 과한 추상화 비용을 넣지 않는다.

## 작업 순서

1. 이해: 요청과 기존 구조를 먼저 확인한다.
2. 최소 변경: 필요한 파일과 코드만 수정한다.
3. 검증: 가능한 명령, 테스트, 파일 확인으로 결과를 확인한다.
4. 요약: 변경 내용과 남은 위험을 짧게 보고한다.

## 현재 단계: Phase 5 Linked Dual View & Crosshair 통합·검증

- Phase 0 기획은 완료됐다.
- `HANDOFF_PHASE5.md`와 `docs/19_PHASE5_LINKED_DUAL_VIEW.md`를 먼저 읽고 비교 뷰·crosshair와 성능 검증 상태를 확인한다.
- Phase 1 기술 스파이크와 Phase 2 최소 실사용 뷰어 범위는 승인됐고 완료됐다.
- 파일 열기, Canvas 표시, 정확한 프레임 탐색, 상태·진단 표시와 방향성 RAM cache를 구현했다.
- FFmpeg는 Phase 1B에서 승인된 BtbN Windows x64 LGPL shared 고정 자산만 사용하며 `scripts/setup-ffmpeg.ps1`의 checksum 검증을 거쳐 로컬 배치한다.
- Phase 2.1 RGBA rollback cache 예산은 72MiB, 목표 최소 5·최대 61프레임이다. 대표 영상은 순방향 20/40, 역방향 40/20, 교대 30/30을 사용한다.
- Zoom/Pan/Fit/Fullscreen, MP4 Video Display, 세션 전용 프레임 주석과 PNG/clipboard 내보내기를 구현했다. 자동 재생, 프로젝트 저장, DICOM과 PACS는 아직 구현하지 않는다.
- 전체 I420 cache, 제한 block LRU와 WebGL2 BT.601 limited 표시를 Phase 2.3 제품 기본 경로로 통합했다.
- `CCR_FORCE_RGBA=1` 긴급 rollback과 기존 Phase 2.1 RGBA segment cache를 삭제하지 않는다.
- Phase 3A View Transform은 image pixel center와 Fit 대비 1~10배 zoom을 공통 의미로 사용하며 decoder/cache와 결합하지 않는다.
- Phase 3B preset은 화면 픽셀 기반 candidate이며 실제 HU 값이나 진단 보장을 뜻하지 않는다.
- Phase 3B 승인 후 Ctrl+wheel 10%p step과 Pan/Zoom/Fit/100% 세로 도구 막대를 추가했다. 좌클릭 tool과 우클릭 Level/Width는 단일 pointer 소유권으로 분리한다.
- Phase 4A 주석 geometry는 원본 image pixel 좌표이며 프로젝트 저장 없이 세션 RAM에만 유지한다.
- Phase 4B-1은 실제 displayed frame snapshot만 저장하며 OS/window screenshot, temp preview와 decoder/cache 재실행을 사용하지 않는다.
- Phase 5 비교 뷰의 두 pane는 같은 `frameIndex`, fingerprint와 decoded pixels를 공유한다. View Transform, Video Display, persistent tool과 임시 pointer/Original 상태만 pane별 독립이다.
- linked crosshair는 기존 Phase 3A image↔viewport 변환을 재사용하는 image pixel correspondence이며 DICOM spatial registration이 아니다.
- decoder/cache/navigation/annotation store/timeline은 각각 하나만 유지하고 export는 active pane 기준이다.
- 실제 사용 피드백과 별도 사용자 승인 전 프로젝트 저장, JPEG 또는 clip/batch 내보내기로 범위를 넓히지 않는다. 개인정보 마스킹은 현재 제품 범위에서 제외한다.
- Phase 2.3 NSIS 패키징, unpacked/privacy/checksum 검증, 실제 설치와 재설치를 완료했다.
- 실제 설치 앱에서 Sample A~K, full cache, 직접 입력, Home/End, 휠, 파일 전환과 RGBA rollback을 검증했다.
- 실제 Explorer drag/drop, Windows 제거 등록 확인과 사용자 파일럿 피드백은 남아 있다.
- 설치 UI 세부 항목과 동일 버전 덮어쓰기는 추후 통합 QA로 이월했으며 Phase 2.3 완료를 막지 않는다.

## 단계별 개발 규칙

- 기능은 작은 단계로 나누고 각 단계마다 자동 검사와 실제 샘플 검증 기준을 둔다.
- 문서와 구현이 달라지면 같은 작업에서 관련 문서를 함께 갱신한다.
- 실제 샘플은 Git에 포함하지 않고 파일명·전체 경로·환자 식별정보를 로그와 문서에 남기지 않는다.
- 측정하지 않은 성능을 주장하지 않는다.
- `frameIndex`와 PTS를 혼동하지 않고 FPS만으로 프레임 위치를 계산하지 않는다.
- 원본 MP4를 수정하거나 재인코딩하지 않는다.
- `src/domain`에는 플랫폼·UI·Electron IPC·파일 시스템 의존성을 넣지 않는다.
- 프레임 분석, 프로젝트 schema, 주석 좌표, 표시 보정 preset처럼 모바일에서도 동일해야 하는 규칙은 공통 코어로 유지한다.

## Troubleshooting

- Codex, Browser, Windows, 권한, 샌드박스 또는 실행 환경 문제가 의심되면 먼저 현재 환경의 공용 troubleshooting 문서를 확인한다.
- 여러 프로젝트에서 재발할 수 있는 새 환경 문제를 해결했다면 공용 문서에 증상, 원인, 해결 절차와 검증 방법을 기록한다.
- CT Cine Reviewer에서만 발생하는 영상 처리, 렌더링, 상태, 캐시 또는 배포 문제는 `docs/troubleshooting.md`에 기록한다.
- 같은 해결 절차를 두 문서에 중복 작성하지 않는다. 프로젝트 문제에 공용 원인이 섞여 있으면 공용 문서를 참조하고 프로젝트별 조건만 기록한다.
- 가설과 검증된 해결책을 구분하며, 환자 식별정보나 원본 영상의 민감한 파일명·경로를 troubleshooting 문서에 남기지 않는다.

## 문서 관리

- 프로젝트 문서는 `docs/docs_hub.md`에 인덱싱한다.
- 새 문서 파일을 추가하거나 문서 위치를 바꾸면 `docs/docs_hub.md`도 함께 갱신한다.
