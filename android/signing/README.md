# CCR Android internal-pilot signing policy

## 현재 상태

`SIGNING_BASELINE_READY`

2026-07-28 KST에 사용자의 안전한 대화형 PowerShell에서 canonical primary와 서로 다른
두 backup을 검증했다. 세 JKS는 byte size와 SHA-256이 같고, alias·certificate와 private
key 접근 검사가 모두 통과했다. 검증 증거는 저장소 밖 evidence root에 보관한다.

공개 signing policy 세트는 다음 파일이다. private JKS, backup 경로와 password는 포함하지
않는다.

- `ccr-internal-pilot-v1-cert.pem`
- `ccr-internal-pilot-v1-cert.sha256`
- `ccr-internal-pilot-v1-policy.json`

- public certificate SHA-256:
  `3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`
- primary private key access: `PASS`
- verified backup count: `2`

## 고정 정책

- purpose: `CCR Android internal pilot only`
- lineage: `ccr-internal-pilot-v1`
- alias: `ccr-internal-pilot-v1`
- artifact set revision: `5`
- candidate signing mode: `SIGNED_CANDIDATE`
- standard Android debug key와 공유 금지
- Play production key와 공유 금지
- 별도의 명시적 migration 없이 key rotation 금지

인증서 SHA-256, subject, 생성 시각과 유효기간은 초기화 스크립트가 공개 인증서와
`ccr-internal-pilot-v1-policy.json`에 기록한다. private JKS, password와 backup은 저장소에
기록하지 않는다.

## build 역할 분리

- 일반 `internalDebug`와 CI compile/test는 `CI_EPHEMERAL_DEBUG` 또는 일반 개발 debug다.
  S24 candidate나 보존 artifact가 아니다.
- S24 candidate는
  `android/scripts/build-s24-alpha6-candidate.ps1`만 사용한다.
- candidate wrapper는 명시적 opt-in, key·공개 인증서·두 백업 preflight,
  `signingReport`, 네 APK signer 일치와 revision 5 manifest 검증을 모두 통과해야 한다.
- 네 역할은 `debugApp`, `debugTest`, `benchmarkApp`, `macrobenchmarkTest`다.
- 다음 단계는 final clean HEAD에서 signed candidate APK 네 개와 revision 5 artifact
  세트를 생성하는 별도 작업이다. S24 Gate와 사용자 smoothness 검증은 아직 Pending이다.

사고 기록은 [SIGNING_INCIDENT_2026-07-27.md](SIGNING_INCIDENT_2026-07-27.md), 복구와
백업 절차는 [SIGNING_RECOVERY_RUNBOOK.md](SIGNING_RECOVERY_RUNBOOK.md)를 따른다.
