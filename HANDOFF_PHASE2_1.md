# CT Cine Reviewer Phase 2.1 Handoff

## 결론

Phase 2 최소 실사용 뷰어와 Phase 2.1 Windows 패키징 구현은 완료했다. `win-unpacked` 독립 실행, NSIS Setup 생성·개인정보 검사와 실제 Windows 설치·제거·재설치를 통과했다.

현재 재설치본은 설치된 상태다. 실제 Explorer drag/drop, Windows 제거 등록 확인과 사용자 파일럿 피드백은 남아 있다. 세부 결과는 `docs/11_PHASE2_1_WINDOWS_INSTALLER.md`에 기록했다.

## 현재 Git 기준선

- 이전 커밋: `3bfe032 feat: complete Phase 1 frame decoding spike`
- 이번 커밋 범위: Phase 2 최소 뷰어 전체 + Phase 2.1 패키징 및 unpacked smoke test
- 실제 의료 샘플, FFmpeg 바이너리, 설치 산출물은 Git에 포함하지 않는다.
- `src/domain`과 `src/application`의 플랫폼 독립성은 유지했다.

## 구현 완료

### Phase 2 최소 뷰어

- 파일 선택, `Ctrl+O`, drag/drop 입력
- Canvas RGBA 표시와 세로·가로 원본 비율 유지
- 1·5프레임, Home/End, 직접 입력, 마우스 휠 탐색
- 내부 0 기반·UI 1 기반 변환
- request coalescing, session generation, stale-result 거부
- 72MiB 예산, 최대 61프레임 방향성 RAM cache
- 새 파일·취소·종료 시 probe/decode/cache 정리
- 개발 서버 없이 프로덕션 Electron 실행

### Phase 2.1 패키징

- `electron-builder 26.15.3` + NSIS x64
- 고정 `appId`: `com.snowberried.ctcinereviewer`
- 제품명·실행 파일명: `CT Cine Reviewer`
- 현재 사용자 단위 설치, 관리자 권한 요구 없음
- 시작 메뉴와 바탕화면 바로가기 생성
- 설치 폴더 변경 비허용
- 제거 시 현재 앱 데이터 삭제 설정
- 코드 서명, 자동 업데이트, 런타임 다운로드 없음
- `process.resourcesPath` 기반 설치본 FFmpeg/ffprobe 경로 해석
- FFmpeg 실행 파일·shared DLL·LGPL·버전·buildconf·archive checksum을 unpacked resource로 포함
- 종료 전 활성 ffprobe/FFmpeg 작업을 취소하고 session 자원을 정리
- 매 빌드 전 stale `dist`·`dist-electron` 정리
- Setup checksum, unpacked manifest, 개인정보 검사와 정리된 effective config 생성

## 로컬 설치 산출물

Git에서 제외된 `artifacts/`에 현재 다음 파일이 있다.

| 파일 | 상태 |
| --- | --- |
| `CT-Cine-Reviewer-Setup-0.2.0-phase2.exe` | 143,219,169 bytes |
| Setup SHA-256 | `cb1e45ea8a297852b7dce69ee644979d58fc8ea50547c33cf5881c9e032c4a53` |
| `CT-Cine-Reviewer-Setup-0.2.0-phase2.exe.sha256` | 생성 완료 |
| `win-unpacked/` | 91개 파일 |
| `package-manifest.txt` | 파일별 크기·SHA-256 기록 |
| `builder-effective-config.yaml` | 개발 절대경로 없는 배포 설정 요약 |

재빌드하면 서명되지 않은 NSIS 산출물의 timestamp 등으로 Setup hash가 바뀔 수 있으므로 새 checksum을 사용한다.

## 검증 완료

- 자동 테스트: 34/34 통과
- TypeScript + Vite 프로덕션 빌드 통과
- 패키지 개인정보 검사 통과
- 실제 영상·프레임·썸네일·파일명 목록·개발 홈 경로·`C:\AI_Assistant`가 unpacked 패키지에 포함되지 않음
- FFmpeg/ffprobe와 필요한 shared DLL·LGPL·build 정보 포함 확인
- 시스템 PATH에는 FFmpeg/ffprobe가 없는 상태에서 번들 바이너리 직접 실행 성공
- 프로젝트 밖 OS 임시 폴더로 `win-unpacked`를 복사해 실행 성공
- unpacked 앱 종료 후 CCR, ffmpeg, ffprobe 잔존 프로세스 0
- Windows 제거 등록의 `CT Cine Reviewer` 항목 0건: 이 항목은 실제 설치 전 unpacked 검증 시점의 상태

### Unpacked GUI smoke

무작위로 선택한 비식별 로컬 샘플 세 개를 generic hard-link 이름으로 열었다. 원본은 수정하거나 복사하지 않았다.

