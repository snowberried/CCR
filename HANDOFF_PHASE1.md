# Project Handoff

이 문서는 CT Cine Reviewer의 완료된 Phase 1 기술 스파이크와 Phase 2 최소 실사용 뷰어 상태를 인계한다.

## 현재 상태

- Phase 0 기획 문서 작성 완료
- 프로젝트명: CT Cine Reviewer
- 약칭: CCR
- 설명: CT 동영상 프레임 검토 및 주석 도구
- Git 저장소: 준비됨
- 애플리케이션 scaffold: Electron + React + TypeScript 최소 scaffold 작성됨
- npm 패키지: 설치 및 테스트/빌드 검증 완료
- 공통 코어: `FramePoint`, `VideoStreamMetadata`, `VideoProbeResult`, 코드 기반 프레임 시퀀스 검증 작성됨
- 공통 포트: 제네릭 `VideoProbeProvider<TSource>` 작성됨
- Electron 어댑터: 실제 ffprobe 실행, timeout·취소·출력 제한과 비식별 오류 매핑 작성됨
- 프레임 코어: 공통 `FrameRequest`, descriptor/result/cache 모델, `VideoFrameProvider`와 request coordinator 작성됨
- 프레임 어댑터: FFmpeg stdout RGBA decoder와 61프레임 RAM 구간 cache provider 작성됨
- 최소 UI: 파일 열기, Canvas 프레임 표시, ±1/±5/Home/End/직접 이동, PTS·cache·요청 상태 표시 작성됨
- 자동 테스트: 단위·synthetic FFmpeg 통합 테스트 21개 통과
- FFmpeg/ffprobe: BtbN Windows x64 LGPL shared 고정 자산을 checksum 검증 후 프로젝트 로컬 배치
- Phase 1B Sample A: 518프레임 entry, PTS 중복·역행·누락 0건, 총 probe 약 698ms
- Phase 1C Sample A/B/C: 2,879/2,560/518프레임, 모두 406×720 H.264, frame/PTS·fingerprint 불일치 0건
- 캐시 결정: stdout RGBA + 61프레임 RAM cache(뒤 20, 현재 1, 앞 40), 약 68MiB
- 성능: first 241~273ms, hit p95 0.003ms 미만, miss p95 366~418ms, far seek 312~366ms
- Phase 2 UI: 파일 선택·Ctrl+O·drag/drop, Canvas 표시, UI 1 기반 ±1/±5/Home/End/직접 입력 구현
- Phase 2 cache: 72MiB 예산, 최대 61프레임, 방향성 20/40·40/20·30/30과 overlap 재사용 구현
- Phase 2 QA: 실제 Sample A/B/C 정확성 오류 0건, 합성 HEVC·1080p/60fps·VFR·B-frame·회전 metadata 통과
- Phase 2 soak: 20분, 52,410회 요청, 20회 파일 전환, 오류 0건, 후반 heap 기울기 약 +0.7KiB/분
- `local-samples/`: 현재 컴퓨터의 동영상 후보를 비식별 분류해 대표 2개와 짧은 1개를 사용함
- 샘플 총 크기: 미측정
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
- 향후 모바일 앱 개발 가능성을 전제로 핵심 로직과 데이터 모델은 공통 코어로 유지하고 UI는 플랫폼별로 분리함
- Phase 1B의 BtbN LGPL shared 고정 자산 취득과 ffprobe 실제 실행

다음 사항은 아직 승인되지 않았다.

- Phase 3 기능 범위
- 재생, 보정, 주석, 이미지 저장 등 제품 기능

## FFmpeg 확정 상태

- Release tag: `autobuild-2026-06-30-13-34`
- Asset: `ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip`
- SHA-256: `27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da`
- 구성: Windows x64, shared, LGPLv3, GPL/nonfree 비활성
- 로컬 배치: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1`
- 저장 정책: 바이너리는 Git에서 제외하고 고정 취득 스크립트와 `docs/08_FFMPEG_DISTRIBUTION.md`를 커밋

## 대표 샘플의 확인된 특성

- Representative A: 406×720 H.264, 119.958초, 2,879프레임
- Representative B: 406×720 H.264, 106.667초, 2,560프레임
- Short C: 406×720 H.264, 21.583초, 518프레임
- 세 샘플 모두 실제 frame entry와 디코딩 수를 대조했다. duration × FPS로 프레임 수를 확정하지 않는다.

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
8. `docs/07_PHASE1_SPIKE_RESULTS.md`
9. `docs/09_FRAME_DECODING_AND_CACHE.md`
10. `docs/10_PHASE2_MINIMUM_VIEWER.md`

환경·권한·샌드박스 문제가 발생하면 현재 환경의 공용 troubleshooting 문서를 먼저 확인한다.

## 새 프로젝트의 첫 작업 순서

1. 기존 문서를 읽고 삭제하거나 대체하지 않는다.
2. `.gitignore`가 `local-samples/`와 `tools/ffmpeg/`를 제외하는지 확인한다.
3. 샘플 수만 확인하고 실제 파일명을 출력하지 않는다.
4. FFmpeg 로컬 도구가 없으면 고정 setup 스크립트로 checksum 검증 후 준비한다.
5. `npm test`, `npm run build`로 현재 Phase 2 기준선을 확인한다.
6. `npm start`로 Electron 최소 뷰어를 실행한다.
7. 다음 사용자 승인 전에는 Phase 3와 제품 기능을 시작하지 않는다.

## 개인정보 규칙

- 실제 샘플은 외부로 전송하지 않는다.
- 샘플 파일명, 전체 경로, 환자 식별정보를 로그나 문서에 남기지 않는다.
- 결과 문서에서는 `Sample A`처럼 표기한다.
- 샘플 프레임이나 스크린샷을 저장소에 추가하지 않는다.
- 원본 영상은 읽기 전용으로 취급하고 재인코딩하지 않는다.
- 앱 전용 임시 캐시 밖의 파일을 삭제하지 않는다.

## 다음 작업에 보낼 첫 메시지

```text
HANDOFF_PHASE1.md, AGENTS.md와 docs/10_PHASE2_MINIMUM_VIEWER.md를 먼저 읽어라.
Phase 2 실제 사용 피드백을 확인하고 Phase 3 범위를 사용자에게 승인받기 전에는 구현을 시작하지 마라.
```

## 인계 시점의 차단 사항

Phase 2 최소 실사용 뷰어는 완료됐다. 다음 차단 사항은 실제 사용 피드백과 Phase 3 범위에 대한 사용자 승인이다.
