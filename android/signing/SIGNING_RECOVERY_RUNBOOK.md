# CCR Android signing recovery runbook

## 저장 위치 정책

- private key primary:
  `%USERPROFILE%\CCR-Secrets\Android\ccr-internal-pilot-v1.jks`
- artifact root:
  `%USERPROFILE%\Documents\CCR-Artifacts`
- evidence root:
  `%USERPROFILE%\Documents\CCR-Evidence`
- private key backup: 사용자가 지정하는 서로 다른 두 디렉터리
- `C:\tmp`: final artifact, evidence 또는 signing backup으로 사용 금지

private key와 backup은 저장소 밖에만 둔다. password는 password manager에 보관하며
문서, shell history, 채팅, Gradle argument, 로그에 기록하지 않는다. GitHub secret은
유일한 복구 백업으로 취급하지 않는다.

## 초기화와 기준선 검증

일반 PowerShell에서 저장소 루트로 이동한 뒤 초기화 스크립트를 실행한다. 스크립트는
두 backup 디렉터리와 password를 대화형으로 받는다. 기존 primary·backup·공개 정책
파일이 하나라도 있으면 overwrite하지 않는다.

초기화가 성공하려면 다음이 모두 일치해야 한다.

- primary와 두 backup의 byte size
- primary와 두 backup의 JKS SHA-256
- alias `ccr-internal-pilot-v1`
- primary와 두 backup의 certificate SHA-256
- export된 public certificate SHA-256

성공한 뒤 생성되는 공개 PEM, fingerprint와 policy JSON만 함께 커밋한다.

현재 `ccr-internal-pilot-v1`은 2026-07-28 KST에 primary와 두 backup 검증을 완료했다.
공개 certificate SHA-256은
`3a995765c4cb2502815b5bff31afd11aba220874be83f525fcd5ee64ab007e2e`다.
외부 readiness evidence에는 검증기·공개 policy 파일 해시와 backup 2개 검증 결과만
기록하며 secret 경로, password와 private key material은 기록하지 않는다.

## build 전 preflight

candidate build 전에 항상 다음을 확인한다.

1. canonical JKS와 alias 존재
2. 저장소의 공개 fingerprint와 JKS certificate 일치
3. 공개 PEM certificate와 fingerprint 일치
4. 두 backup의 byte size, JKS SHA-256, alias, certificate 일치
5. public policy lineage가 `ccr-internal-pilot-v1`
6. 다섯 candidate signing 입력이 모두 존재

검증기는 지정된 세 경로만 읽으며 드라이브·사용자 폴더 검색을 하지 않는다.

## restore test

1. primary와 별개의 임시 복구 위치를 준비한다.
2. backup 하나를 임시 위치에 복사한다.
3. `verify-ccr-android-pilot-signing.ps1`과 같은 alias·certificate 검사를 수행한다.
4. JKS SHA-256이 현재 primary와 일치하는지 확인한다.
5. 복구 사본으로 candidate signing preflight까지만 수행하고 APK나 S24 Gate는 만들지 않는다.
6. 검증한 임시 복구 사본은 안전하게 폐기한다.

backup 두 개를 같은 저장장치의 같은 장애 영역에 두지 않는다.

## key 변경과 기기 영향

- key rotation은 별도 migration 계획과 사용자 승인 없이는 수행하지 않는다.
- Play production key와 internal-pilot key를 공유하지 않는다.
- 일반 Android debug key를 internal-pilot key로 사용하지 않는다.
- S24에 같은 package의 다른 signer 앱이 설치돼 있으면 새 candidate 설치 전에 제거해야 한다.
- 기존 앱을 제거하면 app-local data와 SAF grant가 사라질 수 있으므로 먼저 사용자에게 알리고
  필요한 비식별 상태를 별도로 확인한다.
