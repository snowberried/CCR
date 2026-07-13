# CT Cine Reviewer

**CCR — CT 동영상 프레임 검토 및 주석 도구**

- 프로젝트 식별자: `ct-cine-reviewer`

카카오톡 등으로 전달받은 CT cine 동영상을 Windows PC에서 프레임 단위로 검토하고, 화면 표시를 보정하며, 주석을 붙여 공유하기 위한 완전 로컬 보조 뷰어 프로젝트이다.

> 이 프로젝트는 의료기기나 공식 진단·PACS 프로그램이 아니며, 원본 PACS/DICOM 판독을 대체하지 않는다.

## 현재 단계

Phase 2.3 I420 제품 cache부터 Phase 4B-1 PNG/clipboard까지의 기준선 위에 Phase 5 **비교 뷰**를 통합했다. View A와 View B는 항상 같은 영상의 동일한 현재 프레임을 공유하고, Zoom/Pan과 Video Display는 pane별로 독립적이다. linked crosshair는 DICOM registration이 아니라 같은 image pixel 좌표를 두 transform 사이에서 대응시킨다. 상세 내용은 [Phase 5](docs/19_PHASE5_LINKED_DUAL_VIEW.md)에서 확인한다.

- 실제 로컬 샘플은 Git에 포함하지 않으며 컴퓨터별 `local-samples/`에서 확인함
- Electron/React/TypeScript 최소 scaffold 작성됨
- 데스크톱·모바일 공용 영상 분석 모델, 프레임 검증 규칙과 `VideoProbeProvider` 포트 작성됨
- 고정 BtbN LGPL shared FFmpeg/ffprobe 취득·checksum·라이선스 기록 절차 작성됨
- `FfmpegCliProbeProvider` 실제 실행, timeout·취소·출력 제한과 비식별 Sample A 분석 완료
- 실제 비식별 샘플 세 개에서 프레임·PTS·픽셀 fingerprint 정확성 검증 완료
- FFmpeg stdout RGBA rawvideo와 61프레임 RAM 구간 캐시를 Phase 2 기본안으로 결정
- 전체 raw RAM, 전체 PNG 디스크와 181프레임 RAM 캐시는 실측 결과 기본안에서 제외
- 파일 선택, `Ctrl+O`, MP4 drag/drop과 세션 전환 구현
- Canvas 원본 비율 표시와 UI 1 기반 프레임 탐색 구현
- 72MiB 예산 기반 최대 61프레임 방향성 RAM cache 구현
- Phase 2.2 격리 경로에서 전체 I420 RAM cache, 제한 block LRU와 RGBA fallback 검증
- 실제 11개 제품 경로에서 첫 I420 p95 131.8ms, 전체 cache p95 1.321초, cache 탐색 p95 0.327ms
- WebGL2 BT.601 limited 색 정확성 통과와 실제 Electron 30초 press-and-hold 로딩 0회 검증
- Phase 2.3 제품 기본 mode는 I420 full/LRU, 안전하지 않은 색·layout은 RGBA fallback
- `CCR_FORCE_RGBA=1`에서 기존 Phase 2.1 RGBA 경로로 즉시 rollback 가능
- Phase 2.3 설치본에서 실제 A~K full cache, 순·역 30초 hold, 직접 입력·Home/End·휠과 종료 정리 검증 완료
- Phase 3A Fit 대비 1~10배 Zoom, cursor anchor, pointer Pan, Electron fullscreen과 renderer 공통 transform 구현
- Phase 3B Video Level/Width, Gamma, Inverse, luminance Sharp, candidate preset과 Original hold compare 구현
- 고정 10%p Ctrl+wheel과 Pan/Zoom/Fit/100% 세로 도구 막대 구현
- 프레임별 Arrow/Text/Ellipse/Rectangle 주석, 선택·이동·resize·삭제와 전역 Undo/Redo 구현
- 픽셀 열 집계 annotated timeline과 WebGL/RGBA 공통 SVG overlay 구현
- 확정 Video Display와 선택적 주석을 포함한 전체 프레임/현재 보기 PNG 저장·clipboard 복사 구현
- 동일 frame/pixels를 공유하는 View A/B 비교 뷰, pane별 독립 View/Display/tool과 image-space linked crosshair 구현
- Sample A/B/C와 합성 HEVC·1080p/60fps·VFR·B-frame·회전 metadata QA 완료
- 실행: `npm start`
- Windows 패키지 생성: `npm run package:win`
- 세부 결과는 [Phase 2 Minimum Viewer](docs/10_PHASE2_MINIMUM_VIEWER.md)에서 확인한다.

## v0.1 범위

- MP4 중심의 동영상 파일 열기와 정확한 프레임 인덱스 탐색
- 확대·축소, Pan, 화면 맞춤과 동일 프레임 비교 뷰
- Video Level/Width, Gamma, Inverse, Sharp 등 화면 픽셀 기반 표시 보정
- Lung-like 등 Video Display Preset
- 화살표·텍스트·기본 도형 주석
- 원본·보정·주석 포함 프레임을 PNG로 저장·복사
- 인터넷, 로그인, 텔레메트리 없이 완전 로컬 동작

## v0.1 제외 범위

- DICOM 폴더/ZIP 및 실제 HU 기반 Window Center/Width
- HU·거리·면적 측정
- PACS 또는 DICOMweb 연동
- AI 판독, 클라우드 동기화, 사용자 계정, 자동 업데이트
- 서로 다른 프레임·영상 비교, registration, 개인정보 마스킹, 프로젝트 저장, JPEG/clip/batch export와 자동 재생

## 문서 안내

전체 기획 문서는 [Docs Hub](docs/docs_hub.md)에서 찾을 수 있다. 아직 확정되지 않은 선택은 [Decisions and Open Questions](docs/06_DECISIONS_AND_OPEN_QUESTIONS.md)에 모아 둔다.
