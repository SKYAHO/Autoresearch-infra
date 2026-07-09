# GitHub Actions Terraform plan + GCP OIDC 구현 계획 (#6)

> Status: Done (PR #15 merged, apply 완료)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PR 오픈 시 GitHub Actions가 Terraform `fmt/validate/plan`을 자동 실행해 PR 댓글로 게시하고, GCP 인증은 SA key 없이 GitHub OIDC + Workload Identity Federation으로 처리한다.

**Architecture:** `terraform/bootstrap/`(local state)에서 GCS state 버킷·WIF 풀/프로바이더·CI SA를 1회성 생성하고, `terraform/envs/dev/`(GCS backend)는 그 버킷을 state로 사용한다. GitHub Actions runner는 OIDC 토큰으로 WIF를 거쳐 CI SA를 가장해 plan만(viewer + state bucket 접근) 실행한다.

**Tech Stack:** Terraform >= 1.6 (google provider), GitHub Actions (`google-github-actions/auth@v2`, `hashicorp/setup-terraform@v3`, `actions/github-script@v7`), GCP Workload Identity Federation.

## Global Constraints

- GCP project id = `ar-infra-501607`(tfvars에만, gitignored)
- 네이밍: `${name_prefix}-*` = `autoresearch-*`. state 버킷 = `autoresearch-dev-tfstate`(dev 고정 리터럴). WIF 풀 = `autoresearch-github`, 프로바이더 = `github`, CI SA = `terraform-ci`
- Terraform `backend` 블록은 variable/local 참조 불가 → 버킷명 리터럴 고정
- GitHub variables는 **4개**(OIDC keyless라 secret 불필요): `GCP_PROJECT_ID`, `WIF_POOL_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`(버킷명은 versions.tf 리터럴이라 제외)
- Terraform plan workflow는 내부 브랜치 PR에서만 실행한다. fork PR은 `github.event.pull_request.head.repo.full_name == github.repository` guard로 GCP 인증 전에 skip한다.
- 검증 = pytest 없는 Terraform repo → `terraform fmt -recursive` + `validate`. bootstrap `plan`/`apply`, dev `plan`은 GCP 인증 + bootstrap apply 후
- 컨벤션: 커밋 `<type>: <한글 설명>` 50자 이내 현재형. 브랜치 `feat/6-tf-plan-oidc`. PR Draft + `Closes #6`, labels terraform/ci-cd/gcp/iam/security, assignee hyeongyu-data, squash merge
- API 수동 활성화 정책(google_project_service 미사용). secret/state/tfvars 커밋 금지
- GitHub 원격 작업(push/PR/variables) 및 GCP apply는 사용자 확인 후

---

## File Structure

**신규**:
- `terraform/bootstrap/versions.tf` — terraform/providers 블록, provider google
- `terraform/bootstrap/variables.tf` — project_id, github_repository, region
- `terraform/bootstrap/main.tf` — GCS bucket, WIF pool/provider, CI SA, IAM, WI binding
- `terraform/bootstrap/outputs.tf` — 5개 output(state bucket name/self_link, WIF pool/provider name, CI SA email)
- `.github/workflows/terraform-plan.yml` — PR 트리거 워크플로
- `docs/TERRAFORM_BOOTSTRAP.md` — 1회성 부트스트랩 절차 문서

**수정**:
- `terraform/envs/dev/versions.tf` — `backend "gcs"` 블록 추가(리터럴 bucket)
- `docs/TERRAFORM_DEV.md` — CI 자동 검증 섹션 추가
- `README.md` — 진행 단계 한 줄

---

### Task 1: `terraform/bootstrap/` 스캐폴드 (versions.tf + variables.tf)

**Files:**
- Create: `terraform/bootstrap/versions.tf`
- Create: `terraform/bootstrap/variables.tf`

**Interfaces:**
- Produces: variable `project_id`(string, 필수), `github_repository`(string, default `SKYAHO/Autoresearch-infra`), `region`(string, default `asia-northeast3`). provider google(project=var.project_id)

- [x] **Step 1: versions.tf 작성**

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
}
```

- [x] **Step 2: variables.tf 작성**

```hcl
variable "project_id" {
  description = "GCP project id for bootstrap infrastructure (state bucket, WIF, CI SA)."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to impersonate the CI SA via WIF (owner/name)."
  type        = string
  default     = "SKYAHO/Autoresearch-infra"
}

