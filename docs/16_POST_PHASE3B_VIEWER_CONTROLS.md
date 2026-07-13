# Phase 3B 후속 Viewer Controls

## 결론

Phase 2.3 decoder/cache와 Phase 3A View Transform, Phase 3B Video Display를 변경하지 않고 PACS식 입력 도구와 고정 zoom step을 추가했다.

- Ctrl+wheel, 상단 `+/-`, 키보드 `+/-`: Fit 대비 정확히 10 percentage point씩 이동
- Pan/Zoom: 왼쪽 세로 막대의 persistent tool, 새 file session은 Pan으로 초기화
- Fit/100%: persistent tool을 바꾸지 않는 command
- 100%: 원본 픽셀 1:1이며 기존 Fit 대비 1~10배 범위에서 clamp
- 우클릭: tool과 무관하게 기존 MP4 Level/Width drag
- active pointer: Pan, Zoom, Level/Width 중 하나만 소유

주석, preset 재튜닝, 자동 재생, 저장, Crop, 마스킹, DICOM/PACS는 추가하지 않았다.

## Zoom 정책

wheel step은 `zoom + direction × 0.10`으로 계산하고 부동소수점 누적 오차를 정리한 뒤 기존 `zoomAtViewportPoint`에 전달한다. 현재 값의 1.1배는 사용하지 않는다. 작은 trackpad delta는 50 pixel 상당의 임계값까지 누적하고 큰 wheel event는 event당 한 step으로 제한한다.

Zoom tool은 drag 시작 zoom과 viewport anchor를 저장하고 다음 식을 사용한다.

`nextZoom = startZoom × exp(-verticalDelta × 0.003)`

위 drag는 확대, 아래 drag는 축소이며 horizontal delta는 계산에서 제외한다. 매 이동은 기존 image pixel center transform과 clamp를 그대로 사용한다.

100% command는 `targetZoom = 1 / fitScale`로 원본 픽셀 1:1을 계산한다. viewport 중심을 anchor로 사용해 현재 image center를 보존하며, 목표가 기존 범위를 벗어나면 1~10배로 clamp한다. Fit은 기존처럼 zoom 1과 image center로 복귀한다.

## 입력 소유권과 UI

React 계층의 active gesture는 `pan | zoom | display` 단일 union이다. 좌클릭은 현재 Pan/Zoom tool에, 우클릭은 항상 display gesture에 배정한다. pointer capture, pointer up/cancel, lost capture, window pointer up/blur와 Escape가 같은 종료 함수를 사용한다.

도구 막대는 `40px + minmax(0, 1fr)` 비중첩 grid이다. Pan/Zoom은 `aria-pressed`, tooltip과 접근 가능한 이름을 제공하며 Fit/100%는 선택 상태로 남지 않는다. 720×600 시각 검사에서 rail 40px, viewport 660px, horizontal overflow 0을 확인했다.

## 검증 결과

- unit: 72/72 통과
- wheel: `1.0 → 1.1 → 1.2 → 1.1`, multiplicative 계산 아님
- cursor anchor: 실제 Electron 오차 0.076 image pixel
- drift: 중심 anchor 100회 확대/축소 뒤 zoom 1, center drift 0
- Zoom drag: 1.1에서 위 drag 1.4848, 반대 drag 1.1 복귀
- Pan: 실제 1:1 상태에서 center `203,360 → 203,310`
- Fit/100% 뒤 Zoom tool 유지, 새 file session은 Pan·Fit으로 초기화
- WebGL2 tool 입력: texture upload `3 → 3`, seek `0 → 0`
- `CCR_FORCE_RGBA=1`: texture upload `0 → 0`, seek `0 → 0`, 같은 transform 결과
- Level/Width, Gamma, Sharp, Inverse, Original compare와 WebGL/RGBA parity 회귀 통과
- Phase 2.3 순·역 30초 탐색: loading 0, seek 0, View/Display 유지
- product build 통과

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.3.2-controls.exe`
- 크기: 143,236,989 bytes (136.60 MiB)
- SHA-256: `b10d8176c252bb4e138d5ea25dd06e8a995ddcfd3fedf908eb27d590d6d800d9`
- unpacked 91개 파일과 privacy inspection 통과
