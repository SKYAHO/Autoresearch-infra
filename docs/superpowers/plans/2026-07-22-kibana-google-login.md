# Kibana Google 로그인 구현 계획 (#293)

설계: `../specs/2026-07-22-kibana-google-login-design.md`

## 변경 (코드, 이 PR)

1. `terraform/admin/elastic-k8s/variables.tf`: `kibana_anonymous_role`(기본 viewer),
   `kibana_public_base_url`(localhost:4181), `oauth2_proxy_image` 추가. MLflow의
   로컬 4180과 충돌하지 않도록 Kibana의 로컬 포트는 4181을 사용한다.
2. `elasticsearch.tf`: `nodeSets[].config`에 `xpack.security.authc.anonymous`
   (username/roles=var/authz_exception) 추가.
3. `kibana.tf`: `spec.config`에 anonymous(order 0)+basic(order 1) provider,
   `server.publicBaseUrl` 추가.
4. `oauth2_proxy.tf`(신규): `kibana-oauth-proxy` Deployment(https upstream +
   skip-verify, `kibana-oauth` Secret 참조) + ClusterIP Service(4180).
5. `main.tf`: elastic-ingress에서 노드→5601 직접 경로 **제거**하고 4180만 허용
   (anonymous 우회 차단), elastic-egress services CIDR에 5601 추가(proxy→Kibana VIP,
   #122). proxy Google egress는 elastic-egress의 기존 private googleapis VIP(#138)가
   커버하므로 신규 egress 정책 없음.
6. 문서: `README.md`(kibana-oauth 주입·anonymous 설명), `KIBANA_OPERATIONS_RUNBOOK.md`
   (Google 로그인 접속), spec/plan.

## 운영 적용 (apply 단계, 이 PR 이후)

1. Google OAuth Web client 생성, redirect URI `http://localhost:4181/oauth2/callback`.
2. `kibana-oauth` Secret 주입(client-id/secret/cookie-secret/authenticated-emails,
   file 기반). README 절차.
3. `terraform apply`(필요 시 Kibana/ES CR config 반영 확인) → `rollout restart
   deployment/kibana-oauth-proxy`.

## 검증 체크리스트

- [ ] `fmt -check` / `init -backend=false` / `validate` 통과
- [ ] (apply 후) 연속 plan `No changes` — Kibana CR config 추가가 #99 SSA 왕복에
      드리프트를 만들지 않는지 확인(만들면 computed_fields 조정)
- [ ] (apply 후) 허용 이메일 Google 로그인 → Kibana 자동 로그인(재로그인 없음)
- [ ] (apply 후) 익명 사용자가 `viewer` 범위로 제한(쓰기 불가), 목록 밖 계정 거부
- [ ] (apply 후) `elastic` basic 로그인(`/login`) break-glass 정상
- [ ] (apply 후) proxy→Kibana(5601 VIP) 성립, proxy→Google(googleapis private VIP)로
      로그인 성립. 노드→5601 직접 port-forward는 차단(우회 불가)
- [ ] (apply 후) proxy 장애 시 break-glass(5601 ingress 임시 복원 → elastic) 재현
- [ ] client id/secret·이메일이 Git/state에 없음(`git diff`/`git grep`)

## 롤백

oauth2-proxy·anonymous 설정·NetworkPolicy 변경을 되돌려 apply → `elastic` 인증 복귀.
`kibana-oauth` Secret·Google client 별도 삭제.
