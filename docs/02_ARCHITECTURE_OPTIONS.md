# Architecture Options

## 문서 상태와 평가 전제

- 이 문서는 기술 선택을 확정하거나 구현을 승인하지 않는다.
- 평가는 Windows 로컬 전용 v0.1, MP4 중심, Codex와 반복 개발, 향후 DICOM 입력 계층 추가 가능성을 기준으로 한다.
- 정확한 프레임 탐색은 UI 프레임워크가 아니라 FFmpeg 디코딩·인덱싱·캐시 전략에 크게 좌우된다.
- 실제 성능과 배포 크기는 기술 스파이크 전에는 보장할 수 없다.

## 요약 비교

평가: 5가 가장 유리하며, 숫자는 현재 요구사항에 대한 상대 평가이다.

| 항목 | Electron + React + TS | Tauri + Web + Rust | Qt/C++ | C#/.NET 데스크톱 |
| --- | ---: | ---: | ---: | ---: |
| 정확한 프레임 탐색 구현 용이성 | 4 | 4 | 5 | 4 |
| FFmpeg 연동 단순성 | 4 | 4 | 3 | 3 |
| Windows 배포 단순성 | 4 | 4 | 3 | 4 |
| GPU 표시 보정·주석 UI | 5 | 5 | 4 | 4 |
| Codex 반복 개발·유지보수 | 5 | 3 | 2 | 4 |
| 실행 크기·메모리 효율 | 2 | 4 | 4 | 4 |
| 네이티브 성능 상한 | 3 | 4 | 5 | 4 |
| 보안 경계의 단순성 | 3 | 4 | 4 | 4 |
| 향후 DICOM 웹 생태계 연결 | 5 | 5 | 3 | 3 |

## 후보 1: Electron + React + TypeScript + FFmpeg

### 예상 구조

- Electron main/utility process: 파일 접근, ffprobe/FFmpeg 실행, 앱 전용 캐시 관리, 내보내기
- sandboxed renderer: React UI, 키보드·마우스 상태, WebGL 또는 Canvas 기반 표시·주석
- preload bridge: 필요한 기능만 타입이 있는 좁은 IPC API로 노출

### 장점

- TypeScript 한 언어로 UI·상태·프로젝트 포맷을 다루기 쉽다.
- Canvas/WebGL과 풍부한 웹 UI 도구가 표시 보정·주석 구현에 적합하다.
- 향후 Cornerstone3D 같은 웹 기반 DICOM 렌더링 계층을 검토하기 쉽다.
- Codex가 작은 변경과 자동 테스트를 반복하기 좋은 생태계이다.
- FFmpeg CLI를 main/utility process에서 제한적으로 실행하면 초기 스파이크가 단순하다.

### 위험과 대응 원칙

- 번들 크기와 메모리 사용량이 상대적으로 크다.
- 렌더러에 Node.js 또는 임의 파일 접근을 노출하면 보안 경계가 약해진다.
- FFmpeg raw frame 파이프의 backpressure, 프로세스 종료, 한글 경로, 캐시 정리가 필요하다.
- 대응: `contextIsolation`, renderer sandbox, `nodeIntegration: false`, 제한된 IPC, 로컬 앱 자원만 로딩, CSP를 설계 조건으로 둔다. Electron 공식 보안 지침도 이 원칙을 권고한다.

### 적합성 판단

현재 요구사항에서는 **1순위 추천**이다. 최고 성능이나 최소 실행 크기보다 빠른 검증, 주석 UI, 표시 보정, 유지보수의 균형이 가장 좋다.

## 후보 2: Tauri + Web frontend + Rust + FFmpeg

### 예상 구조

- Rust core: 파일·프로세스·캐시 수명 관리
- WebView frontend: React/TypeScript 기반 UI와 표시·주석
- 명시적 command/event 경계로 프레임 데이터 전달

### 장점

- Electron보다 작은 설치 크기와 낮은 기본 런타임 부담을 기대할 수 있다.
- Rust 쪽에 파일·FFmpeg 권한을 모아 보안 경계를 명확히 만들 수 있다.
- WebGL/Canvas UI와 향후 웹 기반 DICOM 도구를 활용할 수 있다.

### 위험

