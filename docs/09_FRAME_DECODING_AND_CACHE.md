# Frame Decoding and Cache

## Phase 1C 결론

Phase 2 최소 뷰어의 기본안은 **FFmpeg stdout RGBA rawvideo + 61프레임 RAM 구간 캐시**로 결정한다.

- 캐시 범위: 현재 기준 뒤 20, 현재 1, 앞 40프레임
- cache hit p95: 모든 샘플에서 0.003ms 미만
- cache miss p95: 365.9~418.3ms
- 먼 frame seek: 312.4~365.9ms
- first frame: 240.9~273.4ms
- 캐시 메모리: 약 68MiB
- frame/PTS 대응 오류: 0건
- 픽셀 fingerprint 불일치: 0건
- 취소 응답: 27.4~31.9ms

181프레임 초기 가설은 약 202MiB를 사용하고 miss p95가 952~1,217ms여서 기본안에서 제외한다.

## 프레임 전달 방식

### 선택: stdout rawvideo pipe

- 한 FFmpeg process가 요청 구간을 presentation order로 RGBA rawvideo에 출력한다.
- 프레임 크기 `width × height × 4`로 stdout을 정확히 분할한다.
- ffprobe의 frameIndex/PTS 배열과 같은 순서로 descriptor를 결합한다.
- `-ss` accurate seek 후 구간 단위로 1회 실행하며 프레임마다 process를 만들지 않는다.
- SHA-256 픽셀 fingerprint를 전체 framehash baseline과 비교한다.

장점은 디스크에 환자 프레임을 남기지 않고 Canvas/ImageData와 직접 호환되며, adapter 내부 Buffer를 공통 모델에 노출하지 않는다는 점이다.

### 비교 후 제외한 방식

| 방식 | 판단 |
| --- | --- |
| 임시 PNG 전체 캐시 | frame hit 파일 읽기는 빠르지만 준비 3.7~22초, 132~761MiB 디스크와 잔여 민감정보 위험 때문에 기본안 제외 |
| 장기 실행 FFmpeg stream | 순차 전진에는 유리하지만 임의 seek·역방향·취소·세션 전환 protocol이 복잡해 Phase 1C 기본안에서 제외 |
| 프레임별 FFmpeg process | process 생성 비용과 반복 seek 비용 때문에 제외 |
| 전체 framehash | 프레임 전달 방식은 아니며 presentation order와 fingerprint baseline 검증에만 사용 |

저해상도 preview 캐시는 현재 full-resolution 구간 캐시가 목표를 충족했고 작은 구조를 놓칠 수 있어 구현하지 않았다.

## 픽셀 포맷

RGBA 8-bit, 프레임당 4 bytes/pixel을 선택했다.

- grayscale 강제 변환으로 PACS overlay나 색상 정보를 잃지 않는다.
- RGB24보다 메모리는 33% 크지만 Canvas `ImageData`에 추가 변환 없이 전달한다.
- BGRA보다 브라우저 표시 전 channel swap이 필요 없다.
- Sample 영상 한 프레임은 1,169,280 bytes다.

1,169,280-byte Uint8Array를 실제 Electron IPC로 30회 왕복한 결과 p50 약 3.1ms, p95 약 3.4ms, 최대 약 5.4ms였다. 현재 샘플 크기에서는 IPC가 50ms 목표의 병목이 아니었다.

## 비식별 샘플군

Phase 1C 시작 시 `local-samples/` 후보를 ffprobe 정보만으로 분류하고 로컬 별칭을 사용했다.

| 샘플 | 역할 | 길이 | 프레임 | 해상도·코덱 |
| --- | --- | ---: | ---: | --- |
| Sample A | Representative | 119.958초 | 2,879 | 406×720 H.264 |
| Sample B | Representative | 106.667초 | 2,560 | 406×720 H.264 |
| Sample C | Short | 21.583초 | 518 | 406×720 H.264 |

원래 파일명과 전체 경로는 로그와 문서에 기록하지 않았다. 프레임 이미지와 raw cache도 저장소에 포함하지 않았다.

## 정확성 검증

