# Android 대표 해상도·64 MiB 검증

## 결론

Android `0.2.0-alpha.3`은 새 제품 기능을 추가하는 단계가 아니라, 720p/1080p 합성 영상에서 정확 프레임·64 MiB cache 압박·탐색 부드러움·자원 수명을 분리 검증하는 내부판이다. 기존 256×144 Gate 3 결과는 정확성 기준선으로 유지하지만 720p/1080p 성능 근거로 재사용하지 않는다.

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

MP4와 전체 golden JSON 약 155 MiB는 Git에 넣지 않는다. ignored `android/.generated/testdata/representative-resolution/`에서만 유지하고 exact cache key와 SHA-256으로 복원한다. 일반 CI는 lock만 검사하고, S24 exact job은 exact cache miss 시 자동 재인코딩하지 않고 Pending으로 중단한다. GitHub Release는 fixture 저장소로 사용하지 않는다.

- MP4 합계: `155,637,771 bytes`
- golden JSON 합계: `6,409,366 bytes`
- artifact set SHA-256: `afca46737a71b0f8d837fd1cd86fc466be4c27bde96b744b02c249af010004fc`
- exact cache key: `ccr-representative-resolution-v1-afca46737a71b0f8d837fd1cd86fc466be4c27bde96b744b02c249af010004fc`

## exact subset 계약

fixture마다 first/last, 모든 sync GOP, B-frame reorder 경계, 실제 VFR cadence 변화, deterministic random 50, 연속 ±1 30, ±5 sequence와 duplicate PTS 전체를 검사한다. 판정값은 다음과 같다.

- displayFrameIndex, ptsUs, duplicateOrdinal, sampleOrdinal
- SurfaceTexture timestamp와 expected PTS
- embedded frame ID/CRC
- signature tolerance: MAE ≤6, p99 ≤16, max ≤40
- hardware codec component, write-open 0
- stale/swap/surface/publication invariant violation 0

기존 17-fixture exact Gate는 별도 hard gate로 계속 유지한다.

## 64 MiB cache와 prefetch

제품 cache budget은 `min(64 MiB, Java max heap/4)`이다. canonical RGBA frame과 게시·목표·renderer/codec 여유 4프레임을 반영한 effective prefetch limit은 다음과 같다.

| canonical frame | 기대 limit |
| --- | ---: |
| 1280×720 RGBA8 | 12 |
| 1920×1080 RGBA8 | 4 |
| 2560×1440 RGBA8 | 0 |

현재 게시 texture와 foreground 목표는 보호한다. cache는 byte budget을 넘지 않으며 방향 반대편의 먼 항목부터 제거한다. 파일 generation 변경과 Surface 폐기 때 GL texture를 해제하고 allocation ID로 double-release 0을 검증한다. cache entry/bytes, peak, eviction, rejection, immediate thrash와 texture created/released/live/peak를 비식별 diagnostics에 기록한다.

prefetch permit은 ±1/±5의 실제 입력 방향과 500 ms absolute deadline을 보존한다. 최초 열기·복원·처음/마지막·직접 입력·timeline은 permit을 열지 않는다. background, 취소, 파일 전환, Surface 소실과 방향 전환은 permit epoch를 즉시 무효화한다. foreground request가 항상 speculative work를 선점한다.

## smoothness 측정

internalBenchmark에서만 JankStats를 사용하며 URI, 파일명, 경로와 hash를 기록하거나 업로드하지 않는다. 다음 8개 제품 경로 시나리오를 측정한다.

- 720p +1/+5 hold 각 60초
- 1080p +1/+5 hold 각 60초
- 1080p 방향 반전, distant seek
- 1080p H.264→HEVC, HEVC→H.264

fixture가 360 frame이므로 60초 hold는 segmented 방식이다. 경계 재배치 구간을 active window와 interval 통계에서 제외하며 단일 연속 hold로 표현하지 않는다.

기록값은 successful PublicationEvent interval p50/p95/max, published fps, requested-displayed lag p50/p95/max, active window의 최대 gap, foreground decoded frame, coalesced request, prefetch hit/cancel/waste, 전체 cache eviction, swap failure와 JankStats count/ratio다. 절대 성능 합격선은 두지 않는다.

## 분리 내구성과 배터리

- 1080p 단일 파일 cache pressure: 15분, 5초 간격 Java/native/PSS/graphics-PSS proxy/cache/texture/thermal 기록
- H.264↔HEVC: 500회, codec/surface/EGL/texture recovery 기록
- lifecycle: rotation 100, home/resume 100 이상, Surface detach/reattach, screen off/on 30
- idle: 한 frame 표시 후 10분 동안 decode/prefetch/publication 증가 0

memory plateau는 sample 분석 전 `INCONCLUSIVE`이며 무조건 PASS로 올리지 않는다. graphics PSS는 실제 GPU allocation byte가 아니라 Android memory summary proxy임을 명시한다.

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
| 기존 17 fixture S24 exact Gate | Pending — 실기기 실행 대기 |
| 대표 해상도 S24 exact/cache/smoothness | Pending — 실기기 실행 대기 |
| memory/codec/lifecycle/idle | Pending — 실기기 실행 대기 |
| battery | `NOT_EVALUABLE` until unplugged manual run |
| 실제 사용자 파일 | Pending |

S24 실측 report에는 비식별 기기 모델·빌드·보안 패치·화면 mode, app/fixture SHA, hardware codec component와 위 계측값만 기록한다. 실제 영상·URI·파일명·로컬 경로·ADB serial은 기록하지 않는다.