| 샘플 | 해상도/FPS | 프레임 | Probe | 첫 cache decode | 합계 |
| --- | --- | ---: | ---: | ---: | ---: |
| Sample A | 406×720 / 24fps | 359 | 542.9ms | 802.1ms | 약 1.35초 |
| Sample B | 406×720 / 24fps | 754 | 1,015.8ms | 753.5ms | 약 1.77초 |
| Sample C | 406×720 / 24fps | 518 | 760.7ms | 737.9ms | 약 1.50초 |

Sample A에서 `Right` 1→2, `Shift+Right` 2→7, `End` 359, `Home` 1, 직접 입력 100, 휠 한 notch 100→101을 확인했다. cache hit 요청은 0.1ms였고, 72MiB 상한을 넘지 않았다.

## 2026-07-11 실제 설치 파일럿 결과

- 자동 테스트 34/34, 프로덕션 빌드와 패키지 개인정보 검사 통과
- 현재 사용자 설치와 재설치 통과
- Sample A/B/C, Ctrl+O, 1·5프레임, Home/End, 직접 입력과 휠 탐색 통과
- 공백·한글·특수문자·183자·읽기 전용·다른 드라이브 경로 통과
- 빠른 정·역 입력, 분석 취소, 72MiB cache 상한 통과
- 유휴 상태 network endpoint 0, 종료 후 앱·ffmpeg·ffprobe 잔존 0
- 공식 제거 프로그램 `/S` 실행, 설치 폴더·바로가기·앱 데이터 제거와 원본 hash 보존 통과
- 깨끗한 재설치 후 실행 파일·제거 프로그램·바로가기·FFmpeg·라이선스 재생성 통과
- 동일 버전 덮어쓰기 설치는 사용자 결정으로 생략
- 검증용 하드링크와 합성 파일 정리 완료, 원본 샘플 디렉터리 유지

## 미완료: 다음 작업의 시작점

다음 작업에서는 **새 기능을 구현하지 말고** 아래 순서로 Phase 2.1 파일럿을 끝낸다.

1. Windows Explorer에서 실제 MP4 drag/drop을 수동 확인한다.
2. Windows 설정의 설치된 앱 목록과 제거 등록을 확인한다.
3. 등록이 보이지 않으면 NSIS uninstall registry 생성을 진단하고 수정 범위를 승인받는다.
4. 실제 사용자 파일럿 피드백을 기록한다.
5. 사용자 승인 전 Phase 3와 제품 기능을 시작하지 않는다.

## 실제 사용자 파일럿 체크리스트

아내분의 설치본 사용 후 다음을 짧게 기록한다.

1. 파일 열기가 어렵지 않은가?
2. MP4 drag/drop이 자연스러운가?
3. 마우스 휠 방향이 PACS 사용감과 맞는가?
4. 휠 한 칸이 정확히 한 프레임으로 느껴지는가?
5. 빠르게 앞뒤로 넘길 때 멈춤이나 이전 프레임 혼입이 있는가?
6. 키보드 1·5프레임, Home/End와 직접 입력이 편한가?
7. 세로 영상이 충분히 크게 보이고 비율 왜곡이 없는가?
8. 실제 사용을 막는 오류나 가장 먼저 고칠 불편은 무엇인가?

## 알려진 한계와 메모

- 기본 Electron 아이콘을 사용한다. 전용 아이콘 디자인은 이번 범위 밖이다.
- 코드 서명이 없어 Windows 경고가 나타날 수 있다. 경고 우회 코드는 넣지 않았다.
- 현재 컴퓨터에는 Node.js가 설치돼 있어 “Node가 전혀 없는 PC” 자체는 검증하지 못했다. 앱은 패키지 안 Electron runtime만 사용하며 외부 `node` 명령을 호출하지 않는다.
- 실제 설치 상태의 경로 matrix, 네트워크 관찰, 제거·재설치는 완료했다. Explorer drag/drop과 Windows 제거 등록 확인은 남아 있다.
- 최초 패키징에서 Electron archive 추출 폴더 rename이 Windows 외부 핸들로 잠겼다. 동일 버전의 로컬 `node_modules/electron/dist`를 `electronDist`로 사용하고 `artifacts/` 출력으로 분리해 해결했다. 실패한 `release/win-unpacked.tmp`는 이후 정상 삭제했다.
- Zoom/Pan, 자동 재생, 영상 보정, 주석, 이미지 저장과 DICOM/PACS는 시작하지 않는다.

## 재현 명령

```powershell
npm.cmd install
npm.cmd test
npm.cmd run build
npm.cmd run package:win
npm.cmd run verify:package
```

`tools/ffmpeg/`가 없는 컴퓨터에서는 먼저 승인된 고정 자산을 준비한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1
```
