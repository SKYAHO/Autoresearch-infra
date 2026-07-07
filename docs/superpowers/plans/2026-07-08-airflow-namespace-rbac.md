# Airflow 운영 인프라 경계 구현 Plan (#32)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev GKE 클러스터에 Airflow를 운영 수준으로 설치할 수 있는 K8s namespace/RBAC 경계와 GCP 리소스(SA, Cloud SQL DB, GCS 버킷, IAM)를 Terraform으로 구성한다.

**Architecture:** `kubernetes` provider를 추가해 GKE 클러스터 내 namespace·RBAC·네트워크 정책을 IaC로 관리하고, GCP SA `airflow`를 신규 생성해 Workload Identity로 K8s SA와 매핑한다. Cloud SQL·GCS·BigQuery 접근 권한을 최소 권한 원칙으로 부여한다.

**Tech Stack:** Terraform (google/google-beta/random + kubernetes provider 신규), GKE, Cloud SQL, GCS, BigQuery, Workload Identity, K8s RBAC/NetworkPolicy.

## Global Constraints

- **전제: PR #34(팀원 GKE kubectl 접근)가 main에 merge되어 `variable "gke_kubectl_user_emails"`가 존재해야 함.** 미머지 상태면 Task 3(installer_admin RoleBinding)이 validate에 실패한다. PR #34 merge 후 feat/32 브랜치를 main에 rebase하고 시작한다.
- terraform `required_version = ">= 1.6.0"`.
- kubernetes provider 버전 `>= 2.20`.
- 리소스 이름 prefix = `${var.name_prefix}-${var.environment}` (= `autoresearch-dev`, locals `resource_prefix`).
- GCS 버킷은 `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`.
- 데이터 영속 GCS 버킷(신규 airflow-dags/airflow-logs)은 기존 raw/feast 버킷과 동일하게 `lifecycle { prevent_destroy = true }`.
- dev는 삭제 보호 기본 false(SA, Cloud SQL database, namespace는 protect=false).
- 커밋 컨벤션: `<type>: <한국어 설명>`, type = feat/docs/refactor/chore.
- 각 task 종료 검증: `terraform -chdir=terraform/envs/dev fmt -check -recursive` + `terraform -chdir=terraform/envs/dev init -backend=false` + `terraform -chdir=terraform/envs/dev validate` + `git diff --check`. IaC는 단위 테스트 대신 이 세 검증이 test equivalent.
- 브랜치: `feat/32-airflow-namespace-rbac` (이미 생성, spec 커밋 8ec8ae5 포함).

## File Structure

| 파일 | 책임 | 신규/수정 |
|---|---|---|
| `terraform/envs/dev/versions.tf` | kubernetes provider + 인증 data source 추가 | 수정 |
| `terraform/envs/dev/variables.tf` | airflow K8s namespace/SA 변수 | 수정 |
| `terraform/envs/dev/locals.tf` | airflow SA name, WI principal, 버킷 name locals | 수정 |
| `terraform/envs/dev/airflow.tf` | K8s 리소스 + GCP 리소스(SA/IAM/DB/버킷) 단일 파일 | 신규 |
| `terraform/envs/dev/outputs.tf` | airflow 출력값 5개 | 수정 |
| `docs/TERRAFORM_DEV.md` | Airflow 설치 runbook 섹션 | 수정 |

---

## Task 1: provider, 변수, locals 기반 추가

**Files:**
- Modify: `terraform/envs/dev/versions.tf` (required_providers 블록 + provider/data 블록)
- Modify: `terraform/envs/dev/variables.tf` (맨 끝에 변수 2개 추가)
- Modify: `terraform/envs/dev/locals.tf` (airflow locals 추가)

**Interfaces:**
- Consumes: `var.name_prefix`, `var.environment`, `var.project_id` (기존)
- Produces: `local.airflow_sa_name`, `local.airflow_workload_identity_principal`, `local.airflow_dags_bucket_name`, `local.airflow_logs_bucket_name`, `var.airflow_k8s_namespace`, `var.airflow_k8s_service_account`, kubernetes provider

