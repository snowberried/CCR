# CT Cine Reviewer Phase 3B Handoff

## 결론

Phase 3A 기준선 `795ee14` 위에 플랫폼 중립 Video Display와 WebGL/RGBA 실시간 표시 보정을 통합했다.

- 버전: `0.3.1-phase3b`
- Original Phase 3A byte equality: 통과
- Level/Width, Gamma, Inverse, luminance Sharp: 통과
- candidate preset, 우클릭 drag, R/I/O와 Original hold compare: 통과
- Display parameter FFmpeg/seek/texture 재업로드 증가: 0
- WebGL/RGBA parity: mean 0.543, p99 2, max 3
- RGBA fallback redraw: 406×720 20.6ms, BT.709/full-range 합성 통과
- 순·역 30초 hold: loading·seek 0, View/Display 유지
- Sample A~K 첫·중간·마지막 preset 평가: 완료
- 10분 내구: 38,187회, 오류·seek·parameter texture upload 0, draw p95 0.1ms, RSS 기울기 0.40MiB/분으로 통과
- NSIS·설치 앱 WebGL/RGBA 실사용: 통과. SHA-256 `7a31a58be3bf595cefb160f4977ccaa2e14512b1d8193f29325821bd57aeaf61`
- 설치 앱을 `CCR_FORCE_RGBA=1`로 실행해 72MiB segment cache(대표 영상에서 1-41), preset 적용, frame 이동 시 상태 유지와 Original 복귀를 확인했다.
- 승인 후 고정 10%p zoom과 Pan/Zoom/Fit/100% 세로 도구 막대를 추가했다. WebGL/RGBA에서 tool 입력에 따른 seek·texture upload 증가 0, cursor anchor 오차 0.076 image pixel을 확인했다.

표시 보정은 `docs/15_PHASE3B_VIDEO_DISPLAY.md`, 후속 조작 개선은 `docs/16_POST_PHASE3B_VIEWER_CONTROLS.md`를 확인한다.

## 다음 작업

1. 실제 사용자가 candidate preset, Sharp와 우클릭 drag 민감도를 비교한다.
2. preset 조정값을 승인한다.
3. 별도 승인 뒤 Phase 4 주석 범위를 정한다.

## 제한

자동 재생, 주석, 이미지 저장, 개인정보 마스킹, 프로젝트 저장과 DICOM/PACS를 시작하지 않는다.
