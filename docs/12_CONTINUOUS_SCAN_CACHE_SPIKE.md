# Phase 2.2 Continuous Scan Cache Spike

## 결론

Phase 2.2 격리 기술 스파이크는 현재 제품의 61프레임 RGBA 이동창에서 발생하던 연속 탐색 로딩을 제거할 수 있음을 확인했다.

- 11개 실제 샘플 모두 2GiB soft cap 안에서 전체 I420 RAM cache 모드를 사용했다.
- 첫 I420 프레임 p95 149.2ms, 실제 Electron 첫 Canvas 표시 313.1ms였다.
- 전체 cache 완료 p95 1,244.4ms, 완료 후 탐색 p95 0.332ms·최대 4.035ms였다.
- 완료 후 전체 순방향·역방향·처음→끝→처음·관심 구간 왕복에서 FFmpeg 재디코딩은 0회였다.
- 30초 방향키 지속 입력에서 보이는 로딩 0회, 최종 프레임 오차 0, stale frame 0을 확인했다.
- VideoFrame 직접 표시는 색 정확성 기준을 실패했다. WebGL2 BT.601 limited 변환은 통과했고, 그 외 range/matrix는 기존 RGBA 경로로 fallback한다.
- 제품 기본 경로는 변경하지 않았다. 새 경로는 `CCR_PHASE22_SPIKE=1`에서만 활성화된다.
- 30분 내구 시험은 2,228회 세션 전환·445,600회 요청에서 정확성 오류와 cache 재디코딩 0으로 통과했다.

성공 결과를 제품 기본 경로로 통합하려면 별도 사용자 승인이 필요하다.

## 기존 병목과 비교 기준

Phase 2.1은 FFmpeg stdout RGBA 8-bit와 최대 61프레임 방향성 RAM cache를 사용한다. cache 경계를 넘을 때 FFmpeg accurate seek가 반복되어 단일 miss 약 366~418ms가 발생했다.

최종 11개 샘플 기준 기존 RGBA 패턴 측정은 다음과 같다.

| 항목 | Phase 2.1 RGBA 61-frame | Phase 2.2 전체 I420 |
| --- | ---: | ---: |
| 순방향 패턴 p95 | 6,812.8ms | cache 탐색 p95 0.332ms |
| 역방향 패턴 p95 | 6,879.4ms | cache 탐색 p95 0.332ms |
| 교대 패턴 p95 | 461.6ms | cache 탐색 p95 0.332ms |
| 최대 cache payload | 68MiB | 1,203.9MiB |
| cache 완료 후 재디코딩 | 경계 miss마다 발생 | 0회 |

패턴 수치는 여러 이동을 한 묶음으로 측정한 값이므로 단일 요청 지연과 직접 비교하지 않는다. 기존 경로는 삭제하지 않고 fallback과 제품 기준선으로 유지한다.

## 실제 다중 샘플 특성

`local-samples/`에서 11개를 확인해 모두 분석했다. 파일명·전체 경로·hash는 결과와 문서에 기록하지 않았다.

| 특성 | 결과 |
| --- | --- |
| 별칭 | Sample A~K |
| 해상도·FPS | 모두 406×720, 24fps |
| codec·pixel format | 모두 H.264, yuv420p |
| 길이 | 14.000~119.958초 |
| frame 수 | 336~2,879 |
| 최대 keyframe 간격 | 250프레임 |
| frameIndex/PTS 오류 | 0건 |
| 색 metadata | 11개 모두 range/matrix/primaries/transfer 없음 |
| 중복 | A/J, B/K 두 그룹이며 모두 유지해 검증 |
| 예상 I420 payload | 147,329,280~1,262,383,920 bytes |

합성 영상은 실제 샘플에 없는 세로·1080p60·BT.709·HEVC·B-frame·VFR·321×241 홀수 plane·full range·90도 회전만 보완했다. 합성 8종에서 packet index, layout, fingerprint, 색 정책, 회전 오류는 모두 0이었다.

## 추천 구조

### 첫 표시와 지속 decoder

1. quick ffprobe와 첫 I420 프레임 디코드를 병렬 실행한다.
2. 첫 프레임을 IPC로 보내 Canvas에 먼저 표시한다.
3. renderer의 첫 표시 확인 뒤 FFmpeg background sequential decoder 하나를 시작한다.
4. stdout YUV420P를 presentation order로 읽어 block slab에 직접 채운다.
5. 별도 packet index probe가 raw PTS와 frameIndex를 구성한다.

packet 기반 인덱스는 전체 frame JSON probe보다 작고 빠르며, 실제 11개와 합성 B-frame/VFR에서 기존 전체 probe와 순서가 일치했다.

### 전체 cache와 제한 LRU

16GB PC 기준 정책은 다음과 같다.

