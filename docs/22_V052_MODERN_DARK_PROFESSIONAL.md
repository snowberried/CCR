# v0.5.2 Modern Dark Professional

## 결론

Phase 5 기능 기준선을 변경하지 않고 CCR 데스크톱 UI를 Modern Dark Professional 시각 체계로 교체했다. decoder/cache/navigation, View Transform, pane별 Display, shared annotation, linked crosshair와 PNG/clipboard export의 의미는 그대로다. 자동 재생·재생/정지·오디오·볼륨은 추가하지 않았다.

## 레이아웃 계약

- 앱 여백 12px, 상단 66px, 하단 프레임 탐색 84px을 사용한다.
- Electron 기본 시작 창은 1360×820이며 최소 창 720×600과 자유로운 최대화·전체 화면을 유지한다.
- 데스크톱 본문은 `viewer | 조정/정보 탭 패널 294px`의 2열이다.
- 1180px 이하에서는 탭 패널 218px, 도구 막대 52px을 사용한다.
- 820px 이하에서는 탭 패널 180px, 도구 막대 44px을 사용한다.
- 오른쪽 패널은 `조정 / 정보` 두 탭을 같은 폭으로 표시하고 앱 시작 시 `조정`을 기본 선택한다.
- 탭 자체가 제목 역할을 하므로 탭 내용 안에 `조정` 또는 `정보` 제목을 반복하지 않는다.
- 내부 pane A/B 의미는 유지하되 사용자 화면에는 `왼쪽 영역 / 오른쪽 영역`으로 표시한다.
- 화면 보정의 Original reset은 상단 `원본 보기` 하나만 제공하며, 일시적인 `원본 비교`는 설정된 단축키 안내와 함께 유지한다.
- 타임라인과 `MM:SS.mmm / MM:SS.mmm` 시간은 viewer workspace 아래에 둔다.
- 하단 탐색은 `첫 | 빠른 이전 N | 이전 1 | 현재/전체 | 다음 1 | 빠른 다음 N | 마지막`의 3:1:3 대칭 구조다. N의 기본값은 5이며 설정에서 변경한다.
- 확대율은 하단 오른쪽의 현재 `%` 선택 셀로 이동하고, 별도 화면 맞춤 버튼은 제거한다. 선택 항목은 `화면 맞춤, 50%, 75%, 100%, 125%, 150%, 175%, 200%`이며 숫자는 원본 픽셀 기준 실제 배율이다. `−/+`는 10%p씩 조정하고 화면 맞춤 상태에서도 셀은 계산된 현재 `%`를 표시한다.
- 하단 왼쪽에는 독립 설정창을 여는 테두리 없는 13px `설정`을 둔다. 설정창은 빠른 프레임 이동 간격, 전용 단축키 설정 진입과 사용자가 직접 실행하는 GitHub 최신 Release 확인을 제공한다. 3:1:3 탐색은 두 유틸리티 사이의 중앙에 놓고 `#FFD54F` 2px·80% opacity 구분선은 양쪽 빈 여백의 중앙에 둔다.

## 시각 체계와 자산

- 배경은 near-black navy/charcoal, 경계는 얇은 blue-gray, 주요 파일 열기만 강한 blue primary로 사용한다.
- 활성 pane은 `#1298ff`, focus는 `#57b9ff`, ready는 `#2bcb74`를 사용한다.
- 아이콘은 디자인 패키지의 30개 SVG와 같은 시각 규격의 설정 SVG 1개를 `src/assets/icons`에 배치하고 CSS mask로 현재 색상과 disabled 상태를 적용한다.
- Unicode·emoji 아이콘과 새 아이콘 라이브러리를 사용하지 않는다. `−N`과 `+N`은 탐색 수치 표기로만 사용한다.

## 기능 경계

- 두 pane는 같은 frame/pixels를 공유하고 View/Display/tool만 독립이다.
- linked crosshair는 image pixel correspondence이며 DICOM registration이 아니다.
- 정보 탭은 읽기 전용이며 조정 탭에만 button/input/select를 둔다.
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

## v0.5.3 후속 정리

- 상단 제품명 옆에 현재 앱 버전을 표시한다.
- 조정 패널의 카드형 셀 배경·테두리를 제거하고 섹션 사이에 annotation yellow 구분선을 둔다.
- 하단 설정은 독립 모달을 열며 사용자가 직접 실행하는 GitHub 최신 Release 확인 하나만 제공한다.
- 자동 다운로드·설치와 백그라운드 업데이트 확인은 제공하지 않는다.
