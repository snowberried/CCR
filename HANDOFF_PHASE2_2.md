# CT Cine Reviewer Phase 2.2 Handoff

## 결론

Phase 2.2 연속 탐색 로딩 제거 기술 스파이크의 구현·실샘플 성능·색 정확성·실제 Electron UI·30분 내구 검증을 완료했다.

- 브랜치: `codex/phase2-2-cache-spike`
- Phase 2.1 복구 기준선: commit `3d716f2`, tag `phase-2.1-installer-baseline`
- 기존 제품 경로: Phase 2.1 RGBA 61-frame cache 그대로 유지
- 새 경로: `CCR_PHASE22_SPIKE=1`에서만 활성화
- 제품 기본 통합: 미시행, 사용자 승인 대기
- 실제 샘플·파일명·전체 경로·hash·frame image: Git과 문서에 없음

상세 근거는 `docs/12_CONTINUOUS_SCAN_CACHE_SPIKE.md`에 있다.

## 구현 상태

- quick probe와 첫 I420 frame 병렬 준비
- 첫 Canvas 표시 뒤 지속 FFmpeg sequential decoder 시작
- packet PTS 기반 presentation-order frame index
- 약 32MiB 목표의 block slab와 LRU
- 16GB 기준 최대 2GiB soft cap, full/LRU/RGBA fallback
- background와 seek의 동일 block load 병합
- 메모리 압박 budget 축소와 eviction
- BT.601 limited WebGL2 renderer, 지원하지 않는 색 조건은 기존 RGBA fallback
- key repeat navigation intent와 requestAnimationFrame pump 분리
- session/generation 기반 open·cancel·A→B→C stale 차단
- QA 전용 파일 open은 `CCR_PHASE22_QA=1`일 때만 별칭 인덱스로 노출

## 최종 실제 샘플 결과

현재 `local-samples/`의 11개를 Sample A~K로 모두 분석했다.

- 모두 406×720, 24fps, H.264, yuv420p
- 336~2,879 frames, 14.000~119.958초
- 최대 keyframe 간격 250 frames
- A/J와 B/K는 중복 그룹이지만 모두 검증
- frameIndex/PTS 오류 0
- 색 metadata는 모두 없음

| 항목 | 결과 |
| --- | ---: |
| 첫 I420 frame p95 | 149.2ms |
| 실제 Electron 첫 Canvas | 313.1ms |
| 전체 cache p95 | 1,244.4ms |
| cache 탐색 p95 / 최대 | 0.332 / 4.035ms |
| background 중 먼 End 최대 | 300.8ms |
| 최대 cache payload | 1,262,383,920 bytes |
| cache 완료 후 seek decode | 0회 |
| fingerprint/frameIndex/PTS 오류 | 0건 |

## 색과 UI

VideoFrame 직접 표시는 평균 1.222, p99 8, 최대 channel 오차 45로 실패했다. 최종 WebGL2 shader는 평균 0.407, p99 1, 최대 2, draw p95 0.100ms로 통과했다.

31.20초 방향키 repeat 963회에서 보이는 로딩 0회, 최종 목표 frame 오차 0, 재디코딩 0회였다. A→B→C는 C만 수락됐고 취소 후 늦은 frame 수락도 0건이었다. BT.709 첫 frame은 오류 없이 기존 RGBA 경로로 fallback했다.

## 검증 상태

- 최종 자동 테스트: 44/44 통과
- 최종 TypeScript/Electron/Vite production build: 통과
- 실제 sample benchmark: 11/11 통과
- 합성 edge QA: 8/8 통과
- Electron color QA: 통과
- Electron UI 30초 QA: 통과
- 30분 soak: 2,228 sessions, 445,600 requests, 오류/재디코딩 0, peak RSS 1,537,466,368 bytes, 후반 +2.44MiB/분으로 통과
- `temp/` frame artifact: 0
- Git 추적 actual sample/temp entry: 0

BT.709/full-range 첫-frame RGBA retry와 실제 11개용 128MiB 강제 LRU를 최종 재실행했다. LRU는 최대 134,174,880 bytes, eviction 181회, 11개 모두 첫 재방문 miss·두 번째 hit, fingerprint 오류 0으로 통과했다. 반복 `spawn EPERM`은 동일 명령 권한상승으로 해결했고 공용 troubleshooting에 기록했다.

## 다음 결정

다음 작업은 코딩이 아니라 사용자 승인이다.

1. 전체 I420 cache + 제한 LRU + RGBA fallback을 제품 기본 경로로 통합할지
2. 색 metadata가 없는 영상을 `candidate-bt601-limited` WebGL2로 표시할지, 항상 RGBA fallback할지
3. 16GB PC에서 2GiB soft cap과 관측 약 1.3GB main RSS를 허용할지
4. 통합 후 실제 표시 pilot과 GPU/context-loss QA를 시행할지

승인 전 Phase 2.1 기본 경로를 삭제하거나 Phase 3, Zoom/Pan, 보정, 재생, 주석, 이미지 저장, DICOM/PACS를 시작하지 않는다. 설치 UI 세부 항목과 동일 버전 덮어쓰기도 추후 통합 QA로 유지한다.

## 재현 명령

```powershell
npm.cmd test
npm.cmd run build
npm.cmd run analyze:phase2.2
npm.cmd run benchmark:phase2.2
npm.cmd run benchmark:phase2.2:active
npm.cmd run qa:phase2.2:synthetic
npm.cmd run qa:phase2.2:color
npm.cmd run qa:phase2.2:ui
npm.cmd run soak:phase2.2
```

개발 spike 실행:

```powershell
$env:CCR_PHASE22_SPIKE = "1"
npm.cmd start
```
