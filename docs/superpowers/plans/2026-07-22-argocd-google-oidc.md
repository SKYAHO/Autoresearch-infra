# ArgoCD Google OIDC 로그인 구현 계획 (#289)

설계: `../specs/2026-07-22-argocd-google-oidc-design.md`

## 변경 (코드, 이 PR)

1. `terraform/admin/argocd-k8s/helm-values/argo-cd.values.yaml` →
   `argo-cd.values.yaml.tftpl`로 전환. `configs.cm.url`, `configs.cm."oidc.config"`
   (Google issuer, `$argocd-google-oidc:*` 참조), `configs.rbac`(policy.default 거부,
   scopes email, `templatefile` 루프로 이메일→role 렌더) 추가. `dex.enabled: false` 유지.
2. `main.tf`: `helm_release.argo_cd`의 `values`를 `file()` → `templatefile()`로 변경,
   `argocd_server_url`·`admin_emails`·`readonly_emails` 주입.
3. `variables.tf`: `argocd_server_url`, `argocd_admin_user_emails`,
   `argocd_readonly_user_emails`(이메일 형식 validation) 추가, `argocd_values_file_path`
   기본값을 `.tftpl`로.
4. `terraform.tfvars.example`: 새 변수 예시.
5. 문서: `README.md`(OIDC secret 주입·redirect·RBAC 절차), `ARGOCD_OPERATIONS_RUNBOOK.md`
   (SSO 로그인 섹션), spec/plan.

## 운영 적용 (apply 단계, 이 PR 이후)

1. Google OAuth Web client 생성, redirect URI `https://localhost:8443/auth/callback`.
2. client id/secret을 Secret Manager 저장 → `argocd-google-oidc` K8s Secret 주입
   (label `app.kubernetes.io/part-of=argocd`, `--from-env-file`). README 절차.
3. 로컬 `terraform.tfvars`에 허용 이메일 지정.
4. `terraform apply` → `rollout restart deployment/argo-cd-argocd-server`.

## 검증 체크리스트

- [ ] `fmt -check` / `init -backend=false` / `validate` 통과
- [ ] `templatefile` 렌더가 유효한 `policy.csv`(이메일→role) 생성 — 로컬 console로 확인
- [ ] (apply 후) 허용 이메일 Google 로그인 성공, 목록 밖 계정 거부
- [ ] (apply 후) admin=내장 role:admin(전체 관리, sync/rollback 포함), readonly=조회만
- [ ] (apply 후) 로컬 `admin` 로그인·`argocd` CLI 회귀 없음
- [ ] client id/secret·이메일이 Git/state/values에 없음(`git diff` + `git grep`)

## 롤백

변수/템플릿의 OIDC·RBAC 부분을 되돌려 apply → 로컬 admin 단일 계정 복귀.
`argocd-google-oidc` Secret·Google client 별도 삭제.
