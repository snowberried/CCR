# GitHub Windows Release Automation

## 목적

CT Cine Reviewer의 버전을 올린 커밋이 `main`에 푸시되면 검증된 Windows 설치 파일과 업데이트 메타데이터를 공개 GitHub Release로 자동 배포한다. 사람이 태그를 먼저 만들 필요가 없다. 앱은 설정창에서 사용자가 `확인`을 누를 때만 GitHub의 최신 Release를 확인한다. 새 버전이 있으면 `업데이트 설치`를 눌러 다운로드하고, 완료 후 앱을 종료해 현재 사용자용 NSIS 설치를 조용히 실행한 뒤 앱을 다시 연다.

## 배포 조건

워크플로 `.github/workflows/release-windows.yml`은 `main` push로 실행된다. 먼저 가벼운 version detection job이 현재 push 직전의 `package.json`과 새 커밋을 비교한다. 버전이 같으면 Windows job과 배포를 건너뛴다. 버전이 바뀌었다면 공개 배포 전에 다음 조건을 모두 검사한다. 실패로 태그와 Release가 모두 생성되지 않은 경우에만 Actions의 `Run workflow`에서 현재 `package.json` 버전을 입력해 같은 커밋을 다시 검증·배포할 수 있다.

1. 새 버전과 이전 버전이 모두 정확한 `숫자.숫자.숫자` 형식이다.
2. 새 버전이 이전 `main` 버전보다 크다.
3. `package.json`, `package-lock.json`과 lockfile root package의 버전이 모두 같다.
4. 생성할 `vX.Y.Z` 태그와 GitHub Release가 아직 존재하지 않는다.
5. 전체 테스트, 제품 빌드, 패키지 개인정보 검사와 체크섬 검증이 통과한다.

의존성 설치 뒤 `node node_modules/electron/install.js`를 명시적으로 실행하고 `node_modules/electron/dist/electron.exe` 존재를 확인한다. electron-builder의 암묵적 publish는 `--publish never`로 차단한다. 모든 검증이 끝나면 GitHub CLI가 현재 push 커밋을 대상으로 `vX.Y.Z` 태그와 Release를 생성한다.

어느 조건이든 실패하면 새 태그와 Release를 만들지 않는다. 기존 태그와 Release도 덮어쓰지 않는다.

## 배포 자산

- `CT-Cine-Reviewer-Setup-X.Y.Z.exe`
- `CT-Cine-Reviewer-Setup-X.Y.Z.exe.sha256`
- `CT-Cine-Reviewer-Setup-X.Y.Z.exe.blockmap`
- `latest.yml`

Release 제목은 `CT Cine Reviewer vX.Y.Z`이며 GitHub가 변경 내역을 자동 생성하고 해당 Release를 Latest로 지정한다. 워크플로는 저장소 기본 `GITHUB_TOKEN`의 `contents: write` 권한만 사용한다.

## 새 버전 배포 절차

1. 다음 명령으로 `package.json`과 `package-lock.json`의 버전을 함께 올린다.
2. 변경을 커밋하고 `main`에 푸시한다.
3. GitHub Actions의 `CCR Windows Release` 성공 여부를 확인한다.

```powershell
npm version 0.5.7 --no-git-tag-version
git add package.json package-lock.json
git commit -m "release: prepare v0.5.7"
git push origin main
```

워크플로가 `v0.5.7` 태그와 Latest Release를 자동 생성하고 설치 파일·체크섬·blockmap·`latest.yml`을 게시한다. 버전 변경이 없는 일반 `main` push에서는 version detection job만 성공하고 Windows 패키징과 Release는 실행하지 않는다.

워크플로 자체의 일시적 오류를 고친 뒤 같은 버전의 누락된 Release를 복구할 때는 GitHub Actions에서 `CCR Windows Release`의 `Run workflow`를 열고 현재 버전만 입력한다. 입력 버전이 `package.json`과 다르거나 같은 태그·Release가 이미 있으면 배포 전에 실패하므로 기존 공개 자산을 덮어쓰지 않는다.

## 제한

- 자동 확인이나 강제 설치는 하지 않으며, 사용자가 설정창에서 확인과 설치를 각각 직접 실행한다.
- 업데이트 기능이 없는 기존 설치본은 업데이트 기능이 포함된 설치파일을 한 번 직접 설치해야 한다.
- 설치 파일은 현재 코드 서명되지 않았으므로 Windows 게시자 경고가 표시될 수 있다.
- 배포할 의도가 없는 작업 커밋에서는 버전을 올리지 않는다.
- 태그나 공개 Release는 같은 버전으로 다시 만들지 않고 다음 버전으로 올린다.
