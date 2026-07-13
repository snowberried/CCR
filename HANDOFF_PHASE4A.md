# CT Cine Reviewer Phase 4A Handoff

## 결론

버전 `0.4.0`에 원본 image pixel 좌표의 프레임별 Arrow/Text/Ellipse/Rectangle, Select 편집, 전역 Undo/Redo와 annotated timeline을 통합했다.

- 세션 RAM 전용이며 새 파일에서 주석·history·marker가 초기화된다.
- SVG overlay는 WebGL/RGBA와 Video Display 픽셀 처리에서 분리된다.
- Pan/Zoom/Level·Width/Ctrl+wheel 입력 정책을 보존했다.
- 78개 테스트와 Phase 2.3/3A/3B 회귀 QA를 통과했다.
- 상세 결과는 `docs/17_PHASE4A_FRAME_ANNOTATION.md`를 확인한다.

## 다음 작업

1. 실제 사용자가 주석 도구와 annotated timeline 조작감을 평가한다.
2. 별도 승인 뒤 프로젝트 저장 schema, mask 또는 이미지 내보내기 중 다음 범위를 결정한다.
3. Phase 3B candidate preset 사용자 피드백은 별도 항목으로 유지한다.

## 제한

프로젝트 저장, mask, 이미지 저장, 자동 재생, DICOM/PACS, AI/OCR/cloud는 시작하지 않는다.

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.4.0.exe`
- 크기: 143,244,089 bytes (136.61 MiB)
- SHA-256: `182ade14306844a01336d9b7492a35f48942fc8c5ed573790aed16e4013ebdbe`
- unpacked 91개 파일, privacy inspection 통과
