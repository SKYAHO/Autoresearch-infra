# dev root 승인 게이트 CI apply 구현 순서 (#341)

설계: `../specs/2026-07-24-dev-apply-gated-ci-design.md`

## 작업 분해

1. **IaC — apply SA** (`terraform/envs/dev/github_actions.tf`, `variables.tf`)
   - `google_service_account.dev_apply`(`autoresearch-dev-dev-apply`)
   - WIF 바인딩: `var.dev_apply_workflow_ref`(default `dev-apply.yml@refs/heads/main`)
   - 프로젝트 role 19종 `for_each` 부여(spec 표) — 열거가 곧 감사 목록
2. **workflow** (`.github/workflows/dev-apply.yml`)
   - admin-apply 패턴 복제: dispatch → plan(요약/마스킹/GCS) → env 승인 → apply → 정리
   - TF_VAR는 terraform-plan.yml과 동일 Vars 재사용
3. **문서**: TERRAFORM_DEV.md(dev-apply 절 + break-glass 격하), INFRASTRUCTURE_SUMMARY.md
4. **PR·머지 후 운영 순서**(코드 머지 ≠ 가동):
   1. #331 로컬 매듭(retrain import + apply) — CI는 import 불가
   2. dev root 로컬 apply로 SA·IAM 생성(이 단계까지는 기존 로컬 경로)
   3. GitHub Environment `dev-apply` 생성 + required reviewer 지정
   4. 첫 dev-apply run: plan 요약 검토 → 승인 → apply → 연속 plan `No changes`
   5. 이후 dev root 변경은 머지 → dev-apply 실행이 표준 경로, 로컬은 break-glass

## 검증 체크리스트

- [ ] `fmt -check`/`validate` 통과, 실 tfvars에 신규 변수 override 없음
- [ ] SA apply 후 `gcloud iam service-accounts describe` + role 19종 부여 확인
- [ ] 첫 run plan 요약에 예상 diff만(#211 마스킹 동작 포함) 표시
- [ ] apply 후 drift run green, 로컬 plan `No changes`
- [ ] 403 발생 시 부족 role 실측 기록 → spec 표 갱신(#310 전례)
