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
│       ├── airflow.tf        # #32 Airflow namespace/RBAC + GCP SA/WI + DB/버킷
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
| Noncurrent 정리 | 30일 후 삭제 | prefix와 무관하게 archived(noncurrent) object version 정리 |
| 접근 주체 | GKE app SA | `roles/storage.objectCreator` + `roles/storage.objectViewer`, 삭제/overwrite 제외 |
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
- versioning은 원본 보호용이며, prefix 오타나 신규 데이터 유형 경로까지 포함해 모든 noncurrent version은 30일 후 삭제해 dev 비용 누적을 줄인다.
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

> `roles/bigquery.jobUser`는 query/load job 실행에 필요하지만 project-level job 실행 권한이다. dev app/배치는 쿼리 실행 시 `maximum_bytes_billed` 같은 job-level 비용 제한을 함께 설정해야 하며, infra 차원의 quota/reservation 가드는 #22에서 다룬다.

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
| 접근 주체 | GKE app SA | BigQuery dataset `dataEditor`, Feast GCS bucket `storage.objectAdmin` |

## dev proxy Cloud Run (#27)

| 항목 | 값 | 비고 |
|---|---|---|
| Service | `autoresearch-dev-proxy` | `${resource_prefix}-proxy` (`cloud_run.tf`) |
| Region | `asia-northeast3` | `var.region` |
| 이미지 | `asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:dev-20260708-001` | `var.proxy_image` 비어 있을 때 예시 기본값. 재배포 시 새 tag/digest로 변경. 소스: 앱 저장소 `proxy/Dockerfile` |
| 컨테이너 | 포트 `8080`, `uvicorn app:app` | 이슈 #27 전제 |
| 헬스체크 | startup/liveness probe `GET /health`:8080 | 실패 시 revision 비정상 처리 |
| 스케일링 | min **0** / max 1 | 유휴 비용 0. `var.proxy_max_instances` |
| 리소스 | 1 vCPU / 512Mi, `cpu_idle=true` | 요청 처리 중에만 CPU 과금 |
| 런타임 SA | `autoresearch-dev-proxy@...` | 전용 SA, **role 없음**(최소 권한). GCP 리소스 접근 필요 시 리소스 수준으로 추가 |
| 인증 | public access 없음, `roles/run.invoker`만 | `var.proxy_invoker_members` 기본 빈 목록 → collector SA 확정 시 추가 |
| ingress | `INGRESS_TRAFFIC_INTERNAL_ONLY` | collector가 같은 VPC(GKE)에서 호출 가정. VPC 밖 호출 확정 시 `INGRESS_TRAFFIC_ALL`로 변경(IAM 인증 유지) |
| deletion_protection | false (dev) | `var.proxy_deletion_protection` |

### 이미지 빌드/배포 (수동 — CI 자동화는 별도 이슈)

```bash
gcloud auth configure-docker asia-northeast3-docker.pkg.dev
docker build -t asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:dev-20260708-001 proxy/
docker push asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:dev-20260708-001
```

**순서 제약**: 이미지가 AR에 없으면 apply(revision 배포)가 실패한다. plan은 이미지
없이도 통과하므로 PR 머지는 가능하고, apply는 push 후에 한다. `run.googleapis.com`
API도 apply 전 수동 활성화가 필요하다.

**재배포 원칙**: 같은 `:latest` 태그를 다시 push해도 Terraform의 `image` 문자열은
변하지 않아 새 Cloud Run revision이 트리거되지 않는다. 새 proxy 이미지를 배포할 때는
`proxy_image`를 새 버전 태그(`proxy:dev-YYYYMMDD-N`) 또는 digest(`proxy@sha256:...`)로
바꾼 뒤 plan/apply한다.

### 호출 방법 (collector)

```bash
# invoker 권한이 있는 SA의 ID token으로 호출
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "$(terraform -chdir=terraform/envs/dev output -raw proxy_service_uri)/health"
```

### 비용/롤백

- min 0 + 일 수 회 호출 → 사실상 무과금. 콜드 스타트(수 초)는 dev에서 허용.
- 롤백: `cloud_run.tf` 리소스 제거 후 apply(또는 `-target` destroy). 상태ful 데이터 없음.

## dev GKE (#5)

