# Phase 3B Video Display Adjustment

## 결론

Phase 2.3 decoder/cache와 Phase 3A ViewTransform을 변경하지 않고 MP4 화면 픽셀용 Video Level/Width, Gamma, Inverse, luminance Sharp, candidate preset과 Original 비교를 통합했다.

- 제품 버전: `0.3.1-phase3b`
- MP4 화면 픽셀 보정이며 DICOM HU Window가 아니다.
- Original은 Phase 3A 출력과 byte 단위 동일하다.
- WebGL preset redraw: 약 0.1~0.2ms, texture 재업로드·FFmpeg·seek 증가 0
- WebGL/RGBA parity: mean 0.543, p99 2, max 3
- 순·역 30초 hold: loading 0, seek decode 0, View/Display 상태 유지
- 10분 내구: 38,187회, 오류·seek·parameter texture upload 0, draw p95 0.1ms, RSS 기울기 0.40MiB/분으로 통과
- NSIS·설치 앱 WebGL/RGBA 실사용: 통과

자동 재생, 주석, 이미지 저장, 개인정보 마스킹, 프로젝트 저장과 DICOM/PACS는 시작하지 않았다.

## 의미와 한계

Video Display는 전달받은 MP4에 남아 있는 RGB/YUV 표시 luminance를 조절한다. 손실된 HU나 압축 전 정보를 복원하지 않으며 특정 preset이 진단 정확도를 보장하지 않는다. UI에는 `MP4 화면 픽셀 보정 · HU Window 아님`을 한 번만 표시한다.

## 데이터 모델

`src/domain/videoDisplay.ts`의 `VideoDisplayState`가 공통 의미를 소유한다.

| 필드 | 범위 | 기본값 | 의미 |
| --- | ---: | ---: | --- |
| `level` | 0~1 | 0.5 | 표시 luminance 중심 |
| `width` | 0.02~2 | 1 | 표시 luminance 폭 |
| `gamma` | 0.25~4 | 1 | 1보다 크면 중간톤이 밝아짐 |
| `invert` | boolean | false | 조정 luminance 반전 |
| `sharpAmount` | 0~1 | 0 | 고정 1-pixel radius luminance sharp |
| `presetId` | preset/custom | original | 선택 또는 수동 상태 |
| `revision` | 정수 | 0 | Display 상태 변경 횟수 |

ViewTransform과 별도 상태이며 frame/cache/session payload에 넣지 않는다. 새 파일 session은 revision 0 Original로 초기화하고 같은 session의 frame 이동과 fallback에서는 유지한다.

## 처리 순서와 공식

1. YUV/RGBA를 기존 색 정책으로 RGB 표시값으로 변환
2. RGB에서 BT.601 표시 luminance 계산
3. Level/Width mapping
4. Gamma
5. Inverse
6. luminance Sharp
7. 기존 chroma를 유지하도록 luminance delta만 RGB에 더하고 clamp
8. Phase 3A ViewTransform

Level/Width는 다음 한 수식을 CPU reference와 shader가 공유한다.

```text
lower = level - width / 2
mapped = clamp((luminance - lower) / width, 0, 1)
```

Gamma는 `pow(mapped, 1 / gamma)`다. 따라서 Gamma가 1보다 크면 중간톤이 밝아지고 1보다 작으면 어두워진다. Inverse는 Gamma 뒤 `1 - mapped`다.

## Sharp

Sharp는 원본 복원이 아니라 표시 보정이다. 기본값은 Off이며 상하좌우 1-pixel luminance 이웃에 제한된 unsharp 항을 적용한다.

```text
sharp = clamp(center + amount × 0.25 × (4×center - left - right - up - down), 0, 1)
```

chroma에는 직접 적용하지 않고 출력은 0~1로 clamp한다. Denoise, 다단계 enhancement와 AI super-resolution은 포함하지 않았다.

## Candidate preset

값은 `src/domain/videoDisplay.ts` 한 곳에서 관리하며 shader에 하드코딩하지 않는다.

