# CT Cine Reviewer v0.5.6 Handoff

## 결론

v0.5.6은 MP4 화면 보정 프리셋을 제거해 수동 미세 조정 흐름으로 단순화하고, 빈 화면 파일 열기·빠른 프레임 이동 간격·사용자 지정 단축키를 추가한 로컬 Windows 빌드이다. 사용자가 설정창에서 승인하는 GitHub Release 업데이트 다운로드·설치도 지원한다. 이후 실사용 피드백에 따라 2GiB를 넘는 영상의 LRU 준비·선읽기 정책을 보완했으며, 디코더 출력, 프레임·PTS, 표시와 주석 데이터 모델은 유지했다.

## 사용자 화면 변경

- 화면 보정 프리셋을 제거했다. 밝기·명암·감마·선명도·반전과 `원본 보기`만 유지한다.
- 영상이 없는 중앙 영역을 클릭하거나 Enter/Space를 누르면 파일 선택창을 연다.
- 빈 화면에 `동영상 파일 열기`, `클릭 또는 드래그로 파일을 입력하세요` 안내를 표시한다.
- 빠른 프레임 이동 간격은 기본 5이며 2·5·10·20·30·50프레임 또는 2~999 직접 입력을 지원한다.
- 하단 빠른 이동 버튼의 `−N/+N`, 접근성 문구와 실제 이동 간격이 설정값을 함께 사용한다.
- 향후 모바일 앱은 Android 우선, 같은 저장소의 별도 구성으로 검토하며 병원 미니 PC에서는 개발·무선 디버깅하지 않는다.

## 사용자 지정 단축키

- 설정의 `단축키`에서 넓은 전용 창으로 진입한다.
- 파일·프레임·화면·표시 보정을 기능당 한 조합으로 변경하거나 해제할 수 있다.
- 변경 초안은 `저장` 전까지 적용되지 않으며 취소·창 닫기 시 폐기한다.
- 중복, 고정 단축키 충돌, modifier 단독, Windows 키, Tab·Enter·Space·Esc·Delete·Backspace와 Alt+F4를 차단한다.
- 사용자 설정은 `KeyboardEvent.code`와 Ctrl·Shift·Alt 상태로 비교하고 `ccr.shortcuts.v1`에 저장한다.
- 빠른 이동 간격은 `ccr.fastFrameStep.v1`에 저장한다.
- 손상되거나 불완전한 단축키 저장값은 전체 기본값으로 복구한다.

### 변경 가능한 기본값

| 기능 | 기본 단축키 |
| --- | --- |
| 파일 열기 | `Ctrl+O` |
| 이전/다음 프레임 | `←` / `→` |
| 빠른 이전/다음 | `↓` / `↑` |
| 첫/마지막 프레임 | `Home` / `End` |
| 확대/축소/화면 맞춤 | `+` / `-` / `0` |
| 전체 화면 | `F` |
| 화면 보정 원본 보기/반전/원본 비교 | `R` / `I` / `O` |

`Shift+←/→`, `=`, 숫자패드 `+/-`와 `_` 보조 조합은 제거했다. 휠, Ctrl+휠, Esc, 주석 Undo/Redo/Delete와 입력창 Enter/Esc는 고정이다.

## 검증 결과

- `npm test`: 현재 소스 100/100 통과
- `npm run build`: 통과
- 브라우저 UI QA: 전용 창 레이아웃, 키 캡처, 충돌 저장 차단, Esc 캡처 취소, 초안 폐기, 저장·재실행 유지, 비활성화와 기본값 복원 통과
- 비식별 합성 60프레임 MP4 Electron QA: 사용자 지정 빠른 이동, 반복 이동 종료·재시작, 입력창 억제, 원본 비교 hold/release와 기존 Shift+Right 제거 통과
- `npm run package:win`: 통과
- `npm run verify:package`: 91개 unpacked 파일과 개인정보 검사 통과
- 업데이트용 `app-update.yml`, `latest.yml`, blockmap과 설치파일 SHA-512 일치 검증 통과

## Windows 설치 파일

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.6.exe`
- 크기: 143,704,733 bytes
- SHA-256: `7eca1e28000b6febe696d66cbc1bf6cc97353f82734af490c72dd54f737d369d`
- NSIS x64, 현재 사용자 설치, 관리자 권한 요구 없음

`artifacts/`는 Git 배포 대상이 아니다. 이전에 만든 업데이트 기능 없는 v0.5.6 설치본을 사용 중이면 이번 설치파일을 한 번 직접 설치해야 하며, 이후 버전부터 앱 안의 `업데이트 설치`를 사용할 수 있다.

## 자동 Release 후속 변경

- Windows Release 워크플로는 수동 태그 push가 아니라 `main` push에서 버전 증가를 감지한다.
- `package.json`과 `package-lock.json` 버전을 함께 올려 커밋·push하면 검증 후 `vX.Y.Z` 태그와 공개 Latest Release를 자동 생성한다.
- 버전이 같은 일반 push는 배포를 건너뛰고, 버전 감소·lockfile 불일치·중복 태그 또는 Release는 실패한다.
- 테스트·Windows 패키징·privacy·checksum 검증이 끝나기 전에는 태그나 Release를 만들지 않는다.
- 이 워크플로 변경의 실제 원격 자동 배포 검증은 다음 버전 증가 커밋을 `main`에 push할 때 수행한다.

## 장시간·고해상도 LRU 후속 변경

- 1280×720, 3,766-frame 영상은 raw I420 기준 약 4.85GiB이므로 2GiB RAM cap에 전체 cache할 수 없다.
- 이전처럼 LRU background가 전체 영상을 훑으며 앞부분을 제거하지 않고, 예산에 들어가는 첫 window까지만 준비한다.
- 현재 위치와 이동 방향을 기준으로 앞쪽 최대 4개 block을 선읽고, 같은 block의 foreground 요청과 병합한다.
- 정보 탭에 준비 frame, 제거·foreground 재디코드와 미리 읽기 횟수를 표시한다.
- 2GiB cap, 디스크 cache 없음, full mode와 `CCR_FORCE_RGBA=1` rollback은 유지한다.
- 자동 테스트 100/100과 production build를 통과했고, 비식별 로컬 샘플 11개의 128MiB 강제 LRU에서 경계 hit 11/11, 경계 foreground seek decode 0, fingerprint 오류 0을 확인했다.
- 이 변경은 아직 위의 v0.5.6 설치 파일에는 포함되지 않았다. 실사용 확인 후 다음 버전으로 올려 패키징한다.

## 운영 및 다음 작업

- 병원 미니 PC는 유선 LAN을 유지하고 무선랜을 활성화하지 않는다.
- 이 앱은 MP4 보조 뷰어이며 PACS/DICOM 원본 판독을 대체하지 않는다.
- 모바일 개발은 추후 집 데스크탑에서 별도 승인 후 시작한다.
- 설치 실행은 소스 push와 별도 작업이다. 다음 버전부터 태그와 GitHub Release는 버전 증가 `main` push에 의해 자동 생성된다.
