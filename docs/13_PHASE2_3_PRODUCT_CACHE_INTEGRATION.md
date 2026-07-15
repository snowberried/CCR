# Phase 2.3 Product Cache Integration

## 결론

Phase 2.2에서 검증한 전체 I420 RAM cache·제한 block LRU·WebGL2 표시를 Phase 2.3 제품 기본 경로로 통합했다. 기존 Phase 2.1 RGBA segment cache는 삭제하지 않고 `CCR_FORCE_RGBA=1` 긴급 rollback 경로로 유지한다.

- 제품 버전: `0.2.3-phase2.3`
- 기본 decoder mode: `i420-cache`
- 명시적 rollback mode: `rgba-rollback`
- Phase 2.2 승인 기준선: commit `4164225`, tag `phase-2.2-cache-spike-approved`
- 실제 11개 성능·정확성: 통과
- 제품 Electron UI·context loss·RGBA fallback: 통과
- 30분 제품 soak: 통과
- NSIS 설치본·실제 설치 검증: 통과

Zoom/Pan, 영상 보정, 자동 재생, 주석, 이미지 저장, DICOM/PACS는 시작하지 않았다.

## 통합 구조

| 계층 | 책임 |
| --- | --- |
| `src/domain` | I420 layout, block 크기, dynamic budget, 색 정책 |
| `src/application` | 제품 decoder mode 선택 의미 |
| `electron/adapters` | FFmpeg sequential/seek decode, packet index, block RAM storage |
| `electron/cache` | session lifecycle, full/LRU/fallback, IPC, generation/cancel |
| `src/ui` | WebGL2 BT.601 limited 표시와 RGBA fallback |

`src/domain`과 `src/application`에는 Electron, IPC, Node Buffer, FFmpeg, 파일 시스템, WebGL 타입이 없다. benchmark와 실제 sample 분석 스크립트는 제품 패키지에 포함하지 않는다.

## 제품 mode 선택

파일 open 순서는 quick probe → 첫 I420 frame → display policy와 memory policy 평가 → full/LRU/RGBA mode 선택이다.

### 전체 I420 cache

- 원본 pixel format이 `yuv420p`
- 색 정책이 명시적 BT.601 limited 또는 승인된 metadata 없는 H.264/yuv420p profile
- 예상 payload와 frame metadata가 budget의 80% 이내
- 최소 안전 budget 256MiB 이상

### 제한 block LRU

- I420/WebGL 조건은 충족하지만 전체 예상 payload가 budget의 80%를 초과
- background에서는 전체 영상을 끝까지 훑지 않고 RAM 예산에 들어가는 첫 window만 준비
- 현재 block과 이동 방향 앞쪽 8개 block을 후보로 보호하고 준비된 앞쪽 block이 4개 미만이면 최대 4개를 한 번에 미리 읽음
- 반대 방향으로 움직이면 선읽기 방향도 즉시 전환
- 방문 block은 soft cap까지 유지하며 현재·직전 이동 방향의 block보다 오래된 block부터 제거
- background와 seek가 같은 block을 요청하면 load를 병합
- pressure 축소 시 least-recently-used block부터 제거

### RGBA fallback

- `yuv420p`가 아닌 원본 pixel layout
- metadata 없는 H.264/yuv420p 이외의 새 공급원 profile
- BT.709, full range, 불명확하거나 충돌하는 matrix/primaries/transfer
- 안전 budget 256MiB 미만
- WebGL2 초기화·layout·shader 실패 또는 context loss
- 개발·긴급 rollback에서 `CCR_FORCE_RGBA=1`

fallback은 검증된 Phase 2.1 RGBA segment cache와 direction policy를 그대로 사용한다.

## 메모리 정책

자동 기본값은 다음과 같다.

```text
targetBudget = min(2GiB, totalRAM × 0.125, availableRAM × 0.25)
```

- 2GiB 선예약 없음
- 약 32MiB slab 목표로 점진 할당
- 406×720 실제 영상은 64-frame block
- 1080p는 10-frame block
- session close와 파일 변경에서 block 참조 해제
- 전체 RGBA cache와 frame 디스크 cache 없음

