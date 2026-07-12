# Decisions and Open Questions

## 사용 방법

- **확정**: 사용자가 이미 동의했거나 프로젝트 안전 원칙상 고정된 사항
- **제안**: 현재 1순위지만 구현 전 사용자 승인이 필요한 사항
- **미결정**: 샘플·측정·사용자 선택이 더 필요한 사항

## 확정된 결정

| 항목 | 결정 | 근거 |
| --- | --- | --- |
| 제품 성격 | 의료기기나 공식 진단 프로그램이 아닌 로컬 보조 뷰어 | 원본 PACS/DICOM을 대체하지 않기 위해 |
| v0.1 중심 입력 | 카카오톡 등으로 받은 MP4 | 현재 실제 전달 방식 |
| 탐색 의미 | 시간 증감이 아닌 디코딩 프레임 인덱스 중심 | 한 프레임 이동 정확성이 핵심이기 때문 |
| MP4 표시 의미 | 화면 픽셀 기반 Video Display 보정 | MP4에는 원본 HU가 없기 때문 |
| HU 표기 | MP4 preset에 HU 또는 DICOM Window 명칭을 사용하지 않음 | 의료적 의미 혼동 방지 |
| 원본 처리 | 읽기 전용, 주석·상태는 별도 프로젝트 파일 | 원본 보존과 재편집을 위해 |
| 개인정보 | 로컬 처리, 클라우드·로그인·텔레메트리 없음 | 환자 자료 외부 전송 최소화 |
| v0.1 제외 | DICOM, PACS, AI, 클라우드, 실제 HU 측정 | 동영상 핵심 완성도에 집중 |
| 개발 방식 | 작은 Phase, 각 단계 검증 및 다음 단계 전 사용자 승인 | 과설계와 추측 구현 방지 |
| 공통 코어 | 영상 분석 모델과 검증 규칙은 플랫폼 독립 TypeScript로 유지 | 향후 모바일에서 같은 의미와 데이터 계약을 재사용하기 위해 |
| 분석 포트 | `VideoProbeProvider<TSource>`의 입력은 플랫폼별 타입, 출력은 공통 결과 | Windows 경로를 모바일 입력 모델에 강제하지 않기 위해 |
| PTS 저장 | 원시 정수 문자열과 초 단위 값을 함께 보존 | 정확한 순서 검증과 화면 표시를 분리하기 위해 |
| Phase 1 기술 구성 | Electron + React + TypeScript scaffold와 공통 포트 검증 | 현재 기술 스파이크 범위에서 빌드와 mock 테스트가 통과함 |
| FFmpeg 배포판 | BtbN `n8.1.2-21-gce3c09c101` Windows x64 LGPL shared 월말 고정 자산 | checksum·buildconf·H.264/H.265 decoder를 실제 검증함 |
| FFmpeg 저장 정책 | 바이너리는 Git 제외, 고정 setup 스크립트와 배포 문서는 Git 보관 | 저장소 용량을 줄이면서 재현성과 checksum 검증을 유지하기 위해 |
| 최소 Windows | Windows 10 22H2 이상 | BtbN이 이 버전 이상만 보장함 |
| Sample A probe | 406×720 H.264, 518 frame entry, PTS 이상 0건, 전체 약 698ms | 실제 로컬 비식별 샘플 측정 결과 |
| 프레임 전달 | FFmpeg stdout의 RGBA 8-bit rawvideo | 디스크에 프레임을 남기지 않고 Canvas ImageData와 직접 호환되며 실제 정확성 검증을 통과함 |
| 기본 캐시 | 61프레임 RAM 구간 캐시: 뒤 20, 현재 1, 앞 40 | 약 68MiB로 hit p95 0.003ms 미만, miss p95 365.9~418.3ms를 달성함 |
| 전체 캐시 | 전체 raw RAM과 전체 PNG 디스크 캐시는 기본안에서 제외 | 짧은 영상도 RAM 약 638MiB 증가, PNG는 최대 761MiB와 22초가 필요함 |
| Electron IPC | 현재 406×720 RGBA payload는 IPC 전달 가능 | 1,169,280 bytes 30회 왕복 p95 약 3.4ms로 현재 목표의 병목이 아님 |
| Phase 1C 정확성 | Sample A/B/C에서 frame/PTS 및 픽셀 fingerprint 불일치 0건 | presentation order baseline과 순·역·교대 탐색으로 검증함 |
| Phase 2 cache 예산 | 기본 72MiB, 목표 최소 5·최대 61프레임 | 406×720에서는 61장, 1080p에서는 9장으로 상한을 유지함 |
| 방향성 cache | 순방향 20/40, 역방향 40/20, 교대 30/30 | 최종 실측에서 역방향 탐색이 Sample A/B/C 기준 약 23~30% 개선됨 |
| cache 재사용 | miss 때 겹치는 Buffer를 유지하고 누락 구간만 디코딩 | 방향 전환 때 전체 cache 폐기를 피하기 위해 |
| UI frame 표기 | 내부는 0 기반, 사용자 UI는 1 기반 | 일반 사용자가 보는 프레임 번호의 직관성을 위해 |
| Phase 2.2 격리 | 새 YUV 경로는 `CCR_PHASE22_SPIKE=1`에서만 활성화 | 검증 전 Phase 2.1 제품 기준선을 보존하기 위해 |
| YUV cache 예산 | 16GB PC 기준 최대 2GiB soft cap, 80% 이내면 full, 초과면 block LRU | 실제 11개 최대 payload 1,203.9MiB와 전체 cache p95 1.244초를 검증함 |
| YUV block | 약 32MiB slab 목표, 현재 406×720은 64프레임 | 32/64 평균이 각각 652.47/644.85ms이고 64가 block 객체 수를 절반으로 줄임 |
| frame index | background decode와 병렬인 packet PTS index | 실제 11개와 B-frame/VFR 합성에서 full frame probe와 불일치 0건 |
| YUV 표시 후보 | BT.601 limited WebGL2, 그 외 조건은 기존 RGBA fallback | VideoFrame은 색 기준 실패, WebGL은 평균 0.407·p99 1·최대 2로 통과 |
| Phase 2.3 제품 기본 mode | 전체 I420 cache 또는 제한 LRU를 기본 사용 | Phase 2.2 승인과 실제 11개 제품 재측정 통과 |
| Phase 2.3 색 fallback | 명시적 BT.601 limited와 승인된 metadata 없는 H.264/yuv420p만 WebGL2 | 새 공급원 profile을 임의 BT.601로 일반화하지 않기 위해 |
| 긴급 rollback | `CCR_FORCE_RGBA=1`에서 Phase 2.1 RGBA IPC 전체 사용 | 제품 통합 뒤에도 즉시 복구 가능하게 유지 |

