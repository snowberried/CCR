# v0.5.2 Modern Dark Professional

## 결론

Phase 5 기능 기준선을 변경하지 않고 CCR 데스크톱 UI를 Modern Dark Professional 시각 체계로 교체했다. decoder/cache/navigation, View Transform, pane별 Display, shared annotation, linked crosshair와 PNG/clipboard export의 의미는 그대로다. 자동 재생·재생/정지·오디오·볼륨은 추가하지 않았다.

## 레이아웃 계약

- 앱 여백 12px, 상단 66px, 하단 프레임 탐색 84px을 사용한다.
- 데스크톱 본문은 `viewer | 조정 294px | 정보 244px`의 독립 3열이다.
- 1180px 이하에서는 조정 218px, 정보 184px, 도구 막대 52px을 사용한다.
- 820px 이하에서는 조정 180px, 정보 160px, 도구 막대 44px을 사용한다.
- 조정과 정보는 지원 폭에서 합치거나 위아래로 쌓지 않는다.
- 타임라인과 `MM:SS.mmm / MM:SS.mmm` 시간은 viewer workspace 아래에 둔다.
- 하단 탐색은 `첫 | −5 | 이전 1 | 현재/전체 | 다음 1 | +5 | 마지막`의 3:1:3 대칭 구조다.

## 시각 체계와 자산

- 배경은 near-black navy/charcoal, 경계는 얇은 blue-gray, 주요 파일 열기만 강한 blue primary로 사용한다.
- 활성 pane은 `#1298ff`, focus는 `#57b9ff`, ready는 `#2bcb74`를 사용한다.
- 아이콘은 디자인 패키지의 30개 SVG를 `src/assets/icons`에 그대로 배치하고 CSS mask로 현재 색상과 disabled 상태를 적용한다.
- Unicode·emoji 아이콘과 새 아이콘 라이브러리를 사용하지 않는다. `−5`와 `+5`는 탐색 수치 표기로만 사용한다.

## 기능 경계

- 두 pane는 같은 frame/pixels를 공유하고 View/Display/tool만 독립이다.
- linked crosshair는 image pixel correspondence이며 DICOM registration이 아니다.
- 정보 컬럼은 읽기 전용이며 조정 컬럼에만 button/input/select를 둔다.
- MP4 화면 픽셀 보정은 실제 DICOM HU Window가 아니다.
- annotation과 작업 상태는 앱 종료 후 저장되지 않는다.

## 검증

- 단위 테스트: `npm test`
- TypeScript/Electron/Vite build: `npm run build`
- Modern UI 계약·시각 캡처: `npm run qa:v0.5.2:ui`
- Phase 5 비교 보기: `npm run qa:phase5:dual`
- 주석·내보내기 회귀: `npm run qa:phase4a:annotations`, `npm run qa:phase4b1:export`
- 패키징·privacy·checksum: `npm run package:win`, `npm run verify:package`

최종 시안과 구현 비교, 반응형 측정과 판정은 `design-qa.md`에 기록한다.
