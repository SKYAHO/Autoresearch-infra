# Airflow GKE Runtime Drift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Airflow dev 배포에 필요한 live GCP/GKE drift를 Terraform과 운영 문서에 반영한다.

**Architecture:** GCP-side 리소스와 IAM은 Terraform dev root module에서 관리한다. Kubernetes namespace/KSA는 Terraform CI plan의 네트워크 의존성을 피하기 위해 Airflow 배포 runbook에서 관리하고, GSA impersonation binding만 Terraform에 둔다.

**Tech Stack:** Terraform Google provider, GKE Standard node pool, GCP IAM, GCS, Helm, Airflow CLI.

---

### Task 1: Drift 분류와 설계 기록

**Files:**
- Create: `docs/superpowers/specs/2026-07-08-airflow-gke-runtime-design.md`
- Create: `docs/superpowers/plans/2026-07-08-airflow-gke-runtime.md`

- [x] **Step 1: live drift를 코드화/문서화/원복으로 분류한다.**
- [x] **Step 2: Kubernetes namespace/KSA를 Terraform에 직접 넣지 않는 이유를 기록한다.**

### Task 2: Terraform 변수와 locals 추가

**Files:**
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/locals.tf`

- [x] **Step 1: Airflow node pool 변수와 KSA 변수 추가**
  - `airflow_gke_node_pool_name = "airflow-dev"`
  - `airflow_gke_machine_type = "e2-standard-2"`
  - `airflow_gke_node_count_min = 1`
  - `airflow_gke_node_count_max = 1`
  - `airflow_k8s_namespace = "airflow"`
  - `airflow_batch_k8s_service_account = "autoresearch-batch"`

- [x] **Step 2: Cloud Build compute SA와 bucket 이름 locals 추가**
  - `cloud_build_compute_service_account_email`
  - `cloud_build_bucket_name`
  - `airflow_batch_workload_identity_principal`

### Task 3: Terraform 리소스 추가

**Files:**
- Modify: `terraform/envs/dev/gke.tf`
- Create: `terraform/envs/dev/cloud_build.tf`

- [x] **Step 1: `google_container_node_pool.airflow`를 추가한다.**
- [x] **Step 2: `google_service_account_iam_member.gke_app_airflow_batch_wi`를 추가한다.**
- [x] **Step 3: Cloud Build compute SA IAM member 3개를 추가한다.**
  - Artifact Registry writer
  - Cloud Build bucket objectViewer
  - project logging.logWriter

### Task 3.5: Airflow API key Secret Manager 경계 추가

**Files:**
- Modify: `terraform/envs/dev/secret_manager.tf`
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/locals.tf`

- [x] **Step 1: YouTube/OpenRouter API key용 Secret Manager metadata를 추가한다.**
- [x] **Step 2: secret payload는 Terraform state에 넣지 않는 운영 경계를 문서화한다.**
- [x] **Step 3: K8s Secret `autoresearch-airflow-env` 동기화 절차를 runbook에 남긴다.**

### Task 4: 예시 변수와 출력 추가

**Files:**
- Modify: `terraform/envs/dev/terraform.tfvars.example`
- Modify: `terraform/envs/dev/outputs.tf`

- [x] **Step 1: Airflow node pool/KSA 변수 예시를 추가한다.**
- [x] **Step 2: Airflow node pool, WI principal, Cloud Build compute SA 출력을 추가한다.**

### Task 5: 운영 문서 갱신

**Files:**
- Modify: `docs/TERRAFORM_DEV.md`
- Modify: `terraform/envs/dev/README.md`

- [x] **Step 1: Airflow node pool과 Cloud Build API/권한을 문서화한다.**
- [x] **Step 2: namespace/KSA manifest와 Helm upgrade 절차를 문서화한다.**
- [x] **Step 3: DAG smoke 전 GCS 입력 확인 명령을 문서화한다.**

### Task 6: 검증

- [x] **Step 1: Terraform fmt/check/validate를 실행한다.**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

- [x] **Step 2: 가능하면 Terraform plan을 실행한다.**

```bash
terraform -chdir=terraform/envs/dev plan
```

Expected: Airflow 범위 변경만 보여야 한다. Cloud Run proxy 또는
`gke_kubectl_users` destroy가 보이면 이번 변경을 apply하지 않고 별도
state/code 정합성 작업으로 분리한다.

Result: 2026-07-08 재확인 기준 코드에는 Airflow/Cloud Build/GKE access
리소스가 있으나 remote state에는 아직 import되지 않아, live에 이미 존재하는
아래 10개 리소스가 create로 표시됐다. state lock 해제 후 모두 remote
state에 import했다.

- `google_container_node_pool.airflow`
- `google_service_account_iam_member.gke_app_airflow_batch_wi`
- `google_artifact_registry_repository_iam_member.cloud_build_compute_ar_writer`
- `google_storage_bucket_iam_member.cloud_build_compute_bucket_object_viewer`
- `google_project_iam_member.cloud_build_compute_logging`
- `google_project_iam_member.gke_kubectl_users` 5개

추가로 `dev-default` node pool live machine type이 `e2-standard-4`로
확인되어 Terraform 기본값을 live에 맞췄다. 이후 plan은 Airflow API key
Secret Manager metadata/IAM `4 to add, 0 to change, 0 to destroy`만
표시했고, `terraform apply`로 반영했다. Secret payload version은 Terraform
밖에서 추가했으며 version 2가 enabled, 줄바꿈이 들어간 초기 version 1은
disabled 상태로 정리했다. 후속 `terraform plan -detailed-exitcode`는
`No changes`로 종료됐다.

- [x] **Step 3: GCS 입력과 Airflow smoke를 확인한다.**

```bash
gcloud storage ls gs://ar-infra-501607-autoresearch-dev-raw-data/data_lake/youtube_trending_kr/dt=2026-07-07/part-0.parquet
gcloud storage ls gs://ar-infra-501607-autoresearch-dev-raw-data/asset/virtual_user/vu_1000.parquet
```

Result: `2026-07-07` YouTube partition과 virtual user parquet은 존재했다.
초기 REST smoke run `manual__smoke_2026-07-07T163100Z`는 KPO
`serviceAccountName` Jinja literal 문제로 pod 생성 전 403이 발생해 추가
retry 방지를 위해 `failed`로 정리했다. Autoresearch-airflow `bb39385`
수정 후 git-sync 반영을 확인했고, DAG run
`manual__smoke_2026-07-07T20260707T165929Z`는 task
`ensure_action_log_partition` 1회차 성공 및 action log GCS output 생성을
확인했다.