variable "region" {
  description = "Location for the Terraform state GCS bucket."
  type        = string
  default     = "asia-northeast3"
}
```

---

### Task 2: `terraform/bootstrap/main.tf` — 리소스 전부

**Files:**
- Create: `terraform/bootstrap/main.tf`

**Interfaces:**
- Consumes: Task 1 variables(project_id, github_repository, region)
- Produces: `google_storage_bucket.tfstate`(name=`autoresearch-dev-tfstate`), `google_iam_workload_identity_pool.github`(name=full WIF pool), `google_iam_workload_identity_pool_provider.github`(name=full provider), `google_service_account.terraform_ci`(email), IAM members, WI binding

- [x] **Step 1: main.tf 작성(locals + state bucket)**

```hcl
locals {
  name_prefix       = "autoresearch"
  state_bucket_name = "${local.name_prefix}-dev-tfstate"
  wif_pool_id       = "${local.name_prefix}-github"
  wif_provider_id   = "github"
  ci_sa_id          = "terraform-ci"

  default_labels = {
    environment = "bootstrap"
    managed_by  = "terraform"
    project     = "autoresearch"
    repository  = "autoresearch-infra"
  }
}

# 원격 state 저장 버킷 (dev 루트가 backend 로 사용)
resource "google_storage_bucket" "tfstate" {
  name                        = local.state_bucket_name
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = false
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = local.default_labels

  lifecycle {
    prevent_destroy = true
  }
}

# CI SA 가 state read/write 가능하도록(UBLA 이므로 버킷 IAM)
resource "google_storage_bucket_iam_member" "ci_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform_ci.email}"
}
```

- [x] **Step 2: WIF pool + provider 추가**

```hcl
# Workload Identity Federation 풀
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = local.wif_pool_id
  project                   = var.project_id
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions OIDC (autoresearch-infra)."
}

# GitHub OIDC provider (attribute_condition 으로 repo 제한)
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id         = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.wif_provider_id
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"   = "assertion.sub"
    "repository"       = "assertion.repository"
    "repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
```

- [x] **Step 3: CI SA + project IAM 추가**

```hcl
# CI 용 service account (GitHub Actions 가 WIF 경유로 가장)
resource "google_service_account" "terraform_ci" {
  account_id   = local.ci_sa_id
  project      = var.project_id
  display_name = "Terraform CI (GitHub Actions)"
  description  = "Used by GitHub Actions for terraform plan (read-only)."
}

# plan 용 read 권한
resource "google_project_iam_member" "ci_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.terraform_ci.email}"
}

```

- [x] **Step 4: WI binding 추가**

```hcl
# GitHub repo -> CI SA 가장 허용 (repository 속성으로 제한)
resource "google_service_account_iam_member" "ci_wi" {
  service_account_id = google_service_account.terraform_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
```

---

### Task 3: `terraform/bootstrap/outputs.tf`

**Files:**
- Create: `terraform/bootstrap/outputs.tf`

**Interfaces:**
- Produces: outputs `tf_state_bucket_name`, `tf_state_bucket_self_link`, `wif_pool_name`(full), `wif_provider_name`(full), `ci_service_account_email`

- [x] **Step 1: outputs.tf 작성**

```hcl
output "tf_state_bucket_name" {
  description = "GCS bucket name for Terraform remote state (dev)."
  value       = google_storage_bucket.tfstate.name
}

output "tf_state_bucket_self_link" {
  description = "Self link of the Terraform state GCS bucket."
  value       = google_storage_bucket.tfstate.self_link
}

output "wif_pool_name" {
  description = "Full WIF pool name: projects/<N>/locations/global/workloadIdentityPools/autoresearch-github"
  value       = google_iam_workload_identity_pool.github.name
}

output "wif_provider_name" {
  description = "Full WIF provider name: projects/<N>/.../providers/github"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account_email" {
  description = "CI service account email (GitHub Actions impersonates via WIF)."
  value       = google_service_account.terraform_ci.email
}
```

---

### Task 4: `terraform/envs/dev/versions.tf` — backend 블록 추가

**Files:**
- Modify: `terraform/envs/dev/versions.tf`(terraform 블록 내 backend 추가)

**Interfaces:**
- Produces: dev 루트가 GCS backend 사용(bucket=`autoresearch-dev-tfstate`, prefix=`dev/`)

- [x] **Step 1: terraform 블록에 backend 추가**

`terraform { required_version ... required_providers {...} }` 블록 닫는 `}` 전에 아래 backend 블록 삽입.

```hcl
  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "dev/"
  }
