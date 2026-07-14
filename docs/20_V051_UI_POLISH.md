# v0.5.1 UI Polish — Navigation Hierarchy & Korean Labels

## 결론

v0.5.1은 v0.5.0 기능 동결 기준선 위에서 메뉴, 명칭, 도구 배치와 시각적 계층만 정리한다. decoder/cache/navigation, View Transform 수학, annotation model/history, export 의미와 linked crosshair 좌표 계산은 변경하지 않는다.

## Electron window

- `Menu.setApplicationMenu(null)`로 File/Edit/View/Window application menu를 제거한다.
- 기본 `BrowserWindow` frame을 유지해 Windows title bar, 앱 아이콘과 최소화·최대화·닫기 기능을 보존한다.
- renderer의 Ctrl+O, annotation Undo/Redo/Delete, Text input copy/paste·한글 composition, fullscreen·zoom·frame shortcut을 유지한다.

## 상단 전역 명령

왼쪽에는 제품명, 준비 상태와 영상 metadata를 둔다. 오른쪽은 다음 순서다.

1. 축소 / 현재 확대율 / 확대
2. 화면 맞춤 / 전체 화면 또는 창 모드
3. 단일 보기 / 비교 보기 segmented control
4. 폴더 icon과 파일 열기 primary action

현재 확대율 버튼을 누르면 기존 원본 픽셀 100% 명령을 실행한다. 작은 화면에서는 영상 metadata를 먼저 숨기며 전역 명령은 한 줄과 접근 가능 영역을 유지한다.

## 왼쪽 도구와 Crosshair

도구 순서는 Pan, Zoom, 연결 십자선, separator, Select, Arrow, Text, Ellipse, Rectangle이다. Fit과 100% 중복 버튼은 제거하고 상단 명령으로 유지한다.

연결 십자선은 기존 `crosshairEnabled` 상태를 그대로 사용하며 persistent pane tool을 바꾸지 않는다. 단일 보기에서는 disabled이고 비교 보기 첫 진입에서는 ON, 같은 파일에서 재진입하면 세션 상태를 복원한다.

## 한국어 표시 명칭

- Fit → 화면 맞춤
- 전체 → 전체 화면, fullscreen 진입 후 창 모드
- 비교 뷰 → 비교 보기
- 열기 → 파일 열기
- View A/B → 왼쪽 영역/오른쪽 영역(v0.5.2 사용자 표시 명칭)
- Video Display → 화면 보정
- Annotation → 주석
- Preset / Level / Width / Gamma / Sharp → 프리셋 / 레벨 / 폭 / 감마 / 선명도
- Inverse / Original reset → 반전 / 초기 설정(v0.5.2에서 중복 원본 reset 버튼 제거)

Preset id와 domain label 의미는 바꾸지 않는다. `original` option의 UI 표시만 원본으로 분리한다. “MP4 화면 픽셀 보정 · HU Window 아님” 설명은 유지한다.

## 검증

- 변경 전 전체 테스트 88/88와 TypeScript/Electron/Vite build 통과
- 실제 main window에서 application menu 제거와 native window controls 확인
- Ctrl+O, 한글 composition, Text copy/paste, Ctrl+Z/Y/Shift+Z, Delete/Backspace와 fullscreen shortcut 통과
- segmented mode, Crosshair와 Pan/Select 독립성, single disabled와 dual session restore 통과
- 1440×900, 720×600, Windows DPR 1.5에서 horizontal overflow 0과 inspector 유지
- 기존 Phase 5 WebGL 실제 영상 QA에서 frame/pixel sync, pane 상태, crosshair, annotation/export와 seek 0 유지
- 제품 기본 WebGL 5초 hold: 161 repeats, loading 0, seek delta 0, A/B sync 유지
- RGBA rollback 기능 parity smoke: shared pixels, pane 상태, crosshair, annotation/export, seek 0과 responsive QA 통과

RGBA rollback에 동일한 20ms 반복의 5초 고속 hold stress를 적용했을 때 A/B sync와 seek 0은 유지했지만 loading insertion 10회가 관찰됐다. 이번 UI 변경은 decoder/cache 경로를 수정하지 않으며, 이 수치를 숨기기 위한 제품 의미 변경이나 test 완화는 하지 않았다. 기본 WebGL 제품 경로의 요구 기준은 통과했다.

## 최종 패키지

- 전체 테스트: 88/88
- TypeScript, Electron과 Vite product build: 통과
- 파일: `CT-Cine-Reviewer-Setup-0.5.1.exe`
- 크기: 143,250,568 bytes
- SHA-256: `091ec44ef69b43233c96515f75a9d07d8197cfe4d5ad46f84c6fbb13c1c06194`
- unpacked: 91개 파일
- package privacy inspection과 verify-only checksum 재검증: 통과
