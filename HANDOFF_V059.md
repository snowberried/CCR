# CT Cine Reviewer v0.5.9 Handoff

## 결론

v0.5.9은 v0.5.8의 5프레임 이동 성능 기준선을 유지하면서 프레임 cache RAM 상한을 PC 전체 RAM에 맞춰 수동 선택할 수 있게 한 사용자 합격 안정판이다. 기본값은 기존과 같은 `자동 (최대 2 GiB)`이며, 수동값은 선예약량이 아니라 cache가 점진적으로 커질 수 있는 최대치다.

## 선택 정책

| 감지한 전체 RAM | 수동 선택 가능 |
| ---: | --- |
| 8 GiB 미만 | 없음, 자동만 사용 |
| 8~15 GiB | 2 GiB |
| 16~23 GiB | 2 / 4 GiB |
| 24~31 GiB | 2 / 4 / 6 GiB |
| 32 GiB 이상 | 2 / 4 / 6 / 8 GiB |

Windows의 hardware reserved 차이를 고려해 Node가 보고한 전체 RAM을 GiB 단위로 반올림한 뒤 구간을 판정한다. 현재 PC에서는 31.9 GiB가 감지돼 2 / 4 / 6 / 8 GiB가 허용됐다.

## 실제 적용 규칙

- 자동은 기존 `min(2 GiB, total RAM × 12.5%, available RAM × 25%)`를 유지한다.
- 수동은 파일을 열 때마다 전체·현재 여유 RAM을 다시 읽는다.
- 실제 상한은 `min(선택값, total RAM × 25%, available RAM × 50%)`다.
- 실제 상한이 I420 cache 최소 안전값 256 MiB보다 작으면 기존 RGBA fallback 정책을 사용한다.
- RAM은 미리 확보하지 않고 decode된 block만큼만 점진 할당한다.
- 설정 변경은 이미 열린 영상의 cache를 재시작하지 않고 다음 파일부터 적용한다.
- 저장된 수동값이 다른 PC의 허용 범위를 벗어나면 자동으로 돌아간다.

## UI와 진단

- 설정창 `프레임 캐시 RAM`에서 현재 PC가 허용하는 값만 선택한다.
- 선택은 로컬 설정 `ccr.cacheMemoryGiB.v1`에 저장한다.
- 설정창은 현재 영상의 선택값과 실제 적용 상한을 함께 표시한다.
- 정보 탭은 `RAM 설정`에 선택값을, 기존 `메모리`에 실제 사용량/적용 상한을 각각 표시한다.
- 원본 영상, 파일명이나 사용 정보는 외부로 전송하지 않는다.

## 검증

- RAM 구간, 저장 복구, 허용되지 않은 값의 자동 복귀, 여유 RAM 50% 제한 테스트 추가
- low-memory에서 최소 안전값 미달 시 기존 fallback 사용 확인
- session metadata의 선택값 전달 확인
- 전체 자동 테스트 106/106 통과
- renderer·Electron TypeScript와 production build 통과
- NSIS package privacy, unpacked 91개 파일, update metadata와 checksum 검증 통과
- 사용자 실사용에서 8 GiB 수동 설정, `full` cache mode와 약 `4964.9 MiB / 8009.9 MiB`의 점진 사용을 확인해 안정판으로 승인했다.

Windows UI 자동화에서는 동일 app ID가 이미 설치된 v0.5.8을 열었고, 별도 QA 실행 파일은 `ShellExecuteW returned 5`, 로컬 browser 연결은 runtime property 충돌로 중단됐다. 따라서 실제 v0.5.9 설치 후 설정창 클릭·작은 창 배치는 사용자 파일럿에서 확인한다. 제품 코드·패키지 검증 실패는 아니다.

## Windows 설치 파일

- 사용자 합격 로컬 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.9.exe`
- 로컬 크기: 143,707,272 bytes
- 로컬 SHA-256: `afcb4377e8ca5306fde9fc6ead59d3a32682230e8793d5988b53b80463bdf4b2`
- 공개 Release 크기: 143,707,402 bytes
- 공개 Release SHA-256: `d489c82b6badc8b81cda81a79f8deea139c8216c7d94206245e098c6e94bc06e`
- 실행 파일 제품 버전: `0.5.9.0`
- NSIS x64, 현재 사용자 설치, 관리자 권한 요구 없음

## 안정판 기준선과 배포 상태

- 기준 commit: `92f26ddb3fcbfd125986cf85f21560fb9a5655b2`
- tag: `v0.5.9` (기준 commit을 가리키는 lightweight tag)
- 공개 Release: <https://github.com/snowberried/CCR/releases/tag/v0.5.9>
- Release 상태: Latest, EXE·SHA256·blockmap·`latest.yml` 4개 자산 확인
- Desktop CI: <https://github.com/snowberried/CCR/actions/runs/29392342278>
- Windows Release workflow: <https://github.com/snowberried/CCR/actions/runs/29392342210>

로컬 합격 설치파일과 GitHub runner 재빌드 설치파일은 같은 기준 commit에서 만들어졌지만 NSIS/PE 생성 시각 때문에 byte-identical하지 않다. 두 checksum을 혼동하지 않는다.

## 재현 명령

```powershell
npm.cmd test
npm.cmd run build
npm.cmd run verify:package
```

위 명령은 기준선에서 자동 테스트 106/106, production build, unpacked 91개 파일, package privacy와 update metadata 검증을 통과했다.

## 지원 범위와 알려진 제한

- Windows x64 NSIS 설치 앱, 로컬 MP4 보조 검토, 정확 frameIndex 탐색과 RAM cache가 지원 범위다.
- DICOM/PACS, AI, 클라우드, 자동 재생, 오디오와 프로젝트 저장은 지원하지 않는다.
- HEVC Main10, HDR와 Dolby Vision은 v0.5.9 데스크톱 안정판의 보장 범위가 아니다.
- Explorer cross-window drag/drop 실제 파일럿 검증은 기존 이월 항목이다.
