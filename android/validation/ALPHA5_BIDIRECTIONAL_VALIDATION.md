# Android 0.2.0-alpha.5 양방향 탐색 검증 계약

이 문서는 Alpha 4 사용자 평가에서 확인된 역방향·직접 이동 병목과 Alpha 5 검증 경계를 기록한다. 실제 사용자 영상, 파일명, URI, 경로 또는 source hash는 기록하지 않는다.

## Alpha 4 고정 기준선

Alpha 4의 보존된 APK와 manifest만 사용해 S24 Ultra에서 측정한 결과다. 원본 보고서는 저장소 밖 read-only 보존 디렉터리에 유지한다.

| 항목 | 결과 |
| --- | --- |
| reverse -1 | 121 publications / 30.726 s = 3.938 fps, 최대 간격 496.432 ms |
| reverse -5 | 116 publications / 30.486 s = 3.805 fps, 최대 간격 502.546 ms |
| random 250 targets | p50 173.015 ms, p95 1050.853 ms, max 2236.016 ms |
| cache/history | p50 5.416 ms, p95 7.782 ms, max 29.814 ms |
| same GOP | p50 255.767 ms, p95 1050.853 ms, max 1669.500 ms |
| adjacent GOP | p50 78.018 ms, p95 106.202 ms, max 136.786 ms |
| far random | p50 313.133 ms, p95 1416.548 ms, max 1640.147 ms |

반복 seek/flush와 이전 sync sample부터 목표까지의 순방향 decode가 주 병목이었다. decoded output 수와 latency의 상관계수는 0.9746이었다. texture/cache 비용은 상대적으로 작았다.

## Alpha 5 구조

- hold cadence는 같은 stride의 forward/reverse에 동일하게 적용한다.
- 선택 cadence는 stride 1에서 15 publications/s, stride 5에서 12 publications/s다.
- foreground exact decode는 최대 8개의 nonblocking input batch로 codec pipeline을 채우며 target-only render 계약은 유지한다.
- 64 MiB cache hard cap 안에서 최근 canonical texture를 backward history로 유지한다.
- reverse miss는 이전 sync부터 target window를 한 번에 만들고, READY 이후 exact target만 역순으로 게시한다.
- rolling refill은 foreground 요청에 양보하되 같은 gesture의 완성된 exact texture와 decoder 진행을 보존한다.
- direct/timeline seek는 no-op, cache, history, reverse window, sequential ahead, same GOP, previous sync 순서로 exact 비용을 비교한다.
- 근사 프레임과 software decoder fallback은 허용하지 않는다.
- dual decoder는 single-decoder 결과가 기준을 충족하지 못하고 S24 A/B에서 20% 이상 개선이 입증될 때만 검토한다.

## 동일 아티팩트 경계

최종 runtime source SHA `R`, harness source SHA `H`, runtime input tree `T`, APK 4개의 SHA-256은 저장소 밖 artifact manifest revision 3에 고정한다. A–H runner는 manifest 자체 SHA-256까지 입력받고, build나 assemble을 실행하지 않는다. A–G 완료 후 tracked evidence commit을 만들면 `H`가 바뀌므로 금지한다. 실제 결과는 read-only 외부 evidence와 stacked Draft PR 본문에 기록한다.

`PreflightOnly`와 실제 실행 checkpoint는 서로 다른 resume domain으로 취급하며, domain이 다른 session·stage·summary는 fail-closed로 거부한다. 사전점검과 실제 실행은 별도 외부 출력 디렉터리를 사용한다.

- `R`: `823c39504a1ddd8f0e457755ebff0d067d6dc863`
- `T`: `9689cadf140b54d0b93f67749e527fc8fab1392d0cd4117893ea91908f7530b3`
- `H`와 APK SHA-256: 최종 tracked 검증 하네스 커밋 뒤 외부 manifest에서 확정

## S24 순서

A. 17-fixture exactness  
B. representative 7-fixture exactness  
C. forward +1/+5 exactness와 각 3회 trace  
D. reverse -1/-5 exactness와 각 3회 trace  
E. 동일 deterministic target의 random exactness 후 timing  
F. direction/file/Surface generation 전환  
G. 10분 cache/resource  
H. 사용자 수동 확인

A–G의 hard correctness가 하나라도 실패하면 다음 단계는 실행하지 않는다. H는 자동 PASS로 처리하지 않는다.

## 승인된 성능 합격선

- reverse -1은 12 publications/s 이상, -5는 10 publications/s 이상이어야 한다.
- 같은 stride의 forward/reverse 처리량 차이는 25% 이하여야 한다.
- requested/displayed raw lag는 -1에서 최대 1 frame, -5에서 최대 5 frames이며 p95도 같은 한도를 지켜야 한다.
- warm-up 이후 250 ms 초과 reverse refill stall은 0이어야 한다.
- random 전체 p95는 Alpha 4의 동일 target set보다 30% 이상 개선되고 max는 Alpha 4보다 악화되지 않아야 한다.
- random cache/history p95는 16 ms 이하, same-GOP p95는 150 ms 이하, far p95는 300 ms 이하여야 한다.

이 값은 평균으로 대체하지 않으며 하나라도 미달하면 해당 성능 Gate는 FAIL이다. 정확성 실패는 성능 실행보다 우선한다.
