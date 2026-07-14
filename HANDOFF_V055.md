# CT Cine Reviewer v0.5.5 Handoff

## 결론

v0.5.4 기능과 설치 UI를 그대로 유지하면서 깨끗한 GitHub Windows 러너에서도 Electron 배포본을 명시적으로 설치하고, 검증된 설치 파일과 SHA-256을 GitHub Release에 자동 배포하도록 릴리스 워크플로를 보완했다.

## 자동 배포

- 워크플로: `.github/workflows/release-windows.yml`
- 실행 조건: main에 포함된 `vX.Y.Z` 태그 푸시
- Electron 준비: `node node_modules/electron/install.js` 실행 후 `dist/electron.exe` 존재 확인
- 패키징: electron-builder의 태그 기반 암묵적 publish를 `--publish never`로 차단
- 공개 단계: GitHub CLI가 설치 파일과 SHA-256 체크섬만 새 Release에 업로드
- 실패 정책: 패키징과 검증을 별도 단계로 실행해 앞 단계 실패 시 Release를 만들지 않는다.

## v0.5.4 실패 기록

- `v0.5.4` 태그의 첫 자동 배포는 GitHub 러너에 `node_modules/electron/dist`가 없어 패키징 전에 실패했다.
- 태그·main·버전 검증과 전체 테스트는 통과했고 공개 Release는 생성되지 않았다.
- 이미 푸시된 태그를 교체하지 않고 수정 버전 `v0.5.5`로 재배포한다.

## 검증 기준

- 로컬 전체 테스트 통과
- Windows NSIS 패키징과 `verify:package` 통과
- GitHub Actions `CCR Windows Release` 성공
- GitHub Latest Release `v0.5.5`와 설치 파일·체크섬 확인
