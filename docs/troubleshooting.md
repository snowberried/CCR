# Project Troubleshooting

이 문서는 **CT Cine Reviewer 프로젝트에서만 발생하는 문제와 검증된 해결 방법**을 기록한다.

## 기록 범위

다음과 같이 이 프로젝트의 영상 처리, 상태 관리, 렌더링 또는 배포 구조에 직접 관련된 문제를 기록한다.

- 특정 코덱·컨테이너에서 프레임 인덱스와 PTS가 어긋나는 문제
- 전후 프레임 이동, keyframe 재탐색 또는 캐시에서만 재현되는 문제
- 표시 보정과 원본 해상도 내보내기 결과가 달라지는 문제
- 주석·마스킹 좌표가 zoom, pan, DPI 또는 저장 과정에서 어긋나는 문제
- 이 앱의 프로젝트 파일, 원본 fingerprint 또는 임시 캐시 정리 문제
- 이 프로젝트의 패키징·포터블 배포 구성에서만 발생하는 문제

## 공용 문제와의 구분

Codex, Browser, Windows, 권한, 샌드박스, `Path/PATH`, `node_repl`, Vite 실행 환경처럼 다른 프로젝트에서도 반복될 수 있는 문제는 먼저 현재 환경의 공용 troubleshooting 문서를 확인한다.

- 공용 문서에 이미 해결 절차가 있으면 이 문서에 같은 내용을 복제하지 않고 공용 절차를 적용한다.
- 다른 프로젝트에서도 재현될 수 있는 새 환경 문제를 해결했다면 공용 문서에 증상, 원인, 해결 절차와 검증 방법을 기록한다.
- 프로젝트 설정이 공용 문제를 촉발한 경우에는 이 문서에 프로젝트 측 조건만 기록하고 공용 해결 문서를 참조한다.

## 기록 원칙

- 추측을 해결책처럼 기록하지 않는다. 가설은 `미검증`이라고 표시한다.
- 해결 절차는 실제로 재현 문제를 없앤 뒤에만 `검증 완료`로 표시한다.
- 증상, 재현 조건, 원인, 해결 절차, 검증 방법을 함께 남긴다.
- 관련 코드·설정·문서 변경 위치를 기록하되 환자 이름, 등록번호, 원본 영상 파일명과 절대 경로는 익명화한다.
- 같은 문제가 다시 발생했을 때 그대로 따라 할 수 있을 정도로 구체적으로 작성한다.
- 해결하지 못한 문제도 반복 재현된다면 `미해결` 상태와 현재까지 배제한 원인을 기록할 수 있다.

## 기록 형식

새 항목은 다음 형식을 사용한다.

```markdown
## YYYY-MM-DD 문제 제목

상태: 미검증 | 미해결 | 검증 완료

### 증상

### 재현 조건

### 원인

### 해결 절차

### 검증 방법

### 관련 변경
```

## 현재 기록

## 2026-07-10 FFmpeg setup 스크립트와 Windows PowerShell 5

상태: 검증 완료

### 증상

- `scripts/setup-ffmpeg.ps1` 직접 실행이 시스템 실행 정책에 의해 차단될 수 있다.
- `$ErrorActionPreference = "Stop"` 상태에서 FFmpeg의 정상적인 stderr 버전 출력이 `NativeCommandError`로 승격될 수 있다.

### 원인

- 현재 Windows PowerShell 실행 정책이 `.ps1` 직접 실행을 허용하지 않는다.
- FFmpeg는 `-version`과 `-buildconf` 일부 출력을 stderr로 보내지만 exit code는 0이다. Windows PowerShell 5는 이 stderr를 오류 record로 변환할 수 있다.

### 해결 절차

- 시스템 정책을 영구 변경하지 않고 다음처럼 해당 프로세스에만 `ExecutionPolicy Bypass`를 적용한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1
```

- setup 스크립트는 `.NET ProcessStartInfo`로 stdout, stderr와 exit code를 분리 수집한다. stderr 존재가 아니라 exit code로 성공 여부를 판단한다.

### 검증 방법

- 스크립트가 `Pinned FFmpeg setup completed and checksum verified.`를 출력한다.
- `tools/ffmpeg/`에 `VERSION.md`, `SHA256SUMS.txt`, `BUILDINFO.md`, `licenses/LICENSE.txt`와 runtime 파일이 생성된다.
- `BUILDINFO.md`의 `ffmpeg -version`, `ffprobe -version`, `ffmpeg -buildconf`가 완전하게 기록된다.

### 관련 변경

- `scripts/setup-ffmpeg.ps1`
- `docs/08_FFMPEG_DISTRIBUTION.md`
## 2026-07-10 Electron 프로덕션 창이 흰 화면인 경우

상태: 검증 완료

### 증상

- Vite 개발 서버에서는 UI가 보이지만 `npm start`의 `file://` 프로덕션 창은 흰 화면이다.

### 원인

