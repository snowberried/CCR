# Phase 1 Spike Results

## 상태

Phase 1B의 고정 FFmpeg 배포판 준비와 실제 ffprobe 연결에 이어, Phase 1C의 실제 프레임 디코딩·정확성 검증·캐시 전략 비교까지 완료했다. 제품 재생, 보정, 주석, 이미지 저장과 DICOM/PACS 기능은 시작하지 않았다.

Phase 1C의 현재 추천안은 **FFmpeg stdout RGBA rawvideo + 61프레임 RAM 구간 캐시(뒤 20, 현재 1, 앞 40)**다. 세부 실측은 `09_FRAME_DECODING_AND_CACHE.md`에 기록했다.

## 테스트 환경

- OS build: Windows `10.0.26200`, x64
- CPU: AMD Ryzen 7 5800X3D
- RAM: 약 31.9 GiB
- Node.js: `v24.16.0`
- Electron: `43.1.0`
- FFmpeg/ffprobe: `n8.1.2-21-gce3c09c101-20260630`
- FFmpeg 구성: Windows x64, shared, LGPLv3

## Phase 1B Sample A

`local-samples/`의 사용자 승인 영상 후보 11개 중 하나를 무작위 선택해 로컬 비식별 별칭으로 분석했다. 원래 파일명과 전체 경로는 기록하지 않았고 원본 영상은 수정하지 않았다.

이 절의 Sample A는 Phase 1B 당시 사용한 518프레임 짧은 샘플을 뜻한다. Phase 1C에서는 대표·짧은 샘플군을 다시 구성했으므로 현재 별칭과 혼동하지 않는다.

| 항목 | 결과 |
| --- | --- |
| 파일 크기 | 5,550,007 bytes |
| 컨테이너 | `mov,mp4,m4a,3gp,3g2,mj2` |
| 비디오 코덱 | H.264 |
| 오디오 스트림 | 1개 |
| 해상도 | 406 × 720 |
| 회전 메타데이터 | 없음 |
| duration | 21.583333초 |
| nominal FPS | 24/1 |
| average FPS | 24/1 |
| time base | 1/90000 |
| 메타데이터 프레임 수 | 518 |
| 실제 frame entry 수 | 518 |

`duration × average FPS`는 517.999992로 실제 518개와 사실상 일치한다. 소수점 duration 표기의 반올림 차이이며 프레임 누락으로 판단할 근거는 없다.

## PTS와 시퀀스

| 항목 | 결과 |
| --- | --- |
| 첫 PTS | raw `0`, 0초 |
| 마지막 PTS | raw `1938750`, 21.541667초 |
| 중앙 PTS 간격 | 약 0.041667초 |
| 큰 PTS gap | 0건 |
| PTS 누락 | 0건 |
| PTS 형식 오류 | 0건 |
| PTS 중복 | 0건 |
| PTS 역행 | 0건 |
| frameIndex 불연속 | 0건 |
| duration 누락 entry | 0건 |

큰 gap은 양수 PTS 간격이 중앙 간격의 3배를 초과한 경우로 정의했다. `FrameSequenceValidation`은 연속 frameIndex, 완전하고 유효한 PTS, 단조 증가를 모두 통과했다.

## Keyframe

- keyframe 수: 4개
- keyframe 간 중앙 간격: 109프레임
- keyframe 최대 간격: 218프레임

## 성능

| 구간 | 결과 |
| --- | --- |
| ffprobe 실행 | 약 689.4ms |
| JSON 크기 | 1,067,072 bytes |
| 파싱·검증 | 약 7.9ms |
| 전체 처리 | 약 698.3ms |

초기 목표였던 ffprobe 메타데이터 분석 2초 이내를 이 Sample A에서 충족했다. 이는 현재 PC와 한 개 샘플에서 측정한 값이며 다른 길이·코덱 영상의 보장값이 아니다.

## 구현과 테스트

- `spawn` 배열 인자와 `shell: false`로 ffprobe 실행
- 30초 timeout, AbortSignal 취소, 64MiB 결합 출력 제한
- stderr와 파일 경로를 사용자 오류에 포함하지 않는 코드 기반 오류 매핑
- raw ffprobe JSON은 Electron adapter 내부에서만 처리
- 정상 mock, 누락·N/A·가변 duration·회전·PTS 이상 단위 테스트
- 비의료 synthetic MP4 실제 probe 통합 테스트
- 한글·공백·특수문자 경로, 오디오 전용 파일과 손상 파일 통합 테스트
- 자동 테스트 18개 통과

## Phase 1C 프레임 디코딩 결과

Phase 1C에서는 비식별 로컬 별칭 세 개를 사용했다.

| 샘플 | 역할 | 길이 | 프레임 | 해상도·코덱 |
| --- | --- | ---: | ---: | --- |
| Sample A | Representative | 119.958초 | 2,879 | 406×720 H.264 |
| Sample B | Representative | 106.667초 | 2,560 | 406×720 H.264 |
| Sample C | Short | 21.583초 | 518 | 406×720 H.264 |

- 전체 framehash와 ffprobe PTS를 presentation order로 대조해 세 샘플 모두 프레임 수·PTS 불일치 0건을 확인했다.
- first/last/임의 중간/keyframe 경계/cache 안팎 이전 프레임과 100회 순·역·교대 탐색의 픽셀 fingerprint 오류가 0건이었다.
- 전체 raw RAM 캐시는 짧은 Sample C도 raw 약 578MiB, RSS 증가 약 638MiB를 사용해 제외했다.
- 전체 PNG 디스크 캐시는 3.7~22.0초와 132~761MiB가 필요하고 민감정보 잔존 위험이 있어 제외했다.
- 181프레임 RAM 캐시는 약 202MiB와 952~1,217ms miss p95를 보여 제외했다.
- 61프레임 RAM 캐시는 약 68MiB, hit p95 0.003ms 미만, miss p95 365.9~418.3ms, 먼 seek 312.4~365.9ms였다.
- 실제 Electron IPC에서 1,169,280-byte RGBA payload 30회 왕복은 p95 약 3.4ms로 현재 해상도에서 병목이 아니었다.
- 취소 응답은 27.4~31.9ms였고 stale result가 화면에 적용된 사례는 없었다.
- 최종 자동 테스트 21개와 TypeScript/Electron/Vite 프로덕션 빌드가 통과했다.

## 남은 위험과 다음 결정

- 현재 자산은 LGPLv3 shared build이며 제품 배포 전 FFmpeg와 포함된 외부 라이브러리의 정확한 소스 제공·고지 절차를 별도로 완성해야 한다.
- BtbN archive에는 단일 `LICENSE.txt`만 포함되어 있어 외부 라이브러리별 notice 검토가 제품 패키징 단계에 남아 있다.
- Phase 1C 샘플 세 개가 모두 406×720 H.264이므로 H.265, 다른 해상도, VFR과 손상된 실제 영상에 대한 대표성은 아직 없다.
- 고정 20-back/40-forward 캐시는 역방향 연속 탐색에서 miss가 더 많았다. Phase 2에서 이동 방향에 따라 비율을 전환하는 방식은 별도 측정 후 적용한다.
- Phase 2 최소 뷰어 진입을 권고하지만 사용자 승인 전에는 시작하지 않는다.
