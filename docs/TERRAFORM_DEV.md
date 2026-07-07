# Terraform Dev Environment

이 문서는 Terraform dev 환경(`#1`~`#6`)의 현재 구성과 운영 방법을 팀원이 빠르게 이해하도록 정리합니다.

## 현재 상태

- GCP 프로젝트: `ar-infra-501607`
- dev root module: `terraform/envs/dev`
- Terraform backend: GCS `autoresearch-dev-tfstate`, prefix `dev/`
- 마지막 실제 apply: 2026-07-06, `25 added, 0 changed, 0 destroyed`
- #18 현재 브랜치 변경: dev 원본 데이터 GCS bucket 추가 예정(plan/apply 전)

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
│       ├── storage.tf        # #18 dev 원본 데이터/Feast GCS bucket
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
| Labels | `default_labels` 상속 | provider `default_labels`에서 일괄 적용 |
| Image URL | `asia-northeast3-docker.pkg.dev/ar-infra-501607/autoresearch-dev-docker` | `output.artifact_registry_image_url` |
| IAM | GKE node SA에 `roles/artifactregistry.reader` | app 이미지 pull용. CI push 권한은 별도 배포 이슈에서 결정 |

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
| Private services 대역 | `192.168.0.0/20` | 현재 dev apply 값. VPC subnet(`10.10.0.0/20`)과 미중복 |
| Private IP | `192.168.0.3` | `output.cloud_sql_private_ip_address` |
| DB / User | `autoresearch` / `app` | `var.db_name`, `var.db_app_user` |
| 비밀번호 | random 24자 → SQL user 주입, #5 Secret Manager 저장 | `random_password.db_app_password`, `output.db_app_password_secret_id` |
| Backup | 켜짐, point-in-time recovery on | `start_time 17:00` UTC |
| Maintenance | `stable` track, 일 17:00 UTC(월 02:00 KST) | `day=7`(1=Mon..7=Sun) |
| deletion_protection | **false** (dev) | `var.sql_deletion_protection`. 운영 전환 시 true |

**선행 API**: `sqladmin.googleapis.com`, `servicenetworking.googleapis.com`, `secretmanager.googleapis.com` (수동 활성화 — `google_project_service` 미사용).

접속은 같은 VPC의 리소스(GKE 노드, Cloud SQL Auth Proxy)에서 private IP(`output.cloud_sql_private_ip_address`)로. 비밀번호는 `random_password`로 생성되어 SQL user에 주입되며, #5에서 Secret Manager(`output.db_app_password_secret_id`)에도 저장한다.

## dev 원본 데이터 GCS (#18)

| 항목 | 값 | 비고 |
|---|---|---|
| Bucket | `ar-infra-501607-autoresearch-dev-raw-data` | `${project_id}-${resource_prefix}-raw-data`, 전역 unique 이름 |
| Location | `asia-northeast3` | `var.raw_data_bucket_location` |
| Storage class | `STANDARD` | dev 원본 적재/검증용 |
| Public access | 차단 | `public_access_prevention = "enforced"` |
| IAM 모델 | Uniform bucket-level access | 객체 ACL 대신 bucket IAM만 사용 |
| Versioning | enabled | 원본 overwrite/삭제 실수 대비 |
| Soft delete | disabled | dev 비용 누적 방지. versioning/lifecycle로 보호 |
| Noncurrent 정리 | 30일 후 삭제 | `var.raw_data_noncurrent_version_retention_days`, dev 비용 누적 방지 |
| 접근 주체 | GKE app SA | `roles/storage.objectUser` bucket-level grant |
| Destroy 보호 | `force_destroy=false`, `prevent_destroy=true` | 원본 데이터 유실 방지. 삭제 필요 시 lifecycle 해제 후 별도 계획 |

### Prefix 규칙

GCS는 폴더 리소스를 따로 만들지 않고 object name prefix를 폴더처럼 사용한다. 원본 전체 데이터는 아래 prefix로 나눠 적재한다.

| 데이터 | Prefix | 예시 |
|---|---|---|
| YouTube raw | `youtube/raw/` | `youtube/raw/dt=2026-07-07/video_id.json` |
| 유저 원본 | `users/raw/` | `users/raw/dt=2026-07-07/users.jsonl` |
| 액션 로그 원본 | `action-logs/raw/` | `action-logs/raw/dt=2026-07-07/events.jsonl` |
| 페르소나 원본 전체 | `personas/raw/` | `personas/raw/dt=2026-07-07/personas.csv` |

원본 bucket은 정형 분석 저장소가 아니라 landing/raw zone이다. BigQuery 적재용 정제 테이블이나 PostgreSQL 서비스 DB와 섞지 않는다.

### 삭제/비용 운영

