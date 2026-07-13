# Roadmap

## 운영 원칙

- 각 Phase는 이전 Phase의 검증 결과와 사용자 승인을 진입 조건으로 한다.
- 완료 조건을 만족하기 전 다음 기능을 함께 구현하지 않는다.
- DICOM과 PACS는 v0.1 로드맵 밖이며, 별도 승인 전 의존성이나 코드를 추가하지 않는다.

## Phase 0: 기획

### 목적

문제, 범위, 기술 후보, 데이터 의미, 검증 기준과 미결정을 문서로 고정한다.

### 산출물

- README, 프로젝트 지침, Charter, Product Requirements
- Architecture Options, Technical Spike Plan
- Data and State Model, Roadmap, Decisions and Open Questions

### 진입 조건

- 동영상 중심 보조 뷰어라는 큰 방향에 대한 사용자 합의

### 완료 조건

- 문서 간 MP4/HU, v0.1 범위, 보안 원칙이 충돌하지 않는다.
- 기술 선택과 미결정을 구현 완료처럼 표현하지 않는다.
- 소스코드·scaffold·패키지·외부 바이너리가 없다.

### 다음 단계 승인

- 1순위 기술 스택으로 기술 스파이크를 시작할지
- 사용할 대표 샘플과 개인정보 처리 방식
- FFmpeg 취득·라이선스 확인 범위

## Phase 1: 프레임 탐색 기술 스파이크

### 목적

대표 MP4의 프레임 인덱스/PTS 정확성, 역방향 이동, 캐시 전략, Windows 경로와 오류 처리를 검증한다.

### 산출물

- 최소 검증 도구와 자동화된 핵심 검사
- 샘플 분석표와 성능 측정 결과
- 전체 선디코딩 대 구간 캐시 비교 및 추천

### 진입 조건

- Phase 0 승인
- 승인된 익명화/테스트 샘플 확보
- 기술 구성과 외부 바이너리 출처 승인

### 완료 조건

- `docs/03_TECHNICAL_SPIKE_PLAN.md`의 합격/실패 기준을 증거와 함께 판정한다.
- 원본 보존과 캐시 정리를 검증한다.
- 실패 시 원인과 대안을 재현 가능하게 기록한다.

### 다음 단계 승인

- 기본 디코딩·캐시 전략
- 최소 지원 영상 범위와 성능 기준
- Phase 2 앱 scaffold 생성

## Phase 2: 최소 뷰어

### 목적

영상 열기와 정확한 프레임 탐색에 집중한 실사용 가능한 최소 뷰어를 만든다. Zoom/Pan과 재생은 별도 승인까지 제외한다.

### 산출물

- Windows 로컬 앱 개발판
- 파일 열기/드래그 앤 드롭
- 인덱스 탐색, 현재/전체 프레임 표시
- Canvas 원본 비율 표시와 1·5프레임 탐색
- 메모리 예산 기반 방향성 RAM cache
- 핵심 자동 테스트와 샘플 회귀 검사

### 진입 조건

- Phase 1 합격과 캐시 전략 승인

### 완료 조건

- 대표 샘플에서 P0 탐색 수용 기준을 만족한다.
- 한글·긴 경로와 오류 입력에서 앱이 통제된 상태를 유지한다.
- 원본과 앱 전용 캐시 경계가 검증된다.
- 실제 샘플 정확성과 장시간 메모리 상한을 검증한다.

### 다음 단계 승인

- Phase 2 실제 사용 피드백
- Zoom/Pan, 최소 재생과 표시 보정 중 다음 우선순위

## Phase 3A: View Transform

### 목적

향후 표시 보정·주석·저장에서 공유할 image 좌표 기반 Zoom/Pan/Fit을 구축한다.

### 산출물

- 플랫폼 중립 View Transform과 좌표 왕복
- cursor anchored Zoom, pointer Pan과 Fit
- WebGL/RGBA 공통 transform 의미
- Electron window fullscreen