- [ ] **Step 1: versions.tf에 kubernetes provider와 인증 data source 추가**

`versions.tf`의 `required_providers` 블록에 `kubernetes`를 추가하고, provider/data source를 파일 끝에 추가한다.

`required_providers` 블록을 다음으로 교체 (random 뒤에 kubernetes 추가):

```hcl
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

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20"
    }
  }
```

파일 끝(google-beta provider 블록 뒤)에 다음을 추가:

```hcl

data "google_client_config" "default" {}

# ponytail: apply 시점 ADC/WIF로 cluster 접근. 별도 kubeconfig 불필요.
provider "kubernetes" {
  host                   = "https://${google_container_cluster.dev.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.dev.master_auth.0.cluster_ca_certificate)
}
```

- [ ] **Step 2: variables.tf에 airflow 변수 2개 추가**

`variables.tf` 맨 끝(proxy_deletion_protection 변수 뒤)에 추가:

```hcl

variable "airflow_k8s_namespace" {
  description = "Airflow 구성요소가 배포되는 Kubernetes namespace."
  type        = string
  default     = "airflow"
}

variable "airflow_k8s_service_account" {
  description = "Airflow Workload Identity 매핑용 Kubernetes service account 이름."
  type        = string
  default     = "airflow"
}
```

> 참고: spec은 `airflow_gcp_sa_name` 변수도 언급하지만, 기존 `gke_app` 패턴(`gke_app_sa_name`은 local에 정의, 변수가 아님)과 일관되게 GCP SA 이름은 `local.airflow_sa_name`으로 관리한다. 변수로 두면 default에서 `local`을 참조할 수 없어 패턴이 깨진다.

- [ ] **Step 3: locals.tf에 airflow locals 추가**

`locals.tf`의 `gke_workload_identity_principal` 라인 뒤에 추가:

```hcl

  airflow_sa_name                     = "${local.resource_prefix}-airflow"
  airflow_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_k8s_service_account}]"
  airflow_dags_bucket_name            = "${var.project_id}-${local.resource_prefix}-airflow-dags"
  airflow_logs_bucket_name            = "${var.project_id}-${local.resource_prefix}-airflow-logs"
```

- [ ] **Step 4: 검증**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

Expected: fmt 변경 없음(이미 포맷됨), init 성공(kubernetes provider 다운로드), validate Success.

- [ ] **Step 5: 커밋**

```bash
git add terraform/envs/dev/versions.tf terraform/envs/dev/variables.tf terraform/envs/dev/locals.tf terraform/envs/dev/.terraform.lock.hcl
git commit -m "feat: #32 kubernetes provider 및 airflow 변수/locals 추가"
```

> `.terraform.lock.hcl`은 `init` 시 kubernetes provider 체크섬이 추가되므로 함께 커밋한다.

---

## Task 2: airflow.tf GCP 리소스 (SA, WI, IAM, DB, 버킷)

**Files:**
- Create: `terraform/envs/dev/airflow.tf`

**Interfaces:**
- Consumes: `local.airflow_sa_name`, `local.airflow_workload_identity_principal`, `local.airflow_dags_bucket_name`, `local.airflow_logs_bucket_name`, `var.region`, `var.project_id`, 기존 리소스(`google_sql_database_instance.dev`, `google_storage_bucket.raw_data/feast_registry/feast_staging`, `google_bigquery_dataset.feast_offline_store`)
- Produces: `google_service_account.airflow` (이메일, name), `google_storage_bucket.airflow_dags/logs`, `google_sql_database.airflow` — Task 3, 4에서 참조

- [ ] **Step 1: airflow.tf 생성 — GCP SA + Workload Identity 매핑**

`terraform/envs/dev/airflow.tf` 생성, 다음 작성:

```hcl
# #32 Airflow 운영 인프라 경계
# K8s namespace/RBAC + GCP SA(WI) + Cloud SQL DB + GCS 버킷. Airflow Helm values 자체는 앱 저장소 범위.

# --- GCP 서비스 계정 + Workload Identity ---

resource "google_service_account" "airflow" {
  account_id   = local.airflow_sa_name
  display_name = "Autoresearch dev Airflow workload identity SA"
}

resource "google_service_account_iam_member" "airflow_wi" {
  service_account_id = google_service_account.airflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}
```

- [ ] **Step 2: project-level IAM (cloudsql.client, bigquery.jobUser) 추가**

같은 파일에 이어서 작성:

```hcl

# --- GCP IAM (project-level) ---

resource "google_project_iam_member" "airflow_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_project_iam_member" "airflow_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}
```

- [ ] **Step 3: Cloud SQL database (airflow) 추가**

같은 파일에 이어서 작성:

```hcl

# --- Cloud SQL metadata DB ---

resource "google_sql_database" "airflow" {
  name     = "airflow"
  instance = google_sql_database_instance.dev.name
}
```

- [ ] **Step 4: GCS 버킷 2개 (airflow-dags, airflow-logs) 추가**

같은 파일에 이어서 작성:

```hcl

# --- GCS 버킷 (DAG 버전관리, 로그 영속화) ---

resource "google_storage_bucket" "airflow_dags" {
  name                        = local.airflow_dags_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    data_class = "dags"
    purpose    = "airflow-dags"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "airflow_logs" {
  name                        = local.airflow_logs_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    data_class = "logs"
    purpose    = "airflow-logs"
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

- [ ] **Step 5: GCS bucket IAM (airflow SA objectAdmin × 5 버킷) 추가**

같은 파일에 이어서 작성:

```hcl

# --- GCS bucket IAM (airflow SA objectAdmin) ---

