# Phase 3A View Transform Foundation

## 결론

Phase 2.3 decoder/cache/색 경로를 변경하지 않고 Zoom, Pan, Fit과 Electron window fullscreen의 공통 좌표 기반을 추가했다.

- 제품 버전: `0.3.0-phase3a`
- 좌표 모델: 원본 image pixel 좌표와 image-space center
- Zoom: Fit 기준 1×~10×
- 확대 합성: linear
- 제품 UI·좌표·fallback QA: 통과
- 10분 반복 조작: 통과
- NSIS·실제 설치 앱: 통과(Explorer cross-window drop만 별도 실기 확인 필요)

## v0.5.2 사용자 승인 확대율 표시 변경

Phase 3A의 image pixel center 좌표식과 내부 `zoom = 실제 scale / fitScale` 의미는 유지한다. 다만 v0.5.2 UI에서는 사용자 승인에 따라 다음 동작이 Phase 3A의 과거 `Fit보다 작은 축소 금지` 정책보다 우선한다.

- 사용자에게 보이는 `%`는 Fit 대비가 아니라 원본 픽셀 대비 `effectiveScale × 100`이다.
- 새 영상은 contain 화면 맞춤으로 시작하지만 확대율 셀에는 계산된 현재 `%`를 표시한다.
- 선택 메뉴는 `화면 맞춤, 50%, 75%, 100%, 125%, 150%, 175%, 200%`를 제공한다.
- 버튼·키보드·Ctrl+wheel의 고정 step은 현재 원본 픽셀 배율에서 10%p다.
- 수동 배율은 창 크기가 바뀌어도 실제 scale을 유지하고, 화면 맞춤 상태는 새 viewport의 contain Fit을 다시 계산한다.
- 기존 Fit 대비 1~10배 범위는 보존하되 50~200% 선택 항목이 항상 도달 가능하도록 내부 clamp 범위를 필요한 만큼 확장한다.

Video Level/Width, Gamma, preset, Sharp, 자동 재생, 주석, 이미지 저장과 DICOM/PACS는 시작하지 않았다.

## 목적과 구조

`src/domain/viewTransform.ts`가 좌표와 transform의 의미를 소유한다. React·DOM·Canvas·WebGL·Electron 타입은 이 파일에 없다. `src/domain/viewInteraction.ts`는 wheel/shortcut/pointer lifecycle 의미를, `src/application/fullscreenPolicy.ts`는 fullscreen 상태 전이를 순수 함수로 유지한다.

Electron/React 계층은 입력과 실제 창·canvas를 연결할 뿐 decoder, cache, FFmpeg와 transform을 결합하지 않는다.

## View transform 모델

| 필드 | 의미 |
| --- | --- |
| `imageSize` | 원본 frame pixel 크기 |
| `viewportSize` | viewer surface의 CSS pixel 크기 |
| `center` | viewport 중심에 놓이는 image pixel 좌표 |
| `zoom` | contain Fit 대비 사용자 배율 |
| `minZoom` / `maxZoom` | 1 / 10 |
| `fitMode` | `contain` |
| `revision` | transform 변경 횟수 |

`fitScale = min(viewportWidth/imageWidth, viewportHeight/imageHeight)`이고 실제 표시 scale은 `fitScale × zoom`이다.

## 좌표계와 정확성

- image → viewport: `(imagePoint - center) × scale + viewportCenter`
- viewport → image: 위 식의 역변환
- 주석은 향후 image pixel 좌표 또는 이를 image size로 나눈 normalized 좌표를 저장할 수 있다.
- frame 교체는 transform을 변경하지 않는다.
- 새 file session은 새 image size의 중앙 Fit으로 초기화한다.

단위 테스트에서 image→viewport→image 오차는 `1e-9` 이하였고, viewport 중심 기준 100회 zoom in/out 뒤 center drift는 0이었다.

## Zoom 정책

- Ctrl+wheel과 touchpad의 Ctrl+wheel 입력은 연속 exponential curve를 사용한다.
- event당 wheel delta를 ±240 CSS pixel로 제한해 폭주를 막는다.
- 버튼, `+`/`-`, `0`, Fit과 더블클릭을 지원한다.
- 일반 wheel은 기존 ±1 frame 이동을 유지한다.
- text input 편집 중 `+`/`-`/`0`/`F`는 동작하지 않는다.

Fit보다 작은 축소는 영상이 검은 영역 안에서 불필요하게 작아지는 사용성을 피하기 위해 허용하지 않는다. 이동 가능한 축은 cursor anchor를 유지한다. 확대 뒤에도 영상이 viewport보다 작은 축은 중앙 정렬 clamp가 우선하므로 해당 축 cursor anchor 이동은 정책상 허용한다.

실제 세로 영상의 이동 가능 축 cursor anchor 오차는 0.218 image pixel이었다.

## Pan과 clamp

- Navigate 기본 mode에서 좌클릭 drag를 사용한다.
- pointer capture, pointer up/cancel/lost capture와 Esc 종료를 처리한다.
- drag 중 일반 wheel frame 이동은 무시하고 Ctrl+wheel zoom은 허용한다.
- 표시 영상이 viewport보다 작은 축은 중앙 정렬한다.
- 큰 축은 viewport가 영상 밖으로 벗어나지 않는 범위로 image center를 clamp한다.
- file drag/drop은 별도 drag event 흐름을 유지한다.

## Fit과 resize

Fit은 `zoom=1`, image center로 복귀한다. ResizeObserver가 viewport 변경을 감지하고 기존 image center와 zoom을 유지한 뒤 새 경계로 clamp한다. 전체화면 진입·종료도 같은 resize 경로를 사용한다.

## Fullscreen

