# Android Canonical Image Coordinates

## 결론

Android 정확 프레임 스파이크의 표시 좌표는 데스크톱과 같은 좌상단 원점, pixel-center와 image-space center 의미를 유지한다. 다만 Android는 container의 rotation과 pixel aspect ratio(PAR)를 canonical image에 실제 적용하고, 데스크톱 v0.5.9는 아직 적용하지 않는 차이가 있다.

## 변환 순서

변환 순서는 다음과 같이 고정한다.

`encoded raster → inclusive crop → PAR correction → clockwise rotation → canonical image → center/scale → EGL physical pixel`

1. crop width와 height는 각각 `right - left + 1`, `bottom - top + 1`이다.
2. PAR은 encoded image의 가로축에 먼저 적용한다. 회전 전 square-pixel width는 `round(cropWidth × parNumerator / parDenominator)`이며 최소 1이다.
3. rotation은 PAR 보정 뒤에 clockwise 0/90/180/270도로 적용한다. 90도와 270도는 canonical width와 height를 교환한다.
4. Fit scale은 `min(renderWidth / canonicalWidth, renderHeight / canonicalHeight)`이고 image center를 EGL render target center에 놓는다.
5. Android 100%는 canonical image 1단위를 EGL render target의 물리 픽셀 1개로 표시한다. dp는 image 좌표나 scale 계산에 사용하지 않는다.

## 점과 픽셀 의미

- image 좌표 원점은 canonical image의 좌상단이다.
- 정수 `(x, y)`는 pixel center를 뜻한다.
- image center는 `(canonicalWidth / 2, canonicalHeight / 2)` 의미를 사용한다.
- GL readback은 bottom-up row이므로 frame identity probe와 signature를 계산하기 전에 좌상단 기준 row로 변환한다.
- SurfaceTexture transform matrix는 decoder buffer의 crop/texture 방향을 처리하고, 제품 shader가 그 앞에서 명시적 clockwise rotation을 역매핑한다.

## 데스크톱 v0.5.9와의 관계

- square-pixel, rotation 0 영상은 데스크톱 View Transform과 수치적으로 같은 image-space와 contain Fit 수학을 사용한다.
- 데스크톱 v0.5.9는 MP4 rotation/PAR metadata를 표시 변환에 적용하지 않는다. 따라서 해당 metadata가 있는 영상은 두 플랫폼의 최종 canonical raster 크기와 방향이 다를 수 있다.
- 이 차이는 decoder/cache/navigation 의미를 바꾸지 않으며, Android UI 코드를 데스크톱 hot path에 공유하지 않는다.
- 이 좌표는 MP4 화면 픽셀 좌표이며 DICOM patient 좌표나 spatial registration이 아니다.

## 정확성 판정

- frame identity는 `(displayFrameIndex, ptsUs, duplicateOrdinal)`와 embedded finder/CRC frame ID가 모두 같아야 한다.
- canonical RGB는 16×16 정수 box-average signature로 비교한다.
- 허용치는 mean absolute error `≤ 6`, p99 `≤ 16`, max `≤ 40`이다.
- 전체 RGB byte equality는 hardware decoder와 YUV→RGB 구현 차이 때문에 사용하지 않는다.
