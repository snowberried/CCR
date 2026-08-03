# 프로젝트 작업 지침

이 파일은 이 프로젝트에서 작업할 때 우선 확인해야 하는 상위 지침이다.

## 핵심 원칙

- 중요한 결정은 Codex가 독단으로 하지 않는다.
- 요구사항 해석이 여러 가지일 때는 가능한 해석을 밝히고 사용자에게 확인한다.
- 구현 방향, 데이터 구조, 외부 의존성 추가, 큰 리팩토링, 삭제 작업처럼 되돌리기 어렵거나 영향 범위가 큰 선택은 먼저 사용자 동의를 받는다.
- 단순하고 되돌리기 쉬운 변경은 기존 요청 범위 안에서 최소 변경으로 진행한다.
- 이 앱은 전달받은 CT 동영상 검토를 돕는 보조 뷰어이며 의료기기나 공식 진단 프로그램으로 표현하지 않는다.
- MP4의 화면 픽셀 보정과 DICOM의 HU 기반 window를 혼동하지 않는다. MP4 preset에는 HU 값을 붙이지 않는다.
- 원본 영상은 읽기 전용으로 취급하고, 환자 영상·파일명·사용 정보를 외부로 전송하지 않는다.
- 사용자가 명시적으로 승인하기 전 DICOM, PACS, AI 또는 클라우드 기능으로 범위를 넓히지 않는다.
- 향후 모바일 앱을 개발할 계획이 있으므로 핵심 기능의 의미와 데이터 모델은 데스크탑과 모바일에서 공유 가능하게 설계한다.
- 데스크탑과 모바일의 화면 구성·조작 방식은 크게 달라질 수 있으므로 UI 구현은 플랫폼별로 분리하고, 공통 로직을 특정 UI나 Electron에 묶지 않는다.
- 공통화는 데이터 모델, 검증 규칙, 좌표계, 프로젝트 schema처럼 의미가 같아야 하는 영역에 우선 적용한다.
- 데스크탑 프레임 이동의 hot path에는 불필요한 IPC, JSON 직렬화, 프로세스 재실행, 과한 추상화 비용을 넣지 않는다.

## Android 서명 신원

- 자동 생성되는 Android standard debug key는 임시 개발 신원이다. 장기 파일럿,
  보존 artifact, S24 pinned candidate 또는 release 신원으로 사용하지 않는다.
- 장기 candidate는 versioned signing lineage, 저장소의 공개 인증서 fingerprint,
  저장소 밖 private key와 서로 다른 두 backup을 가져야 한다.
- candidate build는 명시적 opt-in, key·backup·public policy preflight와 모든 APK의
  signer 일치를 통과해야 한다. 일반 debug 또는 `CI_EPHEMERAL_DEBUG` 결과를 candidate로
  승격하지 않는다.
- private key, password와 실제 secret 값은 저장소·문서·채팅·명령행·로그에 남기지 않는다.
- key 분실 시 무제한 검색이나 임시 key 재생성으로 기존 신원을 가장하지 않는다.
  historical evidence를 보존하고 명시적인 새 signing lineage로 전환한다.

## 작업 순서

1. 이해: 요청과 기존 구조를 먼저 확인한다.
2. 최소 변경: 필요한 파일과 코드만 수정한다.
3. 검증: 가능한 명령, 테스트, 파일 확인으로 결과를 확인한다.
4. 요약: 변경 내용과 남은 위험을 짧게 보고한다.

## 실행 시간·정체 방지 규칙 (강제)

다음 규칙은 권고가 아니라 필수 작업 지침이다.

### 적용 범위

- `git`, `gh`, Node/npm, Java/keytool, Gradle, Android SDK, ADB, APK 검사·압축,
  대규모 hash·재귀 검색처럼 native 또는 외부 자식 process를 만드는 모든 실행
- 예상 총시간이 5분 이상인 build·test·검증·모니터링 및 다단계 작업
- 이전에 timeout 무시, 무응답 또는 장시간 정체가 발생한 실행 경로