Windows 설치 앱에는 DOM fullscreen 대신 Electron `BrowserWindow.setFullScreen`을 사용한다. 앱 창 전체가 fullscreen 대상이다.

- preload는 get/set/toggle boolean과 changed event만 노출한다.
- main은 IPC sender의 `webContents`가 속한 BrowserWindow만 조작한다.
- `F`, 버튼과 Esc 종료를 지원한다.
- renderer에 Electron 객체나 임의 window 제어 API를 노출하지 않는다.

## WebGL2와 RGBA fallback

YUV→RGB shader, 색상 상수와 plane texture는 변경하지 않았다. 원본 크기 offscreen WebGL 결과를 main canvas에 그린 뒤 플랫폼 UI 합성에서 view placement를 적용한다. RGBA ImageData도 같은 main canvas와 transform을 사용한다.

- transform 변경은 decode·frame payload 복사·texture upload를 유발하지 않는다.
- CSS 합성 filtering은 linear(`image-rendering: auto`)다.
- WebGL context loss 뒤 RGBA로 바뀌어도 zoom/center가 유지된다.
- Phase 3B display parameter는 view transform과 독립적으로 renderer에 추가할 수 있다.

## 입력 조작

| 입력 | 동작 |
| --- | --- |
| wheel | ±1 frame |
| Ctrl+wheel | cursor anchored zoom |
| `+` / `-` | 1.25× / 0.8× |
| `0`, Fit, double-click | Fit |
| 좌클릭 drag | Pan |
| Left/Right, Shift+Left/Right | ±1 / ±5 frame |
| Home/End, 직접 입력 | 기존 frame 이동 |
| `F`, Fullscreen 버튼 | fullscreen toggle |
| Esc | Pan 종료 → fullscreen 종료 → 기존 cancel 순서 |

## 성능과 회귀

- transform draw: 3.3ms, smoke p95 2.0ms
- cursor anchor error: 0.218 image pixel
- resize center error: 0
- WebGL→RGBA fallback transform 차이: 0
- 순·역 30초 hold loading 0, seek 재디코딩 0
- 최종 Phase 2.3 첫 Canvas 198.7ms, cache/decoder 구조 변경 0
- 기존 11-sample 색 QA candidate 경로 통과(mean 0.407, p99 1, max 2, draw p95 0.1ms)

## 내구 결과

- 실행 시간: 10.04분
- file session/조작 순환: 451회
- 오류: 0
- 최대 seek 재디코딩: 0
- transform draw p95: 1.8ms
- 후반 browser RSS 기울기: -0.31MiB/분
- 종료 후 Electron/FFmpeg/ffprobe 잔존: 0

## 설치본 QA

- 설치 파일: `artifacts/CT-Cine-Reviewer-Setup-0.3.0-phase3a.exe`
- SHA-256: `1f88ba45492b08040841ab0d1116fd998219f2873163b52af42d6a7ebc91276a`
- silent install exit code 0, 설치 앱 product version `0.3.0.0`
- 기본 WebGL2 경로: 대표 영상 열기, Zoom/Pan/Fit, frame 이동·직접 입력·Home/End 후 transform 유지, fullscreen 진입·종료와 창 resize 통과
- 파일 전환: 125% 상태에서 다른 영상을 열었을 때 `Zoom 100%`, image center, revision 0으로 초기화됨
- `CCR_FORCE_RGBA=1`: 72MiB segment cache 경로에서 Zoom 125% → Pan → Fit 100%와 동일 좌표 의미 확인
- context loss fallback과 순·역 30초 hold는 제품 Electron UI 자동화에서 transform 유지, loading 0, seek 재디코딩 0으로 통과
- 설치 앱 종료 뒤 CCR/Electron/FFmpeg/ffprobe 관련 프로세스 0, 관련 TCP 연결 0
- 원본 11개 aggregate SHA-256은 설치 전후 `790fd7baccf41c1f0e72fac6c126067704cb961db400b61eecc7b0bf1f4e9552`로 동일
- 앱 temp/AppData의 RGBA/I420/YUV/raw/frame image 잔존 0

Explorer cross-window drag는 검증 중 다른 활성 창이 drop 대상 위에 개입해 이번 자동 조작에서 확정하지 못했다. 앱의 기존 drop handler는 변경하지 않았고 새 session Fit 초기화는 file-open UI와 제품 UI 자동화에서 확인했다. 실제 Explorer drop 1회는 사용자 파일럿 체크리스트에 유지한다.

## 개인정보와 보안

- 원본과 frame payload는 기존 읽기 전용·RAM 경로를 유지한다.
- transform은 숫자 상태만 보유하며 파일명·경로·frame bitmap을 저장하지 않는다.
- 실제 sample과 synthetic temp는 package/Git에 포함하지 않는다.
- nodeIntegration 비활성화, contextIsolation과 sandbox를 유지한다.

## 알려진 한계

- pixel-preserving nearest 확대는 이번 단계에 포함하지 않았다.
- 작은 축 중앙 정렬이 cursor anchor보다 우선하는 경우가 있다.
- touch gesture는 Windows가 Ctrl+wheel로 전달하는 경로만 검증한다.
- 영상 전용 floating window와 모바일 UI는 구현하지 않았다.
- 실제 Explorer cross-window MP4 drop 1회는 파일럿에서 확인해야 한다.

## Phase 3B 진입 조건

- 최종 설치 앱 Zoom/Pan/Fit/fullscreen과 10분 내구 검사 통과
- 실제 사용자 파일럿에서 좌표·입력 충돌에 중대한 문제 없음
- Video Level/Width, Gamma, Inverse, preset, Sharp 범위를 사용자 별도 승인

조건 충족 전 Phase 3B 표시 보정을 시작하지 않는다.
