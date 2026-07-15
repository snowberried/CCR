# CT Cine Reviewer v0.5.7 Handoff

## 결론

v0.5.7은 2GiB RAM 예산보다 큰 영상에서 빠른 이동 중 반복되던 foreground 재디코딩을 줄이기 위한 LRU cache 보완판이다. 전체 영상을 background에서 끝까지 훑지 않고 현재 위치와 이동 방향을 기준으로 준비·선읽기한다. 디코더 출력, 프레임·PTS, 표시, 주석과 내보내기 의미는 변경하지 않았다.

## 변경 내용

- LRU background warmup을 전체 영상이 아니라 RAM 예산에 들어가는 첫 window로 제한했다.
- 현재 block과 실제 이동 방향 앞쪽 최대 4개 block을 우선 유지하고 미리 읽는다.
- 이동 방향이 바뀌면 선읽기 방향도 전환한다.
- foreground와 선읽기가 같은 block을 요청하면 기존 `getOrLoad`에서 한 번만 디코딩한다.
- 정보 탭에 `캐시 준비`, `제거 / 재디코드`, `미리 읽기` 진단을 추가했다.
- 2GiB soft cap, 디스크 cache 없음, full mode와 `CCR_FORCE_RGBA=1` rollback은 유지했다.

## 자동 검증

- `npm test`: 100/100 통과
- `npm run build`: 통과
- 3-block 합성 강제 LRU: 첫 window hit, 다음 traversal block 선읽기와 foreground seek decode 0 확인
- 비식별 로컬 샘플 11개, 128MiB 강제 LRU: background eviction 0, 첫 frame miss 0, 첫 window 경계 hit 11/11, 경계 foreground seek decode 0, fingerprint 오류 0

## Windows 설치 파일

- 파일: `artifacts/CT-Cine-Reviewer-Setup-0.5.7.exe`
- 크기: 143,705,755 bytes
- SHA-256: `79491309a37b26356e6fad565b795bb0ef5cbd661eaf18c2e4c935bc3f1bcd5b`
- 실행 파일 제품 버전: `0.5.7.0`
- NSIS x64, 현재 사용자 설치, 관리자 권한 요구 없음
- unpacked 91개 파일, privacy 검사, `latest.yml`·blockmap·업데이트 checksum 검증 통과

## 실사용 확인 항목

1. 기존 버전을 종료하고 v0.5.7을 설치한다.
2. 같은 장시간 영상을 열고 정보 탭에서 mode가 `lru`인지 확인한다.
3. 처음부터 끝까지 기존과 같은 방식으로 빠르게 이동한다.
4. `디코딩 중` 표시 빈도와 체감 정지 여부를 확인한다.
5. 정보 탭의 `제거 / 재디코드`, `미리 읽기` 값을 기록한다.
6. 끝에서 처음 방향으로도 빠르게 이동해 역방향 선읽기를 확인한다.
7. 앱 종료 후 CT Cine Reviewer, FFmpeg와 ffprobe 프로세스가 남지 않는지 확인한다.

준비 window와 4-block 선읽기 범위를 벗어난 직접 점프는 새 디코딩이 필요할 수 있다. 이번 변경의 성공 기준은 임의 점프를 포함한 로딩 0이 아니라 순차·빠른 이동 중 반복 정지 감소다.

## 배포 상태

이 설치파일은 로컬 실사용 검증용이다. 아직 커밋·push·태그·GitHub Release를 만들지 않았다. 검증 후 `main`에 버전 증가 커밋을 push하면 자동 Release 워크플로가 `v0.5.7` 태그와 공개 Latest Release를 생성한다.