정확한 파일 하나를 읽는 `Get-Item`·`Get-Content`처럼 자식 process를 만들지 않고
예상 10초 이하인 bounded 순수 PowerShell 읽기만 한 번에 하나씩 직접 실행할 수 있다.

### 명령 실행

- 적용 범위의 shell/native 명령은 process-tree 종료 권한이 승인된 외부 hard
  watchdog을 통해서만 시작한다.
- shell/native 명령을 `multi_tool_use.parallel`에 넣지 않는다.
- shell 도구의 `timeout_ms`는 보조 제한일 뿐 종료 보장이 아니므로 hard watchdog
  대신 사용하지 않는다.
- watchdog은 시작 시 exact PID, 시작 시각, 고유 stdout/stderr 로그 경로와 deadline을
  확보해야 한다. deadline 초과 시 exact PID tree를 종료하고
  `COMMAND_WATCHDOG_TIMEOUT`으로 보고한다.
- watchdog 또는 exact PID tree 종료 권한을 준비할 수 없으면 명령을 시작하지 않고
  `BLOCKED — WATCHDOG_NOT_READY`로 중단한다.
- 새 실행 환경의 첫 적용 작업, watchdog 변경 뒤, timeout 이상 발생 뒤에는 120초
  synthetic hang을 2~5초 deadline으로 먼저 검증한다. exact PID tree 종료와 잔류
  process 0이 확인되기 전 적용 범위 작업을 재개하지 않는다.

### 장기 작업

- 장기 작업은 동기식 shell 호출로 기다리지 않는다.
- `Start-Process -WindowStyle Hidden -PassThru`로 한 번만 시작하고 PID와 고유 로그
  경로를 기록한 뒤 즉시 제어권을 돌려받는다.
- 20~30초 간격으로 process 상태, 로그 마지막 시각·크기와 새 결과를 짧게 poll한다.
- 사용자 진행 보고가 60초 이상 끊기지 않게 한다.
- process 생존만으로 진전을 판정하지 않는다. 로그 변화, 새 checkpoint·결과 또는
  완료 단계처럼 검증 가능한 진행 증거가 있어야 한다.

### 5분 작업 임대제

- 적용 범위 작업을 시작할 때 시작 시각, 현재 phase, 성공 기준과 active PID·로그를
  기록한다.
- 시작 후 5분 이내와 이후 매 5분마다 새 작업 예약을 멈추고 강제 재평가한다.
- 새 로그·checkpoint·결과 또는 단계 완료가 확인되면 `PROGRESS_CONFIRMED`로
  중간보고하고 다음 5분을 연장한다.
- 진전 증거가 불충분하면 `PROGRESS_UNCERTAIN`으로 분류하고 새 작업을 시작하지 않은
  채 bounded 진단만 수행한다.
- 진전이 없거나 같은 단계가 비정상 반복되면 exact PID tree를 종료하고
  `STALLED_OPERATION`으로 중단 보고한다.
- 같은 blocker 또는 동일 실행 형태를 자동 재시도하지 않는다. 같은 blocker가 두 번
  발생하면 추가 시도는 사용자 승인 없이는 금지한다.

## 현재 상태: 프로젝트 1차 완성 및 종료

