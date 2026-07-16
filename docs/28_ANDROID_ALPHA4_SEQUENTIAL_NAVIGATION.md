# Android 0.2.0-alpha.4 순차 탐색

## 결론

Android `0.2.0-alpha.4`는 길게 누르기 target 생성을 게시 완료 기준으로 제한하고, 안전한 순방향 `+1/+5`에서 codec/extractor cursor를 재사용한다. Samsung S24 Ultra의 서로 다른 pre-final 측정 APK에서 기존 17-fixture exact gate와 새 H.264 B-frame·long-GOP·VFR forward-sequential gate가 각각 통과했다. 두 gate를 최종 clean commit의 동일 APK로 재실행하는 항목, 성능 개선 Gate와 사용자 체감은 `Pending`이다. 태그·Release·원격 push는 하지 않는다.

## 기준과 버전

- 시작 SHA: `e5a02f41938e681208f5341793c042b96d560367`
- 작업 branch: `codex/android-sequential-navigation`
- 순차 디코드 구현 SHA: `7c04f802b89e63518a8cafab7985969d5cf89044`
- hold pacing 구현 SHA: `30606cf008663a30675854510c440772cd0bc9e4`
- versionName: `0.2.0-alpha.4`
- versionCode: `5`
- desktop `v0.5.9`와 `android-v0.1.0-gate3-pass`는 변경하지 않는다.
- alpha.4 tag는 사용자 체감·성능 합격 전까지 만들지 않는다.

## 확인된 alpha.3 병목

기존 long-press는 50 ms timer가 decoder보다 앞서 target을 계속 만들었고, 한 요청이 처리되는 동안 latest pending request가 미래 index로 합쳐졌다. cache miss는 대부분 `MediaCodec.flush()` 후 이전 sync로 `MediaExtractor.seekTo()`하고 GOP를 다시 순방향 decode했다. 게시 target은 OES texture에서 새 canonical RGBA texture로 복사한 뒤 cache put/evict, 2D draw, swap을 수행했다.

보관된 alpha.3 Perfetto 24개는 broad counter 분석에는 사용할 수 있지만 새 phase section이 없으므로 canonical copy와 cache 비용의 독립 기여를 판정할 수 없다. 따라서 transient OES direct render는 이번 버전에 넣지 않았다.

## alpha.4 변경

### Completion-driven hold

- `DISCRETE_TAP`, `TIMELINE_SEEK`, `HOLD_TRAVERSAL`을 구분한다.
- hold는 accepted 또는 acceptance 대기 target을 합쳐 최대 1개만 가진다.
- matching `Published` 뒤 gesture와 file generation이 계속 유효할 때만 다음 stride를 예약한다.
- requested index는 hold target acceptance 뒤에만 이동하고 displayed index는 `Published` 뒤에만 이동한다.
- release 직전 accepted target은 게시할 수 있지만 이후 target은 만들지 않는다.
- stale/error/unsupported/lifecycle stop/Surface 소실/file switch/cancel은 traversal을 무효화한다.
- deterministic simulation의 outstanding target depth는 p95/max 모두 `1`이다. raw frame lag 계약은 `+1 <= 1`, `+5 <= 5`다.

### ForwardSequentialEngine

같은 file·codec·Surface generation, prior exact/sequential published cursor, 정확히 다음 `+1/+5` target, input EOS 전, hold의 prefetch permit 없음 조건에서만 진입한다. `+5`의 중간 output은 `render=false`로 소비하고 정확한 다섯 번째 `FrameKey`만 게시한다.

방향 반전, random/direct seek, file/codec/Surface 변경, output format continuity 손실, mapping/FrameKey 불일치, target 통과, EOS, timeout, stale/error/render 실패는 sequential state를 무효화하고 기존 previous-sync exact seek를 한 번 수행한다. 기존 exact path는 삭제하지 않았다.

### Trace와 prefetch

`CCR.request.accept`, `actor.start`, `seek`, `flush`, `input.first`, `output.first`, `output.target`, `surface.wait`, `texture.update`, `canonical.copy`, `cache.put`, `cache.evict`, `draw`, `swap`, `publish`를 추가했다. label은 file/request generation, frame index, PTS만 사용하며 URI·파일명·경로·source hash를 넣지 않는다.

