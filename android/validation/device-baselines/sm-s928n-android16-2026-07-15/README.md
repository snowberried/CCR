# SM-S928N Android 16 Gate 3 기준선

이 디렉터리는 기존 비식별 Gate 3 증거를 요청된 device-baseline 위치에 동결한 사본이다. 원본 사용자 영상이나 새 실기기 측정값을 추가하지 않았다.

## 기준

- 기준 tag: `android-v0.1.0-gate3-pass`
- source commit: `61e85dcec314b1ec94faf554262db8586abdef51`
- app APK SHA-256: `a07b46817d1b52934d2b1d5d63245b61f6738a2cb632ba5357de2cedebd401eb`
- instrumentation APK SHA-256: `1e2ded93b98ecca388afb75e7cdcaf7e97023d79d352b50f44f4ad0a0adf8f6e`
- 당시 로컬 source report SHA-256: `04cfe47587106ea3d51b754379d6d1fbcee95cd1848be15c16ddbfddaa2a6bbd`
- sanitized report SHA-256: `5f801d03c1d2023c7d915ff4c1e6869d147e72f868a472e0d5c632e13ba01a5e`
- fixture checksum manifest SHA-256: `4172bc38b4cf691660bdd64c56f56a279fe936ed7e1307fa659ee8c056daaf73`
- fixture 수: 16개

fixture checksum manifest 값은 sanitized report의 `fixtureSha256` 16개 항목을 파일명 오름차순으로 정렬하고 `sha256␠␠filename\n` 형식으로 연결해 계산했다. 원본 fixture archive의 별도 hash라고 해석하지 않는다.

## 기기와 결과

- 제조사/모델: Samsung `SM-S928N`
- Android/API: Android 16 / API 36
- build: `BP4A.251205.006.S928NKSS6DZF3`
- security patch: `2026-06-05`
- codec components: `c2.qti.avc.decoder`, `c2.qti.hevc.decoder`
- fixture/frame identity mismatch: 0
- publication invariant violation: 0
- write open: 0
- software decoder fallback: 0

latency와 memory는 측정 snapshot일 뿐 성능 합격선이 적용되지 않았다.

## 개인정보와 무결성

- ADB serial, 사용자명, 로컬 절대경로와 파일명을 포함하지 않는다.
- 환자 영상, 환자 정보, 실제 사용자 파일 또는 화면 캡처를 포함하지 않는다.
- `checksums.sha256`은 이 디렉터리의 sanitized report 무결성을 검증한다.
