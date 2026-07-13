# Phase 5 Linked Dual View & Crosshair

## 결론

버전 `0.5.0`에 UI 명칭 **비교 뷰**를 추가했다. View A와 View B는 항상 같은 영상의 동일한 committed `frameIndex`, fingerprint와 decoded pixel object를 사용한다. 서로 다른 프레임·영상 비교 기능이 아니다.

- 공용: source, frame navigation, decoded frame, color metadata, decoder/cache, annotation store/history와 timeline
- pane별 독립: View Transform, Video Display, persistent tool, Original hold와 pointer/gesture 상태
- active pane: 단일 PACS toolbar, Video Display inspector와 export 명령의 대상
- linked crosshair: 같은 image pixel을 두 pane의 독립 transform으로 투영하는 overlay

Crosshair는 DICOM spatial registration, cross-reference line 또는 자동 alignment가 아니다.

## 상태와 수명

`src/domain/linkedDualView.ts`가 `PaneId`, pane state, frame identity 일치와 crosshair mapping의 순수 의미를 정의한다. React·DOM·WebGL·Electron 의존성은 없다.

비교 뷰 첫 진입에서는 현재 single pane의 View/Display/tool을 A/B에 복제하고 View A를 active로 둔다. 비교 뷰를 끄면 active pane 상태를 single view로 그대로 사용한다. 같은 파일에서 다시 켜면 A/B 상태를 세션 RAM에서 복원한다.

새 파일은 다음과 같이 초기화한다.

- A/B: Fit, Original, Pan
- active pane: A
- crosshair: ON
- annotation/history/timeline: 기존 Phase 4A 정책대로 초기화
- 비교 뷰 ON/OFF 선택은 유지 가능하지만 이전 파일의 pane state는 섞이지 않음

프로젝트 파일, pane cache image, thumbnail, pointer log 또는 crosshair telemetry는 만들지 않는다.

## Frame synchronization

기존 `desiredFrameRef` → 단일 pump → 단일 `window.ccr.getFrame` 흐름을 유지한다. accepted frame 하나를 A/B canvas에 모두 그린 뒤 같은 동기 구간에서 pane별 rendered identity를 기록하고 React frame state를 한 번 commit한다.

Crosshair는 다음이 모두 같을 때만 표시한다.

- frameIndex
- fingerprint
- `Uint8Array` pixel object identity

새 decoder, cache, navigation queue, FFmpeg process와 seek 경로를 추가하지 않았다.

## Renderer

### WebGL2

기존 단일 offscreen `I420WebglRenderer`와 texture 세 개(Y/U/V)를 공유한다.

1. committed frame의 I420 planes를 한 번 upload한다.
2. View A Display uniform으로 draw하고 A visible 2D canvas에 복사한다.
3. texture upload 없이 View B Display uniform으로 redraw하고 B visible 2D canvas에 복사한다.

즉 committed frame당 upload transaction 1회(plane upload 3회), pane draw 2회다. Crosshair와 annotation은 별도 DOM/SVG overlay이므로 video texture에 영향을 주지 않는다.

### RGBA fallback

`CCR_FORCE_RGBA=1` 또는 WebGL context-loss 뒤에도 같은 decoded RGBA `Uint8Array`를 두 pane가 공유한다. pane별 Display state에 따라 CPU reference 처리를 각 1회 수행한다. FFmpeg 재실행, cache 복제와 pane별 frame request는 없다.

Context loss는 crosshair를 즉시 숨긴 뒤 기존 RGBA fallback 정책으로 전환한다. A/B View/Display/tool과 shared annotation은 유지된다.

## Linked crosshair

새 좌표 수학을 만들지 않고 Phase 3A의 함수를 그대로 조합한다.

```text
source viewport point
→ viewportToImage(source transform)
→ image pixel point
→ imageToViewport(target transform)
→ target crosshair
```

Source letterbox, target viewport 밖, frame identity 불일치, invalid renderer, pointerleave/cancel, blur, file change, frame transition, 비교 뷰 OFF와 context loss에서는 숨긴다. Target 밖의 점을 경계로 clamp하지 않는다.

Pointer move는 requestAnimationFrame으로 coalesce하고 crosshair DOM transform만 바꾼다. React pane state, decoder, cache, RGBA display와 WebGL texture/draw를 변경하지 않는다.

