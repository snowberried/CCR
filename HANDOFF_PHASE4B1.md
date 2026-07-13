# CT Cine Reviewer Phase 4B-1 Handoff

## 결론

버전 `0.4.1`에 실제 displayed frame 기준의 deterministic PNG 저장과 OS clipboard 복사를 통합했다.

- 전체 프레임은 원본 해상도, 확정 Video Display와 선택적 주석만 포함한다.
- 현재 보기는 viewport CSS 크기 × DPR backing에 Zoom/Pan/letterbox와 선택적 주석을 포함한다.
- Save dialog 전에 frame index/fingerprint, pixels, display, view와 같은 프레임 주석을 RAM snapshot한다.
- WebGL은 기존 texture redraw, RGBA는 기존 CPU reference를 재사용한다.
- Windows clipboard DIB는 monitor DPI를 보상해 그림판에서도 원본 `406×720` pixel 크기로 붙여넣어진다.
- export로 FFmpeg, decoder, seek, cache rebuild 또는 texture upload를 요청하지 않는다.
- 상세 계약과 QA는 `docs/18_PHASE4B1_FRAME_EXPORT.md`를 확인한다.

## 기준과 검증

- 시작 branch: `codex/phase2-2-cache-spike`
- 시작 HEAD / Phase 4A baseline: `cf30651`
- 테스트: 82/82
- WebGL2 / `CCR_FORCE_RGBA=1` 실제 Electron QA 통과
- 720×600 horizontal overflow 없음
- package, checksum과 최종 commit은 이 문서의 완료 기록을 기준으로 확인한다.

## 다음 작업

1. 실제 사용자가 전체 프레임/현재 보기와 clipboard 공유 흐름을 평가한다.
2. 별도 승인 뒤 개인정보 mask/blur와 공유 전 확인 UX 범위를 결정한다.
3. 프로젝트 저장, JPEG/clip/batch와 autoplay는 계속 별도 범위로 유지한다.

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.4.1.exe`
- 크기: 143,247,637 bytes (136.61 MiB)
- SHA-256: `f246de87ceee25572f2590e6733915a1b11c88ec703c4c8f10e74d34ab9902b3`
- unpacked 91개 파일, privacy inspection 통과