- 전체 RGBA framehash 수와 ffprobe frame entry 수가 세 샘플 모두 일치했다.
- framehash와 ffprobe PTS를 각각 time base로 초 단위 정규화한 결과 불일치 0건이었다.
- first, last, 임의 중간, keyframe 직전·직후, cache 안팎 이전 프레임을 fingerprint로 비교했다.
- 100프레임 순방향, 역방향, 앞뒤 교대와 동일 index 반복 요청에서 fingerprint 오류 0건이었다.
- synthetic H.264와 B-frame MPEG-4 영상에서도 decode 수와 presentation order가 일치했다.
- request coordinator의 coalescing, session generation, stale result 폐기를 자동 테스트했다.

fingerprint 값 자체는 환자 영상과 연결될 필요가 없으므로 문서에 기록하지 않았다.

## 전략별 실측

### 전체 raw RAM 캐시

| 샘플 | 예상/실제 raw 크기 | 전체 준비 | 판단 |
| --- | ---: | ---: | --- |
| Sample A | 약 3,210MiB 예상 | 안전 한도로 미실행 | 제외 |
| Sample B | 약 2,855MiB 예상 | 안전 한도로 미실행 | 제외 |
| Sample C | 578MiB raw, RSS 약 638MiB | 약 2.12초 | 짧은 영상에도 과도함 |

### 전체 PNG 디스크 캐시

| 샘플 | 첫 파일 | 전체 준비 | 디스크 | 정리 |
| --- | ---: | ---: | ---: | ---: |
| Sample A | 185ms | 22.04초 | 760.7MiB | 2.94초 |
| Sample B | 183ms | 20.93초 | 639.4MiB | 2.18초 |
| Sample C | 154ms | 3.70초 | 132.2MiB | 0.22초 |

임시 캐시는 OS temp 아래 무작위 CCR session 폴더를 사용했고 측정 직후 삭제했다. 정상 흐름에서는 잔여 파일이 없음을 확인했다.

### RAM 구간 캐시 비교

| 샘플 | 181-frame miss p95 | 61-frame miss p95 | 61-frame far seek | 정확성 오류 |
| --- | ---: | ---: | ---: | ---: |
| Sample A | 1,216.8ms | 418.3ms | 312.4ms | 0 |
| Sample B | 952.2ms | 377.9ms | 346.7ms | 0 |
| Sample C | 957.4ms | 365.9ms | 365.9ms | 0 |

61-frame 캐시에서 순방향 100프레임은 약 665~690ms, 역방향 100프레임은 약 1.28~1.36초였다. 고정 20-back/40-forward 범위이므로 역방향에서 miss가 더 많다. Phase 2에서는 이동 방향에 따라 back/forward 비율을 뒤집는 방식을 별도 측정한 뒤 적용한다.

## 혼합형 판단

현재는 구현하지 않는다.

- 61-frame RAM 캐시가 first frame, hit, miss, far seek와 메모리 목표를 충족했다.
- 먼 PNG 캐시는 디스크 비용과 민감정보 잔존 위험이 이득보다 컸다.
- 혼합형은 실제 사용에서 반복되는 장거리 왕복 패턴이 확인될 때 다시 검토한다.

## 구현 경계

공통 영역:

- `FrameRequest`, `DecodedFrameDescriptor`, `FrameDecodeResult`, `FrameCacheStatus`
- `VideoFrameProvider<TPayload>`
- request coalescing과 stale result 거부

Electron adapter 영역:

- FFmpeg 인자, child process, Node Buffer와 파일 경로
- rawvideo chunk 분리와 SHA-256
- 실제 RAM cache와 IPC serialization

모바일에서는 공통 의미와 coordinator를 재사용하고 FFmpeg CLI decoder, Buffer cache와 IPC를 플랫폼 decoder·메모리 객체로 교체한다.

## Phase 2 진입 조건

Phase 2 최소 뷰어 진입을 권고한다. 단 다음은 제품 기능이 아니라 최소 뷰어 구현 중 계속 검증한다.

- 이동 방향별 20/40 cache 비율 전환
- 실제 Electron 창에서 빠른 wheel 입력과 Canvas draw 포함 end-to-end latency
- 8~16GiB RAM PC에서 68MiB cache 상한 유지
- 비정상 종료 뒤 OS temp CCR 잔여 cache 정리

재생, 보정, 주석, 이미지 저장, DICOM과 PACS는 계속 별도 승인 범위다.
