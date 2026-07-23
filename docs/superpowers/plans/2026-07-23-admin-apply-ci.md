# admin root CI apply 구현 계획 (#307)

설계: `../specs/2026-07-23-admin-apply-ci-design.md`

## 변경 (코드, 이 PR)

1. `terraform/envs/dev/github_actions.tf`: `admin_apply` SA + WIF binding
   (`admin_apply_workflow_ref`) + `roles/container.admin` + state 버킷 objectAdmin.
2. `terraform/envs/dev/variables.tf`: `admin_apply_workflow_ref`.
3. `.github/workflows/admin-apply.yml`: `workflow_dispatch`(root 입력) → plan job
   (요약·artifact) → apply job(`environment: admin-apply` 승인). TF_VAR는 vars/secrets.
4. 문서: `argocd-k8s/README.md`(CI apply 정본 + 로컬 break-glass), `TERRAFORM_DEV.md`,
   spec/plan.

## 운영 적용 (apply 단계, 이 PR 이후 · 순서 중요)

1. **먼저 dev root apply**(로컬 또는 후속): `admin_apply` SA·IAM 생성.
2. GitHub 설정: Secret `ARGOCD_ADMIN_USER_EMAILS`(JSON), Variable
   `ADMIN_APPLY_SA_EMAIL`, Environment `admin-apply`+reviewers.
3. `admin-apply` 워크플로우 실행(root=argocd-k8s) → plan 확인 → 승인 → apply.
4. 결과가 로컬 apply와 동일한지(policy.csv 5명 유지) 확인.

## 검증 체크리스트

- [ ] `fmt -check`/`validate`(dev root) 통과, `actionlint`(admin-apply.yml) 통과
- [ ] (apply 후) admin_apply SA가 `admin-apply.yml@main`에서만 가장 가능(다른 ref 거부)
- [ ] (실행 후) 승인 전 apply job이 대기(미승인 시 미실행)
- [ ] (실행 후) Secrets 값으로 argocd-k8s apply → `policy.csv` 5명 유지(#305 재발 없음)
- [ ] plan 요약에 이메일·secret 미노출(#211)
- [ ] 로컬 break-glass apply 절차 문서화

## 롤백

워크플로우·SA·IAM revert 후 로컬 apply 복귀. GitHub Secrets/Environment 제거.