- 사용자는 2026-08-03 KST에 Windows v0.5.9와 Android 내부용 v1.0.0을 현재 합의 범위의 완성본으로 결정했다.
- 새 작업자는 `docs/29_PROJECT_COMPLETION_GUIDE.md`, `README.md`, 대상 플랫폼 README와 `docs/docs_hub.md`를 먼저 읽는다.
- 단계별 임시 `HANDOFF_*.md`는 최종 안내서와 정식 `docs/`에 유효 결론을 통합한 뒤 제거했다. 삭제된 handoff를 복원하거나 현재 기준으로 인용하지 않는다.
- Windows v0.5.9은 기준 commit `92f26ddb3fcbfd125986cf85f21560fb9a5655b2`, tag `v0.5.9`의 공개 안정판이다.
- 데스크톱 기능 기준 `ae70761a098ce69cc47228881d3be08c348f0fd1`의 decoder/cache/navigation, View Transform, annotation, export와 crosshair 의미를 검증 없이 바꾸지 않는다.
- 데스크톱은 I420 full/LRU와 WebGL2가 기본이며 `CCR_FORCE_RGBA=1`의 72MiB RGBA rollback을 유지한다.
- Android v1.0.0은 `com.snowberried.ctcinereviewer.internal`, versionCode 8, `ccr-internal-pilot-v1` 서명의 S24 내부 사용자 합격 안정판이다.
- Android 최종 runtime source는 `f4d2ec16e555d938380b46f422ed3f9c9ea32b94`이며 제품 판정은 `PASS — ANDROID_1_0_0_INTERNAL_USER_ACCEPTED`다.
- Android `ExactFrameSession`, frame-index/publication/cache/stale-result, Surface lease와 `ViewerViewModel` navigation/hold cadence 의미는 동결한다.
- Android 대표 해상도 Full Stage 1과 Random 250은 `DEFERRED — REPRESENTATIVE_RESOLUTION_AUTOMATION`이며 PASS로 바꾸지 않는다.
- 자동 재생·오디오, 프로젝트 저장, DICOM/PACS, AI와 cloud는 두 제품의 현재 범위가 아니다.
- Android 1.0에는 landscape, 비교 보기, 펜·주석, 직접 frame 입력, export와 Play 배포가 없다.
- 실제 재현 가능한 제품 결함 또는 사용자가 범위·성공 기준을 명시적으로 승인한 다음 버전 외에는 새 제품 작업을 시작하지 않는다.

## 단계별 개발 규칙

- 기능은 작은 단계로 나누고 각 단계마다 자동 검사와 실제 샘플 검증 기준을 둔다.
- 문서와 구현이 달라지면 같은 작업에서 관련 문서를 함께 갱신한다.
- 실제 샘플은 Git에 포함하지 않고 파일명·전체 경로·환자 식별정보를 로그와 문서에 남기지 않는다.
- 측정하지 않은 성능을 주장하지 않는다.
- `frameIndex`와 PTS를 혼동하지 않고 FPS만으로 프레임 위치를 계산하지 않는다.
- 원본 MP4를 수정하거나 재인코딩하지 않는다.
- `src/domain`에는 플랫폼·UI·Electron IPC·파일 시스템 의존성을 넣지 않는다.
- 프레임 분석, 프로젝트 schema, 주석 좌표, 표시 보정 preset처럼 모바일에서도 동일해야 하는 규칙은 공통 코어로 유지한다.

## Troubleshooting

- Codex, Browser, Windows, 권한, 샌드박스 또는 실행 환경 문제가 의심되면 먼저 현재 환경의 공용 troubleshooting 문서를 확인한다.
- 여러 프로젝트에서 재발할 수 있는 새 환경 문제를 해결했다면 공용 문서에 증상, 원인, 해결 절차와 검증 방법을 기록한다.
- CT Cine Reviewer에서만 발생하는 영상 처리, 렌더링, 상태, 캐시 또는 배포 문제는 `docs/troubleshooting.md`에 기록한다.
- 같은 해결 절차를 두 문서에 중복 작성하지 않는다. 프로젝트 문제에 공용 원인이 섞여 있으면 공용 문서를 참조하고 프로젝트별 조건만 기록한다.
- 가설과 검증된 해결책을 구분하며, 환자 식별정보나 원본 영상의 민감한 파일명·경로를 troubleshooting 문서에 남기지 않는다.

## 문서 관리

- 프로젝트 문서는 `docs/docs_hub.md`에 인덱싱한다.
- 새 문서 파일을 추가하거나 문서 위치를 바꾸면 `docs/docs_hub.md`도 함께 갱신한다.