- `prevent_destroy=true`: dev root 전체 `terraform destroy`를 실행해도 이 bucket에서 먼저 차단된다.
- `force_destroy=false`: lifecycle 보호를 해제해도 객체/버전이 남아 있으면 bucket 삭제가 실패한다.
- 의도적으로 삭제하려면 원본 백업/이관 → lifecycle 해제 PR → 객체와 noncurrent version 정리 → 필요 시 `force_destroy=true` 임시 변경 → 별도 apply 순서로 진행한다.
- versioning은 원본 보호용이며, noncurrent version은 30일 후 삭제해 dev 비용 누적을 줄인다.
- dev에서는 soft delete를 꺼서 versioning과 soft delete가 중복으로 보존 비용을 만드는 상황을 피한다.

## dev BigQuery (#20)

| 항목 | 값 | 비고 |
|---|---|---|
| Dataset | `autoresearch_dev_analytics` | `${resource_prefix}_analytics`에서 `-`를 `_`로 변환 |
| Feast offline store | `feast_offline_store` | Feast feature offline store 전용 dataset |
| Location | `asia-northeast3` | `var.bigquery_location`, GCS raw bucket과 동일 리전 |
| 용도 | 구조화 분석 데이터 | GCS raw에서 적재/정제된 테이블 저장 |
| Destroy 보호 | `prevent_destroy=true` | 분석 테이블 유실 방지 |
| delete_contents_on_destroy | false | table/view가 있으면 dataset 삭제 실패 |
| GKE app SA 권한 | dataset `dataEditor` + project `jobUser` | app/배치가 load/query job 실행 가능 |

### GCS와 BigQuery 역할

| 데이터 | 원본 보관 | 분석/조회 |
|---|---|---|
| YouTube raw | GCS `youtube/raw/` | BigQuery table로 정제 적재 |
| 유저 원본 | GCS `users/raw/` | BigQuery table로 정제 적재 |
| 액션 로그 원본 | GCS `action-logs/raw/` | BigQuery partitioned table 후보 |
| 페르소나 원본 전체 | GCS `personas/raw/` | BigQuery dimension/reference table 후보 |

GCS는 원본 파일 보존, BigQuery는 SQL 분석과 downstream feature 생성을 담당한다.

### Feast 저장소

| 항목 | 값 | 비고 |
|---|---|---|
| Offline store dataset | `feast_offline_store` | Feast feature table 저장 |
| Registry bucket | `ar-infra-501607-feast-registry` | `gs://ar-infra-501607-feast-registry`, registry.db 등 메타데이터 |
| Staging bucket | `ar-infra-501607-feast-staging` | `gs://ar-infra-501607-feast-staging`, materialization/load 임시 파일 |
| Bucket naming | `${project_id}-feast-registry`, `${project_id}-feast-staging` | 사용자가 지정한 project id 기반 이름 |
| Registry 보호 | versioning enabled, noncurrent 30일 보존 | registry 갱신 이력 보호와 비용 제어 |
| Staging 정리 | 7일 후 object 삭제 | 임시 파일 비용 누적 방지 |
| 접근 주체 | GKE app SA | BigQuery dataset `dataEditor`, GCS bucket `storage.objectUser` |

## dev GKE (#5)

| 항목 | 값 | 비고 |
|---|---|---|
| Cluster | `autoresearch-dev-gke` | Standard, zonal `asia-northeast3-a` |
| Endpoint | `34.64.97.177` | public endpoint + authorized networks |
| 모드 | private nodes, public endpoint(authorized) | 노드 공인 IP 없음, 마스터는 본인 IP만 |
| Master CIDR | `172.16.0.0/28` | 현재 dev apply 값. dev subnet/private services와 미중복 |
| Pods/Services 대역 | `172.16.64.0/20` / `172.16.128.0/24` | 서브넷 2차 대역, VPC-native(alias IP) |
| 노드풀 | `dev-default`, e2-small, pd-standard 30GB | autoscaling min=1/max=2 |
| 노드 SA | `autoresearch-dev-gke-nodes@ar-infra-501607.iam.gserviceaccount.com` | AR reader + logging/metric writer |
| app SA(WI) | `autoresearch-dev-app@ar-infra-501607.iam.gserviceaccount.com` | cloudsql.client + secretAccessor, KSA 매핑 |
| WI principal | `ar-infra-501607.svc.id.goog[autoresearch/autoresearch-app]` | Terraform에서 GCP SA IAM binding까지 생성 |
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
    iam.gke.io/gcp-service-account: autoresearch-dev-app@ar-infra-501607.iam.gserviceaccount.com
