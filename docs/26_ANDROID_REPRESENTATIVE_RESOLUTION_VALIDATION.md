# Android 대표 해상도·64 MiB 검증

## 결론

Android `0.2.0-alpha.3`은 새 제품 기능을 추가하는 단계가 아니라, 720p/1080p 합성 영상에서 정확 프레임·64 MiB cache 압박·탐색 부드러움·자원 수명을 분리 검증하는 내부판이다. 측정 앱 코드 SHA `5887a54b11775770f7005a0ec96320283a402010`으로 S24 Ultra exact/cache/background와 대표 Macrobenchmark를 완료했다. 정확성은 PASS지만 연속 탐색 게시 속도는 4.299~6.632 fps여서 완전히 부드럽다고 판정하지 않는다. 15분 memory plateau는 `INCONCLUSIVE`, 장기 codec/lifecycle/idle과 USB 분리 배터리는 `Pending`이다.

실제 사용자 파일, DICOM/PACS, AI, cloud, Zoom/Pan, 필터, 주석, 비교 보기, PNG export와 Play 배포는 이 단계에 포함하지 않는다.

## 버전과 런타임 변경

- versionName: `0.2.0-alpha.3`
- versionCode: `4`
- install ID: `com.snowberried.ctcinereviewer.internal`
- runtime 변경: 활성 방향 탐색에만 허용되는 speculative prefetch permit, 64 MiB cache hard cap, cache/GL texture 수명 계측
- 배포 상태: 로컬 검증 전용. Android tag, GitHub Release, PR과 원격 branch를 만들지 않는다.

## 대표 해상도 fixture

`android/testdata/representative-resolution/manifest.lock.json`은 다음 비식별 합성 fixture 7개의 불변 identity와 provenance를 기록한다.

| fixture | 표시 해상도 | codec/profile | frame |
| --- | ---: | --- | ---: |
| 720p H.264 B-frame | 1280×720 | H.264 Main 8-bit | 360 |
| 1080p H.264 B-frame | 1920×1080 | H.264 Main 8-bit | 360 |
| 1080p H.264 long-GOP | 1920×1080 | H.264 Main 8-bit | 360 |
| 1080p HEVC | 1920×1080 | HEVC Main 8-bit | 360 |
| 1080p VFR | 1920×1080 | H.264 Main 8-bit | 360 |
| switch A | 1920×1080 | H.264 Main 8-bit | 360 |
| switch B | 1920×1080 | HEVC Main 8-bit | 360 |

1080p bitstream의 coded raster는 1920×1088이고 inclusive crop `0,0–1919,1079`로 canonical 1920×1080을 만든다. 모든 frame은 기존 embedded 16-bit ID, CRC-8/0x07, finder pattern과 16×16 정수 box-average signature를 가진다.

MP4와 전체 golden JSON은 Git에 넣지 않는다. ignored `android/.generated/testdata/representative-resolution/`에서만 유지하고 exact cache key와 SHA-256으로 복원한다. 일반 CI는 lock만 검사하고, S24 exact job은 exact cache miss 시 자동 재인코딩하지 않고 Pending으로 중단한다. GitHub Release는 fixture 저장소로 사용하지 않는다. 모든 fixture는 container와 bitstream에 BT.709 primaries/transfer/matrix, limited range를 명시하며 golden RGB도 같은 계약으로 만든다.

- MP4 합계: `158,745,420 bytes`
- golden JSON 합계: `6,407,765 bytes`
- generator SHA-256: `98d36d7449ec2f790b90e09118da217113f27fd53d45cec095fdda90286ebbcc`
- artifact set SHA-256: `ada531a0ccebaafebe49accb3065bebc7c3d2cea31e7b669a5e6975420d4dafb`
- exact cache key: `ccr-representative-resolution-v1-ada531a0ccebaafebe49accb3065bebc7c3d2cea31e7b669a5e6975420d4dafb`