```

수정 후 전체 terraform 블록:

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0, < 8.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "dev/"
  }
}
```

---

### Task 5: `.github/workflows/terraform-plan.yml`

**Files:**
- Create: `.github/workflows/terraform-plan.yml`

**Interfaces:**
- Consumes: GitHub variables `WIF_PROVIDER_ID`, `CI_SA_EMAIL`(bootstrap apply 후 등록)
- Produces: PR 오픈/갱신 시 plan 실행 + 결과를 PR 댓글로 게시

- [x] **Step 1: workflow 파일 작성**

```yaml
name: Terraform Plan

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  id-token: write        # GitHub OIDC 토큰 발급 (GCP WIF 인증)
  contents: read         # 코드 체크아웃
  pull-requests: write   # PR 댓글 게시

jobs:
  plan:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER_ID }}
          service_account: ${{ vars.CI_SA_EMAIL }}

      - uses: hashicorp/setup-terraform@v3

      # backend 없이 init (fmt/validate 용)
      - run: terraform -chdir=terraform/envs/dev init -backend=false
      - run: terraform -chdir=terraform/envs/dev fmt -recursive -check -no-color
      - run: terraform -chdir=terraform/envs/dev validate -no-color

      # backend 포함 init (plan 용, state 참조)
      - run: terraform -chdir=terraform/envs/dev init -reconfigure -no-color

      - name: terraform plan
        id: plan
        continue-on-error: true
        run: terraform -chdir=terraform/envs/dev plan -no-color -input=false > /tmp/plan.out 2>&1

      - name: PR 댓글 게시
        if: always() && github.event_name == 'pull_request'
        uses: actions/github-script@v7
        env:
          PLAN_OUTCOME: ${{ steps.plan.outcome }}
        with:
          script: |
            const fs = require('fs');
            let plan = '';
            try {
              plan = fs.readFileSync('/tmp/plan.out', 'utf8');
            } catch (e) {
              plan = '(plan 출력 없음)';
            }
            const outcome = process.env.PLAN_OUTCOME;
            const status = outcome === 'success' ? '✅ plan success' : `⚠️ plan ${outcome}`;
            const body = [
              `### Terraform Plan — ${status}`,
              '',
              '<details><summary>plan 출력 (최대 60000자)</summary>',
              '',
              '```hcl',
              plan.slice(0, 60000),
              '```',
              '',
              '</details>',
            ].join('\n');
            await github.rest.issues.createComment({
              ...context.repo,
              issue_number: context.issue.number,
              body,
            });
```

---

### Task 6: 문서 (TERRAFORM_BOOTSTRAP.md + TERRAFORM_DEV.md + README.md)

**Files:**
- Create: `docs/TERRAFORM_BOOTSTRAP.md`
- Modify: `docs/TERRAFORM_DEV.md`(CI 섹션 추가)
- Modify: `README.md`(진행 단계 한 줄)

- [x] **Step 1: `docs/TERRAFORM_BOOTSTRAP.md` 작성**

```markdown
# Terraform Bootstrap (1회성)

`terraform/bootstrap/` 은 dev 인프라의 **원격 state backend** 와 **CI 인증(WIF + SA)** 을 1회성으로 생성하는 별도 루트 모듈이다. local state 를 사용하고 dev 본루트(`terraform/envs/dev/`)와 분리된다(닭/알 순환 방지).

> **언제 실행하나?** 처음 1회 + bootstrap 구성 변경 시에만 수동 apply. dev 루트 plan/apply 와는 무관.

## 전제

