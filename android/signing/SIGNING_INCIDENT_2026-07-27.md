# Android signing incident — 2026-07-27

## 결론

`LEGACY_ALPHA4_DEBUG_SIGNING_KEY_LOST`

확인된 사실은 기존 인증서에 대응하는 private key를 현재 복구하지 못했다는 것이다.
유출이나 탈취가 확인된 것은 아니다. 추가적인 드라이브·사용자 프로필·복구 프로그램
검색은 수행하지 않는다.

## 식별자

- historical legacy debug certificate:
  `49379c1b2a2fec8a50c320955a7027c515aff10f28483b08ae9c27b3ffcfbef0`
- legacy private key: `unavailable`
- 현재 사용자 standard debug certificate:
  `db0a604f8d02d5d82cf9a4f0d89f1ba31400578cb36ec50869214a698be414b0`
- 폐기한 별도 생성 APK certificate:
  `4122e9cf0db971a79165db7ae7d14d0499a6d89846a33f75c47c7844630dbda0`

`49379c…`, `db0a604f…`, `4122e9cf…` 중 어느 것도 새 internal-pilot candidate
lineage로 사용하지 않는다.

새 signing baseline:

- lineage: `ccr-internal-pilot-v1`
- public certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`
- artifact set revision: `5`
- primary와 두 backup 검증: `PASS`
- private JKS와 password의 Git 보관: 금지

## 구조적 원인

자동 생성되는 Android debug signing을 장기 candidate identity로 사용했고, Alpha 4의
debug signer를 가진 공통 pinned helper가 Alpha 6까지 암묵적으로 상속됐다. 따라서
제품 runtime과 역방향 프레임 구현이 정상이어도, 다른 PC·사용자 home·재생성된
`debug.keystore`에서 만든 APK는 기존 artifact와 같은 검증 신원을 재현할 수 없었다.

문제는 특정 keystore 파일을 더 오래 찾지 못한 것이 아니라 다음 경계가 없었던 것이다.

- 일반 개발 debug와 장기 candidate signer의 분리
- versioned signing lineage와 공개 fingerprint
- private key의 복구 가능한 두 백업
- build 전 key·backup·public policy preflight
- 네 APK의 signer 일치와 provenance 검증

## 결정과 증거 보존

- `49379c…`는 historical legacy signer로만 보존한다.
- Alpha 4/5 contract와 Alpha 6 artifact set revision 4는 historical evidence다.
- 새 candidate는 `ccr-internal-pilot-v1`과 artifact set revision 5만 사용한다.
- 2026-07-28 KST에 primary와 서로 다른 두 backup의 byte-identical JKS, alias,
  certificate와 private key 접근 검증을 완료했다.
- 일반 debug와 `CI_EPHEMERAL_DEBUG` APK는 candidate verifier가 거부한다.
- 제품 runtime은 signing reset 때문에 변경하지 않는다.
- 기존 revision 4 evidence를 새 signer로 재서명하거나 덮어쓰지 않는다.