## 현재 제안

| 항목 | 1순위 제안 | 확정 조건 |
| --- | --- | --- |
| 다음 단계 | 실제 Phase 2 사용 피드백 수집 | Phase 3 범위에 대한 별도 사용자 승인 |
| FFmpeg 연동 | 먼저 CLI process로 검증, native addon은 근거가 생길 때만 검토 | 성능·배포 측정 |
| 초기 배포 | 포터블 Windows 앱 | 실제 사용 및 보안 정책 확인 |
| 프로젝트 형식 | versioned JSON 계열 | schema와 저장 안전성 검토 |
| 좌표 | 원본 content 기준 0~1 normalized 좌표 | 렌더링/내보내기 왕복 검증 |
| 이미지 기본 형식 | PNG, JPEG는 선택 | 공유 용량 요구 확인 |
| Phase 2.3 파일럿 | 새 설치본으로 아내분 실제 사용 피드백 수집 | 설치·기능 통합 QA 완료 후 |

## 중요한 미결정 사항

### 1. 구간 캐시의 방향 적응

- 방향성 cache 적용을 확정했다.
- 세 번 이상 같은 방향 입력에서 순방향 20/40 또는 역방향 40/20으로 전환한다.
- 잦은 교대는 30/30 균형형을 사용하며 1,000회 실측에서 hit 99.9%였다.

### 2. 지원할 최대 영상 크기와 길이

- 필요한 정보: 실제 파일 크기, 해상도, 프레임 수, duration 분포와 사용 PC 사양.
- 결정 전에는 임의 상한을 보장하지 않는다.

### 3. 재생 기능 수준

- 최소안: 원래 순서 재생/일시정지와 한 가지 속도.
- 확장안: 속도 조절, 반복 구간, frame pacing 보정.
- 프레임 검토가 핵심이므로 확장안은 실제 필요가 확인될 때만 포함한다.

### 4. Sharp와 Denoise 기본값

- Sharp 기본 Off를 우선 제안한다.
- Denoise는 v0.1 P1 또는 P2 중 미결정이다.
- 강한 보정은 가짜 경계 위험이 있어 preset 값은 실제 샘플 비교 후 정한다.

### 5. v0.1 주석 도구 범위

- 우선 제안: 화살표, 텍스트, 원, 사각형, 마스크.
- 자유선, 여러 프레임 복제, 고급 스타일은 실제 필요 확인 전 P2로 둔다.

### 6. 프로젝트 자동 저장