- GCP 인증 완료(`gcloud auth application-default login`)
- `container`/`compute`/`iam`/`cloudresourcemanager` 등 API 활성화(이슈 #5 에서 활성화 완료)
- 활성 `ar-infra-501607` 프로젝트 접근 권한

## 1. bootstrap apply

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -var="project_id=ar-infra-501607"
```

생성 대상: GCS 버킷(`autoresearch-dev-tfstate`), WIF 풀/프로바이더, CI SA(`terraform-ci`), IAM.

## 2. outputs 회수

```bash
terraform -chdir=terraform/bootstrap output -raw wif_pool_name
terraform -chdir=terraform/bootstrap output -raw wif_provider_name
terraform -chdir=terraform/bootstrap output -raw ci_service_account_email
```

## 3. GitHub repo variables 등록(4개)

GitHub → Settings → Secrets and variables → Actions → **Variables** 에 추가(secret 아님):

| variable | 값 |
|---|---|
| `GCP_PROJECT_ID` | `ar-infra-501607` |
| `WIF_POOL_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github` |
| `WIF_PROVIDER_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github/providers/github` |
| `CI_SA_EMAIL` | `terraform-ci@ar-infra-501607.iam.gserviceaccount.com` |

`<N>` 은 프로젝트 번호. `gcloud projects describe ar-infra-501607 --format='value(projectNumber)'` 로 확인.

## 4. dev 루트 backend 마이그레이션

```bash
terraform -chdir=terraform/envs/dev init -migrate-state
```

현재 dev 루트는 GCS backend(`autoresearch-dev-tfstate`, prefix `dev/`)를 사용한다. 새 환경에서 local state로 먼저 apply했다면 이 단계에서 state가 GCS로 이동한다.

## 롤백

- backend 되돌리기: `terraform/envs/dev/versions.tf` 에서 backend 블록 제거 → `terraform -chdir=terraform/envs/dev init -migrate-state`
- bootstrap 제거: state 버킷은 `prevent_destroy=true`로 보호되므로 일반 `terraform destroy`로 삭제되지 않는다. 삭제가 필요하면 state 백업 후 lifecycle을 명시적으로 해제한다.
- GitHub variables 는 Settings 에서 수동 삭제
```

- [x] **Step 2: `docs/TERRAFORM_DEV.md` 에 CI 섹션 추가**

문서 말단(롤백 뒤 또는 적절한 섹션)에 추가:

```markdown
## CI 자동 검증 (이슈 #6)

PR 이 열리면 GitHub Actions(`.github/workflows/terraform-plan.yml`)가 자동으로 `terraform fmt/validate/plan` 을 실행하고 결과를 PR 댓글로 게시한다.

- **인증**: SA key 없이 GitHub OIDC + Workload Identity Federation(WIF). CI SA(`terraform-ci`)는 `roles/viewer`와 state bucket 접근 권한만 가진다. Secret payload 접근은 부여하지 않는다.
- **state**: GCS 원격 backend(`autoresearch-dev-tfstate`). 부트스트랩 절차는 `docs/TERRAFORM_BOOTSTRAP.md` 참조.
- **제한**: WIF `attribute_condition` 으로 `SKYAHO/Autoresearch-infra` 저장소만 허용하고, workflow guard로 fork PR의 plan 인증을 막는다.
- **apply 자동화는 범위 밖**(별도 이슈). 본 워크플로는 plan 만 게시한다.

필요 GitHub variables(4개, secret 아님): `GCP_PROJECT_ID`, `WIF_POOL_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`.
```

- [x] **Step 3: `README.md` 진행 단계 한 줄 갱신**

기존 진행 단계 문장에 CI(#6) 추가(컨벤션에 맞춰 기존 표현 유지). 예: `... GKE(#5) 단계까지 구성 완료, CI 자동 검증(#6) 추가.`

---

### Task 7: 로컬 검증 (fmt + validate)

**Files:**
- Verify: `terraform/bootstrap/`, `terraform/envs/dev/`, `.github/workflows/terraform-plan.yml`

- [x] **Step 1: bootstrap fmt + validate**

```bash
terraform -chdir=terraform/bootstrap fmt -recursive
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
```
Expected: fmt OK, init OK, validate Success.

- [x] **Step 2: dev fmt + validate**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```
Expected: fmt OK, init OK, validate Success. backend 블록이 추가되어도 `-backend=false` 이므로 GCS 미연결 에러 없음.

- [x] **Step 3: whitespace 점검**

```bash
git diff --check
```
Expected: 출력 없음(clean).

- [x] **Step 4: workflow YAML 문법 점검(옵션)**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/terraform-plan.yml'))" && echo OK
```
Expected: `OK`(YAML 파싱 성공).

---

### Task 8: 부트스트랩 apply + GitHub variables + dev 마이그레이션 (사용자 실행, GCP/GitHub 원격 — 보류)

**사용자 확인 후 실행**. Task 1-7 코드 머지/커밋과 무관하게, 실제 GCP/GitHub 변경이 수반되므로 별도 게이트.

- [x] **Step 1: bootstrap apply(GCP)**

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -var="project_id=ar-infra-501607"
```
Expected: bucket, bucket IAM, WIF pool, provider, CI SA, viewer, WI binding 리소스 add. 에러 시 API/권한 확인.

- [x] **Step 2: outputs 회수 → GitHub variables 4개 등록**

```bash
terraform -chdir=terraform/bootstrap output
gcloud projects describe ar-infra-501607 --format='value(projectNumber)'
```
GitHub UI/API 로 variables 등록(또는 `gh variable set` — 사용자 확인 후).

- [x] **Step 3: dev backend 마이그레이션**

```bash
terraform -chdir=terraform/envs/dev init -migrate-state
```
Expected: local → GCS 로 즉시 마이그레이션(state 비어있음).

- [x] **Step 4: 워크플로 연기 테스트**

이 계획의 PR 이 main 머지 후, 임의 PR(README 1줄 변경)을 올려 Actions 가 정상 실행되는지 확인. 실패 시 로그로 WIF/variable/권한 디버깅.

---

### Task 9: 커밋 + push + Draft PR (사용자 확인 후)

**사용자 확인 후 실행**. 브랜치 `feat/6-tf-plan-oidc`.

- [x] **Step 1: 커밋(2개 분리 권장)**

```bash
# docs 커밋
git add docs/superpowers/specs/2026-07-06-github-actions-tf-plan-oidc-design.md docs/superpowers/plans/2026-07-06-github-actions-tf-plan-oidc.md
git commit -m "docs: #6 GitHub Actions TF plan/OIDC 설계 스펙 및 구현 계획"

# 구현 커밋
git add terraform/bootstrap/ terraform/envs/dev/versions.tf .github/workflows/terraform-plan.yml docs/TERRAFORM_BOOTSTRAP.md docs/TERRAFORM_DEV.md README.md
git commit -m "feat: GitHub Actions TF plan + GCP OIDC(WIF) 구성 (#6)"
```

- [x] **Step 2: push + Draft PR**

```bash
git push -u origin feat/6-tf-plan-oidc
gh pr create --draft --base main --head feat/6-tf-plan-oidc \
  --title "feat: GitHub Actions TF plan + GCP OIDC(WIF) 구성 (#6)" \
  --assignee hyeongyu-data \
  --label terraform --label ci-cd --label gcp --label iam --label security \
  --body "..."  # 본문: 작업내용/변경사항/Closes #6/체크리스트/리뷰어참고사항
```

본문 체크리스트: bootstrap fmt/validate✅, dev fmt/validate✅(GCS backend 포함), workflow YAML✅. **보류**: bootstrap apply(GCP), GitHub variables 등록, dev migrate, workflow 실동작 테스트(Task 8, 사용자 실행 후).

---

## Self-Review

- **Spec coverage**: 4.1 bootstrap(bucket/pool/provider/SA/IAM/WI) → Task 2. 4.2 dev versions backend → Task 4. 4.3 workflow → Task 5. 4.4 variables(4개) → Task 6 BOOTSTRAP.md + Task 8. outputs → Task 3. 검증(10) → Task 7. 적용순서(12) → Task 8. 롤백(11) → BOOTSTRAP.md. 산출물(14) 전부 커버. 완료조건(15) 매핑: fmt/validate/plan workflow(5), id-token:write(5), GCS backend(4), CI SA key 없이(2+8), variables 문서화(6).
- **Placeholder scan**: 본문/PR body `"..."` 는 실제 실행 시 채우는 템플릿 자리(사용자 확인 단계). 코드 자체 placeholder 없음.
- **Type consistency**: `local.wif_pool_id`/`wif_provider_id`/`ci_sa_id`(Task 2) ↔ outputs(Task 3) 리소스 참조 일치. WIF pool `name`(full) 을 member principalSet 에 사용(Terraform docs 준수).