## exact subset 계약

fixture마다 first/last, 모든 sync GOP, B-frame reorder 경계, 실제 VFR cadence 변화, deterministic random 50, 연속 ±1 30, ±5 sequence와 duplicate PTS 전체를 검사한다. 판정값은 다음과 같다.

- displayFrameIndex, ptsUs, duplicateOrdinal, sampleOrdinal
- SurfaceTexture timestamp와 expected PTS
- embedded frame ID/CRC
- signature tolerance: MAE ≤6, p99 ≤16, max ≤40
- hardware codec component, write-open 0
- stale/swap/surface/publication invariant violation 0

기존 17-fixture exact Gate는 별도 hard gate로 계속 유지한다.

### S24 Ultra exact 결과

- 기기: Samsung `SM-S928N`, Android 16/API 36, build `BP4A.251205.006`/firmware `S928NKSS6DZF3`, 보안 패치 `2026-06-05`, 1440×3120/최대 120 Hz
- 기존 Gate: 17 fixture, 236 frame PASS
- 대표 Gate: 7 fixture, 선택 frame 2,017개, mismatch 0, write-open 0, full-frame readback 3,314
- codec: `c2.qti.avc.decoder`, `c2.qti.hevc.decoder`, hardware accelerated
- decoded color: BT.709/limited/SDR (`MediaFormat` 1/2/3)
- frame key, PTS, texture timestamp, embedded ID, signature, stale/swap/publication invariant 위반 0

최초 실측에서는 색 메타데이터가 없는 HD fixture의 FFmpeg golden이 BT.601로 계산되고 S24 Surface가 BT.709로 출력해 frame 0 signature MAE 7.53125가 발생했다. frame identity·PTS·embedded ID는 모두 맞았고, BT.709 비교의 독립 MAE 7.552083으로 색 계약 불일치를 확인했다. fixture와 golden을 BT.709 limited로 고정한 뒤 전체 exact Gate가 통과했다.

## 64 MiB cache와 prefetch

제품 cache budget은 `min(64 MiB, Java max heap/4)`이다. canonical RGBA frame과 게시·목표·renderer/codec 여유 4프레임을 반영한 effective prefetch limit은 다음과 같다.

| canonical frame | 기대 limit |
| --- | ---: |
| 1280×720 RGBA8 | 12 |
| 1920×1080 RGBA8 | 4 |
| 2560×1440 RGBA8 | 0 |

현재 게시 texture와 foreground 목표는 보호한다. cache는 byte budget을 넘지 않으며 방향 반대편의 먼 항목부터 제거한다. 파일 generation 변경과 Surface 폐기 때 GL texture를 해제하고 allocation ID로 double-release 0을 검증한다. cache entry/bytes, peak, eviction, rejection, immediate thrash와 texture created/released/live/peak를 비식별 diagnostics에 기록한다.

prefetch permit은 ±1/±5의 실제 입력 방향과 500 ms absolute deadline을 보존한다. 최초 열기·복원·처음/마지막·직접 입력·timeline은 permit을 열지 않는다. background, 취소, 파일 전환, Surface 소실과 방향 전환은 permit epoch를 즉시 무효화한다. foreground request가 항상 speculative work를 선점한다.

### S24 Ultra cache 결과

- budget: 67,108,864 bytes; peak: 66,355,200 bytes; peak entry: 8
- effective prefetch limit: 720p 12, 1080p 4
- eviction 384, rejection 0, immediate thrash/prefetch-evicted-before-use 241
- foreground decoded 144, total decoded 3,492, direction reversal cancellation delta 26
- texture live 6/peak 9, double-release 0, stale 0, swap failure 0

64 MiB hard cap과 수명 invariant는 통과했다. thrash 241은 실패 기준이 아니라 관찰값이며, 향후 prefetch 효율 개선 대상으로 남긴다.