| Preset | Level | Width | Gamma | Inverse | Sharp |
| --- | ---: | ---: | ---: | --- | ---: |
| Original | 0.50 | 1.00 | 1.00 | Off | 0.00 |
| Lung-like | 0.46 | 0.72 | 1.05 | Off | 0.15 |
| Mediastinum-like | 0.52 | 0.45 | 0.95 | Off | 0.08 |
| Abdomen-like | 0.50 | 0.60 | 1.00 | Off | 0.08 |
| Brain-like | 0.54 | 0.40 | 0.90 | Off | 0.10 |
| Bone-like | 0.62 | 0.65 | 1.00 | Off | 0.25 |
| High Contrast | 0.50 | 0.32 | 1.00 | Off | 0.20 |
| Inverse | 0.50 | 1.00 | 1.00 | On | 0.00 |

Level/Width/Gamma/Sharp를 수동 변경하거나 우클릭 drag하면 Custom으로 전환한다. Original과 Inverse 기본 조합은 preset 식별을 복구한다. frame별 histogram 자동 보정은 밝기 pumping을 막기 위해 사용하지 않는다.

## Sample A~K 평가

실제 11개 영상의 첫·중간·마지막 33 frame을 RGBA reference로 평가했다. 파일명·경로·frame 이미지는 결과에 포함하지 않았다.

| Preset | Black clip min~max | White clip min~max | Mean luminance min~max | Colored overlay 보존 최저 |
| --- | ---: | ---: | ---: | ---: |
| Original | 0.000~0.001% | 0.000~0.312% | 0.246~0.402 | 100.0% |
| Lung-like | 0.074~18.667% | 0.000~0.769% | 0.214~0.428 | 87.7% |
| Mediastinum-like | 9.866~59.885% | 0.000~1.127% | 0.124~0.361 | 69.9% |
| Abdomen-like | 6.443~55.405% | 0.000~0.827% | 0.138~0.377 | 86.7% |
| Brain-like | 10.733~60.271% | 0.000~1.183% | 0.114~0.334 | 67.6% |
| Bone-like | 9.939~59.895% | 0.000~0.632% | 0.093~0.257 | 97.0% |
| High Contrast | 10.754~60.267% | 0.000~2.618% | 0.133~0.411 | 47.9% |
| Inverse | 0.000~0.474% | 0.000~0.001% | 0.598~0.754 | 100.0% |

검은 주변 배경을 포함한 영상에서 narrow Width preset의 black clipping이 크게 집계된다. 특히 Mediastinum/Brain/High Contrast는 사용자 파일럿에서 값 완화 여부를 판단해야 한다. 이 값들은 candidate이며 의료적 표준값이 아니다.

## WebGL2

기존 BT.601 limited YUV→RGB 수식과 candidate 허용 정책을 유지한다. Display uniform과 1-pixel texel size만 추가했고 program·texture는 재생성하지 않는다. frame 수신 때만 Y/U/V texture를 업로드하며 parameter 변경은 uniform 갱신과 draw만 수행한다.

Original에서는 별도 Display 수학을 우회해 Phase 3A RGB 출력과 완전히 동일하다. 실제 UI QA에서 1,169,280 byte 차이 0을 확인했다.

## RGBA fallback

`src/domain/videoDisplayReference.ts`가 WebGL과 같은 luminance, Gamma, Inverse, Sharp 의미를 CPU로 구현한다. context loss와 `CCR_FORCE_RGBA=1`에서도 main process 재디코딩 없이 renderer가 현재 RGBA payload를 보정한다.

같은 frame의 Lung-like + Sharp 비교에서 WebGL/RGBA 채널 오차는 mean 0.543, p99 2, max 3이었다. 허용 기준은 mean 4, p99 12, max 80 이하로 두었다.

실제 406×720 RGBA fallback redraw는 20.6ms였다. 합성 320×240 BT.709 Lung-like는 10.7ms, full-range High Contrast는 6.1ms로 기능과 상태 유지가 통과했다. WebGL의 16ms 목표와 달리 RGBA는 안전한 fallback 우선 경로이며 406×720에서 약 한 frame 수준의 지연이다.

## UI와 입력

- 우측 Video Display panel: preset, Level, Width, Gamma, Sharp, Inverse, 초기 설정, 원본 비교
- 좌클릭 drag: 기존 Pan
- 우클릭 drag: 가로 Width `0.003/pixel`, 세로 위쪽 Level `0.002/pixel`
- `R` 또는 `초기 설정`: Original reset
- `I`: Inverse toggle
- `O` hold/비교 버튼 hold: 임시 Original
- pointer up/leave/cancel, keyup, window blur와 Esc에서 임시 상태 해제
- text/range/select 입력 중 display 단축키 억제
- 일반 wheel frame, Ctrl+wheel Zoom과 기존 탐색 단축키 유지