진단 패널은 실제 cache 사용량/budget, 준비된 frame 수, full·lru·fallback mode, 제거·재디코드·미리 읽기 횟수와 색 정책을 표시한다.

### v0.5.9 수동 RAM 상한

설정창은 감지한 전체 RAM에 따라 8GiB 미만은 자동만, 8/16/24/32GiB 구간부터 각각 2/4/6/8GiB까지 수동 상한을 제공한다. 수동 선택도 선예약하지 않으며 파일을 열 때 다음처럼 실제 상한을 다시 계산한다.

```text
manualBudget = min(selectedBudget, totalRAM × 0.25, availableRAM × 0.50)
```

최소 안전값 256MiB보다 작아지면 명시적 I420 상한을 사용하지 않고 기존 low-memory fallback으로 처리한다. 설정은 다음 파일부터 적용되며 정보 탭의 `RAM 설정`은 선택값, `메모리`는 실제 사용량과 적용 상한을 각각 표시한다.

## 2026-07-15 장시간·고해상도 LRU 보완

1280×720, 3,766-frame I420 영상의 raw payload는 약 4.85GiB라 2GiB soft cap 안에 전부 들어가지 않는다. 기존 LRU는 background에서 전체 영상을 한 번 훑으면서 앞부분 block을 제거했기 때문에, 첫 검토 중 이미 읽은 앞부분을 다시 디코딩하는 순간이 생겼다.

후속 보완은 다음처럼 cache 정책만 최소 변경했다.

- LRU background warmup을 전체 영상이 아니라 예산에 들어가는 block 수로 제한
- 현재 요청 위치와 실제 이동 방향을 관찰해 앞쪽 8개 block을 선읽기 후보로 사용
- 현재 block과 바로 앞 후보는 eviction 우선순위에서 보호
- foreground 요청과 같은 block의 선읽기가 겹치면 기존 `getOrLoad`로 한 번만 디코딩
- 2GiB soft cap, full mode, RGBA rollback, 프레임·PTS·표시 경로는 유지

이 변경은 순차 검토와 빠른 이동의 cache 경계 정지를 줄이기 위한 것이다. 준비 window와 선읽기 범위를 벗어난 직접 점프는 물리적으로 새 디코딩이 필요할 수 있다.

검증 결과는 전체 자동 테스트 100/100과 production build 통과다. 비식별 로컬 샘플 11개를 128MiB 강제 LRU로 실행했을 때 background eviction 0, 첫 frame miss 0, 첫 window 경계 hit 11/11, 경계 foreground seek decode 0, fingerprint 오류 0이었다.

### v0.5.8 5프레임 이동용 묶음 선읽기

v0.5.7 실사용에서 1프레임 연속 이동은 끊김이 없었지만 5프레임 연속 이동은 간헐적으로 멈췄다. 진단은 2,025MiB/2,048MiB, 1,536/3,766 frames 준비, prefetch process 175회, eviction 178회와 foreground seek decode 4회를 기록했다. 1280×720에서는 한 block이 24 frames이므로 5프레임 이동은 약 5번의 반복 입력만으로 다음 block에 도달했고, block마다 새 FFmpeg process를 시작하는 v0.5.7 선읽기가 네 차례 뒤처졌다.

v0.5.8은 다음처럼 처리량만 보완한다.

- 앞쪽 준비량이 4-block 미만일 때 8-block high-water 범위 안의 연속 block을 최대 4개 선택
- 선택한 최대 4-block을 FFmpeg 한 번으로 순차 decode해 process 시작·seek 비용을 분산
- batch의 모든 block을 in-flight로 먼저 등록하고 각 block 도착 즉시 cache에 넣어 foreground 중복 decode 차단
- 현재 batch가 끝나면 최신 요청 방향으로 전환하며 동시에 두 prefetch process를 실행하지 않음
- 보호 block을 제거하지 않는 범위에서만 batch 크기를 자동 축소해 2GiB cap 유지

묶음·방향 전환·foreground 병합과 메모리 제한을 포함한 전체 자동 테스트 102/102, production build와 비식별 로컬 샘플 11개 경계 검사를 통과했다. 1280×720 실제 5프레임 정·역방향 체감과 foreground seek decode 0 여부는 v0.5.8 설치본에서 재확인한다.

