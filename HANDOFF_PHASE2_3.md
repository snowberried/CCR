# CT Cine Reviewer Phase 2.3 Handoff

## 결론

Phase 2.2에서 승인된 연속 탐색 경로를 Phase 2.3 제품 기본 경로로 통합했다. 제품 버전은 `0.2.3-phase2.3`이며 기존 RGBA 경로는 `CCR_FORCE_RGBA=1` rollback으로 유지한다.

- Phase 2.2 승인 기준선: `4164225`, `phase-2.2-cache-spike-approved`
- 제품 기본 mode: `i420-cache`
- 긴급 rollback: `rgba-rollback`
- 실제 11개 성능·정확성: 통과
- 제품 UI context loss·BT.709 fallback: 통과
- 30분 제품 soak: 통과
- NSIS 설치본·설치 앱 검증: 통과
- 최종 설치 파일: `artifacts/CT-Cine-Reviewer-Setup-0.2.3-phase2.3.exe`
- SHA-256: `458e98bf5eabb616b26f024116c7f138216bf2a8815220295e77036fc9fe0129`

세부 결과는 `docs/13_PHASE2_3_PRODUCT_CACHE_INTEGRATION.md`에 기록한다.

## 통합 범위

- I420 layout과 약 32MiB block policy
- 2GiB dynamic soft cap
- 전체 cache/제한 LRU/RGBA fallback mode 선택
- background sequential와 on-demand seek decoder
- packet PTS index
- press-and-hold latest-target intent
- WebGL2 BT.601 limited와 context-loss fallback
- session/generation/cancel/close
- Phase 2.1 RGBA rollback

benchmark·sample 분석·QA 계측은 제품 package file 목록에 포함하지 않는다.

## 현재 검증

- 자동 테스트: 47/47 통과
- production build: 통과
- 합성 8종: packet/layout/fingerprint/color/rotation 오류 0
- 실제 11개: 첫 I420 p95 131.8ms, 전체 cache p95 1.321초, cached p95 0.327ms
- background 중 먼 seek 최대 290.7ms
- cache 완료 후 재디코딩과 fingerprint 오류 0
- Electron 첫 Canvas 155.0ms, 순·역 30초 hold 로딩·seek 재디코딩 0
- A→B→C 혼입 0, 취소 후 늦은 frame 0
- BT.709와 WebGL context loss RGBA fallback 통과
- 30.03분 soak: 978 session, 탐색 21,516회, fallback 326회, context loss 98회, 오류 0
- 후반 browser RSS 기울기 0.70MiB/분, soak 최대 seek 재디코딩 0
- 실제 설치 앱 A~K full cache와 직접 입력·Home/End·휠·파일 전환 통과
- 강제 RGBA 설치 앱은 72MiB Phase 2.1 segment cache와 `준비` 상태 전환 통과
- 종료 후 관련 프로세스·외부 TCP·frame 디스크 잔존 0, 원본 11개 hash 보존

## 다음 작업

1. 최종 설치 파일로 아내분 실제 파일럿을 진행한다.
2. Explorer drag/drop과 Windows 제거 등록은 후속 통합 QA에서 확인한다.
3. 실제 첫 실행에서 1회 관찰된 10.47초 cold-start outlier가 재현되는지 파일럿에서 확인한다.
4. 파일럿 피드백과 사용자 별도 승인 전 Phase 3를 시작하지 않는다.

## Phase 3 제한

아내분 설치본 파일럿과 사용자 승인 전 Zoom/Pan, 보정, 자동 재생, 주석, 이미지 저장, DICOM/PACS를 시작하지 않는다.