| 항목 | 값 | 비고 |
|---|---|---|
| Cluster | `autoresearch-dev-gke` | Standard, zonal `asia-northeast3-a` |
| Endpoint | `34.64.97.177` | public endpoint + authorized networks |
| 모드 | private nodes, public endpoint(authorized) | 노드 공인 IP 없음, 마스터는 본인 IP만 |
| Master CIDR | `172.16.0.0/28` | 현재 dev apply 값. dev subnet/private services와 미중복 |
| Pods/Services 대역 | `172.16.64.0/20` / `172.16.128.0/24` | 서브넷 2차 대역, VPC-native(alias IP) |
| Control plane | GKE 관리형 | CPU/RAM 직접 지정 불가. Google이 control plane을 관리 |
| 노드풀 | `dev-default`, e2-standard-4, pd-standard 30GB | autoscaling min=1/max=2 |
| 노드 SA | `autoresearch-dev-gke-nodes@ar-infra-501607.iam.gserviceaccount.com` | AR reader + logging/metric writer |
| app SA(WI) | `autoresearch-dev-app@ar-infra-501607.iam.gserviceaccount.com` | cloudsql.client + secretAccessor, KSA 매핑 |
| WI principal | `ar-infra-501607.svc.id.goog[autoresearch/autoresearch-app]` | Terraform에서 GCP SA IAM binding까지 생성 |
| Egress | Cloud NAT(`autoresearch-dev-nat`) | private 노드 AR(`*.pkg.dev`) pull |
| deletion_protection | false (dev) | 운영 전환 시 true |

### kubectl 접근

팀원 로컬 접근은 #31에서 GCP IAM으로 `roles/container.clusterViewer`를 부여해
`gcloud container clusters get-credentials`를 실행할 수 있게 한다. 이 권한은 GKE
클러스터 조회/연결용이며, Kubernetes namespace 내부 작업 권한은 #32의 RBAC에서 별도로
정한다.

대상 Google 계정은 dev 루트가 아니라 `terraform/admin/gke-team-access`에서 별도 state로
관리한다. 실제 이메일은 해당 경로의 로컬 `terraform.tfvars`에만 기입하며(repo 노출 방지),
일반 PR Terraform plan에는 팀원 이메일과 사람 IAM 변경이 나오지 않게 분리한다.

관리자 적용 절차:

```bash
cd terraform/admin/gke-team-access
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 팀원 Google 계정 입력(repo에 커밋 금지)

terraform init
terraform plan
terraform apply
```

```bash
gcloud auth login
gcloud config set project ar-infra-501607
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a \
  --project ar-infra-501607

kubectl config current-context
kubectl get ns
```

접근이 실패하면 아래를 순서대로 확인한다.

- **IAM 오류**: `roles/container.clusterViewer`가 해당 Google 계정에 부여되어 있는지 확인한다.
- **네트워크 오류/timeout**: 현재 클러스터는 public endpoint에
  `master_authorized_networks`를 적용한다. 팀원 공인 IP가 허용 목록에 없으면 API server
  연결이 실패할 수 있다. 단기적으로는 IP를 추가하고, 중기 접근 경로는 #33(Bastion/VPN)
  에서 정한다.
- **Kubernetes RBAC 오류**: kubeconfig를 받았더라도 namespace 안에서 Helm install/update를
  하려면 Kubernetes RBAC가 필요하다. `airflow` namespace 작업 권한은 #32에서 별도로
  구성한다.
- **잘못된 context**: `kubectl config current-context`가
  `gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke` 계열인지 확인한다.

**Off-boarding**: `terraform/admin/gke-team-access/terraform.tfvars`의
`team_member_emails`에서 이메일을 제거하고 apply하면 `google_project_iam_member`가 해당
member만 제거된다(non-authoritative). 단, 이미 발급받은 access token은 만료(최대 ~1시간)까지
유효하므로 **즉시 차단이 아니다**. 긴급 차단이 필요하면 해당 Google 계정의 GCP 세션을 별도로
종료해야 한다. kubeconfig 자체는 로컬에 남지만 다음 인증 시 403.

기존 dev state에 `google_project_iam_member.gke_kubectl_users[...]`가 남아 있으면
실제 IAM을 destroy하지 않는다. 이 리소스는 `terraform/admin/gke-team-access`가
소유하므로 dev root에서는 `terraform state rm`으로 state에서만 분리한다.