- 선택지: 수동 저장만 / 변경 시 임시 자동 복구 / 명시적 프로젝트 자동 저장.
- 개인정보 잔존, 데이터 손실, 구현 복잡성 사이의 선택이 필요하다.

### 7. 최근 파일 목록

- 편의성은 높지만 환자명 포함 경로가 남을 수 있다.
- 기본 Off, 경로만 암호화/최소화, 기능 제외 중 선택이 필요하다.

### 8. 포터블 대 설치형 앱

- 포터블: 초기 테스트와 제거가 단순하다.
- 설치형: 바로가기, 업데이트, 코드 서명 배포에 유리하지만 운영 범위가 커진다.
- 초기에는 포터블을 제안하지만 Windows 정책 확인이 필요하다.

### 9. 지원할 Windows 최소 버전

- Phase 1 기준 최소 버전은 Windows 10 22H2로 확정했다.
- 실제 제품 배포 전 Electron과 GPU/드라이버 조합을 별도로 검증한다.

### 10. 샘플 영상 확보와 개인정보 제거

- 환자 식별자가 영상 픽셀이나 파일명에 포함될 수 있다.
- 테스트 전 사용 승인, 로컬 저장 위치, 결과 보고의 익명화 기준을 정해야 한다.
- 가능하면 비식별 또는 테스트용 영상을 우선 사용한다.

### 11. 사용자 preset 저장 범위

- 앱 전체 preset과 프로젝트별 preset 중 선택이 필요하다.
- 임상 부위 이름이 녹화 당시 window를 보장하지 않는다는 안내 방식도 확정해야 한다.

### 12. 기술 스택 최종 확정

- Phase 1 기준 데스크톱 구현은 Electron + React + TypeScript + FFmpeg CLI로 확정했다.
- 향후 내보내기·고해상도·장시간 영상에서 측정된 병목이 생길 때만 Tauri, Qt, .NET 또는 native addon을 재평가한다.

### 13. Phase 2.3 색 metadata 없는 영상

- 현재 실제 11개는 range/matrix/primaries/transfer metadata가 모두 없다.
- 독립 RGBA 기준과 일치한 `candidate-bt601-limited` WebGL2 경로는 기술적으로 통과했다.
- 현재 공급원의 H.264/yuv420p만 candidate로 허용하고, 새 공급원 profile과 다른 codec은 RGBA fallback하기로 승인했다.

### 14. Phase 2.3 RAM 사용 허용

- 최대 실제 영상 payload는 1,203.9MiB, Node peak RSS는 약 1.27GiB였다.
- 16GB 기준 최대 2GiB dynamic soft cap과 실제 약 1.3GB payload를 제품 기본값으로 승인했다.
- 32GB용 4GiB 고성능 모드는 이번 단계에서 구현하지 않는다.

## Phase 2.2 제품 통합 승인 체크리스트

- [x] 전체 I420 cache + 제한 LRU + RGBA fallback을 제품 기본 경로로 통합
- [x] 현재 공급원 metadata 없는 H.264/yuv420p에 `candidate-bt601-limited` 허용
- [x] 16GB PC에서 최대 2GiB dynamic soft cap 허용
- [x] 제품 통합 후 실제 표시와 GPU context-loss QA 시행

## Phase 1 시작 전 사용자 승인 체크리스트

- [x] 비식별 Sample A와 개인정보 처리 방식
- [x] Electron + React + TypeScript 기반 기술 스파이크
- [x] FFmpeg/ffprobe 바이너리 출처와 라이선스 검토
- [x] Phase 1B를 ffprobe 분석으로 제한하고 디코딩·캐시는 제외
- [x] 측정 결과에 따라 캐시 전략과 성능 목표를 조정할 수 있음
- [x] DICOM/PACS는 계속 범위 밖임

## Phase 2 시작 전 사용자 승인 체크리스트

- [x] 61프레임 RAM 캐시 기반 최소 뷰어 진입
- [x] 이동 방향별 cache 비율 전환을 측정 대상으로 포함
- [x] Phase 2 범위를 파일 열기·프레임 표시·정확한 전후 탐색·최소 상태 표시로 제한
- [x] 재생, 보정, 주석, 이미지 저장, DICOM/PACS는 계속 제외

## Phase 3 시작 전 사용자 승인 체크리스트

- [ ] 아내의 Phase 2 실제 사용 피드백 확인
- [ ] Zoom/Pan과 표시 보정 중 우선순위 결정
- [ ] 자동 재생을 Phase 3에 포함할지 결정
- [ ] 주석·이미지 저장은 별도 후속 Phase로 유지할지 결정
- [ ] DICOM/PACS는 계속 제외
