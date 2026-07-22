# Kibana Google(Gmail) 로그인 설계 (#293)

## 배경·목적

Kibana UI는 현재 ES 네이티브 `elastic` 슈퍼유저(공유 비밀번호)로만 접근한다.
개인별 감사·회수가 안 되고 슈퍼유저 노출은 과권한이다. Airflow·MLflow(#232)의
내부 UI Google 로그인 + 허용 이메일 패턴을 Kibana에도 적용한다.

## 라이선스 제약과 방식 선택

ECK 기본 **Basic 라이선스**라 ES/Kibana 네이티브 OIDC/SAML realm(Platinum 전용)은
쓸 수 없다. 따라서 **oauth2-proxy 앞단 + Kibana anonymous access** 조합을 쓴다.

| 대안 | 판정 |
|---|---|
| oauth2-proxy 앞단 + Kibana anonymous access | **채택** — Basic에서 동작, MLflow 패턴 재사용 |
| ES 네이티브 OIDC realm | 기각 — Platinum 유료 |
| oauth2-proxy만(anonymous 없음) | 기각 — Kibana가 `elastic` 로그인을 또 요구(이중 인증) |

## 구성

```
브라우저(localhost:4180) → oauth2-proxy(Google 로그인 + 허용 이메일)
  → https://autoresearch-kb-http:5601 (Kibana) → anonymous 인증(자동 로그인)
```

- **oauth2-proxy**(elastic ns, Terraform 관리): MLflow 매니페스트 패턴. Google
  provider, `--authenticated-emails-file`로 허용 이메일 제한, upstream은 Kibana
  https(self-signed → `--ssl-upstream-insecure-skip-verify`). Service는 ClusterIP
  (Kibana와 동일 port-forward 접근, `localhost:4180`).
- **Kibana anonymous provider**(`spec.config`): `anonymous.anonymous1`(order 0,
  `credentials: elasticsearch_anonymous_user`) + `basic.basic1`(order 1). proxy
  통과자를 재로그인 없이 익명 사용자로 자동 로그인. `basic`은 `elastic` 슈퍼유저
  break-glass용으로 유지(`/login`).
- **ES anonymous user**(`nodeSets[].config`): `xpack.security.authc.anonymous`
  username `anonymous_kibana`, role는 변수 `kibana_anonymous_role`(기본 `viewer`).
  `authz_exception: true`.

## 결정

- **익명 역할 = 내장 `viewer`(기본)**. 읽기 전용(대시보드·Discover 조회)이라 현재
  공유 `elastic` 슈퍼유저보다 크게 좁힌다. 저장 객체 생성이 필요하면 변수로
  `editor`(Kibana 객체 편집) 또는 커스텀 role로 전환(한 줄). 커스텀 role은 별도.
- **전원 동일 익명 역할**. Basic 라이선스에선 사용자별 Kibana RBAC/감사가 불가
  (Platinum 필요). dev 팀원 5명·공유 로그 분석 용도로 수용. 개별 감사는 oauth2-proxy
  접근 로그로 대체.
- **git-safe**: client id/secret·cookie-secret·허용 이메일은 `kibana-oauth` Secret으로
  file-based 주입(#213 패턴). 매니페스트엔 Secret 참조만.
- **NetworkPolicy 최소권한**: proxy 전용 egress 정책으로 Google 443(0.0.0.0/0)만
  개방(ES/Kibana 파드엔 인터넷 egress 안 줌). node→4180 ingress 추가.

## 리스크·영향

- 리소스: oauth2-proxy 파드 1개(기존 노드, ~32Mi). 라이선스·비용 변화 없음.
- anonymous 활성화는 ES/Kibana 인증 동작을 바꾸므로 apply 후 재현 검증 필수
  (Kibana CR은 #99에서 SSA 왕복 이슈가 있었음 — config 추가 시 plan 수렴 확인).
- Secret 미주입/오류 시 oauth2-proxy만 실패하고 Kibana의 `elastic` 경로는 정상
  (안전한 부분 실패).

## 롤백

oauth2-proxy·anonymous 설정·NetworkPolicy 변경을 되돌려 apply → `elastic` 인증으로
복귀. `kibana-oauth` Secret·Google OAuth client는 별도 삭제.