dev 내부망 접근 전략(Bastion/VPN 비교, Cloud SQL private IP / 내부 서비스 접근
경로)은 [docs/ACCESS_STRATEGY.md](ACCESS_STRATEGY.md)를 참조한다.

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
- 예상: e2-standard-4 워커 노드는 asia-northeast3 on-demand 기준 대략
  $95~100/월/노드 수준(할인, 환율, 가격 변경 제외) + disk + Cloud NAT 고정비.
  `gke_node_count_min = 1`이라 미사용 시에도 최소 1노드는 상시 과금된다.
  Standard control plane은 직접 과금/사양 지정 대상이 아니다. 정확한 비용은
  apply 전 Google Cloud Pricing Calculator로 확인한다.
- 절감: min=1 고정. 장기 미사용 시 노드풀 count 0 또는 `terraform destroy` 권장(NAT 고정비는 노드 0화로 노드 비용만 절감, NAT 자체는 남음).
- 변경 영향: Terraform plan은 node pool 리소스 `0 destroy` / `1 change`
  in-place로 표시되지만, GKE는 실제 노드 VM을 새 machine type으로 교체/재생성할
  수 있다. 단일 노드풀(min=1)만 있는 상태에서는 Pod가 evict 후 재스케줄되거나
  일시적으로 Pending/Unavailable이 될 수 있으므로 Airflow 등 워크로드가 올라간
  뒤에는 작업 시간을 조율한다.
- **Cloud Operations**(GKE 기본 On): Logging/Monitoring 비용 발생 가능. 비용 민감 시 클러스터 `logging_service`/`monitoring_service` 비활성화 검토.
- **State**: dev 루트는 GCS 원격 backend(`autoresearch-dev-tfstate`)를 사용한다. 비밀번호 평문 저장은 Terraform state의 근본 한계 → 버킷 IAM/UBLA 로 보호.
- 비밀번호 rotation: `random_password` 재생성(수동 `terraform -replace=random_password.db_app_password` 또는 keepers) → SQL user(`cloud_sql.tf`)와 Secret version(`secret_manager.tf`)에 동일 값 반영. 같은 소스라 parity 유지.
- 롤백: `terraform destroy`로 dev stack 제거. state는 GCS backend에 남으며, 비용 리소스(Cloud SQL/GKE/NAT) 삭제 여부를 반드시 확인한다.

## dev Airflow (#32)

Airflow 구성요소가 배포되는 GKE namespace 경계와, 거기에 물릴 GCP 권한(Cloud SQL / GCS / BigQuery)을 IaC로 관리한다. Airflow Helm chart values, executor, fernet key 등 앱 설정은 이 저장소 범위 밖(앱 저장소 `SKYAHO/Autoresearch`)이다.

Airflow는 두 Terraform root로 나눈다.

- `terraform/envs/dev`: GCP 리소스만 관리한다. GCP SA, Workload Identity IAM member, Cloud SQL database, GCS bucket/IAM, BigQuery IAM이 여기 있다.
- `terraform/admin/airflow-k8s`: Kubernetes namespace/RBAC/ResourceQuota/LimitRange/NetworkPolicy만 관리한다. GKE API 서버가 `master_authorized_networks`로 제한되어 있어, GitHub Actions PR plan이 이 root를 실행하지 않는다. apply는 허용된 관리자 네트워크에서 수행한다.

