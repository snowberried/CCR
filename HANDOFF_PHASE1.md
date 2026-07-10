# Phase 1 Handoff

이 문서는 새 Codex 프로젝트에서 CT Cine Reviewer의 Phase 1 기술 스파이크를 바로 이어가기 위한 인수인계 문서이다.

## 올바른 작업공간

반드시 다음 폴더를 프로젝트 루트로 연다.

`C:\AI_Codex\workspace\CCR`

다른 위치에 새 scaffold나 문서를 만들지 않는다.

## 현재 상태

- Phase 0 기획 문서 작성 완료
- 프로젝트명: CT Cine Reviewer
- 약칭: CCR
- 설명: CT 동영상 프레임 검토 및 주석 도구
- Git 저장소: 아직 아님
- 애플리케이션 scaffold: 아직 없음
- npm 패키지: 아직 설치하지 않음
- FFmpeg/ffprobe: 현재 시스템에서 찾을 수 없음
- `local-samples/`: 실제 로컬 샘플 1개 존재
- 샘플 총 크기: 29,757,054 bytes
- 실제 파일명과 전체 경로는 문서·로그·완료 보고에 기록하지 않음

## 사용자 승인 상태

다음 사항은 승인됐다.

- Phase 1 기술 스파이크 진입
- Electron + React + TypeScript 1순위 검증
- 최소 개발·테스트 도구와 최소 UI 작성
- MP4, frameIndex, PTS, 전후 프레임 탐색과 캐시 전략 검증
- 실제 로컬 샘플 사용
- DICOM, PACS, HU window, 주석, Sharp 등 제품 기능 제외
- Phase 1 결과를 보고한 뒤 Phase 2로 넘어가지 않음

다음 사항은 아직 승인되지 않았다.

- 사용할 Windows FFmpeg 바이너리 제공처와 라이선스 구성
- FFmpeg 다운로드와 프로젝트 로컬 배치
- Phase 2 최소 뷰어 구현

## FFmpeg 결정 대기

현재 후보는 두 개다.

### 1안: BtbN Windows LGPL shared build — 권장

- FFmpeg 공식 다운로드 페이지에서 연결하는 Windows build 제공처
- `win64-lgpl-shared` 계열의 고정 release build를 프로젝트 로컬 `tools/ffmpeg/`에 배치
- 버전, checksum, `ffmpeg -buildconf`, 라이선스 파일을 기록
- `tools/ffmpeg/`는 Git에서 제외
- DLL을 함께 관리해야 하지만 향후 배포 라이선스 경계가 상대적으로 명확함

### 2안: Gyan Essentials GPLv3 build

- FFmpeg 공식 다운로드 페이지에서 연결하는 Windows build 제공처
- 정적 실행 파일이라 초기 사용은 단순함
- GPLv3 build이므로 향후 앱과 함께 배포하기 전 별도 검토가 중요함
- Phase 1 로컬 기술 검증에만 사용하고 최종 배포 결정을 뜻하지 않음

공식 참고:

- https://ffmpeg.org/download.html
- https://ffmpeg.org/legal.html

사용자가 1안 또는 2안을 명시적으로 승인하기 전에는 다운로드하지 않는다.

## 대표 샘플의 예상 특성

아래 값은 파일 상세 화면에서 확인한 예상값이며 ffprobe로 재검증해야 한다.

- MP4
- 406 × 720 세로형
- 약 1분 59초
- nominal 24fps
- 예상 약 2,856프레임
- 영상 비트레이트 약 1.88Mbps

실제 프레임 수는 duration × FPS로 확정하지 않는다.

## Phase 1 초기 목표

- 1080p 이하
- 3분 이하
- 약 5,000프레임 이하
- 15~60fps
- 300MB 이하
- 첫 프레임 표시 3초 이내 목표
- 빠른 ffprobe 메타데이터 2초 이내 목표
- 캐시 hit 전후 이동 50ms 이하 목표
- 임의 프레임 이동 500ms 이하 목표
- 반복 왕복 탐색에서 누락·중복·순서 역전 0건

모두 보장값이 아니라 실제 측정을 위한 목표값이다.

## 새 프로젝트에서 먼저 읽을 문서

1. `AGENTS.md`
2. `README.md`
3. `docs/docs_hub.md`
4. `docs/03_TECHNICAL_SPIKE_PLAN.md`
5. `docs/05_ROADMAP.md`
6. `docs/06_DECISIONS_AND_OPEN_QUESTIONS.md`
7. `docs/troubleshooting.md`

환경·권한·샌드박스 문제가 발생하면 다음 공용 문서를 먼저 확인한다.

`C:\AI_Codex\workspace\공용 설정\troubleshooting\troubleshooting.md`

## 새 프로젝트의 첫 작업 순서

1. 작업 루트가 `C:\AI_Codex\workspace\CCR`인지 확인한다.
2. 기존 문서를 읽고 삭제하거나 대체하지 않는다.
3. `.gitignore`가 `local-samples/`와 `tools/ffmpeg/`를 제외하는지 확인한다.
4. 샘플 수만 확인하고 실제 파일명을 출력하지 않는다.
5. 사용자가 승인한 FFmpeg 방식으로만 프로젝트 로컬 도구를 준비한다.
6. checksum, version, build configuration과 라이선스를 확인한다.
7. Phase 1에 필요한 최소 scaffold를 작성한다.
8. ffprobe 분석 → frameIndex/PTS → 캐시 전략 비교 → 최소 UI 순서로 검증한다.
9. 자동 테스트와 실제 샘플 측정 결과를 `docs/07_PHASE1_SPIKE_RESULTS.md`에 기록한다.
10. Docs Hub와 결정 문서를 함께 갱신한다.
11. Phase 2를 시작하지 않는다.

## 개인정보 규칙

- 실제 샘플은 외부로 전송하지 않는다.
- 샘플 파일명, 전체 경로, 환자 식별정보를 로그나 문서에 남기지 않는다.
- 결과 문서에서는 `Sample A`처럼 표기한다.
- 샘플 프레임이나 스크린샷을 저장소에 추가하지 않는다.
- 원본 영상은 읽기 전용으로 취급하고 재인코딩하지 않는다.
- 앱 전용 임시 캐시 밖의 파일을 삭제하지 않는다.

## 새 Codex 프로젝트에 보낼 첫 메시지

아래 메시지에서 FFmpeg 선택지만 채워 보낸다.

```text
HANDOFF_PHASE1.md와 AGENTS.md를 먼저 읽고 CT Cine Reviewer Phase 1을 이어가라.
작업 루트는 C:\AI_Codex\workspace\CCR이다.
FFmpeg는 [1안 BtbN LGPL shared / 2안 Gyan Essentials GPLv3]으로 프로젝트 로컬 준비를 승인한다.
사전 점검 후 최소 기술 스파이크만 구현하고 Phase 2는 시작하지 마라.
```

## 인계 시점의 차단 사항

유일한 외부 차단 사항은 FFmpeg 방식 선택과 다운로드 승인이다. 샘플은 이미 로컬 작업공간에 있다.
