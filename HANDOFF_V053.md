# CT Cine Reviewer v0.5.3 Handoff

## 결론

v0.5.2 기능 기준선을 유지하면서 상단 버전 표시, 조정 패널 구분선 UI, 독립 설정창과 수동 업데이트 확인을 추가하고 Windows 설치본을 생성했다.

- 상단 제품명 옆에 `ver. 0.5.3`을 표시한다.
- 조정 패널은 카드형 셀 배경·테두리를 제거하고 화면 보정/주석/내보내기 사이에 annotation yellow 구분선을 사용한다.
- 하단 `설정`은 조정 탭 바로가기가 아니라 독립 모달을 연다.
- 설정에는 사용자가 직접 실행하는 GitHub 최신 Release 확인만 있다.
- 업데이트 확인은 앱 버전만 User-Agent에 사용하며 영상·파일명·사용 기록을 전송하지 않는다.
- 자동 다운로드, 자동 설치와 백그라운드 확인은 없다.

## 검증

- 전체 테스트: 91/91 통과
- TypeScript/Electron/Vite 제품 빌드: 통과
- 브라우저 UI: `ver. 0.5.3`, 카드 제거, 노란 구분선과 설정 모달 확인
- 브라우저 console error: 0
- 패키지 unpacked 파일: 91개
- package privacy inspection: 통과

## 설치본

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.3.exe`
- 크기: 143,255,294 bytes
- SHA-256: `3aa3fd98e483cbd461dabba5038beaa6b7bbdcbc21906b32884176d37494297a`

## 범위 유지

자동 재생, 프로젝트 저장, 마스크, DICOM/PACS, AI와 cloud 기능은 추가하지 않았다. CCR은 로컬 MP4 검토 보조 뷰어이며 의료기기나 공식 진단 프로그램으로 표현하지 않는다.
