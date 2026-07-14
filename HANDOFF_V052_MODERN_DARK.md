# CT Cine Reviewer v0.5.2 Modern Dark Handoff

## 결론

CCR 데스크톱은 Phase 5 기능 기준선 위에서 v0.5.2 Modern Dark Professional UI와 최신 하단 탐색·확대율 UX까지 구현된 상태다.

- decoder/cache/frame navigation, shared annotation, linked crosshair와 export snapshot 의미는 유지했다.
- 자동 재생과 오디오는 사용자 결정으로 계속 제외한다.
- 오른쪽의 조정·정보는 하나의 `조정 / 정보` 탭 패널로 통합했다.
- 새 영상은 화면 맞춤으로 열리며 확대율 셀은 원본 픽셀 기준 현재 실제 `%`를 계속 표시한다.
- 현재 변경의 전체 테스트, build, 반응형 UI QA와 현재 보기 export 회귀가 통과했다.

## Git 기준

- 작업 저장소: `C:\AI_Codex\workspace\CCR`
- 작업 branch: `codex/frame-navigation-layout`
- 이번 인수인계 커밋의 parent: `51c5f56edda059e3775bb8af03e5b53f287f0871`
- 작업 전 원격 branch: `b3d50a6` (`51c5f56` 한 커밋 앞, divergence 없음)
- 기능 동결 기준: `ae70761a098ce69cc47228881d3be08c348f0fd1`
- v0.5.0 main/tag 기준: `db26a45`

## 현재 UI 계약

### 창과 본문

- 기본 시작 창: `1360×820`
- 최소 창: `720×600`
- 상단: 66px, 하단: 84px, 기본 외곽 여백: 12px
- 본문: viewer와 오른쪽 `조정 / 정보` 탭 패널
- 사용자 pane 명칭: `왼쪽 영역 / 오른쪽 영역`
- 화면 보정 reset: `초기 설정` 하나만 제공하며 중복 `원본` 버튼은 없다.

### 하단 탐색

- 왼쪽: 테두리 없는 톱니바퀴 `설정`, 글자 13px
- 중앙: `첫 | −5 | 이전 | 현재/전체 | 다음 | +5 | 마지막` 3:1:3 대칭 탐색
- 오른쪽: `− | 현재 % 선택 | +`
- 양쪽 빈 여백 중앙: annotation yellow `#FFD54F`, 2px, opacity 0.8 구분선
- 재생·정지·미디어 컨트롤과 취소 셀은 없다.

### 확대율

- 닫힌 확대율 셀은 항상 원본 픽셀 기준 현재 실제 배율을 표시한다.
- 선택 항목: `화면 맞춤, 50%, 75%, 100%, 125%, 150%, 175%, 200%`
- 별도 화면 맞춤 버튼은 없다.
- `−/+`, 키보드와 Ctrl+wheel의 고정 step은 실제 배율 기준 10%p다.
- 화면 맞춤을 선택해도 셀에는 `화면 맞춤` 문구 대신 계산된 현재 `%`가 표시된다.

내부 `ViewTransform.zoom`은 계속 Fit 대비 배율이고 실제 표시 scale은 `fitScale × zoom`이다. `scaleMode`가 `fit/manual`을 구분한다.

- Fit mode: resize 시 새 viewport의 contain Fit과 image center를 다시 계산
- Manual mode: resize 시 원본 픽셀 실제 scale과 image center를 유지
- 기존 Fit 대비 1~10배 범위는 보존하면서 고정 50~200% 선택이 항상 가능하도록 clamp 범위를 필요한 만큼 확장

## 주요 변경 파일

- `src/App.tsx`: 조정/정보 탭, 하단 설정·탐색·확대율 선택 UI와 현재 실제 배율 표시
- `src/styles.css`: Modern Dark layout, 반응형 footer, 동일 yellow divider와 설정 13px
- `src/domain/viewTransform.ts`: original-pixel scale 선택·10%p step과 Fit/manual resize 의미
- `tests/viewTransform.test.ts`: 실제 scale, Fit/manual resize와 50~200% 도달성 검증
- `scripts/electron-v052-modern-ui-qa.cjs`: 1440×900/720×600 layout과 확대율 선택 상호작용 검증
- `scripts/electron-phase4b1-export-qa.cjs`: 새 dropdown을 통한 Fit/100% 현재 보기 export 회귀
- `design-qa.md`, `docs/14`, `docs/16`, `docs/21`, `docs/22`: 최신 계약과 시각 QA 기록

## 최종 검증

2026-07-14 로컬 검증 결과:

- `npm test`: 90/90 통과
- `npm run build`: TypeScript, Electron TypeScript와 Vite product build 통과
- v0.5.2 Electron UI QA: 통과
  - 확대율: `71.48% → 50% → 60% → 71.48%`
  - `1440×900`, `720×600`
  - 조정/정보 탭, 3:1:3 탐색, 설정 13px, 동일 divider와 overflow 계약
- Phase 4B-1 export QA: 통과
  - Fit/100%/zoom-pan 현재 보기
  - full/current PNG와 clipboard 결정성
  - export 중 seek와 texture upload 증가 없음
- `git diff --check`: 통과
- untracked file: 없음

시각 QA 캡처는 Git에 포함하지 않는 `artifacts/qa-v052-modern-dark`에 생성된다.

## 설치본 상태

v0.5.2 설치본은 아직 생성하지 않았다. 이전 설치본 생성 요청은 사용자가 후속 인수인계 요청으로 전환하면서 중단됐다.

현재 마지막 검증 설치본은 v0.5.0이다.

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.0.exe`
- 크기: 143,250,244 bytes
- SHA-256: `8262184e2aec7c32952b2035f086587f93f9820090a246962254c67767ce0a95`

v0.5.2 설치본이 필요하면 현재 commit에서 다음을 새로 실행해야 한다.

1. `npm run package:win`
2. `npm run verify:package`
3. unpacked/privacy inspection 결과와 새 설치본 크기·SHA-256 기록

과거 v0.5.0 checksum을 v0.5.2 설치본에 재사용하면 안 된다.

## 제품 경계와 다음 작업

- CCR은 개인정보가 포함되지 않은 CT cine MP4를 검토하는 로컬 보조 뷰어이며 의료기기·공식 PACS·DICOM 판독 프로그램이 아니다.
- MP4 화면 보정은 실제 DICOM HU Window가 아니다.
- annotation과 작업 상태는 앱 종료 후 저장되지 않는다.
- 자동 재생, 오디오, 프로젝트 저장, DICOM/PACS/cloud, 개인정보 마스킹을 사용자 승인 없이 추가하지 않는다.
- 기능 branch는 삭제하지 않는다. main 통합, tag/release와 v0.5.2 설치본 생성은 별도 사용자 요청에서 수행한다.