## Annotation과 입력

Annotation store와 Undo/Redo history는 전역 하나다. 현재 frame annotation은 같은 image pixel geometry를 각 pane transform으로 투영해 양쪽에 표시한다. Selection outline, handle과 text editor는 editing owner pane에만 표시한다.

Pane pointerdown/wheel/drag는 event target pane을 active로 만들고 해당 pane state만 변경한다. 방향키, hold navigation, timeline, marker와 history frame 이동은 전역이며 A/B를 같은 frame으로 갱신한다. Original hold는 시작 pane에 고정되고 active pane 전환으로 이동하지 않는다.

## Export

Phase 4B-1 coherent snapshot 계약을 유지하며 export 시작 순간의 active pane을 동결한다.

- 전체 프레임: active pane Display + shared annotation, 원본 해상도, View 제외
- 현재 보기: active pane View/Display + shared annotation, 해당 pane viewport만 포함
- 제외: 반대 pane, crosshair, A/B label, divider, active border, selection/handle와 앱 UI

Dual composite, pane별 batch, JPEG/clip export는 추가하지 않았다.

## 검증

- 순수 state/crosshair/frame identity 테스트: DPR 1.0/1.5/2.0, source/target bounds와 0.25px 기준
- 기존 전체 단위/integration 테스트와 TypeScript/Electron/Vite build 통과
- 실제 MP4 Electron QA: WebGL2와 `CCR_FORCE_RGBA=1` 모두 통과
- A/B frameIndex/fingerprint/pixel object identity 일치
- pane별 View/Display/Original hold 독립, annotation ID/geometry 공용과 handle owner 분리
- active-pane 전체/현재 보기 export hash 차이와 반복 결정성, texture upload delta 0
- fullscreen crosshair, letterbox/pointercancel/context-loss 숨김 통과
- 720×600 horizontal overflow 없음, 1440×900에서 각 pane 400 CSS px 이상

최종 WebGL 측정에서는 crosshair image-space error가 `2.84e-14px`, update p95가 `0.4ms`였다. Crosshair 40회 이동 중 texture upload, WebGL draw, RGBA 처리와 seek 증가는 모두 0이었다. Single/dual navigation p95는 `67.14/70.23ms`, cached request p95는 `1.09/1.43ms`, render p95는 `0.5/1.1ms`였다. Committed frame 이동은 WebGL frame upload 1회와 draw 2회였다.

RGBA에서는 committed frame 이동당 같은 source pixels에 pane display 처리 2회가 발생했고 crosshair 이동 중 추가 처리는 0이었다. RGBA smoke의 single/dual cached request p95는 `0.55/0.21ms`였으며 wall navigation p95는 `73.80/78.67ms`였다.

순·역 각 30초 hold에서는 repeat 964회, loading insertion 0, seek 0과 A/B sync를 유지했다. 별도 전체-process 10.08분 soak에서는 13,025 cycles, seek 0, 오류 0이었고 후반부 RSS 기울기는 total `+0.33MiB/분`, renderer `+0.21MiB/분`, Browser `-0.18MiB/분`이었다. Single→dual 직후 renderer RSS 증분은 `+0.38MiB`였고 총 RSS 변화는 측정 잡음 범위의 `-0.88MiB`였다. 지속적인 memory growth 증거는 없었다.

## 개인정보와 제외 범위

제품은 원본을 읽기 전용으로 취급하며 사용자가 명시적으로 저장한 PNG 외 영상을 디스크에 남기지 않는다. 개인정보 마스킹은 현재 제품 범위에서 제외하므로 처음부터 개인정보가 포함되지 않은 MP4만 사용한다.

구현하지 않은 항목: 다른 frame/영상 비교, reference 고정, 독립 frame navigation, linked Zoom/Pan, target 자동 Pan, registration/alignment, DICOM cross-reference, composite export, autoplay, project 저장, crop/mask, tracking, measurement, DICOM/PACS/cloud/telemetry.

## 설치본

- 파일: `CT-Cine-Reviewer-Setup-0.5.0.exe`
- 크기: 143,250,244 bytes (136.61 MiB)
- SHA-256: `8262184e2aec7c32952b2035f086587f93f9820090a246962254c67767ce0a95`
- unpacked: 91개 파일
- package privacy inspection과 verify-only checksum 재검증 통과