- Vite 기본 asset URL이 `/assets/...` 절대 경로라 `file://`에서 앱의 `dist/assets`가 아닌 드라이브 루트를 찾았다.

### 해결과 검증

- `vite.config.ts`에 `base: "./"`를 둔다.
- `npm run build` 후 실제 Electron 창에서 dark viewer UI가 표시되는지 확인한다.

## 2026-07-10 Electron preload bridge가 없는 경우

상태: 검증 완료

### 증상

- UI는 보이지만 파일 열기 시 `ELECTRON_RUNTIME_REQUIRED`가 표시된다.

### 원인

- sandbox preload가 ESM `preload.js`로 출력되어 실행되지 않았다.

### 해결과 검증

- preload source를 `preload.cts`로 두어 CommonJS `preload.cjs`를 출력한다.
- `electron/main.ts`가 같은 출력 파일을 가리키게 한다.
- `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`는 유지한다.
- 실제 Electron 파일 대화상자로 synthetic 영상과 Sample A/B/C를 열어 bridge 동작을 검증한다.

## 2026-07-12 강제 RGBA rollback이 `분석 중`에 머무는 경우

상태: 검증 완료

### 증상

- `CCR_FORCE_RGBA=1` 설치 앱에서 첫 RGBA frame과 72MiB segment cache는 표시되지만 상태가 `준비`로 바뀌지 않는다.

### 재현 조건

- Phase 2.3 preload를 사용하면서 main process는 Phase 2.1 `frameIpc` rollback을 등록한 경우다.

### 원인

- UI가 모든 open 결과에 I420 제품 cache 전용 `frame:cacheAckFirst`를 호출했다.
- Phase 2.1 `frameIpc`에는 이 handler가 없어 Promise가 거부됐고 뒤의 `setStatus("ready")`에 도달하지 못했다.

### 해결 절차

- open metadata의 `productCache`가 참일 때만 first-frame ack를 호출한다.
- 기존 RGBA frame/session/cache 구현은 변경하지 않는다.

### 검증 방법

- `CCR_FORCE_RGBA=1` 최종 설치 앱에서 실제 영상을 연다.
- 진단에 72MiB budget과 segment range가 표시되고 상태가 `준비`로 전환되는지 확인한다.
- 환경변수 없는 기본 설치 앱에서 I420 `full` cache와 `candidate-bt601-limited`가 그대로 동작하는지 재확인한다.

### 관련 변경

- `src/App.tsx`
- `docs/13_PHASE2_3_PRODUCT_CACHE_INTEGRATION.md`

## 2026-07-14 NSIS 3.0.4.1에서 `!pragma codepage` 경고로 패키징 실패

상태: 검증 완료

### 증상

- `build/installer.nsh`를 추가한 뒤 `npm run package:win`이 `warning 6100: Unknown pragma`로 실패했다.
- electron-builder 기본값인 `warningsAsErrors` 때문에 경고가 패키징 오류로 처리됐다.

### 원인

번들된 NSIS 3.0.4.1은 `!pragma codepage 65001`을 지원하지 않았다. electron-builder 로그에서는 입력 스크립트가 이미 `UTF8`로 처리되고 있었다.

### 해결 절차

- `build/installer.nsh`에서 지원되지 않는 codepage pragma만 제거한다.
- 한글 `MUI_WELCOMEPAGE_TEXT`와 `customWelcomePage`는 유지한다.

### 검증 방법

- `npm run package:win`이 NSIS installer와 blockmap 생성을 완료하는지 확인한다.
- `npm run verify:package`에서 unpacked 파일 수, privacy inspection과 SHA-256을 확인한다.

### 관련 변경

- `build/installer.nsh`
- `package.json`

## 2026-07-14 GitHub Windows 러너에서 Electron 배포본 누락으로 패키징 실패

상태: 검증 완료

### 증상

- 태그 기반 `CCR Windows Release`가 테스트까지 통과한 뒤 `The specified electronDist does not exist`로 실패했다.
- 누락 경로는 `node_modules/electron/dist`였고 공개 GitHub Release는 생성되지 않았다.

### 원인

Electron 43.1.0 npm 패키지에는 자동 `postinstall` 스크립트가 없다. 기존 로컬 환경에는 Electron 배포본이 이미 있어 문제가 드러나지 않았지만, GitHub의 깨끗한 `npm ci` 환경에는 해당 디렉터리가 생성되지 않았다. 또한 태그 환경의 electron-builder는 명시하지 않으면 암묵적 publish를 시도할 수 있다.

### 해결 절차

- 의존성 설치 후 `node node_modules/electron/install.js`를 실행한다.
- `node_modules/electron/dist/electron.exe`가 실제 존재하는지 검사한다.
- 패키징 명령에 `--publish never`를 지정하고 GitHub Release 생성은 별도 GitHub CLI 단계에서만 수행한다.
- 패키징과 `verify:package`를 별도 Actions 단계로 분리한다.

