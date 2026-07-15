# Android 로컬 비식별 파일 파일럿

이 디렉터리에서 Git이 추적하는 파일은 이 문서와 `manifest.example.json`뿐이다. 실제 MP4와 작성한 로컬 manifest는 저장소 밖에 두거나 이 디렉터리의 무시되는 파일로만 유지한다.

## 개인정보 원칙

- 환자명, 등록번호, 검사번호, 생년월일 또는 원본 파일명을 기록하지 않는다.
- 절대경로, 휴대폰 저장 위치, 기기 serial을 manifest·로그·화면 캡처에 기록하지 않는다.
- 실제 영상, 영상 화면, 작성한 manifest를 Git, CI, GitHub artifact 또는 외부 서비스로 전송하지 않는다.
- `localFixtureId`에는 `sample-a`처럼 비식별 별칭만 사용한다.

## 준비

1. `manifest.example.json`을 저장소 밖의 로컬 작업 위치에 복사한다.
2. 실제 파일의 비식별 기술 정보만 로컬 사본에 입력한다. 파일 hash가 필요하면 tracked 문서가 아닌 로컬 사본에만 추가한다.
3. 데스크톱 기준 frame index와 PTS를 선택하되 파일명과 경로는 기록하지 않는다.
4. 앱에서는 SAF로 파일을 읽기 전용으로 연다.

## 수동 파일럿 체크리스트

- [ ] 처음 열기와 index 구축이 성공한다.
- [ ] first, middle, last 기준 프레임이 데스크톱 결과와 일치한다.
- [ ] 선택한 20개 reference의 0-based frame index와 PTS가 일치한다.
- [ ] 짧은 ±1/±5와 길게 누르기 이동이 요청 방향과 경계를 지킨다.
- [ ] 길게 누르다 손을 떼거나 취소한 뒤 requested frame overshoot가 0이다.
- [ ] 빠른 연속 입력 뒤 마지막 요청 프레임만 표시된다.
- [ ] 첫 파일의 첫 프레임과 두 번째 파일의 첫 프레임이 공백 없이 표시된다.
- [ ] H.264→H.264, H.264→HEVC, HEVC→H.264, HEVC→HEVC 전환이 모두 표시된다.
- [ ] 먼 PTS timeline seek 뒤 정확한 requested frame이 표시된다.
- [ ] 세로↔가로 전환 뒤 같은 requested frame이 복구된다.
- [ ] 홈↔복귀 뒤 같은 requested frame이 복구된다.
- [ ] screen off/on 뒤 같은 requested frame이 복구된다.
- [ ] 파일 A를 보다가 파일 B를 열면 B만 표시되고 A의 늦은 프레임은 게시되지 않는다.
- [ ] ±1/±5 연속 탐색의 주관적 부드러움을 비식별 메모로 기록한다.
- [ ] 공백, 녹색 화면, 잘못된 프레임, crash가 있으면 비식별 재현 단계만 기록한다.

이 수동 파일럿이 끝나기 전 Gate 4A 전체 판정은 `Pending`이다.
