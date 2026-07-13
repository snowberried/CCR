# Data and State Model

## 문서 목적

코드나 확정 schema가 아니라, v0.1에서 어떤 정보의 의미와 수명을 분리해야 하는지 정의한다. 실제 필드명·파일 확장자·hash 방식은 구현 전 사용자 승인과 기술 스파이크를 거쳐 확정한다.

## 핵심 원칙

- 원본 영상은 읽기 전용이며 프로젝트 파일과 캐시는 원본과 분리한다.
- `frameIndex`는 사용자가 탐색하는 연속 순서이고, `PTS`는 영상 시간축의 식별 보조값이다.
- MP4 표시 보정값은 화면 픽셀 기준이며 HU 의미를 갖지 않는다.
- 주석 좌표는 창 크기가 아니라 원본 영상의 표시 영역을 기준으로 저장한다.
- 프로젝트 파일에는 버전과 원본 일치 여부를 확인할 정보가 있어야 한다.

## 개념적 구성

### Project

- schema version
- 프로젝트 생성·마지막 저장 시각
- 원본 영상 참조 정보
- 현재 탐색 상태
- 공통 표시 설정
- 프레임별 주석
- 북마크
- 프로젝트에 포함된 사용자 preset 또는 그 참조
- 앱 버전은 호환성 진단용으로만 기록

### Source Identity

- 사용자가 마지막으로 지정한 경로 또는 상대 경로 힌트
- 파일명, 크기, 수정 시각
- content fingerprint
- ffprobe에서 확인한 video stream 기본 특성
- 개인정보 최소화를 위해 절대 경로를 반드시 영구 저장할지는 미결정

fingerprint 후보:

- 전체 파일 hash: 신뢰도는 높지만 큰 파일에서 비용이 든다.
- 일부 구간 hash + 크기: 빠르지만 충돌 가능성이 더 높다.
- 크기 + 수정 시각만 사용: 가장 빠르지만 변경 탐지 신뢰도가 낮아 단독 사용은 권장하지 않는다.

기본 방식은 기술 스파이크에서 비용을 측정한 뒤 정한다.

### Frame Reference

- `frameIndex`: 0부터 시작하는 내부 연속 인덱스
- 사용자 표시 번호: 1부터 시작할 수 있으나 내부 인덱스와 혼동하지 않는다.
- PTS 및 time base
- 필요 시 frame duration과 keyframe 관련 정보

주석·북마크는 `frameIndex`와 PTS를 함께 저장한다. 같은 원본에서는 인덱스를 우선 사용하고, 디코딩 방식이나 원본이 달라졌을 때 PTS는 진단·복구 보조로만 사용한다. PTS가 비슷하다는 이유만으로 변경된 영상에 주석을 자동 재배치하지 않는다.

### Display Settings

- Video level/center에 대응하는 정규화 값
- Video width/range에 대응하는 정규화 값
- black point, white point
- gamma
- inverse
- sharp 강도
- denoise 강도(포함 여부 미결정)
- 적용 중인 preset ID 또는 custom 상태

표시 설정의 적용 범위는 기본적으로 프로젝트 전체로 제안한다. 프레임별 설정 저장은 사용 사례가 확인되기 전 추가하지 않는다.

### View State

- zoom
- pan x/y
- rotation/flip은 v0.1 포함 여부가 확정될 때만 추가
- fit mode
- 현재 도구와 선택 주석은 세션 상태로 보고 영구 저장 여부를 최소화한다.

View State와 Display Settings를 분리해야 원본 해상도 내보내기에서 화면 배치와 픽셀 보정을 독립적으로 재현할 수 있다.

### Annotation — Phase 4A 확정

공통 정보:

- 고유 ID
- 0 기반 frameIndex
- type: arrow, text, ellipse, rectangle
- 원본 영상 image pixel geometry
- color, logical display-unit line width
- text content와 font size(텍스트일 때)
- z-order 또는 생성 순서
- Phase 4A 세션의 안정적인 생성·z 순서

Phase 4A의 주석은 세션 RAM에만 있으며 PTS, opacity, 숨김, mask, 자유선과 프로젝트 직렬화는 포함하지 않는다. 개인정보 마스크는 내보내기 안전성 검사가 필요하므로 일반 도형처럼 추측 구현하지 않고 별도 승인 단계로 둔다.