### 검증 방법

- Actions에서 Electron 설치 단계, 전체 테스트, 패키징, 검증, Release 생성 단계가 순서대로 통과하는지 확인한다.
- Latest Release의 설치 파일과 `.sha256` 자산을 확인한다.

`v0.5.5` 실행 `29303904117`에서 모든 단계가 통과했고, 공개 설치 파일의 GitHub asset digest와 `.sha256` 파일 내용이 일치했다.

## 2026-07-15 2GiB LRU 영상에서 빠른 이동 중 `디코딩 중`이 순간 표시되는 경우

상태: v0.5.7 실사용 병목 확인, v0.5.8 자동 검증 완료·실사용 확인 대기

### 증상

- 장시간·고해상도 영상을 처음부터 빠르게 이동할 때 `디코딩 중`이 짧게 표시되고 다시 `준비`로 돌아온다.
- 멈춘 뒤 같은 프레임의 정보 탭을 확인하면 이미 cache hit로 바뀌어 원인을 캡처하기 어렵다.

### 재현 조건

- 1280×720, 3,766-frame I420 영상은 frame당 1,382,400 bytes, 전체 약 4.85GiB다.
- 2GiB budget과 24-frame block에서는 최대 64개 block, 약 1,536 frames만 동시에 유지할 수 있다.
- cache mode가 `lru`이고 background가 전체 영상을 끝까지 디코딩하는 이전 정책에서 재현됐다.

### 원인

- 디코더 자체의 절대 한계가 아니라 cache 정책과 사용 흐름의 불일치였다.
- 이전 background 작업이 2GiB보다 큰 영상 전체를 훑으면서 먼저 준비한 앞부분 block을 제거했다.
- 사용자가 처음부터 검토할 때 제거된 block을 다시 요청해 foreground seek decode가 발생했고, UI의 100ms 상태 기준을 넘는 순간 `디코딩 중`이 표시됐다.

### 해결 절차

- LRU background는 예산에 들어가는 첫 window까지만 준비한다.
- 현재 block과 이동 방향 앞쪽 최대 4개 block을 보호·선읽기한다.
- 방향이 바뀌면 선읽기 방향도 바꾸고, foreground와 선읽기의 같은 block 요청은 병합한다.
- 2GiB RAM cap과 디스크 cache 없음 원칙은 유지한다.

### 검증 방법

- 3-block budget의 합성 H.264 영상에서 background eviction 0과 첫 window hit를 확인한다.
- 다음 traversal block을 선읽은 뒤 cache 경계를 요청해 foreground `seekDecodeCount`가 0인지 확인한다.
- 전체 자동 테스트 100/100과 production build를 통과시킨다.
- 비식별 로컬 샘플 11개의 128MiB 강제 LRU에서 background eviction 0, 경계 hit 11/11, 경계 foreground seek decode 0과 fingerprint 오류 0을 확인한다.
- 실제 사용자 영상에서는 정보 탭의 `제거 / 재디코드`, `미리 읽기` 값을 함께 보고 처음→끝 빠른 이동의 체감을 재확인한다.

### v0.5.7 후속 실사용 결과

- 1프레임 정·역방향 연속 이동에서는 끊김이 사라졌다.
- 5프레임 정·역방향 연속 이동에서는 특정 cache 경계에서 간헐적으로 멈췄다.
- 진단에서 prefetch process 175회와 foreground seek decode 4회가 확인됐다.
- 1280×720의 24-frame block을 5프레임씩 소비하면 약 5번의 반복 입력마다 다음 block에 도달하므로, block마다 FFmpeg를 새로 시작하는 선읽기가 네 차례 뒤처진 것으로 판정했다.

### v0.5.8 추가 해결 절차

- 이동 방향 앞쪽 8-block을 high-water 범위로 사용한다.
- 준비된 앞쪽 block이 4개 미만이면 연속된 최대 4-block을 FFmpeg 한 번으로 decode한다.
- batch 대상 block을 in-flight로 예약하고 도착한 block부터 foreground가 즉시 재사용한다.
- 최신 이동 방향 요청을 하나만 보관하고 prefetch process는 동시에 하나만 실행한다.
- cache 보호 범위 밖의 제거 가능한 block 수에 맞춰 batch 크기를 줄여 2GiB cap을 넘지 않는다.

합성 강제 LRU에서 4-block 단일-process refill, foreground 중복 decode 0, 정→역방향 batch 전환과 budget 이하를 확인했다. 전체 자동 테스트 102/102, production build와 비식별 로컬 샘플 11개 경계 검사를 통과했다.

### 관련 변경

- `src/domain/yuvCachePolicy.ts`
- `electron/adapters/YuvBlockCache.ts`
- `electron/cache/YuvCacheSession.ts`
- `src/App.tsx`
- `tests/yuvCachePolicy.test.ts`
- `tests/yuvCacheSession.test.ts`
