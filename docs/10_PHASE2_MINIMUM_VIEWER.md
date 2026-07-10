# Phase 2 Minimum Viewer

## 결론

Phase 2 최소 실사용 뷰어를 구현했다. 아내가 로컬 MP4를 열고 Canvas에서 정확히 한 프레임 또는 다섯 프레임씩 탐색할 수 있는 범위이며, 자동 재생·확대·보정·주석·저장과 DICOM/PACS는 포함하지 않는다.

기본 디코딩은 Phase 1C 기준선을 유지한다.

- FFmpeg stdout rawvideo pipe
- RGBA 8-bit
- 전체 선디코딩과 디스크 프레임 캐시 사용 안 함
- 기본 메모리 예산 72MiB
- 목표 최소 5프레임, 최대 61프레임
- 406×720 대표 영상은 최대 61프레임, 약 68MiB
- 세 프레임 이상 같은 방향으로 이동하면 방향성 cache window 적용

## 구현 구조

공통 영역:

- `frameCachePolicy.ts`: 프레임당 bytes, 예산 기반 capacity와 방향별 window 계산
- `frameNavigation.ts`: 내부 0 기반·UI 1 기반 변환, key와 wheel 안정화
- `SessionGenerationGuard`: 파일 전환 시 오래된 probe/decode 결과 거부
- 기존 `FrameRequestCoordinator`: 빠른 입력 coalescing과 stale result 거부

Electron 영역:

- 파일 대화상자와 drop file path 변환
- ffprobe/FFmpeg 실행, raw RGBA Buffer와 RAM cache
- 무작위 session ID와 generation 기반 IPC 검증
- 파일 경로와 stderr를 renderer에 전달하지 않는 오류 코드

Renderer 영역:

- Canvas 표시와 마지막 정상 프레임 유지
- 로컬 입력 의도 frameIndex를 한 개로 수렴시키는 request pump
- 세션 전환 시 이전 응답 거부와 Canvas 자원 정리

## 사용자 조작

| 입력 | 동작 |
| --- | --- |
| 파일 열기 버튼, `Ctrl+O` | MP4/MOV/AVI/MKV 선택 |
| MP4 드래그 앤 드롭 | 새 세션으로 열기 |
| `Left` / `Right` | 1프레임 이전/다음 |
| `Shift+Left` / `Shift+Right` | 5프레임 이전/다음 |
| `Home` / `End` | 처음/마지막 프레임 |
| 프레임 입력 | 화면 기준 1부터 전체 프레임 수까지 직접 이동 |
| 마우스 휠 | 일반 notch 또는 누적 trackpad delta당 1프레임 |
| `Escape`, 취소 버튼 | 현재 probe/decode 취소 |

내부 frameIndex는 계속 0 기반이며 UI만 1 기반이다. 입력창이 활성화된 동안 탐색 단축키는 동작하지 않는다.

## 화면 구성

- 상단: 앱 이름, 현재 상태, 해상도/FPS/코덱과 파일 열기
- 중앙: 검은 배경의 최대 Canvas 영상 영역
- 우측: 현재 프레임·시간·영상 정보와 접을 수 있는 개발자 진단
- 하단: 처음, ±5, ±1, 직접 입력, 마지막과 취소

세로·가로 영상은 Canvas 원본 비율을 유지하고 사용 가능한 영역 안에 contain 방식으로 표시한다. 900×620 최소 창과 일반 데스크톱 viewport에서 페이지 overflow가 없음을 확인했다.

## 캐시 정책

`bytesPerFrame = width × height × 4`로 계산하고 다음 순서로 capacity를 결정한다.

1. 기본 예산 72MiB 안에 들어가는 프레임 수 계산
2. 최대 61프레임으로 제한
3. 목표 최소는 5프레임이나, 고해상도에서 예산이 부족하면 예산 상한을 우선해 더 적게 유지

예시:

| 영상 | 프레임 크기 | capacity |
| --- | ---: | ---: |
| 406×720 RGBA | 1,169,280 bytes | 61 |
| 1920×1080 RGBA | 8,294,400 bytes | 9 |

cache miss에서는 기존 cache와 새 window가 겹치는 Buffer를 유지하고 빠진 연속 구간만 FFmpeg로 디코딩한다. 방향이 바뀌어도 전체 cache를 폐기하지 않는다.

## 방향성 캐시 실측

세 번 이상 같은 방향 입력:

- 순방향: 뒤 20 / 현재 1 / 앞 40
- 역방향: 뒤 40 / 현재 1 / 앞 20
- 잦은 교대: 뒤 30 / 현재 1 / 앞 30

고정 20/40과 방향성 방식 비교:

| 샘플·패턴 | 고정 | 방향성 | 결과 |
| --- | ---: | ---: | --- |
| A 순방향 1,001회 | 6.77초 | 6.42초 | 동등 범위 |
| A 역방향 1,001회 | 9.16초 | 6.63초 | 약 28% 개선 |
| B 순방향 1,001회 | 6.66초 | 6.83초 | 동등 범위 |
| B 역방향 1,001회 | 9.20초 | 6.41초 | 약 30% 개선 |
| C 순방향 518회 | 3.23초 | 3.25초 | 동등 범위 |
| C 역방향 518회 | 4.41초 | 3.41초 | 약 23% 개선 |

