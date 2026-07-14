# GitHub Windows Release Automation

## 목적

CT Cine Reviewer의 새 버전 태그가 푸시되면 검증된 Windows 설치 파일과 SHA-256 체크섬을 공개 GitHub Release로 자동 배포한다. 앱은 기존 설정창의 `최신 업데이트 확인`을 통해 GitHub의 최신 Release 태그를 확인한다. 설치 파일의 자동 다운로드나 자동 설치는 이번 범위에 포함하지 않는다.

## 배포 조건

워크플로 `.github/workflows/release-windows.yml`은 `vX.Y.Z` 형식의 태그 푸시로 실행된다. 공개 배포 전에 다음 조건을 모두 검사한다.

1. 태그가 정확한 `v숫자.숫자.숫자` 형식이다.
2. 태그에서 `v`를 제외한 버전이 `package.json`의 `version`과 같다.
3. 태그 대상 커밋이 `origin/main`에 포함돼 있다.
4. 전체 테스트, 제품 빌드, 패키지 개인정보 검사와 체크섬 검증이 통과한다.

의존성 설치 뒤 `node node_modules/electron/install.js`를 명시적으로 실행하고 `node_modules/electron/dist/electron.exe` 존재를 확인한다. electron-builder의 태그 기반 암묵적 publish는 `--publish never`로 차단하며, 검증 완료 뒤 GitHub CLI만 Release를 생성한다.

어느 조건이든 실패하면 Release를 만들지 않는다. 기존 Release도 덮어쓰지 않는다.

## 배포 자산

- `CT-Cine-Reviewer-Setup-X.Y.Z.exe`
- `CT-Cine-Reviewer-Setup-X.Y.Z.exe.sha256`

Release 제목은 `CT Cine Reviewer vX.Y.Z`이며 GitHub가 변경 내역을 자동 생성하고 해당 Release를 Latest로 지정한다. 워크플로는 저장소 기본 `GITHUB_TOKEN`의 `contents: write` 권한만 사용한다.

## 새 버전 배포 절차

1. `package.json`과 `package-lock.json`의 버전을 동일하게 올린다.
2. 테스트와 `npm run package:win`, `npm run verify:package`를 통과시킨다.
3. 릴리스 대상 변경과 워크플로가 포함된 커밋을 `main`에 반영한다.
4. main의 릴리스 커밋에 동일 버전 태그를 만들고 푸시한다.

```powershell
git tag -a v0.5.5 -m "CT Cine Reviewer v0.5.5"
git push origin v0.5.5
```

푸시 후 GitHub Actions의 `CCR Windows Release` 성공 여부와 Latest Release의 설치 파일·체크섬을 확인한다.

## 제한

- `electron-updater`, `latest.yml`, blockmap을 사용하지 않는다.
- 설치 파일은 현재 코드 서명되지 않았으므로 Windows 게시자 경고가 표시될 수 있다.
- 태그나 공개 Release는 같은 버전으로 다시 만들지 않고 다음 버전으로 올린다.
