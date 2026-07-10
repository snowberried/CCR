# CT Cine Reviewer

**CCR — CT 동영상 프레임 검토 및 주석 도구**

- 프로젝트 식별자: `ct-cine-reviewer`

카카오톡 등으로 전달받은 CT cine 동영상을 Windows PC에서 프레임 단위로 검토하고, 화면 표시를 보정하며, 주석을 붙여 공유하기 위한 완전 로컬 보조 뷰어 프로젝트이다.

> 이 프로젝트는 의료기기나 공식 진단·PACS 프로그램이 아니며, 원본 PACS/DICOM 판독을 대체하지 않는다.

## 현재 단계

Phase 0 기획은 완료됐으며 **Phase 1: 프레임 탐색 기술 스파이크 인계 상태**이다.

- 올바른 작업공간: `C:\AI_Codex\workspace\CCR`
- 실제 로컬 샘플 1개 준비됨
- Electron/React/TypeScript scaffold는 아직 없음
- FFmpeg/ffprobe는 아직 준비되지 않았으며 취득 방식에 대한 사용자 승인이 필요함
- 다음 작업은 [Phase 1 Handoff](HANDOFF_PHASE1.md)에서 이어간다.

## v0.1 범위

- MP4 중심의 동영상 파일 열기와 정확한 프레임 인덱스 탐색
- 재생·정지, 확대·축소, Pan, 화면 맞춤
- Video Level/Width, Gamma, Inverse, Sharp 등 화면 픽셀 기반 표시 보정
- Lung-like 등 Video Display Preset
- 화살표·텍스트·기본 도형·개인정보 마스킹 주석
- 원본·보정·주석 포함 프레임을 PNG/JPEG로 저장
- 원본을 수정하지 않는 별도 JSON 계열 프로젝트 저장
- 인터넷, 로그인, 텔레메트리 없이 완전 로컬 동작

## v0.1 제외 범위

- DICOM 폴더/ZIP 및 실제 HU 기반 Window Center/Width
- HU·거리·면적 측정
- PACS 또는 DICOMweb 연동
- AI 판독, 클라우드 동기화, 사용자 계정, 자동 업데이트

## 문서 안내

전체 기획 문서는 [Docs Hub](docs/docs_hub.md)에서 찾을 수 있다. 아직 확정되지 않은 선택은 [Decisions and Open Questions](docs/06_DECISIONS_AND_OPEN_QUESTIONS.md)에 모아 둔다.