### 진입 조건

- Phase 2.3 제품 cache 통합 승인
- Zoom/Pan 우선순위 사용자 승인

### 완료 조건

- frame 이동·fallback 뒤 transform이 유지되고 새 file은 Fit으로 초기화된다.
- 좌표 정확성·성능·내구·설치 앱 QA를 통과한다.
- decoder/cache와 표시 보정 범위를 변경하지 않는다.

### 다음 단계 승인

- 실제 사용 Zoom/Pan 피드백
- Phase 3B 표시 보정 기능 범위

## Phase 3B: 표시 보정과 preset

### 목적

MP4 화면 픽셀에 대한 Video Level/Width, Gamma, Inverse, Sharp와 원본 비교를 일관되게 제공한다.

### 산출물

- GPU 또는 검증된 실시간 보정 경로
- Original과 임상 부위 이름을 붙인 `-like` preset 초안
- 사용자 preset 최소 흐름
- 화면/내보내기 공통 처리 정의

### 진입 조건

- Phase 3A 좌표·입력 기반 승인
- MP4 preset이 HU 기반이 아니라는 UI 문구 승인

### 완료 조건

- 보정 on/off와 원본 누르고 보기가 즉시 동작한다.
- 강한 Sharp 등 보정 적용 상태를 사용자가 알 수 있다.
- 대표 샘플에서 성능과 결과 일관성을 검증한다.

### 구현 결과

- 플랫폼 중립 Display 모델과 CPU reference를 추가했다.
- WebGL uniform redraw와 RGBA fallback parity를 검증했다.
- 8개 candidate preset과 Custom 전환, 우클릭 drag, Original hold compare를 구현했다.
- Sample A~K 첫·중간·마지막 frame clipping/luminance를 측정했다.

### 다음 단계 승인

- 초기 preset 값과 Sharp/Denoise 기본값
- v0.1 주석 도구 정확한 범위

## Phase 4A: Frame Annotation MVP + Annotated Timeline

### 목적

프로젝트 저장 없이 원본을 수정하지 않는 프레임별 벡터 주석과 탐색 흐름을 검증한다.

### 산출물

- Arrow, 한 줄 Text, Ellipse, Rectangle
- 선택·이동·resize·삭제와 세션 전체 Undo/Redo
- 원본 image pixel geometry와 별도 SVG overlay
- annotated frame marker와 latest-intent timeline scrub

### 진입 조건

- 마우스·키보드 충돌 규칙 승인
- image pixel 좌표와 세션 RAM 수명 승인

### 완료 조건

- 창 크기·zoom/pan 변경 뒤에도 주석 위치가 유지된다.
- 프레임 간 주석이 섞이지 않는다.
- WebGL/RGBA에서 동일 geometry를 사용하고 decoder/cache 요청이 증가하지 않는다.

### 구현 결과

- Phase 4A 범위를 구현하고 78개 테스트, 양 renderer QA와 Phase 2.3 순·역 30초 회귀를 통과했다.
- 프로젝트 저장, mask, 숨김과 내보내기는 추가하지 않았다.

### 다음 단계 승인

- Phase 4B-1 전체 프레임/현재 보기 PNG와 clipboard 범위를 승인해 구현했다.
- 프로젝트 저장 schema, mask·숨김·자유선은 계속 별도 승인이다.

## Phase 4B-1: Deterministic Frame Export & Clipboard

### 목적

실제로 표시된 한 프레임을 일관된 Video Display·View Transform·주석 상태로 RAM 합성해 PNG 파일 또는 OS clipboard로 전달한다.

### 구현 결과