### Bookmark

- 고유 ID
- frameIndex와 PTS
- 선택적 사용자 label
- 생성 순서

북마크는 영상 내용을 복제하지 않고 프레임 참조만 보관한다.

### User Preset

- 고유 ID와 사용자 표시 이름
- Display Settings 중 preset에 포함되는 값
- 기본 preset과 사용자 preset 구분
- schema version

사용자 preset을 프로젝트 내부에 포함할지 앱 로컬 설정으로 공유할지는 미결정이다. 환자별 정보나 원본 파일 경로는 preset에 저장하지 않는다.

## Phase 4A 주석 좌표

- 좌상단 `(0, 0)`, 우하단 `(imageWidth, imageHeight)`인 원본 image pixel 공간을 사용한다.
- letterbox, viewport, CSS pixel, zoom과 pan은 geometry에 저장하지 않는다.
- 입력과 렌더링은 Phase 3A의 `viewportToImage`와 `imageToViewport`를 그대로 사용한다.
- 선 굵기, 글자, handle과 hit tolerance는 줌과 무관한 logical display unit이다.
- 이전 normalized geometry는 Phase 4 이전 기획 초안이며 Phase 4A 구현 계약으로 사용하지 않는다. 향후 프로젝트 저장 schema는 별도 승인 시 image pixel geometry를 기준으로 다시 결정한다.

## 프로젝트 저장 파일

- 사람이 읽을 수 있는 JSON 계열을 우선 검토한다.
- schema version을 필수로 두고 알 수 없는 미래 필드를 무조건 삭제하지 않는다.
- 원본 프레임 이미지와 임시 캐시는 기본적으로 포함하지 않는다.
- 저장은 임시 파일 작성 후 원자적 교체 방식으로 손상 위험을 줄이는 안을 검토한다.
- 자동 저장 여부와 저장 주기는 미결정이다.

## 원본이 이동하거나 변경된 경우

### 이동됐지만 fingerprint가 일치

사용자가 새 파일을 지정하면 fingerprint와 stream 특성을 확인한 뒤 프로젝트 연결을 갱신할 수 있다. 자동으로 디스크 전체를 검색하지 않는다.

### fingerprint 불일치

- 주석을 즉시 적용하지 않는다.
- 크기·코덱·해상도·프레임 수·fingerprint 차이를 가능한 범위에서 보여준다.
- 읽기 전용으로 프로젝트 내용을 확인하거나, 사용자가 명시적으로 새 원본에 연결하는 선택을 제공할 수 있다.
- 강제 연결 시 오정렬 위험을 분명히 알리고 원본 프로젝트 파일을 덮어쓰지 않는 방안을 우선한다.

### 원본을 찾을 수 없음

주석과 설정 메타데이터는 열어볼 수 있지만 영상 렌더링과 이미지 내보내기는 비활성화한다.

## 캐시와 영구 상태 구분

| 데이터 | 기본 수명 | 프로젝트 저장 |
| --- | --- | --- |
| 디코딩 프레임 캐시 | 세션/앱 전용 임시 수명 | 아니오 |
| ffprobe 분석 결과 | 세션, 필요 시 일부만 프로젝트 | 선별 |
| 표시 설정 | 프로젝트 | 예 |
| Phase 4A 주석 | 세션 RAM | 아니오 |
| 향후 마스크·북마크 | 미결정 | 별도 승인 |
| 최근 파일·썸네일 | 미결정, 기본 최소화 | 별도 앱 설정 |
| 사용자 preset | 미결정 | 프로젝트 또는 로컬 설정 |

## 검증 항목

- zoom/pan/fit/resize와 WebGL/RGBA 전환 뒤 image pixel 주석 위치가 일치한다.
- 다른 창 크기에서도 image pixel geometry와 화면 고정 handle 크기가 유지된다.
- 원본 변경을 탐지하고 사용자 승인 없이 주석을 재연결하지 않는다.
- 프로젝트 저장이나 캐시 정리가 원본 파일을 변경하지 않는다.
- 이전 schema를 읽을 때 명시적 migration 또는 이해 가능한 오류를 제공한다.
