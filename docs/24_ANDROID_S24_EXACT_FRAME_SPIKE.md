# Android S24 Ultra Exact-Frame Spike

## 결론

데스크톱 v0.5.9 안정판 commit `92f26ddb3fcbfd125986cf85f21560fb9a5655b2`에서 `codex/android-s24-spike` 브랜치를 시작한다. 전체 모바일 제품을 만들지 않고 Gate 0~3의 정확 frameIndex·PTS·표시 세대 검증만 수행한다.

## 환경 기준선

- JDK 17.0.19
- Android SDK Platform 17 / API 37.0 revision 2
- Build Tools 36.0.0
- platform-tools / ADB 37.0.0
- AGP 9.3.0, Gradle Wrapper 9.5.0
- minSdk 34, compileSdk/targetSdk 37
- S24 Ultra 연결 상태: 없음, 실기기 Gate `Pending`

## 프로젝트 경계

- Android 구현은 저장소 `android/` 아래 독립 Gradle 프로젝트다.
- 데스크톱 decoder/cache/navigation hot path와 폴더를 이동하거나 공통화하지 않는다.
- 공통 의미는 골든 JSON, frame key, PTS 정수 변환과 좌표 계약으로만 검증한다.
- SAF 읽기 전용 MP4, SDR 8-bit H.264와 HEVC Main 8만 초기 대상으로 한다.
- INTERNET와 광범위 저장소 권한, 원격 분석, 프로젝트 저장, DICOM/PACS, AI와 클라우드는 제외한다.

## Gate 상태

| Gate | 상태 | 판정 |
| --- | --- | --- |
| 0 — v0.5.9 동결 | 통과 | tag/Latest Release와 artifact 확인 |
| 1 — Android 환경/프로젝트 | 진행 중 | local/CI build 필요 |
| 2 — exact decode/render | 대기 | Gate 1 뒤 진행 |
| 3 — golden/S24 | 대기 | 연결 기기 없음 |