- 전체 프레임: 원본 해상도, 확정 Display, 선택적 현재 프레임 주석
- 현재 보기: viewport CSS size × DPR, Zoom/Pan/letterbox와 선택적 주석
- Save dialog 이전 frame index/fingerprint snapshot과 Unicode-safe 기본 파일명
- 임시 PNG, OS screenshot, FFmpeg 재실행, decoder/cache/texture upload 없음
- 82개 테스트, WebGL/RGBA Electron QA와 720×600 compact QA 통과

### 다음 단계 승인

- 실제 사용자 공유 흐름 평가
- 개인정보 mask/blur와 공유 전 확인 UX
- JPEG, clip/batch 또는 프로젝트 저장 필요성

## Phase 5: Linked Dual View & Crosshair

### 목적

같은 영상의 동일한 현재 프레임을 두 pane에서 서로 다른 Zoom/Pan과 Video Display로 비교한다.

### 산출물

- View A/B 동일 frameIndex·fingerprint·decoded pixels
- pane별 독립 View Transform, Video Display와 persistent tool
- 기존 image-space 변환을 재사용한 linked crosshair
- 공용 frame annotation/history/timeline과 active-pane export
- 단일 decoder/cache/navigation과 WebGL texture upload

### 진입 조건

- Phase 4B-1 기준 커밋 `ac810c8`
- 동일 프레임 비교 의미와 pane별 상태 경계 승인

### 완료 조건

- A/B frame identity와 pixel source가 항상 일치한다.
- 한 pane의 View/Display 조작이 다른 pane을 바꾸지 않는다.
- crosshair image-space 오차가 0.25 pixel 이하이며 pointer 이동만으로 decode/cache/texture 작업이 발생하지 않는다.
- WebGL/RGBA, annotation, export, 720×600, hold navigation과 10분 soak를 통과한다.

### 구현 결과

- 버전 0.5.0에 UI 명칭 `비교 뷰`로 통합했다.
- WebGL은 한 I420 frame upload 뒤 pane별 uniform draw 두 번, RGBA는 같은 source pixels의 pane별 CPU display 처리만 수행한다.
- 서로 다른 frame/영상, 자동 registration, linked Zoom/Pan, composite export, 개인정보 마스킹은 구현하지 않았다.

### 다음 단계 승인

- 실제 사용자 비교 흐름 평가와 기능 동결 여부
- 새 기능은 별도 사용자 승인 뒤에만 시작

## Phase 6: 실제 샘플 QA와 Windows 배포

### 목적

실제 사용 환경의 다양한 영상에서 회귀를 찾고 초기 배포물을 만든다.

### 산출물

- 샘플 호환성·성능 결과
- 알려진 한계와 사용자 안내
- 포터블 또는 승인된 설치형 Windows 패키지
- 라이선스 고지, 캐시·보안 점검표

### 진입 조건

- P0/P1 기능 수용 기준 충족
- Windows 최소 버전과 배포 형태 승인

### 완료 조건

- 합의한 샘플 매트릭스와 실제 사용 시나리오를 통과한다.
- 설치/실행/삭제 후 원치 않는 환자 데이터·캐시가 남지 않음을 점검한다.
- 알려진 의료적·기술적 한계를 앱과 문서에 표시한다.

### 다음 단계 승인

- v0.1 배포 승인 또는 추가 수정 범위
- DICOM ZIP을 별도 탐색할지 여부

## 향후 검토: DICOM ZIP

- 실제 DICOM ZIP 샘플과 반출·개인정보 정책이 확보된 뒤 별도 Charter를 작성한다.
- HU window, metadata, series 정렬, 측정 기능은 동영상 preset과 의미를 분리한다.
- Cornerstone3D 등 의존성은 이 단계 승인 전 추가하지 않는다.

## 장기 검토: PACS 또는 DICOMweb

- 병원 PACS 기능, DICOMweb 지원, 인증, 내부망, 감사·보안 요구를 먼저 조사한다.
- v0.1의 입력 인터페이스 분리는 확장 가능성을 보존하기 위한 것이며 PACS 연동 준비 완료를 뜻하지 않는다.
