# 팀원 BigQuery 분석 권한 구현 계획

> 설계: `docs/superpowers/specs/2026-07-16-team-bigquery-access-design.md`
> Issue: #215

**목표:** 기존 팀원 목록에 BigQuery job 실행 권한과 analytics·Feast dataset별
데이터 편집 권한을 최소권한으로 추가하되, 실제 이메일을 Git과 CI 출력에서 분리한다.

**아키텍처:** 사람 IAM은 `terraform/admin/gke-team-access`의 별도 state와 로컬
`terraform.tfvars`가 계속 소유한다. 프로젝트 IAM member 하나(jobUser)와 dataset
IAM member 둘(dataEditor)을 같은 `team_member_emails` 집합으로 additive 관리한다.

---

## Task 1: 작업 경계와 브랜치

- [x] 이슈 #215를 생성하고 `Create a branch` 흐름으로
  `feat/215-grant-team-bigquery-access` 브랜치를 생성한다.
- [x] 이슈·브랜치·문서에 팀원 실제 이메일을 넣지 않는다.

## Task 2: Terraform IAM 추가

**Files:**

- Modify: `terraform/admin/gke-team-access/main.tf`
- Modify: `terraform/admin/gke-team-access/variables.tf`
- Modify: `terraform/admin/gke-team-access/terraform.tfvars.example`

- [x] `roles/bigquery.jobUser`를 프로젝트 IAM member로 추가한다.
- [x] `autoresearch_dev_analytics`, `feast_offline_store`에 각각
  `roles/bigquery.dataEditor` dataset IAM member를 추가한다.
- [x] dataset ID 기본값과 형식 검증을 변수화하고, 예시 tfvars에는 실제 이메일을
  넣지 않는다.
- [x] 프로젝트 수준 Data Editor/Editor/Owner를 추가하지 않는다.

## Task 3: 운영 문서 및 변경 이력

**Files:**

- Modify: `terraform/admin/gke-team-access/README.md`
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- Modify: `docs/TERRAFORM_DEV.md`
- Modify: `docs/CHANGE_HISTORY.md`

- [x] 권한 범위, job 비용 제한, off-boarding 절차를 기록한다.
- [x] 이메일이 로컬 `terraform.tfvars`에만 남는 경계를 기록한다.

## Task 4: 검증과 적용 게이트

- [x] 다음 검증을 실행한다.

```bash
terraform -chdir=terraform/admin/gke-team-access fmt -check -recursive
terraform -chdir=terraform/admin/gke-team-access init -backend=false
terraform -chdir=terraform/admin/gke-team-access validate
git diff --check
```

- [ ] `terraform plan`과 `terraform apply`는 실제 로컬 tfvars 및 GCP 인증이
  필요한 단계다. apply는 사용자의 명시적 승인 후에만 실행한다. plan 검토 시
  생성 대상이 프로젝트 `bigquery.jobUser` 1종과 두 dataset의 `bigquery.dataEditor`
  2종뿐이며, 실제 이메일이나 프로젝트 수준 Data Editor가 출력에 없는지 확인한다.
- [ ] merge 전 exact 파일만 stage하고, Draft PR 전 사용자 승인에 따라 push한다.
