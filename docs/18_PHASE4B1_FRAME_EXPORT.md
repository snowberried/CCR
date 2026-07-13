# Phase 4B-1 Deterministic Frame Export & Clipboard

## 결론

기존 decoder/cache/FFmpeg와 프레임 탐색 흐름을 변경하지 않고, 실제로 표시가 확정된 한 프레임을 PNG로 저장하거나 OS 클립보드에 복사하는 로컬 내보내기를 통합했다.

- 제품 버전: `0.4.1`
- 모드: 전체 프레임 / 현재 보기
- 기본값: 전체 프레임, 현재 프레임 주석 포함
- 기준 커밋: Phase 4A `cf30651`

## 출력 의미

### 전체 프레임

- 출력 크기는 원본 영상의 `width × height`와 정확히 같다.
- 확정된 Video Display를 적용한다. 일시적인 Original hold 비교 상태는 저장하지 않는다.
- Zoom, Pan, 검은 letterbox와 앱 UI는 포함하지 않는다.
- 주석은 원본 image pixel 좌표를 1:1로 합성한다.

### 현재 보기

- 영상 viewport만 출력하며 앱 topbar, 도구 막대, inspector와 timeline은 제외한다.
- 현재 View Transform의 Zoom/Pan/Fit과 검은 letterbox를 그대로 합성한다.
- backing pixel은 `round(viewport CSS size × devicePixelRatio)`이다. 반올림 뒤 X/Y 유효 배율을 각각 사용해 좌표 drift를 피한다.
- 주석 geometry는 기존 `imageToViewport`를 거치고 선 굵기·글자 크기는 CSS logical pixel로 유지한 뒤 DPR만 적용한다.

두 모드 모두 선택 윤곽, resize handle, hit 영역, hover와 inline text editor를 출력하지 않는다.

## 프레임 일관성

내보내기 버튼을 누른 동기 구간에서 다음을 먼저 검사하고 복사한다.

1. `lastFrameRef`가 accepted pixels와 descriptor를 가진다.
2. descriptor의 `frameIndex`가 `displayedFrameRef`와 같다.
3. viewer status가 ready이며 frame pump가 실행 중이지 않다.
4. frame index/fingerprint/크기, 확정 display state, View Transform과 같은 프레임의 주석을 snapshot한다.
5. WebGL 또는 RGBA 표시 결과를 분리된 RAM canvas에 복사한 뒤 PNG encode와 Save dialog를 시작한다.

따라서 encode 또는 Save dialog 중 프레임 이동·파일 열기가 발생해도 requested/desired frame이 아니라 버튼 시점의 실제 displayed frame을 출력한다. QA에서는 0번 프레임 snapshot 직후 1번 프레임으로 이동해도 export identity가 0으로 유지됐다.

## 표시와 주석 합성

- WebGL2: 기존 I420 texture에 `redraw(committedDisplay)`만 실행하고 detached 2D canvas로 복사한다. texture upload는 하지 않는다.
- RGBA fallback: 기존 `applyVideoDisplayToRgba(..., committedDisplay, false)`를 그대로 사용한다.
- 주석: SVG DOM이나 화면 캡처를 사용하지 않고 Arrow/Text/Ellipse/Rectangle만 Canvas에 다시 그린다.
- 합성 순서: 검은 배경(현재 보기만) → Video Display가 적용된 frame → 선택적인 확정 주석.
- OS/window screenshot, FFmpeg 실행, frame seek, decoder restart와 cache rebuild는 사용하지 않는다.

## Electron 경계와 개인정보

- renderer는 PNG를 RAM의 `Uint8Array`로 encode한다.
- Save IPC는 PNG signature와 512MiB 상한을 검사하고 Electron Save dialog가 반환한 최종 경로에만 직접 쓴다.
- 새 파일 쓰기가 실패하면 불완전 파일 제거를 시도한다. 기존 파일은 Windows overwrite confirmation 뒤에만 쓴다.
- Clipboard IPC는 PNG를 1× bitmap representation으로 만든 뒤 `clipboard.writeImage`를 사용하며 임시 파일을 만들지 않는다. Windows 150% 배율처럼 외부 앱이 DIB를 logical pixel로 축소하는 경우에는 현재 창 monitor의 scale factor만큼 clipboard bitmap만 보상한다. 파일 PNG와 export output dimension은 바꾸지 않는다.
- default filename은 Unicode를 유지하고 Windows 금지 문자만 치환한 `source_fNNNN.png`이다. 전체 source path는 renderer UI, QA 결과와 로그에 노출하지 않는다.
- 테스트용 저장 파일도 QA 종료 시 제거하며 제품 동작에는 preview, intermediate PNG 또는 자동 저장이 없다.

## UI

오른쪽 inspector에 `내보내기` 섹션을 추가했다.

- 전체 프레임 / 현재 보기 radio
- 현재 프레임 주석 포함 checkbox
- PNG 저장 / 복사 button
- 처리 중 중복 실행 방지와 간결한 성공·실패 상태
- Save dialog cancel은 기존 결과 문구와 viewer 상태를 바꾸지 않는다.
- 클립보드 성공 문구는 앱 종료 뒤에도 OS clipboard에 이미지가 남을 수 있음을 알린다.

최소 창 크기를 720×600으로 조정했다. 720×600 QA에서 inspector는 표시되고 root `scrollWidth = clientWidth = 720`이었다.

## 검증 결과

- 전체 단위 테스트: 82/82 통과
- 제품 build: TypeScript/Electron/Vite 통과
- 실제 Electron WebGL2와 `CCR_FORCE_RGBA=1`: 전체 `406×720`, 현재 보기 DPR 1.5에서 `1191×797` 일치
- 주석 포함/제외 pixel 결과 차이 확인, 같은 snapshot 반복 결과 동일
- Save PNG 재개방·decode 성공, clipboard는 그림판에서 같은 composition과 `406×720` 크기로 paste 성공
- cancel 뒤 상태 문구 유지
- export texture upload delta: WebGL2 `0`, RGBA `0`
- export 구간 seek count: 양 경로 `0 → 0`
- save/copy 전후 View/Display/annotation 상태 동일
- 실제 frame을 다음 frame으로 바꾼 동안 snapshot frame/fingerprint 유지
- Windows 150% 배율 그림판 paste: object size `406×720`, Arrow/Text/Ellipse/Rectangle과 한글 Text 표시 확인
- QA가 만든 PNG는 종료 시 삭제되어 잔여 파일 없음

## 제외 범위

JPEG, 동영상 clip/GIF, batch, crop, mask/blur, burn-in 프로젝트 저장, autoplay, DICOM/PACS, tracking/interpolation, AI/OCR/cloud, decoder/cache 재설계와 code signing은 구현하지 않았다. 기존 파일 overwrite 도중 저장 장치 오류가 발생하면 원래 파일을 완전히 복구하는 atomic replace는 제공하지 않는다. 이는 intermediate file을 남기지 않는 이번 승인 정책과의 trade-off다. Windows DPI가 100%가 아니면 clipboard DIB의 외부 pixel 크기를 보존하기 위한 보상 resize가 한 번 발생할 수 있으므로 완전한 lossless pixel 전달이 필요하면 PNG 저장을 사용한다.

## 설치본

- `CT-Cine-Reviewer-Setup-0.4.1.exe`
- 143,247,637 bytes (136.61 MiB)
- SHA-256 `f246de87ceee25572f2590e6733915a1b11c88ec703c4c8f10e74d34ab9902b3`
- unpacked 91개 파일, package privacy inspection 통과