| 항목 | 값 | 비고 |
|---|---|---|
| Namespace | `airflow` | `var.airflow_k8s_namespace`. GKE 클러스터 내 신규 namespace |
| KSA | `airflow` | `var.airflow_k8s_service_account`. `iam.gke.io/gcp-service-account` annotation으로 GCP SA 매핑 |
| GCP SA | `autoresearch-dev-airflow` | `${resource_prefix}-airflow`. WI 전용, JSON 키 미발급 |
| WI principal | `ar-infra-501607.svc.id.goog[airflow/airflow]` | KSA annotation으로 사용 |
| RBAC(Role) | `airflow-components` (namespace-scoped) | pods/configmaps/secrets/services, apps, batch 전 동사. KSA에 바인딩 |
| 설치자 RBAC | `installer-admin`(for_each) | `terraform/admin/airflow-k8s/terraform.tfvars`의 `installer_user_emails` 팀원에게 namespace 내 `admin` ClusterRole 바인딩. Helm 설치 경로 |
| ResourceQuota | cpu 4 / mem 8Gi / pods 20 / pvc 4 | namespace 자원 한도 |
| LimitRange | default 500m/512Mi, request 250m/256Mi | Container 기본 request/limit |
| NetworkPolicy(ingress) | 같은 namespace + kube-system만 | deny-by-default |
| NetworkPolicy(egress) | DNS(53), Cloud SQL(private_services_cidr 5432), GKE metadata server(169.254.169.254:80), HTTPS(443) | WI 토큰 교환은 metadata server HTTP 80 필요. 외부 API/googleapis 호출은 443로 |
| Cloud SQL DB | `airflow` | 기존 dev 인스턴스 내 신규 database(metadata DB) |
| Secret Manager | `autoresearch-dev-youtube-api-key`, `autoresearch-dev-openrouter-api-key` | secret payload는 Terraform 밖에서 주입. secret metadata와 Airflow SA accessor만 Terraform 관리 |
| GCS buckets | `ar-infra-501607-autoresearch-dev-airflow-dags`, `...-airflow-logs` | DAG 버전관리 / task log 영속화. `prevent_destroy=true` |
| 접근 권한 | Cloud SQL client, Secret Manager accessor(Airflow API secrets), BigQuery jobUser(project), GCS objectAdmin(dags/logs/feast_registry/feast_staging), GCS objectViewer+objectCreator(raw_data), BigQuery dataEditor(feast_offline_store) | raw_data는 읽기+새 객체 생성만 허용해 기존 원본 삭제/덮어쓰기를 차단 |

### 설치 담당자 Helm 적용 경로

`terraform/admin/airflow-k8s`의 `installer-admin` RoleBinding이 팀원에게 `airflow` namespace 내 `admin` 권한을 준다. 이 root는 GKE API 서버에 접근 가능한 관리자 네트워크에서만 apply한다. 절차:

```bash
# 1) 본인 IP가 master_authorized_networks에 포함되어 있고 roles/container.clusterViewer가 있는지 확인
# 2) credentials 획득
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a --project ar-infra-501607
# 3) K8s 경계 root 적용(관리자만)
cd terraform/admin/airflow-k8s
terraform init
terraform apply
# 4) namespace 확인
kubectl -n airflow get all
# 5) Helm으로 Airflow 설치(values/executor는 앱 저장소에서 관리)
helm install airflow airflow/airflow -n airflow -f values.yaml
```

KSA(`airflow`)와 WI 매핑은 Terraform이 생성하므로 Helm values에서 별도 ServiceAccount 생성은 끄고, 위 KSA를 `existingServiceAccountName`로 지정한다.

### 비용/롤백

- namespace/RBAC/NetworkPolicy 자체는 비용 발생 안 함. GCS 버킷 2개(DAG/log)는 객체 크기에 따라 과금.
- `prevent_destroy=true`: dev 전체 destroy에서도 버킷 삭제 차단. 삭제 필요 시 lifecycle 해제 후 별도 apply.
- Cloud SQL database `airflow`는 기존 인스턴스 비용에 포함(db-f1-micro 공유).
- 롤백: `terraform/envs/dev/airflow.tf`의 GCP 리소스와 `terraform/admin/airflow-k8s`의 K8s 리소스를 각각 제거 후 apply. 단 GCS 버킷은 prevent_destroy로 보호됨.

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
| `run.googleapis.com` | dev proxy Cloud Run 서비스 |
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

## State drift cleanup 기록 (#39)

#39에서 dev state에만 남아 있던 Cloud Build 기본 compute SA 권한, legacy
`airflow-dev` node pool, legacy Airflow batch Workload Identity binding, 추가
GKE master authorized network CIDR을 정리했다. 판단 기준과 롤백 경로는
`docs/superpowers/specs/2026-07-08-dev-state-drift-cleanup-design.md`와
`docs/superpowers/plans/2026-07-08-dev-state-drift-cleanup.md`를 따른다.

이 저장소에서는 drift를 숨기기 위해 state만 제거하지 않는다. 유지 근거가 없는 IAM
grant, node pool, network allowlist는 실제 GCP 리소스까지 정리하거나, 유지 대상이면
Terraform configuration으로 복원한다.