교대 1,000회는 모든 샘플에서 고정·방향성 모두 hit 999회, miss 1회였다. 방향성 방식의 정확성 오류는 전부 0건이고 cache peak는 71,326,080 bytes로 72MiB 예산 아래였다. 따라서 방향성 cache를 유지한다.

## 정확성과 성능

- Sample A/B/C의 순방향·역방향·교대 탐색 fingerprint 오류 0건
- 최대 1,001회 실측 패턴에서 stale result 0건
- 내부/화면 frame index 변환, 경계 clamp, key·wheel, session generation 자동 테스트
- cache overlap 재사용, 방향 전환과 예산 상한 자동 테스트
- Electron IPC는 Phase 1C의 406×720 payload p95 약 3.4ms 기준 유지

실제 프로덕션 Electron 창에서도 파일 대화상자와 bridge를 통해 다음을 확인했다. 실제 의료 프레임은 캡처하지 않고 UI의 비식별 메타데이터만 읽었다.

| 샘플 | GUI 상태 | 첫 표시 | 길이 |
| --- | --- | --- | --- |
| Sample A | 준비 | 1 / 2,879 | 01:59.958 |
| Sample B | 준비 | 1 / 2,560 | 01:46.667 |
| Sample C | 준비 | 1 / 518 | 00:21.583 |

비의료 합성 세로 영상에서는 `Right` 1→2, `Shift+Right` 2→7, `End` 7→72, `Home` 72→1과 직접 입력 36을 실제 창에서 확인했다. Canvas는 360×640 원본 비율을 유지했다.

## Synthetic QA

| 조건 | 결과 |
| --- | --- |
| 세로 H.264 30fps, 무오디오 | 통과 |
| 가로 H.264 1920×1080 60fps | 통과 |
| HEVC/H.265 | 통과 |
| VFR | 통과, PTS issue 0 |
| B-frame MPEG-4 | 통과 |
| 90도 display rotation metadata | metadata 90도 감지, raw frame checkpoint 통과 |

Phase 2에서는 회전 표시 기능을 제공하지 않으므로 decoder에 `-noautorotate`를 사용해 probe 해상도와 raw frame 크기를 일치시킨다. 회전 적용은 별도 승인 범위다.

## 장시간 메모리 검사

최종 코드로 Sample A/B/C를 1분마다 바꾸며 20분 동안 순·역 탐색과 주기적 먼 이동을 반복했다.

- 실제 지속 시간: 20.000분
- 프레임 요청: 52,410회
- 파일 session 전환: 20회
- 정확성 오류: 0건
- cache 최대: 71,326,080 bytes, 약 68MiB
- cache 예산 초과: 0건
- 메모리 표본: 강제 GC 후 10초 간격 120개

전체 구간에서는 RSS가 allocator와 현재 cache 크기에 따라 분당 약 1.62MiB 증가로 계산됐지만 heap은 분당 약 7.7KiB, external은 감소 추세였다. 워밍업을 제외한 후반 10분은 다음과 같다.

| 항목 | 후반 10분 기울기 |
| --- | ---: |
| RSS | 분당 -2.06MiB |
| V8 heap | 분당 약 +0.7KiB |
| external Buffer | 분당 -1.21MiB |
| cache 보정 external | 분당 -1.33MiB |

후반 heap 범위는 약 8.19~8.26MiB였고, 파일 전환과 GC 후 RSS가 실제로 하락했다. 따라서 지속적인 JavaScript heap 또는 frame Buffer 누수 증거는 발견되지 않았다. RSS는 Windows와 Node allocator의 고수위 메모리 보존 때문에 순간 범위가 넓으므로 제품 UI에서는 cache bytes를 직접 상한 지표로 사용한다.

## 보안과 개인정보

- 원본 파일은 읽기 전용이며 재인코딩하지 않는다.
- 실제 샘플, 프레임, fingerprint와 성능 JSON은 Git에 포함하지 않는다.
- UI와 문서에 실제 파일명·전체 경로·stderr를 표시하지 않는다.
- 프레임 cache는 RAM에만 존재하고 session 종료 시 참조를 제거한다.

## 알려진 한계

- 실제 의료 샘플 세 개가 모두 406×720 H.264여서 실제 HEVC·1080p·VFR 의료 영상의 장시간 성능은 아직 모른다.
- 회전 metadata는 감지하지만 Phase 2 화면에 적용하지 않는다.
- 파일 대화상자와 drag/drop은 Electron runtime에서만 동작한다.
- 자동 재생, Zoom/Pan, 밝기·대비·Gamma, Sharp/Denoise, 주석, 저장 기능은 없다.

## 다음 단계

Phase 2 실제 사용 피드백을 먼저 받는다. Phase 3 범위는 사용자 승인 후 결정하며 영상 보정·Zoom/Pan·주석·이미지 저장·DICOM/PACS를 자동으로 시작하지 않는다.