- Rust와 TypeScript 두 계층을 함께 유지해야 한다.
- 대용량 프레임을 WebView 경계로 전달하는 방식이 성능 병목이 될 수 있어 조기 검증이 필요하다.
- Windows WebView2 런타임과 배포 환경 차이를 다뤄야 한다.

### 적합성 판단

앱 크기가 핵심 제약으로 확인되거나 Rust 유지보수가 허용될 때 2순위이다. Phase 1 이전에 선택하면 불필요한 복잡성이 늘 수 있다.

## 후보 3: Qt 기반 네이티브 앱

### 예상 구조

- C++/Qt UI와 렌더링
- Qt Multimedia 또는 libav* 직접 연동
- QGraphicsView/OpenGL 계층으로 주석·표시 보정

### 장점

- 프레임 버퍼와 디코더를 직접 제어하기 좋고 성능 상한이 높다.
- 네이티브 UI·스레드·메모리 제어가 가능하다.
- Qt Multimedia는 현재 주요 플랫폼에서 FFmpeg backend를 사용한다.

### 위험

- C++ 빌드·배포·라이선스·FFmpeg ABI 관리 난도가 높다.
- Qt Multimedia의 일반 재생 API가 이 프로젝트의 정확한 역방향 프레임 탐색 요구를 자동 해결한다고 가정할 수 없다.
- 주석과 상태 UI의 반복 개발 속도가 웹 조합보다 느릴 가능성이 크다.

### 적합성 판단

실제 스파이크에서 Electron 방식이 성능 목표를 만족하지 못하고 네이티브 제어가 필요하다는 증거가 생길 때 재평가한다.

## 후보 4: C#/.NET 데스크톱 + FFmpeg

### 예상 구조

- WPF 또는 WinUI 기반 Windows UI
- FFmpeg CLI 또는 검증된 wrapper로 디코딩
- Direct2D/Skia 계열 표시·주석

### 장점

- Windows 전용 앱에 자연스럽고 타입·도구 지원이 좋다.
- 네이티브 파일·프로세스·설정 관리가 편하다.
- Electron보다 런타임 부담을 줄일 가능성이 있다.

### 위험

- FFmpeg wrapper와 렌더링 라이브러리 선택이 추가 의존성 결정이 된다.
- 향후 웹 기반 DICOM 도구를 직접 재사용하기 어렵다.
- WPF와 WinUI 중 선택, .NET runtime 배포 방식이 추가 미결정이 된다.

### 적합성 판단

향후 DICOM 웹 생태계보다 Windows 네이티브 운영이 더 중요해질 때 유력한 대안이다.

## 1순위 제안

**Electron + React + TypeScript + FFmpeg CLI/ffprobe**를 기술 스파이크의 기본 후보로 제안한다.

핵심 근거:

1. v0.1의 난점은 네이티브 UI보다 프레임 인덱싱·캐시·표시·주석의 조합이며, 웹 렌더링 계층이 반복 실험에 유리하다.
2. FFmpeg CLI로 시작하면 libav ABI와 네이티브 addon을 피하면서 가설을 빠르게 검증할 수 있다.
3. TypeScript 모델을 프로젝트 저장, 주석, preset, UI 상태에 공통 적용하기 쉽다.
4. 향후 DICOM 입력을 추가할 때 공통 Viewer 또는 웹 기반 의료영상 생태계와 연결할 여지가 크다.

## 확정 전 확인할 위험

- 대표 영상에서 raw frame 전달 또는 이미지 캐시가 50ms 안팎 탐색 목표를 만족하는가
- 전체 선디코딩과 구간 캐시 중 어떤 전략이 메모리·디스크·대기시간에 적합한가
- WebGL/Canvas 보정 결과와 원본 해상도 내보내기가 픽셀·좌표 기준으로 일치하는가
- 포터블 배포 시 FFmpeg 바이너리 크기·라이선스·실행 경로가 허용 가능한가
- Electron 보안 설정과 완전 로컬 정책을 자동 검사할 수 있는가

## 공식 참고 자료

- [Electron Security](https://www.electronjs.org/docs/latest/tutorial/security)
- [Electron Process Model](https://www.electronjs.org/docs/latest/tutorial/process-model)
- [Qt Multimedia](https://doc.qt.io/qt-6/qtmultimedia-index.html)

버전 번호와 구체 API는 구현 승인 시 다시 확인한다.