## 색상 정책

순수 domain policy는 다음만 WebGL2로 허용한다.

1. `color_range=tv|mpeg`, `color_space=smpte170m`, BT.709 충돌 metadata가 없는 명시적 BT.601 limited
2. 현재 실제 공급원과 같은 metadata 없는 H.264/yuv420p

두 번째는 `candidate-bt601-limited`로 진단에서 구분한다. HEVC·MPEG4·FFV1 metadata 없음은 임의로 BT.601로 일반화하지 않고 RGBA로 fallback한다.

WebGL2 shader는 BT.601 limited, nearest chroma, 출력 −1 LSB 상수를 한 파일에서 관리한다. 기존 독립 RGBA 기준 오차는 평균 0.407, p99 1, 최대 2다. 최종 합성 8종에서 색 정책, layout, packet index, fingerprint와 회전 오류는 모두 0이었다.

## press-and-hold와 stale 차단

- 단일 keydown은 정확히 ±1 frame
- repeat keydown은 queue가 아니라 `targetFrame` intent만 갱신
- requestAnimationFrame에서 최신 target으로 수렴
- keyup은 정확한 최종 target으로 정착
- session/generation이 다른 결과는 표시하지 않음
- 자동 가속 없음

최종 제품 UI QA에서 순·역 각각 30.0초 hold, A→B→C, 취소와 context loss fallback을 검증했다. 실제 설치 앱에서 직접 입력, Home/End와 휠을 추가 확인했다.

## 실제 Sample A~K 결과

파일명·전체 경로·hash는 기록하지 않았다. 11개 모두 406×720, 24fps, H.264, yuv420p이며 336~2,879 frames다.

| 항목 | Phase 2.3 결과 | 기준 | 판정 |
| --- | ---: | ---: | --- |
| 첫 I420 frame p95 | 131.8ms | 500ms 이하 | 통과 |
| Electron 첫 Canvas | 155.0ms | 500ms 이하 | 통과 |
| 전체 cache p95 | 1,320.6ms | 2,000ms 이하 | 통과 |
| cached navigation p95 | 0.327ms | 16ms 이하 | 통과 |
| cached navigation 최대 | 4.1ms 이하 | 50ms 이하 | 통과 |
| background 중 먼 seek 최대 | 290.7ms | 500ms 이하 | 통과 |
| cache 완료 후 재디코딩 | 0 | 0 | 통과 |
| fingerprint/frameIndex/PTS/stale | 0 | 0 | 통과 |
| 최대 cache payload | 1,262,383,920 bytes | 2GiB 이하 | 통과 |

128MiB 강제 LRU는 최대 134,174,880 bytes, eviction 181회, 11개 모두 첫 재방문 miss·두 번째 hit, fingerprint 오류 0이었다.

## 제품 UI와 fallback 결과

- 순·역 30초 hold 로딩 표시 0
- 순방향 968/예상 968, 역방향 2/예상 2로 최종 frame 오차 0
- 두 방향 모두 seek 재디코딩 0
- A→B→C에서 C만 수락
- 취소 뒤 늦은 frame 수락 0
- BT.709 첫 frame RGBA fallback 통과
- WebGL context loss 뒤 다음 frame RGBA 재표시 통과
- renderer 오류 0

## 내구 결과

- 실행 시간: 30.03분
- 실제 파일 session 생성·해제: 978회
- navigation request: 21,516회
- 강제 RGBA fallback: 326회
- WebGL context loss: 98회
- 정확성·renderer 오류: 0
- 최대 seek 재디코딩: 0
- 후반 browser RSS 기울기: 0.70MiB/분
- peak RSS: browser 1,727.5MiB, renderer 168.8MiB, GPU 124.4MiB
- cache soft cap 초과와 종료 후 관련 프로세스 잔존: 0

## 설치본 결과

