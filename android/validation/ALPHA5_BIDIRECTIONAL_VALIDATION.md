# Android 0.2.0-alpha.5 양방향 탐색 검증 계약

이 문서는 Alpha 4 사용자 평가에서 확인된 역방향·직접 이동 병목과 Alpha 5 검증 경계를 기록한다. 실제 사용자 영상, 파일명, URI, 경로 또는 source hash는 기록하지 않는다.

## Alpha 4 고정 기준선

Alpha 4의 고정 runtime source/input tree와 manifest를 사용해 S24 Ultra에서 측정한 source-equivalent 기준선이다. reverse benchmark 앱은 보존 debug APK와 byte-identical하다고 주장하지 않는다. 원본 보고서는 저장소 밖 read-only 보존 디렉터리에 유지한다.

| 항목 | 결과 |
| --- | --- |
| reverse -1 | 125 publications / 30.501 s = 4.098 fps, 최대 간격 550.645 ms |
| reverse -5 | 122 publications / 30.369 s = 4.017 fps, 최대 간격 488.934 ms |
| random 250 targets | p50 167.000 ms, p95 1130.004 ms, max 2194.244 ms |
| cache/history | p50 5.281 ms, p95 8.404 ms, max 30.315 ms |
| ahead of cursor | p50 428.976 ms, p95 2095.872 ms, max 2194.244 ms |
| same GOP | p50 258.664 ms, p95 1379.761 ms, max 1928.850 ms |
| adjacent GOP | p50 82.020 ms, p95 106.980 ms, max 133.051 ms |
| far random | p50 310.055 ms, p95 1280.723 ms, max 1653.975 ms |

random percentile은 보존 raw target 250개의 `acceptedToPublicationUs`를 nearest-rank로 다시 계산했다. random summary SHA-256은 `5829311f14dbfeb0235fe5e511702c4ca161408ff1d260c41c6e668a9e14bab8`, raw report SHA-256은 `8c9c1390bde85b4a5aebc1732acbaed78639c76d69967fa573a12891fc8feb7f`, reverse PASS summary SHA-256은 `19e87bd448d898b82b4d264ec8b0e2d8a2ad1cc469016e1eb9583b67d77af442`다. 반복 seek/flush와 이전 sync sample부터 목표까지의 순방향 decode가 주 병목이었고, decoded output 수와 publication latency의 상관계수는 전체 0.99124였다. texture/cache 비용은 상대적으로 작았다. reverse와 random은 source-equivalent timing 증거이며 성능 PASS를 소급 주장하지 않는다.

## Alpha 5 구조

- hold cadence는 같은 stride의 forward/reverse에 동일하게 적용한다.
- 선택 cadence는 stride 1에서 15 publications/s, stride 5에서 12 publications/s다.
- foreground exact decode는 최대 8개의 nonblocking input과 ready output을 batch로 처리하며 target-only render 계약은 유지한다.
- 64 MiB cache hard cap 안에서 최근 canonical texture를 backward history로 유지한다.
- reverse miss는 이전 sync부터 target window를 한 번에 만들고, READY 이후 exact target만 역순으로 게시한다.
- rolling refill은 foreground 요청에 양보하되 같은 gesture의 완성된 exact texture와 decoder 진행을 보존한다.
- direct/timeline seek는 no-op, cache, history, reverse window, sequential ahead, same GOP, previous sync 순서로 exact 비용을 비교한다.
- 근사 프레임과 software decoder fallback은 허용하지 않는다.
- dual decoder는 single-decoder 결과가 기준을 충족하지 못하고 S24 end-to-end A/B와 10분 자원 회수에서 합격할 때만 검토한다.
- Direction Gate가 의도적으로 만든 Surface 교체와 lifecycle stop은 in-flight reverse window를 각각 한 번 안전 폐기해야 한다. 두 결과는 `EXPECTED_SUPERSEDED`와 `reverse-window-build` 단계로 증명하며, stale-before-swap·오래된 publication·swap·surface·publication invariant 위반은 계속 0이어야 한다.

## 선택적 dual decoder A/B

숨은 instrumentation-only Activity로 S24 Ultra에서 H.264와 HEVC hardware decoder를 각각 3 cycle 동시 생성·정확 디코드·해제했다. long-GOP 3 cycle의 fresh single previous-sync 중앙값 540.172 ms와 prepared lag-lane same-GOP cursor 중앙값 59.907 ms를 비교해 88.91% 감소를 측정했다. exact mismatch와 write-open은 0, release event 12개는 모두 완료됐고 advertised max instances는 16이었다.

이 결과는 co-resident hardware decoder와 겹치는 outstanding request의 가능성 증거일 뿐 codec 내부 물리 실행 겹침, 제품 전체 reverse/random p95, 10분 자원 회수 또는 사용자 체감 합격을 뜻하지 않는다. 따라서 dual decoder 코드는 제품 runtime에 채택하지 않는다.

## 동일 아티팩트 경계

최종 runtime source SHA `R`, harness source SHA `H`, runtime input tree `T`, APK 4개의 SHA-256은 저장소 밖 artifact manifest revision 3에 고정한다. A–H runner는 manifest 자체 SHA-256까지 입력받고, build나 assemble을 실행하지 않는다. A–G 완료 후 tracked evidence commit을 만들면 `H`가 바뀌므로 금지한다. 실제 결과는 read-only 외부 evidence와 stacked Draft PR 본문에 기록한다.

`PreflightOnly`와 실제 실행 checkpoint는 서로 다른 resume domain으로 취급하며, domain이 다른 session·stage·summary는 fail-closed로 거부한다. 사전점검과 실제 실행은 별도 외부 출력 디렉터리를 사용한다.

- `R`: `dabf11fa103179c4d81fe4448aba84ac340cf230`
- `T`: `612d695e4c9b57d4e4fb10076879bcb9b306d034ff05ba67ad7706c0f22c12e8`
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

A–G의 hard correctness가 하나라도 실패하면 다음 단계는 실행하지 않는다. 수치 성능 미달은 `PERFORMANCE_MISS`로 보존하되 후속 correctness·resource 증거 수집은 계속한다. H는 자동 PASS로 처리하지 않는다.

## 승인된 성능 합격선

- reverse -1은 12 publications/s 이상, -5는 10 publications/s 이상이어야 한다.
- 같은 stride의 forward/reverse 처리량 차이는 25% 이하여야 한다.
- requested/displayed raw lag는 -1에서 최대 1 frame, -5에서 최대 5 frames이며 p95도 같은 한도를 지켜야 한다.
- warm-up 이후 250 ms 초과 reverse refill stall은 0이어야 한다.
- random 전체 p95는 Alpha 4의 동일 target set보다 30% 이상 개선되고 max는 Alpha 4보다 악화되지 않아야 한다.
- random cache/history p95는 16 ms 이하, same-GOP p95는 150 ms 이하, far p95는 300 ms 이하여야 한다.

이 값은 평균으로 대체하지 않으며 하나라도 미달하면 해당 성능 Gate는 `PERFORMANCE_MISS`다. 정확성 실패는 성능 실행보다 우선하며 후속 단계 중단 조건도 정확성·identity·privacy·trace·cache 같은 hard contract 실패로 한정한다.
