# CT Cine Reviewer Phase 5 Handoff

## 결론

버전 `0.5.0`에 **비교 뷰(Linked Dual View & Crosshair)**를 통합했다.

- View A/B는 항상 같은 current frame, fingerprint와 decoded pixels를 공유한다.
- Zoom/Pan, Video Display, persistent tool과 임시 interaction은 pane별 독립이다.
- Annotation/history/timeline, decoder/cache/navigation은 각각 하나다.
- Crosshair는 Phase 3A image-space 변환을 재사용하며 DICOM registration이 아니다.
- Export는 active pane의 Display/View를 기존 Phase 4B-1 snapshot 계약에 사용한다.
- WebGL은 frame upload 한 번 뒤 pane별 두 draw, RGBA는 같은 source pixels의 pane별 처리다.

상세 계약과 검증 근거는 `docs/19_PHASE5_LINKED_DUAL_VIEW.md`를 확인한다.

## 기준

- 시작 branch: `codex/phase2-2-cache-spike`
- 시작 HEAD: `ac810c8626d9b70f4b49e9836fc15987a73633fe`
- 작업 branch: `codex/phase5-linked-dual-view`
- 기준 working tree: clean

## 검증

- 전체 테스트 88/88과 product build 통과
- WebGL2 / `CCR_FORCE_RGBA=1` 실제 MP4 Electron QA 통과
- frame/pixel identity, pane state 독립, active routing, crosshair, annotation과 export 검증
- 720×600 / 1440×900 / fullscreen 검증
- context-loss에서 crosshair 즉시 제거와 RGBA 상태 보존 검증
- Phase 2.3 cache/seek 구조 변경 없음
- 순·역 각 30초 hold: repeat 964회, loading 0, seek 0, A/B sync 유지
- 10.08분 전체-process soak: 13,025 cycles, seek 0, 오류 0, A/B sync 유지
- 후반부 RSS 기울기: total `+0.33MiB/분`, renderer `+0.21MiB/분`, Browser `-0.18MiB/분`
- Single→dual renderer RSS 증분 `+0.38MiB`, 지속적인 memory growth 증거 없음
- 최종 package 결과는 완료 시 이 문서에 기록한다.

## 제품 경계

서로 다른 frame/영상 비교, linked Zoom/Pan, registration, composite export, autoplay, 프로젝트 저장, 개인정보 마스킹, JPEG/clip/batch, DICOM/PACS/cloud는 구현하지 않았다. 개인정보가 포함되지 않은 MP4만 입력으로 사용한다.

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.5.0.exe`
- 절대 경로: `C:\AI_Codex\workspace\CCR\artifacts\CT-Cine-Reviewer-Setup-0.5.0.exe`
- 크기: 143,250,244 bytes (136.61 MiB)
- SHA-256: `8262184e2aec7c32952b2035f086587f93f9820090a246962254c67767ce0a95`
- unpacked 91개 파일
- package privacy inspection과 verify-only checksum 재검증 통과
