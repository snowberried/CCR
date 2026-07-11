# CT Cine Reviewer

**CCR — CT 동영상 프레임 검토 및 주석 도구**

- 프로젝트 식별자: `ct-cine-reviewer`

카카오톡 등으로 전달받은 CT cine 동영상을 Windows PC에서 프레임 단위로 검토하고, 화면 표시를 보정하며, 주석을 붙여 공유하기 위한 완전 로컬 보조 뷰어 프로젝트이다.

> 이 프로젝트는 의료기기나 공식 진단·PACS 프로그램이 아니며, 원본 PACS/DICOM 판독을 대체하지 않는다.

## 현재 단계

Phase 0 기획과 Phase 1 기술 스파이크를 거쳐 **Phase 2 최소 실사용 뷰어**를 구현했다. Phase 2.1 NSIS 설치 패키지, unpacked 검증과 실제 설치·제거·재설치를 완료했다. 실제 Explorer drag/drop과 Windows 제거 등록 확인, 사용자 파일럿 피드백은 아직 남아 있다. 자세한 결과는 [Phase 2.1 Windows Installer Pilot](docs/11_PHASE2_1_WINDOWS_INSTALLER.md)과 [Phase 2.1 Handoff](HANDOFF_PHASE2_1.md)에 기록했다.

- 실제 로컬 샘플은 Git에 포함하지 않으며 컴퓨터별 `local-samples/`에서 확인함
- Electron/React/TypeScript 최소 scaffold 작성됨
- 데스크톱·모바일 공용 영상 분석 모델, 프레임 검증 규칙과 `VideoProbeProvider` 포트 작성됨
- 고정 BtbN LGPL shared FFmpeg/ffprobe 취득·checksum·라이선스 기록 절차 작성됨
- `FfmpegCliProbeProvider` 실제 실행, timeout·취소·출력 제한과 비식별 Sample A 분석 완료
- 실제 비식별 샘플 세 개에서 프레임·PTS·픽셀 fingerprint 정확성 검증 완료
- FFmpeg stdout RGBA rawvideo와 61프레임 RAM 구간 캐시를 Phase 2 기본안으로 결정
- 전체 raw RAM, 전체 PNG 디스크와 181프레임 RAM 캐시는 실측 결과 기본안에서 제외
- 파일 선택, `Ctrl+O`, MP4 drag/drop과 세션 전환 구현
- Canvas 원본 비율 표시와 UI 1 기반 프레임 탐색 구현
- 72MiB 예산 기반 최대 61프레임 방향성 RAM cache 구현
- Sample A/B/C와 합성 HEVC·1080p/60fps·VFR·B-frame·회전 metadata QA 완료
- 실행: `npm start`
- Windows 패키지 생성: `npm run package:win`
- 세부 결과는 [Phase 2 Minimum Viewer](docs/10_PHASE2_MINIMUM_VIEWER.md)에서 확인한다.

## v0.1 범위

- MP4 중심의 동영상 파일 열기와 정확한 프레임 인덱스 탐색
- 재생·정지, 확대·축소, Pan, 화면 맞춤
- Video Level/Width, Gamma, Inverse, Sharp 등 화면 픽셀 기반 표시 보정
- Lung-like 등 Video Display Preset
- 화살표·텍스트·기본 도형·개인정보 마스킹 주석
- 원본·보정·주석 포함 프레임을 PNG/JPEG로 저장
- 원본을 수정하지 않는 별도 JSON 계열 프로젝트 저장
- 인터넷, 로그인, 텔레메트리 없이 완전 로컬 동작

## v0.1 제외 범위

- DICOM 폴더/ZIP 및 실제 HU 기반 Window Center/Width
- HU·거리·면적 측정
- PACS 또는 DICOMweb 연동
- AI 판독, 클라우드 동기화, 사용자 계정, 자동 업데이트

## 문서 안내

전체 기획 문서는 [Docs Hub](docs/docs_hub.md)에서 찾을 수 있다. 아직 확정되지 않은 선택은 [Decisions and Open Questions](docs/06_DECISIONS_AND_OPEN_QUESTIONS.md)에 모아 둔다.