hold의 speculative prefetch는 0이다. discrete 방향 입력 뒤에만 최대 2프레임을 허용한다. 최근 완료 대비 evicted-before-use가 20%를 넘으면 depth를 절반으로 줄이고 50%를 넘으면 중단한다. 유효 hit가 두 window 연속 증가할 때만 천천히 회복한다. cache hard cap은 64 MiB 그대로다.

## S24 Ultra 결과

### 기존 exact gate

2026-07-16에 synthetic fixture만 사용했다.

- 17 fixture, 총 236 source frame: `PASS`
- 검사 latency sample 243개: p50 `63.624 ms`, p95 `200.322 ms`, max `260.504 ms`
- FrameKey/PTS/embedded ID/signature mismatch: `0`으로 gate 통과
- write-open, stale discard/swap, swap failure, publication invariant, cache rejection/thrash, texture double release: 모두 `0`
- hardware codec: `c2.qti.avc.decoder`, `c2.qti.hevc.decoder`
- 측정 APK SHA-256: `909fdc9b8c644319a1e76e89954e971043fdceb7d90b34ad061e867e0155cf38`

이 결과는 alpha.4 핵심 순차 디코드가 들어간 측정 빌드의 유효한 정확성 근거다. 이후 adaptive 진단값·hold prefetch 조기 반환·benchmark 종료 조건을 보강했으므로, 최종 clean commit APK와 source identity를 맞춘 17-fixture 전체 재실행은 `Pending`이다.

### 실제 forward-sequential gate

- fixture: `h264-bframes`, `long-gop`, `vfr`
- stride `+1` 전 구간과 stride `+5` 전 구간, 총 77 target 요청
- JUnit: 1 test, failure `0`, error `0`, test body `2.654 s`
- 모든 게시에서 기존 FrameKey·texture timestamp·embedded ID·RGB signature 검증 통과
- mismatch, stale, swap/surface/publication, cache rejection/thrash, double release, write-open: `0` 강제
- `sequentialEntryCount > 0`, `sequentialOutputCount > 0`, hold prefetch start `0` 강제
- 측정 APK SHA-256: `cacefe4577ab2956470d5d66c04c6719754305fb98c3578db0d9ca363cab8d69`

### 성능 Gate

1080p `+1` 3회 실행은 완료됐으나 초기 wrapper가 AGP additional-output 경로를 잘못 찾아 trace를 회수하지 못했다. `+5`는 안전 제한시간에 도달해 중단됐다. 당시 worktree도 미커밋이어서 report의 HEAD와 실제 APK source identity가 일치하지 않는다. 수치를 복원하거나 성능 PASS로 사용하지 않는다.

wrapper는 다음 실행부터 clean commit을 강제하고, build/install/instrumentation 전체를 `MaxMinutes`에 포함하며, 실제 `connected_android_test_additional_output`에서 scenario별 trace를 회수한다. 성능 상태는 `Pending — clean committed S24 rerun required`다.

## 남은 항목

- clean alpha.4 commit에서 1080p `+1/+5` 각 3회 trace 재측정과 alpha.3 비교
- 대표 7-fixture exact/cache 묶음 재실행. 이번 시도는 기존 10분 제한으로 report 없이 중단돼 `Pending`이다.
- phase trace로 canonical copy/cache 비용을 확인한 뒤에만 transient direct OES 여부 결정
- reverse는 `docs/27_ANDROID_REVERSE_WINDOW_SPIKE.md` 설계만 유지하고 제품 기본 경로는 cache hit 또는 exact fallback 사용
- memory plateau, 500회 codec switch, lifecycle, 10분 idle, USB 분리 battery는 `Pending`
- 실제 사용자 파일 체감 평가는 자동 성능 Gate 뒤 별도 수행

이번 범위 밖인 zoom/pan/fit/100%, 필터, 주석, PNG export, 비교 보기, 프로젝트 저장, DICOM/PACS, AI, cloud, Play 배포는 구현하지 않는다.
