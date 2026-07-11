# CT Cine Reviewer Phase 2.2 Handoff

## 결론

사용자 요청으로 Phase 2.2 연속 탐색·대용량 RAM 캐시 기술 스파이크를 안전 지점에서 중단했다.

- 브랜치: `codex/phase2-2-cache-spike`
- 기존 제품 경로는 그대로 유지된다.
- 새 경로는 `CCR_PHASE22_SPIKE=1`일 때만 활성화된다.
- 설치본과 일반 실행은 계속 Phase 2.1 RGBA 61프레임 캐시를 사용한다.
- 실제 샘플 파일명·경로·hash·프레임 이미지는 Git과 문서에 포함하지 않았다.

## 완료된 구현

- quick ffprobe와 첫 I420 프레임 병렬 준비
- 첫 프레임 확인 후 지속 FFmpeg stdout YUV420P 디코딩
- 짝수·홀수 해상도 I420 plane offset/stride 계산
- 약 32MiB 목표의 8~64프레임 block 정책
- block slab 저장, LRU, seek 요청 간 중복 load 병합
- 16GB 기준 최대 2GiB soft-cap 계산과 full/LRU/fallback 판정
- spike 전용 IPC, session 취소·종료, RGBA 요청 fallback
- `VideoFrame(I420) -> Canvas` 표시와 사용 후 `close()`
- key repeat를 requestAnimationFrame 단위의 최종 목표로 수렴
- 색공간 ffprobe metadata 모델 확장
- 실제 15개 샘플 비식별 벤치마크 하네스
- Electron VideoFrame 색 정확성 비교 하네스

## 실제 샘플 상태

`local-samples/`에서 실제 영상 15개를 확인했다. 결과에는 `Sample A`~`Sample O` 별칭만 사용했다.

- 전부 406×720, 24fps, H.264, YUV420P
- 336~3,184프레임
- 14~132.667초
- 최대 keyframe 간격 429프레임
- Sample N/O는 동일 파일 중복 그룹이며 사용자 지침에 따라 둘 다 검증했다.
- 색 range/matrix/primaries/transfer metadata는 실제 샘플에서 비어 있었다.

## 통과한 실제 성능

최종 15개 전체 결과:

| 항목 | 결과 | 기준 |
| --- | ---: | ---: |
| 첫 I420 프레임 p95 | 383.04ms | 500ms 이하 |
| 전체 YUV cache 완료 p95 | 1,733.64ms | 2초 이하 |
| cache 탐색 p95 | 0.799ms | 16ms 이하 |
| 최대 cache payload | 1,396,120,320 bytes | 2GiB 이하 |
| 전체 cache 후 seek 재디코딩 | 0회 | 0회 |

첫 측정에서는 cache가 커질수록 `availableRAM`이 감소하는 값을 다시 예산에 넣어 앱 자신의 cache를 메모리 압박으로 오인했다. 세션 시작 시 예산을 고정해 eviction과 재디코딩을 제거했다.

stdout을 frame마다 `Buffer.concat`하지 않고 block slab에 직접 복사하고, full probe보다 cache decode를 우선해 가장 긴 실제 샘플도 2초 기준 안으로 낮췄다.

## VideoFrame 색 정확성 결과

`VideoFrame(I420) -> Canvas`는 속도와 자원 해제는 통과했지만 색 정확성은 실패했다.

- draw p95: 약 2.9ms
- 모든 검사에서 `VideoFrame.close()` 확인
- 최선 후보 BT.601 limited: 최대 평균 오차 1.301, p99 8, 최대 channel 오차 45
- 합격 기준: 평균 1 이하, p99 2 이하, 최대 4 이하

따라서 VideoFrame 경로를 제품 후보로 채택하면 안 된다.

계획에 따라 WebGL2 BT.601 limited shader 비교 코드를 `scripts/electron-video-frame-qa.cjs`에 추가했으나, 사용자의 중단 요청 때문에 **구문 검사만 통과했고 실제 QA는 실행하지 않았다.**

## 마지막 검증 상태

- 기존 + 신규 자동 테스트: 39개 통과
- TypeScript/Electron/Vite build: 통과
- WebGL 추가 전 실제 15개 성능 benchmark: 통과
- WebGL QA 스크립트 `node --check`: 통과
- WebGL 실제 색 비교: 미실행
- Git 추적 파일에 실제 샘플·프레임·결과 JSON 없음

## 다음 작업 순서

1. `AGENTS.md`와 이 문서를 읽는다.
2. `npm.cmd test`와 `npm.cmd run build`로 중단 기준선을 다시 확인한다.
3. `npm.cmd run qa:phase2.2:color`를 실행한다. 이 명령은 VideoFrame 후보와 새 WebGL 후보를 실제 15개에서 다시 비교한다.
4. WebGL이 평균≤1, p99≤2, 최대≤4를 모두 통과하면 spike UI에 WebGL renderer를 연결하고 RGBA fallback을 유지한다.
5. WebGL도 실패하면 YUV 표시 경로를 채택하지 말고 기존 RGBA 표시를 유지한 채 cache 형식 대안을 보고한다.
6. H.265, 1080p/60fps, VFR, 회전, 홀수 plane, BT.601/709, limited/full, colored overlay synthetic QA를 추가한다.
7. 제한 LRU에서 background/seek 동일 block 중복 디코딩 방지와 메모리 압박 축소를 검증한다.
8. 저메모리 fallback을 기존 RGBA IPC로 실제 연결한다. 현재는 정책 판정 단위 테스트만 있다.
9. 실제 Electron 창에서 첫 Canvas paint, 30초 press-and-hold, keyup 최종 frame, A→B→C stale frame 0을 검증한다.
10. 30분 soak 스크립트와 memory slope 검증을 추가한다.
11. `docs/12_CONTINUOUS_SCAN_CACHE_SPIKE.md`, `docs/06_DECISIONS_AND_OPEN_QUESTIONS.md`, Docs Hub에 최종 결과를 기록한다.
12. 성공해도 제품 기본 경로로 자동 통합하지 말고 사용자 승인을 요청한다.

## 남은 위험

- 실제 샘플에 색 metadata가 없어 spike runtime은 현재 `candidate-bt601-limited`를 표시 후보로 전달한다. 이 후보는 VideoFrame 기준을 실패했으므로 renderer 결정 전 실제 사용에 적용하지 않는다.
- background 순차 decoder와 별도 seek decoder가 같은 block을 동시에 처리하는 제한 LRU 경계는 아직 완전히 병합하지 않았다.
- 세션 시작 soft cap은 고정했지만 외부 시스템 메모리 압박 시 안전하게 축소하는 통합 검증은 남아 있다.
- 첫 프레임 383ms는 main-process first-I420-ready 기준이다. Canvas draw 자체는 약 2.9ms였지만 실제 앱 IPC를 포함한 end-to-end p95는 아직 별도 측정하지 않았다.
- WebGL context loss와 실제 RGBA fallback 전환은 아직 구현하지 않았다.

## 재현 명령

```powershell
npm.cmd install
npm.cmd test
npm.cmd run build
npm.cmd run benchmark:phase2.2
npm.cmd run qa:phase2.2:color
```

개발 spike 실행은 제품 기본 경로와 분리한다.

```powershell
$env:CCR_PHASE22_SPIKE = "1"
npm.cmd start
```

환자 영상은 외부로 전송하지 않고 원본을 읽기 전용으로 유지한다.