- hard soft cap: 2GiB
- 실제 budget: `min(2GiB, total RAM의 12.5%, available RAM의 25%)`
- 최소 안전 budget 256MiB 미만: 기존 RGBA fallback
- 예상 payload와 frame metadata가 budget의 80% 이하: 전체 I420 cache
- 그보다 큼: 제한 block LRU
- 메모리 압박 통지: budget 축소와 LRU eviction

LRU는 현재 주변 한 창만 남기지 않고 방문 block을 soft cap까지 유지한다. 같은 block의 background fill과 seek load를 병합한다. 실제 11개를 128MiB로 강제한 결과 최대 저장 134,174,880 bytes로 cap을 지켰고 eviction 181회가 발생했다. 11개 모두 첫 재방문은 miss 1회, 즉시 두 번째 재방문은 hit였으며 fingerprint 오류는 0이었다. forced 600,000-byte 통합 시험도 같은 동작을 확인했다. 저메모리 시험은 YUV background를 시작하지 않고 기존 RGBA segment cache의 miss→hit를 확인했다.

### on-demand seek decoder

아직 background가 준비하지 않은 먼 frame, 직접 frame 입력, Home/End만 별도 seek decoder를 사용한다. 최종 11개 모두 background 진행 중 End 요청을 cache miss 상태로 실행했고 최대 300.8ms였다. 결과 fingerprint는 이후 background cache 결과와 모두 일치했다.

background가 곧 채울 인접 block은 짧게 기다려 중복 seek를 피한다. cache 완료 후 seek decode 증가는 0이었다.

## block 크기와 메모리

406×720 I420 한 장은 438,480 bytes다. 약 32MiB slab 목표로 이 샘플군은 64프레임 block을 사용한다.

| 항목 | 32프레임 | 64프레임 |
| --- | ---: | ---: |
| 11개 평균 전체 decode | 652.47ms | 644.85ms |
| 샘플별 승리 | 6/11 | 5/11 |
| 최대 영상 block 수 | 90 | 45 |

64프레임은 평균 약 1.2% 빨랐고 block 객체 수를 절반으로 줄여 선택했다. 해상도가 커지면 같은 약 32MiB 목표에 맞춰 frame 수가 자동 감소하며 1080p는 10프레임이다.

최대 실제 payload는 1,262,383,920 bytes, Node benchmark 최대 RSS는 1,367,420,928 bytes였다. payload를 제외한 관측 RSS 증가의 최대치는 약 22.5MiB였지만 allocator 회수 시점 때문에 이 값은 근사치다. 최종 Electron 30초 QA에서 peak는 main 1,237.0MiB, renderer 175.4MiB, GPU 110.8MiB였고, 내구 시험 중 30초 표본의 FFmpeg peak RSS는 65.92MiB였다.

RAM은 미리 2GiB를 예약하지 않고 block 단위로 점진 할당한다. 전체 RGBA cache와 디스크 PNG/JPEG cache는 구현하지 않았다.

## 탐색과 press-and-hold

key repeat는 디코딩 요청 queue가 아니다. `direction`, `targetFrame`, `startedAt`, `holdDurationMs`를 가진 navigation intent만 갱신하고 requestAnimationFrame에서 최신 target으로 수렴한다. keyup은 마지막 target을 다시 pump해 정확히 정착시킨다.

실제 숨김 Electron 창에서 31.20초 동안 오른쪽 방향키 repeat 963회를 보냈다.

- 예상 UI frame 965, 실제 965
- 로딩 표시 DOM 삽입 0회
- seek 재디코딩 0회
- renderer 오류 0건
- A→B→C 연속 open에서 수락된 세션은 C만 존재
- 취소 뒤 늦은 frame 수락 0건
- BT.709 첫 frame은 오류 없이 기존 RGBA 표시로 fallback

100ms보다 짧은 spike cache hit는 로딩 표시로 내보내지 않는다. 실제 느린 작업은 기존처럼 `디코딩 중` 상태를 표시한다. 자동 가속은 추가하지 않았다.

## 30분 메모리 안정성

11개 실제 샘플을 순환하며 매 세션 전체 cache를 채우고 무작위 frame을 두 번씩 요청한 뒤 session을 닫았다.

- 실제 시간 30.000분
- session open/close 2,228회
- frame 요청 445,600회
- fingerprint 오류 0
- frameIndex 오류 0
- cache 완료 구간 재디코딩 0
- peak RSS 1,537,466,368 bytes
- 종료 RSS 346,824,704 bytes
- 후반 15분 RSS 기울기 2.44MiB/분

설정한 안정성 기준 peak 2GiB 이하·후반 기울기 10MiB/분 이하를 통과했다.

## 성능 결과

