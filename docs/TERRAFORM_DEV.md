# Terraform Dev Environment

이 문서는 `#1 Terraform dev 환경 기본 골격 구성` 결과를 팀원이 빠르게 이해하도록 정리합니다.

## 구조

```text
terraform/
├── README.md
├── bootstrap/            # #6 1회성: GCS state bucket + WIF + CI SA (local state)
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── versions.tf
├── envs/
│   └── dev/
│       ├── README.md
│       ├── artifact_registry.tf
│       ├── backend.tf.example
│       ├── cloud_sql.tf      # #4 dev Cloud SQL (PostgreSQL, private IP)
│       ├── gke.tf            # #5 dev GKE cluster + 노드풀 + SA/WI
│       ├── locals.tf
│       ├── nat.tf            # #5 Cloud Router + Cloud NAT (private 노드 egress)
│       ├── outputs.tf
│       ├── secret_manager.tf # #5 DB 비밀번호 Secret Manager 저장
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       ├── versions.tf
│       └── vpc.tf          # #2 dev VPC / subnet / 최소 firewall
└── modules/
    └── README.md
```

## dev VPC / subnet (#2)

| 항목 | 값 | 비고 |
|---|---|---|
| VPC 이름 | `autoresearch-dev-vpc` | `${name_prefix}-${environment}-vpc` |
| VPC 모드 | custom mode | `auto_create_subnetworks = false` |
| Subnet 이름 | `autoresearch-dev-subnet` | `${resource_prefix}-subnet` |
| Subnet CIDR | `10.10.0.0/20` | `var.dev_subnet_cidr`, dev 확장 여유분 |
| Region | `asia-northeast3` | `var.region` |
| Private Google Access | `true` | `var.enable_private_google_access`, Google API 사설 접근 |
| Route(PGA) | `restricted.googleapis.com`(`199.36.153.8/30`) → default-internet-gateway | `enable_private_google_access=true`일 때 생성. 외부 IP 없는 VM 의 Google API 도달 |
| Firewall(ingress) | IAP(35.235.240.0/20) → TCP 22, `target_tags=["ssh-iap"]` | IAP 경유 SSH. **SSH 필요 VM은 `ssh-iap` 태그 부착 필수**. 접근은 `roles/iap.tunnelAccessor`로 gating |

Cloud SQL / GKE 는 `google_compute_subnetwork.dev.self_link`(`output.dev_subnet_self_link`)를 참조해 같은 VPC에 배치한다.

## Artifact Registry (#3)

| 항목 | 값 | 비고 |
|---|---|---|
| Repository id | `autoresearch-dev-docker` | `${resource_prefix}-docker` (`local.ar_repo_id`) |
| Format | `DOCKER` | 컨테이너 이미지 |
| Location | `asia-northeast3` | `var.region`, dev 기본 region |
| Labels | `default_labels` 상속 | provider `default_labels`에서 일ꯜ 적용 |
| Image URL | `asia-northeast3-docker.pkg.dev/ar-infra-501108/autoresearch-dev-docker` | `output.artifact_registry_image_url` |
| IAM | (미구성) | push/pull 바인딩은 GitHub OIDC SA / GKE 노드 SA 이슈에서 추가 |

배포 workflow는 `output.artifact_registry_repo_id`(repo명)와 `output.artifact_registry_image_url`(이미지 base URL)을 참조한다.

### 왜 GCR이 아니라 Artifact Registry인가

- **GCR은 사실상 deprecated**: Google이 신규 기능/이미지를 Artifact Registry로 이관 중이며, 신규 프로젝트는 AR 권장.
- **IAM 정밀도**: AR은 리포 단위 IAM/labels로 세분화 가능. GCR은 프로젝트 단위(`gcr.io/<project>`)로 권한이 거침.
- **확장성**: AR은 Docker 외 npm/Maven/Python 등 멀티 포맷 + 리전/멀티리전 + 빌트인 취약점 스캔 지원.

## dev Cloud SQL (#4)

| 항목 | 값 | 비고 |
|---|---|---|
| Instance | `autoresearch-dev-pg` | `${resource_prefix}-pg` (`local.sql_instance_name`) |
| Engine | PostgreSQL 15 | `var.db_database_version` |
| Tier | `db-f1-micro` | `var.db_tier`, shared-core 최소 비용 (~$7/월) |
| Availability | `ZONAL` | dev 단일 zone, 비용 절감 |
| 접속 | **private IP only** (`ipv4_enabled=false`) | VPC 내부에서만 접근. `google_service_networking_connection` peering |
| Private services 대역 | `10.20.0.0/20` | `var.private_services_cidr`, VPC subnet(`10.10.0.0/20`)과 미중복 |
| DB / User | `autoresearch` / `app` | `var.db_name`, `var.db_app_user` |
| 비밀번호 | random 24자 → SQL user 주입, #5 Secret Manager 저장 | `random_password.db_app_password`, `output.db_app_password_secret_id` |
| Backup | 켜짐, point-in-time recovery on | `start_time 17:00` UTC |
| Maintenance | `stable` track, 일 17:00 UTC(월 02:00 KST) | `day=7`(1=Mon..7=Sun) |
| deletion_protection | **false** (dev) | `var.sql_deletion_protection`. 운영 전환 시 true |

**선행 API**: `sqladmin.googleapis.com`, `servicenetworking.googleapis.com`, `secretmanager.googleapis.com` (수동 활성화 — `google_project_service` 미사용).