```

### 비용/롤백
- 예상: e2-small ~$13/월 + disk ~$1.5 + Cloud NAT ~$32(고정비) → 1노드 ~$47/월. Standard control plane 무료. Cloud NAT 고정비가 dev 최대 항목.
- 절감: min=1 고정. 장기 미사용 시 노드풀 count 0 또는 `terraform destroy` 권장(NAT 고정비는 노드 0화로 노드 비용만 절감, NAT 자체는 남음).
- **Cloud Operations**(GKE 기본 On): Logging/Monitoring 비용 발생 가능. 비용 민감 시 클러스터 `logging_service`/`monitoring_service` 비활성화 검토.
- **State**: dev 루트는 GCS 원격 backend(`autoresearch-dev-tfstate`)를 사용한다. 비밀번호 평문 저장은 Terraform state의 근본 한계 → 버킷 IAM/UBLA 로 보호.
- 비밀번호 rotation: `random_password` 재생성(수동 `terraform -replace=random_password.db_app_password` 또는 keepers) → SQL user(`cloud_sql.tf`)와 Secret version(`secret_manager.tf`)에 동일 값 반영. 같은 소스라 parity 유지.
- 롤백: `terraform destroy`로 dev stack 제거. state는 GCS backend에 남으며, 비용 리소스(Cloud SQL/GKE/NAT) 삭제 여부를 반드시 확인한다.

## 필수 GCP API

아래 API는 현재 dev stack과 CI plan에 필요한 서비스입니다. 이 루트 모듈은 `google_project_service`로 API enable을 관리하지 않으므로, 새 프로젝트에 재구성할 때는 apply 전에 별도로 활성화합니다.

| API | 사용 예정 |
|---|---|
| `serviceusage.googleapis.com` | GCP API enable 관리 |
| `cloudresourcemanager.googleapis.com` | project metadata 조회 및 관리 |
| `compute.googleapis.com` | VPC/subnet, GKE 기반 네트워크 |
| `bigquery.googleapis.com` | dev 분석 dataset |
| `artifactregistry.googleapis.com` | Docker image repository |
| `sqladmin.googleapis.com` | Cloud SQL |
| `container.googleapis.com` | GKE |
| `iam.googleapis.com` | service account, IAM binding |
| `iamcredentials.googleapis.com` | GitHub OIDC 기반 credential 생성 |
| `sts.googleapis.com` | Workload Identity Federation token exchange |
| `secretmanager.googleapis.com` | secret 저장 및 참조 |
| `storage.googleapis.com` | 원본 데이터 GCS bucket |
| `logging.googleapis.com` | 운영 로그 |
| `monitoring.googleapis.com` | 모니터링 |

## 사전 조건 (apply 전)

이 모듈은 `google_project_service` 리소스로 GCP API를 enable하지 않습니다. API 활성화를 같은
root module에 넣으면 "API가 켜져야 생성 가능한 리소스"와 순환/부트스트랩 문제가 생기는
안티패턴이므로, API enable은 apply 전 별도 부트스트랩 단계로 분리한다.

`google_compute_network` / `google_compute_subnetwork` 생성은 `compute.googleapis.com` 활성화에
하드 의존하므로, 대상 프로젝트(`var.project_id`)에 최소 compute API가 먼저 켜져 있어야 apply가 성공한다.

```bash
# required_services output 전체를 한 번에 활성화
terraform -chdir=terraform/envs/dev output -json required_services \
  | jq -r '.[]' | xargs gcloud services enable --project=ar-infra-501607
```

> Private Google Access(`enable_private_google_access`, 기본 `true`) 사용 시,
> `restricted.googleapis.com`(`199.36.153.8/30`)로 가는 default-internet-gateway 라우트를
> 모듈이 자동 생성한다. `private.googleapis.com` 범위가 필요한 서비스가 생기면 라우트를 추가한다.

## 검증 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan -detailed-exitcode
git diff --check
```

`terraform init`은 provider plugin과 GCS backend 접근이 필요하므로 네트워크와 GCP 인증이 필요합니다. 순수 문법 검증만 할 때는 `terraform -chdir=terraform/envs/dev init -backend=false`를 사용할 수 있습니다.

## CI 자동 검증 (#6)

PR 이 열리면 GitHub Actions(`.github/workflows/terraform-plan.yml`)가 자동으로 `terraform fmt/validate/plan` 을 실행하고 결과를 PR 댓글로 게시한다.

- **인증**: SA key 없이 GitHub OIDC + Workload Identity Federation(WIF). CI SA(`terraform-ci`)는 현재 dev plan에 필요한 `roles/viewer`와 state bucket 접근 권한만 가진다. Secret payload를 읽는 data source는 사용하지 않는다.
- **state**: GCS 원격 backend(`autoresearch-dev-tfstate`). 부트스트랩 절차는 [docs/TERRAFORM_BOOTSTRAP.md](TERRAFORM_BOOTSTRAP.md) 참조.
- **제한**: WIF `attribute_condition` 으로 `SKYAHO/Autoresearch-infra` 저장소만 허용하고, workflow job guard로 fork PR이 아닌 내부 브랜치 PR에서만 plan을 실행한다.
- **apply 자동화는 범위 밖**(별도 이슈). 본 워크플로는 plan 만 게시한다.

필요 GitHub variables(4개, secret 아님): `GCP_PROJECT_ID`, `WIF_POOL_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`.
