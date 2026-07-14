# CT Cine Reviewer v0.5.4 Handoff

## 결론

v0.5.3 기능과 UI를 유지하면서 Windows 앱·바탕화면 바로가기·설치/제거 프로그램에 동일한 CCR 아이콘을 적용하고, NSIS 설치 시작 안내 페이지를 추가했다.

## 설치 UI

- 공통 아이콘: `build/app.ico`
- NSIS 확장: `build/installer.nsh`의 `customWelcomePage`
- 안내 문구:

```text
CT Cine Reviewer

본 프로그램은 동영상을 프레임 단위로 분리하여 검토할 수 있도록 지원합니다.

개인적 용도에 한해 누구나 사용할 수 있습니다.
상업적 이용 문의 또는 기능 제안은 아래 이메일로 연락해 주시기 바랍니다.

개발자: snowberried@naver.com
```

## 검증

- 전체 테스트: 91/91 통과
- TypeScript/Electron/Vite 제품 빌드: 통과
- 설치 프로그램과 unpacked 앱 EXE의 추출 아이콘 SHA-256 일치
- unpacked 파일: 91개
- package privacy inspection: 통과

## 설치본

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.4.exe`
- 크기: 143,378,614 bytes
- SHA-256: `6ebdd5fc5f9c3fbd67096fe6642e4dec0e4641f0e53930b72b83dc38079f1156`

## GitHub 자동 배포

- 워크플로: `.github/workflows/release-windows.yml`
- 실행 조건: main에 포함된 `vX.Y.Z` 태그 푸시
- 선검증: 태그 형식, `package.json` 버전 일치, main 포함 여부, 전체 테스트와 패키지 검증
- 공개 자산: Windows 설치 파일과 SHA-256 체크섬
- 앱 동작: 설정창의 수동 업데이트 확인이 GitHub Latest Release 태그를 읽는다. 자동 다운로드·설치는 하지 않는다.

실제 설치 실행은 수행하지 않았다. 설치·덮어쓰기·제거 검증이 필요하면 별도 승인 후 진행한다.
