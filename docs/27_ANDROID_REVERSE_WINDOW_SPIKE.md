# Android ReverseWindowEngine 설계 스파이크

## 결론

Android `0.2.0-alpha.4`의 기본 reverse cache miss는 기존 ExactSeekEngine을 유지한다. 검증되지 않은 reverse 최적화는 제품 경로에서 활성화하지 않는다. ForwardSequentialEngine의 정확성과 성능이 S24 Ultra에서 통과한 뒤 별도 spike로 구현한다.

## 목표와 비목표

- 목표: 이전 sync부터 한 번 순방향 decode한 결과를 작은 reverse window로 소비해 반복 seek/flush를 줄인다.
- 비목표: 전체 파일 reverse cache, cache budget 증량, FPS 기반 frame 계산, exact fallback 삭제.

## 후보 흐름

1. 요청 FrameKey보다 앞선 sync sample로 ExactSeekEngine과 동일하게 이동한다.
2. sync부터 target까지 PTS와 duplicate ordinal을 대조하며 순방향 decode한다.
3. 최근 N개의 정확한 target texture만 보존한다.
4. `-1`은 window의 인접 frame을 역순으로 소비한다.
5. `-5`는 5 frame 간격 target만 보존하고 나머지는 `render=false`로 폐기한다.
6. 현재 window를 소비하는 동안 이전 sync 구간을 준비할 수 있는지는 foreground 우선권과 texture budget을 침해하지 않는다는 trace 근거가 있을 때만 후속 실험한다.

## 64 MiB 한계

Canonical RGBA8와 게시·target·renderer/codec 여유 4 frame을 그대로 적용한다.

| 해상도 | frame bytes | 준비 가능한 reverse target |
| --- | ---: | ---: |
| 1280×720 | 3,686,400 | 최대 12 |
| 1920×1080 | 8,294,400 | 최대 4 |
| 2560×1440 이상 | 14,745,600 이상 | 0일 수 있음 |

현재 게시 texture와 foreground target은 항상 보호한다. window 준비 때문에 64 MiB hard cap을 올리지 않는다.

## 즉시 ExactSeekEngine으로 fallback하는 조건

- cache miss이고 준비된 reverse window가 없음
- FrameKey, PTS, duplicate ordinal 불일치
- file/surface generation 변경 또는 진행 중 준비 작업의 예상 request generation 불일치. 정상적인 다음 reverse 요청의 generation 증가는 window 자체를 무효화하지 않는다.
- output format 변경, codec error, EOS 또는 timeout
- 방향 재반전이나 window 범위를 벗어난 임의 seek
- cache admission 실패, stale result 또는 swap 실패

## 무효화와 수명

파일 전환, Surface 소실, lifecycle stop, cancel, codec recreate 시 window와 관련 GL texture를 exact-once로 모두 해제한다. 이전 generation의 준비 작업은 texture를 소비하되 cache 또는 화면에 게시하지 않는다.

## 검증 전제

- 기존 17 fixture와 대표 7 fixture exact mismatch 0
- `-1/-5` first/middle/last, GOP 경계, duplicate PTS, VFR 전부 일치
- stale/swap/surface/invariant violation 0
- cache cap과 double release 0
- S24에서 기존 exact fallback 대비 interval, decoded frame, memory를 측정하되 근거 없는 절대 SLA를 만들지 않음