접속은 같은 VPC의 리소스(GKE 노드, Cloud SQL Auth Proxy)에서 private IP(`output.cloud_sql_private_ip_address`)로. 비밀번호는 `random_password`로 생성되어 SQL user에 주입되며, #5에서 Secret Manager(`output.db_app_password_secret_id`)에도 저장한다.

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
> Terraform은 GCP SA + IAM 매핑만 생성. 아래 KSA는 app 매니페스트로 **배포 시 직접 생성해야 함**(미생성 시 WI 동작 안 함).

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
- 예상: e2-small ~$13/월 + disk ~$1.5 + Cloud NAT ~$32(고정비) → 1노드 ~$47/월. Standard control plane 무료. Cloud NAT 고정비가 dev 최대 항목.
- 절감: min=1 고정. 장기 미사용 시 노드풀 count 0 또는 `terraform destroy` 권장(NAT 고정비는 노드 0화로 노드 비용만 절감, NAT 자체는 남음).
- **Cloud Operations**(GKE 기본 On): Logging/Monitoring 비용 발생 가능. 비용 민감 시 클러스터 `logging_service`/`monitoring_service` 비활성화 검토.
- **State**: dev 루트는 #6에서 GCS 원격 backend(`autoresearch-dev-tfstate`)로 전환(bootstrap apply 후 `init -migrate-state`). 비밀번호 평문 저장은 근본 한계 → 버킷 IAM/UBLA 로 보호.
- 비밀번호 rotation: `random_password` 재생성(수동 `terraform -replace=random_password.db_app_password` 또는 keepers) → SQL user(`cloud_sql.tf`)와 Secret version(`secret_manager.tf`)에 동일 값 반영. 같은 소스라 parity 유지.
- 롤백: `terraform destroy`로 cluster/node pool/NAT/SA 일괄 제거(state local).

## 필수 GCP API 후보

아래 API는 후속 이슈에서 필요한 후보입니다. #1에서는 Terraform output으로 목록만 정리하며, 실제 enable은 별도 이슈나 승인 후 진행합니다.

| API | 사용 예정 |
|---|---|
| `serviceusage.googleapis.com` | GCP API enable 관리 |
| `cloudresourcemanager.googleapis.com` | project metadata 조회 및 관리 |
| `compute.googleapis.com` | VPC/subnet, GKE 기반 네트워크 |
| `artifactregistry.googleapis.com` | Docker image repository |
| `sqladmin.googleapis.com` | Cloud SQL |
| `container.googleapis.com` | GKE |
| `iam.googleapis.com` | service account, IAM binding |
| `iamcredentials.googleapis.com` | GitHub OIDC 기반 credential 생성 |
| `sts.googleapis.com` | Workload Identity Federation token exchange |
| `secretmanager.googleapis.com` | secret 저장 및 참조 |
| `logging.googleapis.com` | 운영 로그 |
| `monitoring.googleapis.com` | 모니터링 |

## 사전 조건 (apply 전)

이 모듈은 `google_project_service` 리소스로 GCP API를 enable하지 않습니다. API 활성화를 같은
root module에 넣으면 "API가 켜져야 생성 가능한 리소스"와 순환/부트스트랩 문제가 생기는
안티패턴이므로, API enable은 apply 전 별도 부트스트랩 단계로 분리한다.

`google_compute_network` / `google_compute_subnetwork` 생성은 `compute.googleapis.com` 활성화에
하드 의존하므로, 대상 프로젝트(`var.project_id`)에 최소 compute API가 먼저 켜져 있어야 apply가 성공한다.

```bash
# 최소: VPC/subnet 생성에 필요한 compute API
gcloud services enable compute.googleapis.com --project=ar-infra-501108

# 또는 required_services output 전체를 한 번에
terraform -chdir=terraform/envs/dev output -json required_services \
  | jq -r '.[]' | xargs gcloud services enable --project=ar-infra-501108
```

> Private Google Access(`enable_private_google_access`, 기본 `true`) 사용 시,
> `restricted.googleapis.com`(`199.36.153.8/30`)로 가는 default-internet-gateway 라우트를
> 모듈이 자동 생성한다. `private.googleapis.com` 범위가 필요한 서비스가 생기면 라우트를 추가한다.

## 검증 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

`terraform init`은 provider plugin을 내려받기 때문에 네트워크가 필요합니다.

## CI 자동 검증 (#6)

PR 이 열리면 GitHub Actions(`.github/workflows/terraform-plan.yml`)가 자동으로 `terraform fmt/validate/plan` 을 실행하고 결과를 PR 댓글로 게시한다.

- **인증**: SA key 없이 GitHub OIDC + Workload Identity Federation(WIF). CI SA(`terraform-ci`)는 `roles/viewer` + `roles/secretmanager.secretAccessor`(plan 전용 읽기 권한).
- **state**: GCS 원격 backend(`autoresearch-dev-tfstate`). 부트스트랩 절차는 [docs/TERRAFORM_BOOTSTRAP.md](TERRAFORM_BOOTSTRAP.md) 참조.
- **제한**: WIF `attribute_condition` 으로 `SKYAHO/Autoresearch-infra` 저장소만 허용.
- **apply 자동화는 범위 밖**(별도 이슈). 본 워크플로는 plan 만 게시한다.

필요 GitHub variables(4개, secret 아님): `GCP_PROJECT_ID`, `WIF_POOL_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`.

