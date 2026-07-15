# CT Cine Reviewer v0.5.8 Handoff

## 결론

v0.5.8은 v0.5.7에서 남은 5프레임 연속 이동의 간헐적 정지를 줄이기 위한 묶음 선읽기 보완판이다. 2GiB RAM cap과 단일 prefetch worker를 유지하면서, 이동 방향 앞쪽 준비량이 부족할 때 최대 4개 block을 FFmpeg 한 번으로 채운다. 디코더 출력, 프레임·PTS, 표시, 주석과 내보내기 의미는 변경하지 않았다.

## v0.5.7 실사용 근거

- 1280×720, 3,766 frames, H.264, 24fps, LRU 영상
- 1프레임 정·역방향 연속 이동: 끊김 없음
- 5프레임 정·역방향 연속 이동: 특정 cache 경계에서 간헐적 정지
- 진단: 2,025MiB/2,048MiB, 준비 1,536/3,766, prefetch process 175회, eviction 178회, foreground seek decode 4회

한 block이 24 frames라 1프레임 이동은 약 24회, 5프레임 이동은 약 5회의 반복 입력으로 다음 block에 도달한다. v0.5.7의 block별 FFmpeg 실행이 빨라진 소비 속도를 네 차례 따라잡지 못한 것으로 판정했다.

## 변경 내용

- 이동 방향 앞쪽 8-block을 high-water 후보로 보호한다.
- 준비된 앞쪽 block이 4개 미만이면 연속된 최대 4-block을 FFmpeg 한 번으로 decode한다.
- batch 대상 전체를 in-flight로 먼저 예약하고, block이 도착할 때마다 cache에 넣어 foreground 중복 decode를 막는다.
- 현재 batch가 끝나면 가장 최신 이동 방향으로 전환하고 prefetch process는 동시에 하나만 실행한다.
- 보호 block을 제거하지 않는 범위만 계산해 작은 cache에서는 batch 크기를 자동 축소한다.
- 2GiB cap, 디스크 cache 없음, full mode와 `CCR_FORCE_RGBA=1` rollback은 유지한다.

## 자동 검증

- `npm test`: 102/102 통과
- `npm run build`: 통과
- YUV block cache: batch 전체 예약, block별 즉시 foreground 재사용, 중복 loader 0
- 합성 강제 LRU: 한 FFmpeg process로 최대 4-block refill, 정→역방향 전환, foreground seek decode 0, budget 이하
- 비식별 로컬 샘플 11개, 128MiB 강제 LRU: background eviction 0, 첫 frame miss 0, 첫 window 경계 hit 11/11, 경계 foreground seek decode 0, fingerprint 오류 0

## Windows 설치 파일

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.8.exe`
- 크기: 143,706,303 bytes
- SHA-256: `6d20965d3f8999565bf91bd7960611b7aa574545baa1134c1884d73b05559d14`
- 실행 파일 제품 버전: `0.5.8.0`
- NSIS x64, 현재 사용자 설치, 관리자 권한 요구 없음
- unpacked 91개 파일, privacy 검사, `latest.yml`·blockmap·업데이트 checksum 검증 통과

## 실사용 성공 기준

1. 같은 1280×720 영상을 처음→끝까지 5프레임 단위로 연속 이동한다.
2. 끝→처음도 같은 방식으로 이동한다.
3. 두 방향 모두 체감 정지가 없어야 한다.
4. 정보 탭의 `제거 / 재디코드`에서 두 번의 전체 이동 동안 foreground 재디코드 증가가 0이어야 한다.
5. `미리 읽기` process 횟수가 v0.5.7보다 뚜렷하게 줄어야 한다.
6. 메모리는 2,048MiB를 넘지 않아야 한다.
7. 1프레임 이동, 임의 점프, 파일 전환과 앱 종료가 기존처럼 동작해야 한다.

준비 window와 8-block 범위를 벗어난 임의 점프는 새 디코딩이 필요할 수 있다. 이번 성공 기준은 순차 5프레임 연속 이동이며 임의 점프의 로딩 0은 아니다.

## 배포 상태

이 설치파일은 로컬 실사용 검증용이다. 아직 커밋·push·태그·GitHub Release를 만들지 않았다. 검증 후 `main`에 push하면 자동 Release 워크플로가 `v0.5.8` 태그와 공개 Latest Release를 생성한다.