background 회귀는 3회 반복 통과했다. 최초 open에서는 speculative prefetch started/completed가 0이었고, `ON_STOP` 뒤 completed가 증가하지 않았으며, 입력 없는 resume에서도 started/completed가 증가하지 않았다. resume 뒤 첫 방향 입력에서만 prefetch가 다시 시작됐다.

## smoothness 측정

internalBenchmark에서만 JankStats를 사용하며 URI, 파일명, 경로와 hash를 기록하거나 업로드하지 않는다. 다음 8개 제품 경로 시나리오를 측정한다.

- 720p +1/+5 hold 각 60초
- 1080p +1/+5 hold 각 60초
- 1080p 방향 반전, distant seek
- 1080p H.264→HEVC, HEVC→H.264

fixture가 360 frame이므로 60초 hold는 segmented 방식이다. 경계 재배치 구간을 active window와 interval 통계에서 제외하며 단일 연속 hold로 표현하지 않는다.

기록값은 successful PublicationEvent interval p50/p95/max, published fps, requested-displayed lag p50/p95/max, active window의 최대 gap, foreground decoded frame, coalesced request, prefetch hit/cancel/waste, 전체 cache eviction, swap failure와 JankStats count/ratio다. 절대 성능 합격선은 두지 않는다.

### S24 Ultra Macrobenchmark 결과

각 시나리오는 3회 실행했고 24개 Perfetto trace를 파싱했다. 표는 3회 중앙 실행값이다.

| 시나리오 | interval p50/p95/max ms | published fps | lag p50/p95/max frame | issued/coalesced | Jank count/ratio | swap failure |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 720p +1 | 150.3 / 350.8 / 416.8 | 5.662 | 6 / 12 / 15 | 1172 / 823 | 10 / 0.687% | 0 |
| 720p +5 | 125.0 / 339.5 / 427.6 | 6.632 | 30 / 55 / 70 | 1156 / 720 | 27 / 1.790% | 0 |
| 1080p +1 | 188.9 / 418.5 / 519.5 | 4.529 | 8 / 14 / 18 | 1170 / 881 | 12 / 0.853% | 0 |
| 1080p +5 | 217.0 / 443.1 / 531.4 | 4.299 | 35 / 70 / 95 | 1158 / 835 | 30 / 2.155% | 0 |
| 1080p reverse | 165.7 / 420.9 / 565.9 | 5.593 | 7 / 13 / 17 | 585 / 411 | 3 / 0.422% | 0 |

distant seek는 게시가 한 번뿐이므로 interval 0은 성능값으로 해석하지 않는다. H.264→HEVC 전환은 3/3 trace에서 custom counter가 있었고 HEVC→H.264는 Macrobenchmark 자체 3/3 성공이지만 custom counter는 2/3만 기록되어 해당 방향의 중앙 counter 수치는 참고값이다. 모든 counter-bearing trace의 swap failure는 0이다.

입력은 50 ms마다 발생하지만 실제 게시가 4.299~6.632 fps이고 coalescing/lag가 관찰됐다. 따라서 사용자가 본 `1, 4, 5, 6, 8...` 형태의 requested/displayed 차이는 단순한 느낌이 아니라 최신 요청 합치기와 디코드 처리량의 결과다. 정확성 오류는 없지만 부드러움 개선 여지는 남아 있다.

## 분리 내구성과 배터리

- 1080p 단일 파일 cache pressure: 15분, 5초 간격 Java/native/PSS/graphics-PSS proxy/cache/texture/thermal 기록
- H.264↔HEVC: 500회, codec/surface/EGL/texture recovery 기록
- lifecycle: rotation 100, home/resume 100 이상, Surface detach/reattach, screen off/on 30
- idle: 한 frame 표시 후 10분 동안 decode/prefetch/publication 증가 0

