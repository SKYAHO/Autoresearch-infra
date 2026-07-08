# dev GKE 클러스터 구성 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev 환경에 최소 비용·보안 기본기를 갖춘 Standard GKE 클러스터를 Terraform으로 추가한다 (이슈 #5).

> 2026-07-08 update: 이 문서는 #5 최초 최소 비용 구현 계획 기록이다.
> 워커 노드 머신 타입 기준은 #41에서 `e2-standard-4`로 변경한다.

**Architecture:** Standard zonal 클러스터 + 노드풀 autoscaling(1~2). private nodes + master authorized networks. 노드 SA(AR pull/로깅/모니터링)와 app GCP SA(Workload Identity, Cloud SQL Client + Secret Accessor) 분리. private 노드 egress용 Cloud NAT. #4에서 미뤄둔 DB 비밀번호 Secret Manager 저장을 같이 추가.

**Tech Stack:** Terraform, Google provider(`>=5.0,<8.0`, 현재 7.39.0), google-beta, random. 검증 = `terraform fmt/validate` + `git diff --check` (이 repo는 pytest 없음).

## Global Constraints

- root module: `terraform/envs/dev` (단일 dev 환경)
- 네이밍: `${name_prefix}-${environment}-*` = `autoresearch-dev-*`
- region `asia-northeast3` / zone `asia-northeast3-a`
- `default_labels`는 provider `google`에 이미 일괄 적용됨(리소스별 수동 미부여)
- **API 활성화 수동 정책**(`google_project_service` 미사용): apply 전 `container.googleapis.com` 활성화 필요
- 커밋 금지: `terraform.tfvars`, `*.tfstate`, `*.tfplan`, SA key
- 커밋 컨벤션: `<type>: <한국어 설명>`, 제목 50자 이내, 현재형 동사
- 브랜치: `feat/5-gke` (영어 소문자+하이픈, 이슈번호 포함) — 이미 생성됨
- merge: squash only

## File Structure