Original compare는 저장된 DisplayState, frame과 ViewTransform을 변경하지 않고 renderer bypass만 전환한다.

## 정확성·성능·회귀

- Original byte difference: 0 / 1,169,280
- WebGL/RGBA parity: mean 0.543, p99 2, max 3
- WebGL parameter draw: 약 0.1~0.2ms, 목표 16ms 이하
- parameter texture upload 증가: 0
- parameter seek/FFmpeg 증가: 0
- frame 이동·순역 hold Display 유지: true
- ViewTransform 변화: 0
- 순·역 30초 loading: 0 / 0
- 순·역 30초 seek decode: 0 / 0
- 최종 첫 Canvas: 232.4ms
- RGBA redraw: 406×720 20.6ms, 320×240 BT.709 10.7ms, full-range 6.1ms
- 기존 Zoom/Pan/Fit/fullscreen smoke: 통과

## 내구

- 실행 시간: 10.000분
- preset/compare/frame 조작: 38,187회
- 오류: 0
- 최대 seek decode: 0
- parameter 변경 texture upload: 0
- Display draw p95: 0.1ms
- 후반 Browser RSS 기울기: 0.40MiB/분

## 설치본 QA

- 설치 파일: `artifacts/CT-Cine-Reviewer-Setup-0.3.1-phase3b.exe`
- SHA-256: `7a31a58be3bf595cefb160f4977ccaa2e14512b1d8193f29325821bd57aeaf61`
- unpacked file 91개, package privacy inspection 통과
- silent upgrade exit 0, 설치 실행 파일 product version `0.3.1.0`
- 기본 WebGL 설치 앱: 실제 대표 영상 Original, Bone-like, Level/Width/Gamma/Sharp slider, Inverse, Custom 전환 통과
- frame 1→2 이동 뒤 Custom과 Zoom 125% 유지, fullscreen 진입·종료 통과
- 다른 파일 전환 뒤 Original, L/W 0.50/1.00, Gamma 1.00, Sharp 0, revision 0과 Fit 100% 확인
- context loss, BT.709, full-range와 `CCR_FORCE_RGBA=1` 기능은 제품 자동화에서 통과
- 설치 앱을 `CCR_FORCE_RGBA=1`로 실행해 72MiB segment cache(대표 영상에서 1-41), preset 적용, frame 2 이동 시 상태 유지와 Original 복귀를 확인했다.
- 종료 뒤 관련 프로세스 0, TCP 연결 0, frame/raw/YUV 잔존 0
- 원본 11개 aggregate SHA-256은 설치 전후 `790fd7baccf41c1f0e72fac6c126067704cb961db400b61eecc7b0bf1f4e9552`로 동일

## 개인정보와 보안

- 원본 읽기 전용, frame 디스크 저장 없음
- parameter는 숫자·boolean만 보유하며 파일명·경로를 저장하지 않음
- 외부 연결·로그인·텔레메트리 없음
- renderer에 Node/파일 시스템/child_process 노출 없음
- 실제 sample과 분석 frame은 Git/package에 포함하지 않음

## 알려진 한계와 파일럿 체크리스트

- Candidate preset 이름은 실제 촬영 당시 HU window를 뜻하지 않는다.
- narrow Width 후보의 black clipping과 colored overlay 감소가 크므로 A~K 화면을 사용자가 직접 비교해야 한다.
- Sharp 0.15~0.25의 noise/halo 체감과 최대 허용치를 확인해야 한다.
- 우클릭 drag 민감도 0.003/0.002가 실제 사용에 적합한지 확인해야 한다.
- Gamma > 1 밝아짐 의미가 사용자 기대와 맞는지 확인해야 한다.
- RGBA CPU fallback은 기능 우선 경로이며 고해상도 장시간 조작 성능은 추가 GPU 조합에서 확인할 수 있다.
- Explorer cross-window drop과 코드 서명은 이번 기능 완료를 막지 않는다.

## 다음 단계 진입 조건

1. Candidate preset과 Sharp/drag 민감도에 대한 사용자 파일럿 피드백
2. preset 값 유지 또는 조정 승인
3. 주석 도구의 최소 범위와 입력 충돌 규칙 별도 승인

승인 전 자동 재생, 주석, 이미지 저장, 마스킹, 프로젝트 저장 또는 DICOM/PACS를 시작하지 않는다.