memory plateau는 sample 분석 전 `INCONCLUSIVE`이며 무조건 PASS로 올리지 않는다. graphics PSS는 실제 GPU allocation byte가 아니라 Android memory summary proxy임을 명시한다.

### S24 Ultra 자원 결과

- 단일 1080p 15분: 175 samples, 3,012 operations, thermal status 전 구간 0
- Java used: first 22,842,032 / p50 16,110,080 / max 28,692,992 / last 24,572,416 bytes
- native heap: first 14,479,312 / p50 15,308,688 / max 15,985,472 / last 15,983,104 bytes
- PSS: first 222,696 / p50 274,535 / max 321,192 / last 288,299 KiB
- graphics PSS proxy: first 115,084 / p50 196,852 / max 208,316 / last 208,188 KiB
- cache peak 66,355,200 / budget 67,108,864 bytes, texture live 8/peak 9, double-release/stale/swap failure 0

cap 위반이나 자원 폭증은 보이지 않았지만 마지막 절반과 마지막 1/3의 일부 기울기가 양수라 plateau를 입증하지 못했다. 판정은 `INCONCLUSIVE`다. 500회 codec switch는 사용자의 휴대폰 사용 시한에 맞춰 안전 지점에서 중단했고, 추가 lifecycle 내구와 10분 idle은 실행하지 않았다. 세 항목 모두 `Pending`이다. 테스트 APK와 trace processor를 제거하고 stay-awake를 원상 복구했다.

배터리 검증은 수동 2단계다. 밝기와 refresh rate를 기록하고 시작 배터리 80~90%에서 USB를 분리한 뒤 1080p idle 또는 ±1/±5 탐색을 30분 수행한다. 시작/종료 battery, 매 sample charging/USB, thermal, operation, codec/prefetch activity를 기록한다. USB 연결 또는 충전 상태면 `NOT_EVALUABLE`이며 drain PASS 기준은 두지 않는다.

## 성능 기준선 정책

정확성 오류는 항상 0이어야 한다. 성능 회귀는 대표 해상도 측정이 실제 S24 Ultra에서 완료된 뒤 동일 기기·동일 조건 반복 실행 중앙값의 p95 상대 변화로만 제안한다. thermal throttling 실행은 별도로 표시하며 근거 없는 절대 SLA를 만들지 않는다.

## 현재 검증 상태

| 항목 | 상태 |
| --- | --- |
| desktop 106 tests/build/package | PASS |
| 기존 17 fixture verifier | PASS |
| 대표 7 fixture full SHA/schema verifier | PASS |
| source/privacy contract | PASS |
| Android JVM tests | PASS — 65/65, failure/error/skip 0 |
| Android Lint | PASS |
| Debug/AndroidTest/Benchmark/Macrobenchmark assemble | PASS |
| Debug·Benchmark APK privacy | PASS — forbidden permission 0 |
| PowerShell validation script syntax | PASS |
| 기존 17 fixture S24 exact Gate | PASS — 17 fixture, 236 frame |
| 대표 해상도 S24 exact | PASS — 7 fixture, selected 2,017, mismatch 0 |
| 대표 해상도 cache | PASS — 64 MiB cap/invariant, 효율은 관찰값 |
| 대표 해상도 smoothness | 측정 완료 — 8 scenario×3, 절대 합격선 없음 |
| background prefetch | PASS — 회귀 suite 3회 |
| 단일 파일 memory | `INCONCLUSIVE` — 15분/175 sample |
| codec 500회/lifecycle 추가 내구/idle 10분 | Pending — codec 안전 중단, 나머지 미실행 |
| battery | `NOT_EVALUABLE` — USB 연결, unplugged run Pending |
| 실제 사용자 파일 | Pending |

S24 실측 report에는 비식별 기기 모델·빌드·보안 패치·화면 mode, app/fixture SHA, hardware codec component와 위 계측값만 기록한다. 실제 영상·URI·파일명·로컬 경로·ADB serial은 기록하지 않는다.