- **Create** `terraform/envs/dev/gke.tf` — 노드 SA, app SA(WI binding), GKE cluster, node pool
- **Create** `terraform/envs/dev/nat.tf` — Cloud Router + Router NAT
- **Create** `terraform/envs/dev/secret_manager.tf` — DB 비밀번호 Secret + version (←#4 미룬 것)
- **Modify** `terraform/envs/dev/vpc.tf` — 서브넷 2차 대역(pods/services) additive
- **Modify** `terraform/envs/dev/variables.tf` — GKE/NAT/secret 변수 +13
- **Modify** `terraform/envs/dev/locals.tf` — GKE 이름 locals
- **Modify** `terraform/envs/dev/outputs.tf` — GKE/secret 출력 +7
- **Modify** `terraform/envs/dev/terraform.tfvars.example` — 신규 변수 예시
- **Modify** `docs/TERRAFORM_DEV.md` — GKE 섹션 + kubectl 접근/비용/롤백
- **Modify** `README.md` — 저장소 구조/상태 한 줄
- **Local-only(미커밋)** `agent.md`, `docs/NOTION_PROGRESS_TIMELINE.md`

---

### Task 1: 변수 및 locals 추가

**Files:**
- Modify: `terraform/envs/dev/variables.tf` (append)
- Modify: `terraform/envs/dev/locals.tf` (append into `locals {}` block)

**Interfaces:**
- Produces: 변수 `var.gke_*`, `var.master_authorized_networks`, `var.gke_app_k8s_*`; locals `local.gke_cluster_name`, `local.gke_node_sa_name`, `local.gke_app_sa_name`, `local.gke_node_pool_name`, `local.gke_pods_range_name`, `local.gke_services_range_name`, `local.db_password_secret_id`, `local.gke_workload_identity_principal`

- [ ] **Step 1: variables.tf 끝에 신규 변수 추가**

`terraform/envs/dev/variables.tf` 맨 끝에 append:

```hcl
variable "gke_master_ipv4_cidr" {
  description = "Private GKE 컨트롤 플레인용 /28 CIDR. dev subnet/private services와 미중복."
  type        = string

  validation {
    condition     = can(cidrhost(var.gke_master_ipv4_cidr, 0))
    error_message = "gke_master_ipv4_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_pods_cidr" {
  description = "GKE pods용 서브넷 2차 대역. dev subnet/private services/master CIDR과 미중복."
  type        = string
  default     = "__VG_IPV4_d1c0e8a2__/20"

  validation {
    condition     = can(cidrhost(var.gke_pods_cidr, 0))
    error_message = "gke_pods_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_services_cidr" {
  description = "GKE services용 서브넷 2차 대역. 다른 대역과 미중복."
  type        = string
  default     = "__VG_IPV4_b7e1f903__/24"

  validation {
    condition     = can(cidrhost(var.gke_services_cidr, 0))
    error_message = "gke_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_machine_type" {
  description = "노드 머신 타입 (dev 최소 비용)."
  type        = string
  default     = "e2-small"
}

variable "gke_node_count_min" {
  description = "노드풀 autoscaling 최소 노드 수."
  type        = number
  default     = 1
}

variable "gke_node_count_max" {
  description = "노드풀 autoscaling 최대 노드 수."
  type        = number
  default     = 2
}

variable "gke_node_disk_size" {
  description = "노드 부트 디스크 크기(GB)."
  type        = number
  default     = 30
}

variable "gke_node_disk_type" {
  description = "노드 부트 디스크 타입."
  type        = string
  default     = "pd-standard"
}

variable "gke_release_channel" {
  description = "GKE release channel (관리형 업그레이드)."
  type        = string
  default     = "REGULAR"
}

variable "gke_deletion_protection" {
  description = "GKE cluster 삭제 보호. dev는 false 권장."
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "GKE 마스터 API에 접근 허용할 CIDR 목록. kubectl을 쓰려면 본인 IP를 tfvars에 추가."
  type        = list(string)
  default     = []
}

variable "gke_app_k8s_namespace" {
  description = "Workload Identity로 매핑할 Kubernetes namespace."
  type        = string
  default     = "autoresearch"
}

variable "gke_app_k8s_service_account" {
  description = "Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "autoresearch-app"
}
```

- [ ] **Step 2: locals.tf에 GKE locals 추가**

`terraform/envs/dev/locals.tf`의 `locals {}` 블록 안(`sql_instance_name = ...` 라인 아래)에 append:

```hcl
  gke_cluster_name          = "${local.resource_prefix}-gke"
  gke_node_sa_name          = "${local.resource_prefix}-gke-nodes"
  gke_app_sa_name           = "${local.resource_prefix}-app"
  gke_node_pool_name        = "dev-default"
  gke_pods_range_name       = "gke-pods"
  gke_services_range_name   = "gke-services"
  db_password_secret_id     = "${local.resource_prefix}-db-password"
  gke_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.gke_app_k8s_namespace}/${var.gke_app_k8s_service_account}]"
```

- [ ] **Step 3: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공. (신규 변수/locals만 추가해 리소스 변화 없음.)

---

### Task 2: 서브넷 2차 대역 + Cloud NAT

**Files:**
- Modify: `terraform/envs/dev/vpc.tf:9-15` (`google_compute_subnetwork.dev`에 secondary_ip_range 추가)
- Create: `terraform/envs/dev/nat.tf`

**Interfaces:**
- Consumes: `var.gke_pods_cidr`, `var.gke_services_cidr`, `local.gke_pods_range_name`, `local.gke_services_range_name`, `google_compute_network.dev`
- Produces: 서브넷 2차 대역(Task 4 cluster ip_allocation_policy 참조), `google_compute_router.dev`, `google_compute_router_nat.dev`

- [ ] **Step 1: vpc.tf 서브넷에 2차 대역 추가**

`google_compute_subnetwork.dev` 리소스에 `secondary_ip_range` 블록 2개 추가:

```hcl
resource "google_compute_subnetwork" "dev" {
  name                     = local.dev_subnet_name
  ip_cidr_range            = var.dev_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.dev.id
  private_ip_google_access = var.enable_private_google_access

  secondary_ip_range {
    range_name    = local.gke_pods_range_name
    ip_cidr_range = var.gke_pods_cidr
  }

  secondary_ip_range {
    range_name    = local.gke_services_range_name
    ip_cidr_range = var.gke_services_cidr
  }
}
```

- [ ] **Step 2: nat.tf 생성**

`terraform/envs/dev/nat.tf`:

```hcl
# private GKE 노드의 아웃바운드(AR pull 등)용 Cloud NAT.
# ponytail: AR(*.pkg.dev)은 PGA(restricted.googleapis.com) 범위 밖이라 NAT 필요.
resource "google_compute_router" "dev" {
  name    = "${local.resource_prefix}-router"
  region  = var.region
  network = google_compute_network.dev.id
}

resource "google_compute_router_nat" "dev" {
  name                               = "${local.resource_prefix}-nat"
  router                             = google_compute_router.dev.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_PRIMARY_IP_RANGES"

  depends_on = [google_compute_subnetwork.dev]
}
```

- [ ] **Step 3: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공.

- [ ] **Step 4: 커밋**

```bash
git add terraform/envs/dev/vpc.tf terraform/envs/dev/nat.tf
git commit -m "feat: dev 서브넷 2차 대역 및 Cloud NAT 추가"
```

---

### Task 3: 서비스 계정 + Workload Identity

**Files:**
- Create: `terraform/envs/dev/gke.tf` (이 태스크에서 파일 생성, cluster는 다음 태스크에 추가)

**Interfaces:**
- Consumes: `var.project_id`, `local.gke_node_sa_name`, `local.gke_app_sa_name`, `local.gke_workload_identity_principal`
- Produces: `google_service_account.gke_nodes`, `google_service_account.gke_app`, IAM members, WI binding (Task 4 cluster가 WI pool 사용)

- [ ] **Step 1: gke.tf 생성 — SA + IAM**

`terraform/envs/dev/gke.tf`:

```hcl
# #5 dev GKE — 서비스 계정 + Workload Identity
# 노드 SA: 클러스터 전체(AR pull, 로깅, 모니터링). app SA: pod 단위 권한(Cloud SQL, Secret).

resource "google_service_account" "gke_nodes" {
  account_id   = local.gke_node_sa_name
  display_name = "Autoresearch dev GKE node pool SA"
}

resource "google_project_iam_member" "gke_nodes_ar" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_service_account" "gke_app" {
  account_id   = local.gke_app_sa_name
  display_name = "Autoresearch dev GKE app workload identity SA"
}

# ponytail: Cloud SQL/Secret 접근은 app pod만(WI). 노드 SA에 주지 않음(최소 권한).
resource "google_project_iam_member" "gke_app_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_project_iam_member" "gke_app_secret" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_service_account_iam_member" "gke_app_wi" {
  service_account_id = google_service_account.gke_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.gke_workload_identity_principal}"
}
```

- [ ] **Step 2: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공.

---

### Task 4: GKE 클러스터 + 노드풀

**Files:**
- Modify: `terraform/envs/dev/gke.tf` (cluster + node pool append)

**Interfaces:**
- Consumes: `google_compute_network.dev`, `google_compute_subnetwork.dev`(2차 대역), `google_service_account.gke_nodes`, `var.gke_*`, `var.master_authorized_networks`, `local.*`
- Produces: `google_container_cluster.dev`, `google_container_node_pool.dev` → outputs(Task 7)

- [ ] **Step 1: gke.tf에 cluster + node pool 추가**

`terraform/envs/dev/gke.tf` 맨 끝에 append:

```hcl
resource "google_container_cluster" "dev" {
  name     = local.gke_cluster_name
  location = var.zone
  project  = var.project_id

  network    = google_compute_network.dev.id
  subnetwork = google_compute_subnetwork.dev.id

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.gke_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = local.gke_pods_range_name
    services_secondary_range_name = local.gke_services_range_name
  }

  # private nodes. 엔드포인트는 public(master_authorized_networks로 본인 IP만 허용) — 노트북 kubectl용.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.gke_master_ipv4_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = toset(var.master_authorized_networks)
      content {
        cidr_block   = cidr_blocks.value
        display_name = "user"
      }
    }
  }

  deletion_protection = var.gke_deletion_protection

  depends_on = [google_compute_router_nat.dev]
}

resource "google_container_node_pool" "dev" {
  name       = local.gke_node_pool_name
  cluster    = google_container_cluster.dev.id
  location   = var.zone
  node_count = var.gke_node_count_min

  autoscaling {
    min_node_count = var.gke_node_count_min
    max_node_count = var.gke_node_count_max
  }

  node_config {
    machine_type    = var.gke_machine_type
    disk_size_gb    = var.gke_node_disk_size
    disk_type       = var.gke_node_disk_type
    service_account = google_service_account.gke_nodes.email
    tags            = [local.ssh_iap_tag]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # autoscaler가 노드 수를 바꿔도 Terraform이 되돌리지 않도록.
  lifecycle {
    ignore_changes = [node_count]
  }
}
```

- [ ] **Step 2: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공.

- [ ] **Step 3: 커밋**

```bash
git add terraform/envs/dev/gke.tf
git commit -m "feat: dev GKE 클러스터 및 노드 서비스 계정 추가"
```

---

### Task 5: Secret Manager (DB 비밀번호 저장)

**Files:**
- Create: `terraform/envs/dev/secret_manager.tf`

**Interfaces:**
- Consumes: `random_password.db_app_password`(← cloud_sql.tf, #4), `local.db_password_secret_id`
- Produces: `google_secret_manager_secret.db_app_password`, `_version` → output(Task 7), app SA가 accessor로 접근

- [ ] **Step 1: secret_manager.tf 생성**

`terraform/envs/dev/secret_manager.tf`:

```hcl
# #5 DB app 비밀번호를 Secret Manager에 저장 (← #4에서 GKE app 소비 시점으로 미룬 것).
# random_password.db_app_password 는 cloud_sql.tf(#4)에 이미 존재.
resource "google_secret_manager_secret" "db_app_password" {
  secret_id = local.db_password_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_app_password" {
  secret      = google_secret_manager_secret.db_app_password.id
  secret_data = random_password.db_app_password.result
}
```

- [ ] **Step 2: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공.

---

### Task 6: outputs + tfvars 예시

**Files:**
- Modify: `terraform/envs/dev/outputs.tf` (append)
- Modify: `terraform/envs/dev/terraform.tfvars.example` (append)

**Interfaces:**
- Produces: outputs — `gke_cluster_name`, `gke_cluster_endpoint`, `gke_cluster_ca_certificate`(sensitive), `gke_node_service_account_email`, `gke_app_service_account_email`, `gke_workload_identity_principal`, `db_app_password_secret_id`

- [ ] **Step 1: outputs.tf 끝에 출력 추가**

`terraform/envs/dev/outputs.tf` 맨 끝에 append:

```hcl
output "gke_cluster_name" {
  description = "dev GKE 클러스터 이름."
  value       = google_container_cluster.dev.name
}

output "gke_cluster_endpoint" {
  description = "dev GKE API endpoint."
  value       = google_container_cluster.dev.endpoint
}

output "gke_cluster_ca_certificate" {
  description = "dev GKE 클러스터 CA 인증서(base64)."
  value       = google_container_cluster.dev.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "gke_node_service_account_email" {
  description = "노드 풀에 연결된 GCP 서비스 계정(AR pull/로깅/모니터링)."
  value       = google_service_account.gke_nodes.email
}

output "gke_app_service_account_email" {
  description = "app Workload Identity용 GCP 서비스 계정(Cloud SQL/Secret)."
  value       = google_service_account.gke_app.email
}

output "gke_workload_identity_principal" {
  description = "KSA가 가장할 principal 식별자. app KSA annotation에 사용."
  value       = local.gke_workload_identity_principal
}

output "db_app_password_secret_id" {
  description = "DB app 비밀번호 Secret Manager secret id."
  value       = google_secret_manager_secret.db_app_password.id
}
```

- [ ] **Step 2: terraform.tfvars.example에 신규 변수 예시 추가**

`terraform/envs/dev/terraform.tfvars.example` 맨 끝에 append:

```hcl
# GKE (#5)
gke_master_ipv4_cidr = "__VG_IPV4_2f4a6b1c__/28" # private 컨트롤 플레인. dev subnet/private services와 미중복
gke_pods_cidr        = "__VG_IPV4_d1c0e8a2__/20"
gke_services_cidr    = "__VG_IPV4_b7e1f903__/24"
gke_machine_type     = "e2-small"
gke_node_count_min   = 1
gke_node_count_max   = 2
master_authorized_networks = ["203.0.113.10/32"] # kubectl 접속 본인 IP로 교체
```

- [ ] **Step 3: 검증**

Run:
```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: validate 성공.

- [ ] **Step 4: 커밋**

```bash
git add terraform/envs/dev/secret_manager.tf terraform/envs/dev/outputs.tf terraform/envs/dev/variables.tf terraform/envs/dev/locals.tf terraform/envs/dev/terraform.tfvars.example
git commit -m "feat: DB 비밀번호 Secret Manager 저장 및 GKE 출력 추가"
```

---

### Task 7: 운영 문서 업데이트

**Files:**
- Modify: `docs/TERRAFORM_DEV.md` (GKE 섹션 + kubectl/비용/롤백, "생성하지 않는 것"에서 GKE 제거)
- Modify: `README.md` (상태 한 줄)

- [ ] **Step 1: docs/TERRAFORM_DEV.md 수정**

`## 현재 단계에서 생성하지 않는 것` 목록에서 `- GKE cluster` 라인 삭제. `## dev Cloud SQL (#4)` 섹션 뒤에 새 섹션 추가:

```markdown
## dev GKE (#5)

| 항목 | 값 | 비고 |
|---|---|---|
| Cluster | `autoresearch-dev-gke` | Standard, zonal `asia-northeast3-a` |
| 모드 | private nodes, public endpoint(authorized) | 노드 공인 IP 없음, 마스터는 본인 IP만 |
| Master CIDR | `var.gke_master_ipv4_cidr` (/28) | dev subnet/private services와 미중복 |
| Pods/Services 대역 | 서브넷 2차 `gke-pods`/`gke-services` | VPC-native(alias IP) |
| 노드풀 | `dev-default`, e2-small, pd-standard 30GB | autoscaling min=1/max=2 |
| 노드 SA | `autoresearch-dev-gke-nodes` | AR reader + logging/metric writer |
| app SA(WI) | `autoresearch-dev-app` | cloudsql.client + secretAccessor, KSA 매핑 |
| Egress | Cloud NAT(`autoresearch-dev-nat`) | private 노드 AR(`*.pkg.dev`) pull |
| deletion_protection | false (dev) | 운영 전환 시 true |

### kubectl 접근
```bash
# 1) 본인 IP를 tfvars master_authorized_networks에 추가 후 apply
# 2) credentials 획득
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a --project <project_id>
kubectl get nodes
```

### Workload Identity(app 배포 시)
app KSA에 annotation 부여 → app GCP SA(`autoresearch-dev-app`) 가장:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: autoresearch
  name: autoresearch-app
  annotations:
    iam.gke.io/gcp-service-account: autoresearch-dev-app@<project_id>.iam.gserviceaccount.com
```

### 비용/롤백
- 예상: e2-small ~$13/월 + disk ~$1.5 + Cloud NAT ~$32(고정비) → 1노드 ~$47/월. Standard control plane 무료.
- 절감: min=1 고정. 장기 미사용 시 노드풀 count 0 또는 `terraform destroy` 권장.
- 롤백: `terraform destroy`로 cluster/node pool/NAT/SA 일괄 제거. 현재 dev state는 GCS backend에 저장.
```

- [ ] **Step 2: README.md 상태 라인 업데이트**

README "현재 단계" 문장을 GKE까지 구성 진행 중으로 반영(한 줄).

- [ ] **Step 3: 검증 + 커밋**

```bash
git diff --check
git add docs/TERRAFORM_DEV.md README.md
git commit -m "docs: GKE 클러스터 운영 문서 업데이트"
```

---

### Task 8: 전체 검증 (GCP 인증 필요)

> `terraform plan`은 실제 GCP project + 인증 + `container.googleapis.com` API 활성화가 필요. 사용자 승인 후 실행.

- [ ] **Step 1: API 활성화 확인/활성화**

```bash
gcloud services enable container.googleapis.com --project <project_id>
```
(`container.googleapis.com`은 `locals.required_services`에 포함되지만 수동 활성화 정책)

- [ ] **Step 2: plan 실행**

```bash
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```
Expected: GKE cluster, node pool, 2 SAs + IAM, WI binding, Cloud Router/NAT, subnet 2차 대역(in-place), Secret + version 리소스가 추가 계획에 나타남. (로컬 tfvars에 `gke_master_ipv4_cidr` 등 필수 입력.)

- [ ] **Step 3: 최종 fmt/validate**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```
Expected: 모두 통과.

---

### Task 9: Draft PR (템플릿 적용, 원격 작업은 사용자 확인 후)

> branch push / PR 생성은 GitHub 원격 작업이므로 **사용자 확인 후** 진행.

- [ ] **Step 1: branch push (확인 후)**

```bash
git push -u origin feat/5-gke
```

- [ ] **Step 2: Draft PR 생성 (PR 템플릿 기준)**

본문(`.github/PULL_REQUEST_TEMPLATE.md` 채움):

```markdown
## 작업 내용
dev 환경에 최소 비용·보안 기본기를 갖춘 Standard GKE 클러스터를 Terraform으로 추가합니다(#5). private nodes + master authorized networks, 노드풀 autoscaling(1~2), Workload Identity(노드 SA / app SA 분리), Cloud NAT, #4에서 미룬 DB 비밀번호 Secret Manager 저장을 포함합니다.

## 변경 사항
- GKE Standard zonal 클러스터 + 노드풀(e2-small, autoscaling min1/max2)
- 노드 SA(AR reader/logging/metric) + app SA(WI, cloudsql.client/secretAccessor)
- private nodes + master authorized networks + Cloud NAT(AR pull용)
- 서브넷 2차 대역(pods/services) additive
- DB 비밀번호 Secret Manager 저장(←#4 미룬 것)
- 변수/출력/문서(tfvars.example, TERRAFORM_DEV.md, README)

## 관련 이슈
Closes #5

## 체크리스트
- [x] 대상 GCP 프로젝트, 리전, 리소스 이름을 확인했다
- [x] IAM 권한이 최소 권한 원칙을 따른다 (노드 SA vs app SA 분리, WI)
- [x] secret 값, SA key, Terraform state가 포함되지 않았다
- [x] 비용, quota, 삭제/교체 영향 범위를 확인했다 (~$47/월, NAT 고정비)
- [x] workflow 권한/secret/trigger 해당 없음
- [x] Terraform fmt/validate/plan 결과를 확인했다
- [x] 관련 운영 문서(TERRAFORM_DEV.md, README)를 업데이트했다
- [x] git diff --check를 통과했다
- [x] 시크릿/개인정보가 코드에 포함되지 않았다

## 리뷰어 참고사항
- master_authorized_networks 기본 빈 리스트 — kubectl을 쓰려면 tfvars에 본인 IP 추가 후 apply.
- subnet 2차 대역 추가는 기존 VPC 리소스 in-place 업데이트(CIDR 미중복 확인 필요).
- plan 적용 전 container.googleapis.com 수동 활성화 필요.
- 롤백: deletion_protection=false → terraform destroy.
```

- [ ] **Step 3: PR 메타 설정 (확인 후)**
- Assignees: `hyeongyu-data`
- Labels: `terraform`, `gcp`, `iam`, `cost`, `security`
- Draft 상태로 시작 → 셀프 리뷰 → Ready 전환

- [ ] **Step 4: 이후 워크플로우 (11단계)**
Ready 전환 → Claude Code 리뷰 → 이해도 확인 inline 답변 → 팀원 2명 승인 → squash merge.