- 최종 파일: `artifacts/CT-Cine-Reviewer-Setup-0.2.3-phase2.3.exe`
- SHA-256: `458e98bf5eabb616b26f024116c7f138216bf2a8815220295e77036fc9fe0129`
- unpacked 91개 파일의 필수 runtime, privacy scan과 checksum 재검증 통과
- 현재 사용자 설치와 재설치 exit code 0, 설치 실행 파일 제품 버전 `0.2.3.0`
- 실제 A~K 모두 첫 frame, `full` cache 완료와 `candidate-bt601-limited` 표시 통과
- 최종 설치 후보 기본 I420 재실행은 첫 frame 160.1ms, 216.6MiB full cache로 통과
- 직접 frame `1,234`, Home/End, 휠 `1,235`, 처음→끝→처음과 파일 전환 통과
- 실행 중 설치 앱 관련 외부 TCP·listen endpoint 0
- 종료 후 CT Cine Reviewer/FFmpeg/ffprobe 잔존 프로세스 0
- 원본 11개 aggregate hash 보존, 저장소와 앱 데이터의 PNG/JPEG/raw/YUV frame 잔존 0
- `CCR_FORCE_RGBA=1` 설치 실행은 1~41 frame, 45.7MiB/72MiB Phase 2.1 segment cache와 `준비` 상태 전환 통과

설치 앱 QA 중 RGBA rollback이 I420 전용 first-frame ack를 호출해 상태가 `분석 중`에 남는 회귀를 발견했다. 제품 cache에서만 ack하도록 한 줄 조건을 추가했고, 테스트·빌드·재패키징·재설치 후 rollback과 기본 I420을 모두 재검증했다.

## 개인정보 비잔존

- 원본은 읽기 전용이며 수정·재인코딩하지 않음
- frame payload는 FFmpeg stdout→RAM→IPC로만 전달
- 실제 sample, temp, benchmark JSON은 package/Git 제외
- package privacy scan에서 media, 실제 경로와 개발 홈 문자열 차단
- frame PNG/JPEG/raw/YUV 디스크 artifact 금지
- 설치 실행 중 외부 TCP 연결 0, 종료 후 frame artifact 0을 실측

## RGBA rollback

개발 또는 긴급 복구 시 앱 실행 전에 다음을 설정한다.

```powershell
$env:CCR_FORCE_RGBA = "1"
```

이 경우 제품 main은 Phase 2.1 `frameIpc`와 RGBA segment cache 전체를 사용한다. 환경변수가 없거나 `0`이면 기본 I420 cache 제품 경로다. 일반 사용자 설정 화면에는 decoder 선택을 노출하지 않는다.

## 알려진 위험

- metadata 없는 새로운 공급원은 RGBA fallback되므로 현재 공급원과 성능 특성이 다를 수 있다.
- 다양한 GPU/driver의 WebGL context behavior는 2시간 장기 QA와 함께 후속 통합 QA로 남긴다.
- 2GiB를 넘는 실제 장시간·고해상도 영상은 묶음 방향성 선읽기를 적용했지만, v0.5.8 실제 5프레임 이동 체감 재확인이 필요하다.
- 새 설치 직후 첫 I420 실행에서 10.47초 cold-start outlier가 1회 관찰됐다. 같은 설치본의 후속 실행은 180.2ms, 최종 재설치본은 160.1ms였으므로 파일럿에서 최초 실행 재현 여부를 확인한다.
- 코드 서명이 없어 Windows 경고가 나타날 수 있다.

## 아내분 파일럿 체크리스트

1. 설치와 첫 파일 열기가 어렵지 않은가?
2. 첫 frame이 기다림 없이 보이는가?
3. 방향키를 누른 채 불필요한 구간을 넘길 때 로딩이 보이는가?
4. 관심 구간 앞뒤 한 frame 왕복이 즉각적인가?
5. Home/End, 직접 frame 입력과 휠 방향이 자연스러운가?
6. 여러 파일을 연속으로 열 때 이전 영상 frame이 섞이는가?
7. 세로 영상 비율과 크기가 적절한가?
8. 실제 사용을 막는 오류 또는 가장 먼저 고칠 불편은 무엇인가?

## Phase 3 진입 조건

- Phase 2.3 설치본의 실제 파일럿 완료
- 연속 탐색·색·메모리·fallback에 중대한 회귀 없음
- Zoom/Pan, 보정 또는 재생 중 다음 우선순위를 사용자가 별도 승인

조건 충족 전 Phase 3 기능을 시작하지 않는다.