| 항목 | 결과 | 성공 기준 | 판정 |
| --- | ---: | ---: | --- |
| 첫 I420 프레임 p95 | 149.2ms | 500ms 이하 | 통과 |
| 실제 Electron 첫 Canvas | 313.1ms | 500ms 이하 | 통과 |
| 전체 I420 cache p95 | 1,244.4ms | 2,000ms 이하 | 통과 |
| cache 탐색 p95 | 0.332ms | 16ms 이하 | 통과 |
| cache 탐색 최대 | 4.035ms | 50ms 이하 | 통과 |
| background 중 먼 End | 최대 300.8ms | 500ms 이하 | 통과 |
| Home→End→Home 최대 | 0.299ms | 50ms 이하 | 통과 |
| cache 완료 후 seek decode | 0회 | 0회 | 통과 |
| fingerprint 오류 | 0건 | 0건 | 통과 |
| frameIndex/PTS 오류 | 0건 | 0건 | 통과 |
| stale/file 혼입 | 0건 | 0건 | 통과 |
| 최대 cache payload | 1,203.9MiB | 2,048MiB 이하 | 통과 |

전체 순방향·역방향은 모든 frame을 각각 1회 요청했다. 관심 구간은 중앙 ±20프레임을 1,000회 왕복했고, Home→End→Home도 포함했다.

## 표시 정확성

VideoFrame(I420)→Canvas 후보는 자원 해제와 속도는 통과했지만 색 정확성을 실패했다. 최선 VideoFrame BT.601 limited 결과는 평균 1.222, p99 8, 최대 channel 오차 45였다.

따라서 WebGL2 prototype을 비교했다. 실제 11개 영상 첫·중간·마지막 frame을 독립 RGBA 기준과 비교한 최종 shader는 BT.601 limited, nearest chroma, 출력 −1 LSB였다.

- 평균 channel 오차 0.407
- p99 1
- 최대 2
- draw p95 0.100ms
- 검사 자원 close 100%

허용 기준 평균≤1, p99≤2, 최대≤4를 통과했다. 실제 샘플에는 색 metadata가 없으므로 `candidate-bt601-limited`로만 이 경로를 허용한다. BT.709, full range, 지원하지 않는 layout, WebGL 오류/context loss는 기존 RGBA 경로로 fallback한다. 색 metadata가 없는 새 공급원에 BT.601 limited가 항상 옳다는 뜻은 아니므로 제품 통합 시 경고와 표본 검증이 필요하다.

## 개인정보와 디스크 잔존

- 원본은 FFmpeg 입력으로만 읽고 수정·재인코딩하지 않았다.
- frame payload는 stdout→RAM으로만 전달했다.
- `temp/`의 PNG/JPEG/raw/YUV frame artifact는 0개였다.
- Git 추적 대상의 `local-samples/` 또는 `temp/` 항목은 0개였다.
- 보고서에는 Sample A~K 별칭과 집계값만 사용했다.
- 환자 영상·파일명·전체 경로·hash를 문서나 로그에 남기지 않았다.

## 플랫폼 독립성

I420 layout, block 크기, cache 정책은 `src/domain`에 있고 Node Buffer, Electron IPC, 파일 시스템을 참조하지 않는다. FFmpeg decode와 block 저장은 `electron/adapters`, session과 IPC는 `electron/spike22`, WebGL UI는 `src/ui`에 분리했다. native addon과 WebCodecs 전면 교체는 도입하지 않았다.

## 검증

- 최종 자동 테스트 44개 통과
- 최종 TypeScript/Electron/Vite production build 통과
- 실제 샘플 분석 11/11 통과
- 실제 sample benchmark 11/11 통과
- 합성 edge QA 8/8 통과
- Electron 색 QA 통과
- Electron UI 30초 QA 통과
- 30분 soak: 2,228 sessions·445,600 requests, 정확성/재디코딩 오류 0, 후반 RSS +2.44MiB/분으로 통과

BT.709 첫-frame RGBA retry와 실제 11개 128MiB 강제 LRU도 최종 실행해 각각 fallback 오류 0, fingerprint 오류 0으로 통과했다. Windows sandbox의 반복 `spawn EPERM`은 동일 명령의 권한상승 재실행으로 해결했고 공용 troubleshooting에 재발 사례를 기록했다.

## 권고와 남은 위험

기술적으로는 Phase 2.2 경로를 제품 기본 후보로 통합할 근거가 충분하다. 다만 자동 통합하지 않고 다음을 사용자 승인 사항으로 남긴다.

1. 전체 I420 cache + 제한 LRU + RGBA fallback을 Phase 2 기본 경로로 옮길지 승인
2. 색 metadata가 없는 실제 공급원을 BT.601 limited 후보로 처리할지 승인
3. 16GB PC에서 최대 약 1.3GB main-process RSS를 허용할지 승인
4. 제품 통합 뒤 실제 표시 육안 pilot과 장시간 파일 추가 검증 승인

남은 위험은 색 metadata가 없는 새 영상, WebGL/GPU 드라이버 조합, 2GiB를 넘는 장시간·고해상도 실제 영상의 LRU 실사용 체감이다. Zoom/Pan, 보정, 재생, 주석, 이미지 저장, DICOM/PACS는 이번 단계에서 시작하지 않았다.
