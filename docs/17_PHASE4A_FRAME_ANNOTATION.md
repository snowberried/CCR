# Phase 4A Frame Annotation MVP + Annotated Timeline

## 결론

기존 decoder/cache/FFmpeg와 WebGL/RGBA 픽셀 경로를 변경하지 않고 프레임별 주석과 annotated timeline을 통합했다.

- 제품 버전: `0.4.0`
- 주석 종류: Arrow, 한 줄 Text, Ellipse, Rectangle
- geometry: 원본 image pixel 좌표
- 수명: 현재 파일 세션 RAM, 새 파일에서 전체 초기화
- 렌더링: 영상 canvas와 분리된 SVG overlay
- 전체 테스트: 78/78 통과

## 모델과 좌표

`src/domain/annotation.ts`가 플랫폼 중립 주석, style, 경계 clamp와 전역 transaction history를 소유한다. Arrow는 두 끝점, Text는 anchor와 문자열, Ellipse/Rectangle은 image pixel bounds를 저장한다. 생성·이동·resize는 `(0,0)..(imageWidth,imageHeight)` 안으로 제한한다.

선 굵기와 글자 크기는 logical display unit이며 데스크톱에서는 CSS px와 1:1이다. handle은 8×8px, hit 영역은 최소 14px로 줌과 무관하다. viewport 좌표는 Phase 3A `imageToViewport`/`viewportToImage`로만 변환하며 새로운 pan/zoom 수학을 만들지 않았다.

이 정책은 `docs/04_DATA_AND_STATE_MODEL.md`의 Phase 4 이전 normalized 초안을 대체한다. 프로젝트 저장 schema는 이번 단계에 없다.

## 도구와 입력

- persistent tool: Pan, Zoom, Select, Arrow, Text, Ellipse, Rectangle
- command: Fit, 원본 픽셀 100%; persistent tool 유지
- 좌클릭: 현재 persistent tool만 소유
- 우클릭: 모든 tool과 SVG overlay 위에서 기존 Level/Width
- Ctrl+wheel: 모든 tool에서 고정 10%p zoom
- Text: 한글 composition 중 Enter 무시, 조합 종료 후 Enter 확정, Escape 취소, double-click 재편집
- Delete/Backspace: 선택 주석 삭제
- Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z: 세션 전체 undo/redo

한 drag는 pointerup에서 transaction 하나로 확정한다. pointercancel, lost capture, window blur와 Escape는 draft/preview를 복원하고 stuck gesture를 남기지 않는다. 다른 프레임의 undo/redo는 해당 frame으로 이동하고 가능한 주석을 선택한다.

## Annotated Timeline

하단 track은 현재 progress와 playhead를 표시하고 annotation state에서 marker를 파생한다. frame mapping은 첫·중간·마지막을 포함해 `round(ratio × (frameCount - 1))`이다. 같은 frame의 여러 주석은 하나의 count marker가 되며, 인접 frame이 같은 실제 픽셀 열에 놓이면 bucket 하나로 집계한다. marker DOM 수는 track pixel 폭을 넘지 않는다.

scrub은 기존 deferred `goToFrame`과 latest-intent pump를 사용한다. marker click은 가장 가까운 annotated frame으로 정확히 이동하고 생성 순서가 가장 빠른 주석을 선택한다.

## 검증 결과

- WebGL/RGBA 동일 image geometry, View와 Display 상태: 일치
- 한글 IME composition 보호와 Text 재편집: 통과
- handle 화면 크기: 양 경로 8×8px
- 주석·style·tool 조작 구간 seek: `0 → 0`
- WebGL texture upload: `3 → 3`; RGBA: `0 → 0`
- Ctrl+wheel: `100% → 110%`, tool 유지
- 새 파일: annotation 0, history 0/0, marker 0, Pan, Fit, Original
- 720×600: `scrollWidth 720`, timeline 700px, tool 9개 표시
- 실제 샘플 시각 QA: Arrow 화살촉, Rectangle, 한글 Text와 선택 윤곽 정렬 및 compact UI 통과
- Phase 3A cursor anchor 오차: 0.0618 image pixel
- Phase 3B Original equality와 WebGL/RGBA display parity: 통과
- Phase 2.3 순방향 30.011초: loading 0, seek 0
- Phase 2.3 역방향 30.003초: loading 0, seek 0
- 프레임 탐색 중 View/Display 유지: 통과

## 범위 밖

프로젝트/주석 파일 저장, image export/burn-in, mask, crop, 자동 재생, DICOM/PACS, tracking/interpolation, AI/OCR/cloud와 decoder/cache 재설계는 구현하지 않았다.

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.4.0.exe`
- 크기: 143,244,089 bytes (136.61 MiB)
- SHA-256: `182ade14306844a01336d9b7492a35f48942fc8c5ed573790aed16e4013ebdbe`
- unpacked 91개 파일, privacy inspection과 verify-only 통과