resource "google_storage_bucket_iam_member" "airflow_dags_admin" {
  bucket = google_storage_bucket.airflow_dags.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_logs_admin" {
  bucket = google_storage_bucket.airflow_logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_raw_data_admin" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_registry_admin" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_staging_admin" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}
```

- [ ] **Step 6: BigQuery dataset IAM (feast_offline_store dataEditor) 추가**

같은 파일에 이어서 작성:

```hcl

# --- BigQuery dataset IAM ---

resource "google_bigquery_dataset_iam_member" "airflow_feast_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}
```

- [ ] **Step 7: 검증**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

Expected: fmt clean, validate Success (이 task는 GCP 리소스만 다루고 K8s 리소스가 없으므로 kubernetes provider 없이도 참조 에러 없음).

- [ ] **Step 8: 커밋**

```bash
git add terraform/envs/dev/airflow.tf
git commit -m "feat: #32 Airflow GCP 리소스(SA/WI/IAM/DB/버킷) 추가"
```

---

## Task 3: airflow.tf K8s 리소스 (namespace, RBAC, 네트워크 정책)

> **전제 재확인:** 이 task는 `var.gke_kubectl_user_emails`를 참조한다. PR #34가 main에 merge되어 이 변수가 존재해야 validate가 통과한다. 미머지 상태면 installer_admin RoleBinding 스텝을 제외하고 진행 후, #34 merge 시 rebase로 보탠다.

**Files:**
- Modify: `terraform/envs/dev/airflow.tf` (파일 끝에 K8s 리소스 추가)

**Interfaces:**
- Consumes: `var.airflow_k8s_namespace`, `var.airflow_k8s_service_account`, `var.gke_kubectl_user_emails`(#34), `var.private_services_cidr`, `google_service_account.airflow.email`
- Produces: `kubernetes_namespace.airflow`, `kubernetes_service_account.airflow` — Task 4 outputs에서 참조

- [ ] **Step 1: namespace + K8s SA (WI 어노테이션) 추가**

`airflow.tf` 끝에 추가:

```hcl

# --- Kubernetes namespace + service account ---

resource "kubernetes_namespace" "airflow" {
  metadata {
    name = var.airflow_k8s_namespace
    labels = {
      "app.kubernetes.io/name" = "airflow"
    }
  }
}

resource "kubernetes_service_account" "airflow" {
  metadata {
    name      = var.airflow_k8s_service_account
    namespace = var.airflow_k8s_namespace
    annotations = {
      "iam.gkeusercontent.com/gcp-service-account" = google_service_account.airflow.email
    }
  }

  depends_on = [kubernetes_namespace.airflow]
}
```

- [ ] **Step 2: Role (airflow_components) + RoleBinding (airflow SA) 추가**

`airflow.tf` 끝에 추가:

```hcl

# --- Kubernetes RBAC (Airflow 구성요소용 namespace-scoped Role) ---

resource "kubernetes_role" "airflow_components" {
  metadata {
    name      = "airflow-components"
    namespace = var.airflow_k8s_namespace
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "configmaps", "secrets", "services"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "airflow_sa" {
  metadata {
    name      = "airflow-sa"
    namespace = var.airflow_k8s_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.airflow_components.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.airflow.metadata[0].name
    namespace = var.airflow_k8s_namespace
  }

  depends_on = [kubernetes_namespace.airflow]
}
```

- [ ] **Step 3: installer_admin RoleBinding (팀원 → admin ClusterRole) 추가**

`airflow.tf` 끝에 추가. `gke_kubectl_user_emails`가 PR #34에 정의된 변수다:

```hcl

# --- Kubernetes RBAC (설치 담당자 admin 권한, for_each) ---

# ponytail: dev에서 설치 주체를 별도 variable로 분리하지 않고 gke_kubectl_user_emails(#34) 재사용.
# namespace 내 admin ClusterRole 바인딩으로 Helm 설치 경로 확보.
resource "kubernetes_role_binding" "installer_admin" {
  for_each = toset(var.gke_kubectl_user_emails)

  metadata {
    # ponytail: 이메일에서 K8s name에 쓸 수 없는 문자(@,.)를 하이픈으로 치환. 고유성 보장.
    name      = "airflow-installer-${replace(each.key, "/[^a-z0-9]/", "-")}"
    namespace = var.airflow_k8s_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "User"
    name      = each.key
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [kubernetes_namespace.airflow]
}
```

- [ ] **Step 4: ResourceQuota + LimitRange 추가**

`airflow.tf` 끝에 추가:

```hcl

# --- namespace 자원 경계 ---

resource "kubernetes_resource_quota" "airflow" {
  metadata {
    name      = "airflow-quota"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    hard = {
      "requests.cpu"           = "4"
      "requests.memory"        = "8Gi"
      "pods"                   = "20"
      "persistentvolumeclaims" = "4"
    }
  }

  depends_on = [kubernetes_namespace.airflow]
}

resource "kubernetes_limit_range" "airflow" {
  metadata {
    name      = "airflow-limits"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  }

  depends_on = [kubernetes_namespace.airflow]
}
```

- [ ] **Step 5: NetworkPolicy (ingress allow namespace 내 + kube-system, egress Cloud SQL/HTTPS/DNS) 추가**

`airflow.tf` 끝에 추가:

```hcl

# --- namespace 네트워크 격리 ---

# ponytail: allow 정책으로 deny-by-default 달성. 별도 default-deny NetworkPolicy 불필요.
# ingress: 같은 namespace pod + kube-system(예: GKE 메타데이터 에이전트)만 허용.
resource "kubernetes_network_policy" "airflow_ingress" {
  metadata {
    name      = "airflow-ingress"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {}
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.airflow]
}

# egress: kube-dns(53), Cloud SQL(private_services_cidr 5432), HTTPS(443)만 허용.
# ponytail: Cloud SQL private IP는 private_services_cidr /20 전체 허용 — 단일 IP 추적 비용 > dev에서 대역 허용. 운영 시 좁히기.
resource "kubernetes_network_policy" "airflow_egress" {
  metadata {
    name      = "airflow-egress"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # DNS (kube-dns)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }

      port {
        protocol = "UDP"
        port     = "53"
      }

      port {
        protocol = "TCP"
        port     = "53"
      }
    }

    # Cloud SQL (private services CIDR, 5432)
    egress {
      to {
        ip_block {
          cidr = var.private_services_cidr
        }
      }

      port {
        protocol = "TCP"
        port     = "5432"
      }
    }

    # HTTPS (googleapis.com 등)
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      port {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace.airflow]
}
```

- [ ] **Step 6: 검증**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

Expected: fmt clean, validate Success. 단, `var.gke_kubectl_user_emails`가 정의되지 않았으면(PR #34 미머지) installer_admin에서 에러 → 해당 스텝을 임시 주석 처리하고 진행하거나 #34 merge 후 rebase.

- [ ] **Step 7: 커밋**

```bash
git add terraform/envs/dev/airflow.tf
git commit -m "feat: #32 Airflow K8s namespace/RBAC/네트워크 정책 추가"
```

---

## Task 4: outputs.tf airflow 출력값 추가

**Files:**
- Modify: `terraform/envs/dev/outputs.tf` (파일 끝에 출력 5개 추가)

**Interfaces:**
- Consumes: `kubernetes_namespace.airflow`, `kubernetes_service_account.airflow`, `google_service_account.airflow`, `local.airflow_workload_identity_principal`, `google_sql_database.airflow`
- Produces: (없음 — 최종 task 산출물)

- [ ] **Step 1: outputs.tf에 airflow 출력 5개 추가**

`outputs.tf` 맨 끝(proxy_sa_email 출력 뒤)에 추가:

```hcl

output "airflow_namespace" {
  description = "Airflow 구성요소가 배포되는 Kubernetes namespace."
  value       = kubernetes_namespace.airflow.metadata[0].name
}

output "airflow_k8s_service_account_name" {
  description = "Airflow Workload Identity 매핑용 Kubernetes service account 이름."
  value       = kubernetes_service_account.airflow.metadata[0].name
}

output "airflow_gcp_service_account_email" {
  description = "Airflow Workload Identity용 GCP 서비스 계정 email (Cloud SQL/GCS/BigQuery 접근)."
  value       = google_service_account.airflow.email
}

output "airflow_workload_identity_principal" {
  description = "Airflow KSA가 가장할 principal 식별자. Helm values 참조용."
  value       = local.airflow_workload_identity_principal
}

output "airflow_cloudsql_database_name" {
  description = "Airflow metadata DB (Cloud SQL) 이름."
  value       = google_sql_database.airflow.name
}
```

- [ ] **Step 2: 검증**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

Expected: fmt clean, validate Success.

- [ ] **Step 3: 커밋**

```bash
git add terraform/envs/dev/outputs.tf
git commit -m "feat: #32 Airflow outputs 추가"
```

---

## Task 5: TERRAFORM_DEV.md Airflow 설치 runbook 추가

**Files:**
- Modify: `docs/TERRAFORM_DEV.md` (Airflow 설치 runbook 섹션 추가)

**Interfaces:**
- Consumes: 이 plan의 산출물(output 이름들), 기존 runbook 문서 형식
- Produces: (문서 — 팀원 설치 절차 안내)

- [ ] **Step 1: TERRAFORM_DEV.md에 Airflow 섹션 추가**

`docs/TERRAFORM_DEV.md`의 적절한 위치(GKE 접근 runbook 뒤, 또는 문서 끝)에 다음 섹션을 추가한다. 기존 문서의 헤더 레벨/스타일에 맞춘다.

````markdown
## Airflow 인프라 (#32)

dev GKE `airflow` namespace에 Airflow를 설치하기 위한 인프라 경계가 Terraform으로
프로비저닝된다. Helm values 자체(앱 설정, OAuth, executor)는 앱 저장소 범위.

### 사전 준비

- `terraform apply` 완료 — namespace, K8s SA, GCP SA(WI), Cloud SQL DB, GCS 버킷 생성 확인:

```bash
kubectl -n airflow get namespace,sa,role,rolebinding,resourcequota,limitrange,networkpolicy
gcloud sql databases list --instance=autoresearch-dev-pg | grep airflow
gsutil ls gs://$(terraform -chdir=terraform/envs/dev output -raw project_id)-autoresearch-dev-airflow-dags
```

### Helm 설치 (설치 담당자)

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

# Helm values 예시 (앱 저장소에서 상세 관리):
cat > airflow-values.yaml <<EOF
airflow:
  serviceAccount:
    create: false
    name: airflow  # Terraform이 생성한 K8s SA
  executor: KubernetesExecutor
  data:
    metadataSecretName: airflow-metadata-db
  logs:
    persistence:
      enabled: true
      storageClass: ""
      size: 10Gi
EOF

helm install airflow apache-airflow/airflow -n airflow -f airflow-values.yaml
```

Cloud SQL 연결 문자열 (values의 `database`):

```
postgresql+psycopg2://<user>:<password>@<cloudsql_private_ip>:5432/airflow
```

Cloud SQL private IP는 `terraform -chdir=terraform/envs/dev output -raw cloud_sql_private_ip_address`로 확인.

### 검증

```bash
kubectl -n airflow get pods
# K8s SA 어노테이션 확인 (WI 매핑)
kubectl -n airflow get sa airflow -o jsonpath='{.metadata.annotations.iam\.gkeusercontent\.com/gcp-service-account}'
```

Airflow pod에서 WI 토큰 검증:

```bash
kubectl -n airflow exec -it deploy/airflow-scheduler -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/email"
```

### 트러블슈팅

- **GCP 접근 실패 (403/권한 에러)**: K8s SA 어노테이션과 GCP SA IAM member 양쪽 확인. `iam.gkeusercontent.com/gcp-service-account` 어노테이션이 GCP SA email과 일치해야 함.
- **NetworkPolicy로 통신 차단**: egress 정책이 Cloud SQL(private_services_cidr 5432), HTTPS(443), DNS(53)만 허용. 추가 대상이 필요하면 `kubernetes_network_policy.airflow_egress`에 egress 블록 추가 후 apply.
- **Cloud SQL 연결 타임아웃**: Cloud SQL Auth Proxy / Connector 없이 private IP 직접 접근 시 pod가 private_services_cidr 대역에 도달해야 함. NetworkPolicy egress와 노드 라우팅 확인.

### Airflow 접근 권한 off-boarding

팀원 접근 회수 시 `gke_kubectl_user_emails`에서 이메일 제거 후 apply. kubectl access token 만료까지 최대 ~1시간 지연 가능 — 긴급 시 GCP Console > IAM에서 해당 사용자 세션 별도 종료.
````

- [ ] **Step 2: 검증**

```bash
git diff --check
```

문서 파일이므로 terraform 검증은 생략. 기존 TERRAFORM_DEV.md의 헤더 레벨과 일치하는지 육안 확인.

- [ ] **Step 3: 커밋**

```bash
git add docs/TERRAFORM_DEV.md
git commit -m "docs: #32 Airflow 설치 runbook 추가"
```

---

## Task 6: 최종 검증 + terraform.tfvars.example 갱신

**Files:**
- Modify: `terraform/envs/dev/terraform.tfvars.example` (airflow 변수 예시 추가 — optional, default 있으므로)

**Interfaces:**
- Consumes: 모든 이전 task
- Produces: 최종 커밋 가능 상태

- [ ] **Step 1: terraform.tfvars.example에 airflow 변수 예시 추가 (optional)**

`terraform.tfvars.example`의 적절한 위치(GKE 관련 변수 근처)에 추가. default가 있으므로 주석 처리:

```hcl
# --- Airflow (#32) ---
# airflow_k8s_namespace      = "airflow"
# airflow_k8s_service_account = "airflow"
```

- [ ] **Step 2: 전체 검증 재실행**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

Expected: 전부 PASS.

- [ ] **Step 3: 커밋**

```bash
git add terraform/envs/dev/terraform.tfvars.example
git commit -m "docs: #32 terraform.tfvars.example에 airflow 변수 예시 추가"
```

- [ ] **Step 4: push + Draft PR 생성 (사용자 확인 후)**

```bash
git push -u origin feat/32-airflow-namespace-rbac
```

PR은 사용자 확인 후 생성(title: `feat: Airflow 운영 인프라 경계 구성 (#32)`, Closes #32).

---

## Self-Review

**1. Spec coverage:**
- ✅ kubernetes provider 추가 + 인증 (Task 1)
- ✅ K8s namespace airflow (Task 3 Step 1)
- ✅ K8s SA airflow + WI 어노테이션 (Task 3 Step 1)
- ✅ Role airflow_components + RoleBinding airflow_sa (Task 3 Step 2)
- ✅ RoleBinding installer_admin (for_each) (Task 3 Step 3)
- ✅ ResourceQuota (Task 3 Step 4)
- ✅ LimitRange (Task 3 Step 4)
- ✅ NetworkPolicy ingress (Task 3 Step 5)
- ✅ NetworkPolicy egress (Task 3 Step 5)
- ✅ GCP SA airflow (Task 2 Step 1)
- ✅ WI 매핑 (Task 2 Step 1)
- ✅ cloudsql.client project (Task 2 Step 2)
- ✅ bigquery.jobUser project (Task 2 Step 2)
- ✅ Cloud SQL database airflow (Task 2 Step 3)
- ✅ GCS 버킷 dags/logs prevent_destroy (Task 2 Step 4)
- ✅ storage objectAdmin × 5 (Task 2 Step 5)
- ✅ bigquery dataEditor feast_offline_store (Task 2 Step 6)
- ✅ 변수 airflow_k8s_namespace/airflow_k8s_service_account (Task 1 Step 2)
- ✅ outputs 5개 (Task 4)
- ✅ TERRAFORM_DEV.md runbook (Task 5)

**2. Placeholder scan:** 없음. 모든 스텝에 실제 HCL/명령어 포함.

**3. Type/name consistency:**
- `local.airflow_sa_name` / `local.airflow_workload_identity_principal` / `local.airflow_dags_bucket_name` / `local.airflow_logs_bucket_name` — Task 1에서 정의, Task 2-4에서 동일 이름 참조. ✅
- `var.airflow_k8s_namespace` / `var.airflow_k8s_service_account` — Task 1 정의, Task 3-4 참조. ✅
- `google_service_account.airflow.email` / `.name` — Task 2 정의, Task 3(K8s SA 어노테이션) / Task 4(output) 참조. ✅
- `kubernetes_namespace.airflow` / `kubernetes_service_account.airflow` — Task 3 정의, Task 4 output에서 `.metadata[0].name` 참조. ✅
- spec의 `airflow_gcp_sa_name` 변수 → plan에서는 `local.airflow_sa_name`으로 대체(gke_app 패턴 일관성). Step 2에 주석 명시. ✅
- spec의 `airflow_default_deny_ingress` NetworkPolicy → plan에서는 `airflow_ingress`(allow 정책)로 통합(deny-by-default는 allow 정책으로 달성). Step 5에 ponytail 주석 명시. ✅

**4. 의존성 순서:** Task 1(provider/변수/locals) → Task 2(GCP 리소스, SA email 산출) → Task 3(K8s 리소스, SA email 참조) → Task 4(outputs) → Task 5(문서) → Task 6(tfvars.example + 최종). validate는 각 task마다 통과. ✅
