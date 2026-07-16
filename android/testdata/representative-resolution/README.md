# Representative-resolution fixture lock

이 디렉터리에는 MP4나 전체 golden JSON을 커밋하지 않는다. 비식별 합성 fixture의 불변 identity와 생성 provenance만 `manifest.lock.json`으로 추적한다.

실제 파일은 다음 ignored 경로에 생성한다.

`android/.generated/testdata/representative-resolution/`

고정 RTX 4080 SUPER/NVENC host와 저장소의 고정 FFmpeg에서 생성한다.

```powershell
node .\android\tools\generate-representative-resolution-fixtures.mjs
node .\android\tools\verify-representative-resolution-fixtures.mjs
```

일반 CI는 generated cache가 없어도 tracked 계약만 검사한다.

```powershell
node .\android\tools\verify-representative-resolution-fixtures.mjs --manifest-only
```

생성기는 96×96 marker 프레임만 FFmpeg stdin으로 순차 전송한다. 720p/1080p RGB 전체를 Node 메모리에 모으지 않는다. 각 MP4는 360 frame이며 모든 frame에 기존 16-bit embedded ID, CRC-8/0x07과 finder pattern이 들어간다. full schema-v1 golden은 로컬 generated 경로에 유지한다.

모든 fixture는 BT.709 primaries/transfer/matrix와 limited range를 container와 H.264/HEVC bitstream 양쪽에 명시한다. golden RGB도 같은 BT.709 limited 계약으로 생성한다. 색 메타데이터가 없는 HD 영상을 BT.601 golden과 비교하면 S24의 BT.709 Surface 출력과 signature가 달라지므로 exactness fixture로 인정하지 않는다.

NVENC bitstream은 GPU와 driver에 종속되므로 명령만으로 byte 동일성을 주장하지 않는다. `manifest.lock.json`의 MP4/golden SHA-256과 크기를 권위값으로 사용한다. 다른 host에서 임의 재생성해 lock을 갱신하지 않는다.

S24/high-resolution 전용 job만 manifest의 exact `cache.key`로 generated cache를 복원하고 full verifier를 실행한다. prefix restore는 사용하지 않는다. cache miss는 자동 재인코딩하지 않고 `Pending — immutable fixture cache missing`으로 실패시킨다. 일반 CI의 manifest-only 성공을 고해상도 artifact 검증 성공으로 표현하지 않는다. GitHub Release는 사용하지 않는다.

360 frame은 50 ms repeat에서 단일 60초 hold를 지속하기에 부족하다. smoothness 시험은 여러 hold segment로 구성하고 경계 재배치 구간을 PublicationEvent interval 통계에서 제외한다. 이를 단일 연속 hold 결과로 표현하면 안 된다.

실제 사용자 영상, 파일명, 경로, URI와 식별정보를 fixture, golden, lock 또는 report에 기록하지 않는다.
