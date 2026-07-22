# Terraform Dev 환경

이 문서는 Terraform dev 환경(`#1`~`#6`)의 현재 구성과 운영 방법을 팀원이 빠르게 이해하도록 정리합니다.

## 현재 상태

- GCP 프로젝트: `ar-infra-501607`
- dev root module: `terraform/envs/dev`
- Terraform backend: GCS `autoresearch-dev-tfstate`, prefix `dev/`
- 마지막 실제 apply: 2026-07-08, #46(GKE DNS 엔드포인트)·#50(bastion)·#51(Airflow ILB + private DNS)·#55(OAuth secrets) merge 및 apply 완료
- 최신 검증: 2026-07-08, 위 apply 이후 `terraform/envs/dev`와 `terraform/admin/airflow-k8s` 모두 최종 plan `No changes`
- 2026-07-15: `terraform/admin/autoresearch-k8s`(app namespace/KSA/NetworkPolicy) apply 완료. #203 Feast ↔ Redis Cluster GKE 실연결 검증(dry-run·CLUSTER SHARDS·materialize·온라인 조회) 전 판정 통과.
- 검증에서 발견한 feast SA IAM 누락(`storage.buckets.get`·`bigquery.readsessions.create`) 보강은 #204로 진행 중이며 apply 대기다.

## 구조

```text
terraform/
├── README.md
├── admin/
│   ├── autoresearch-k8s/ # #129 앱 namespace/KSA/Redis Cluster PSC egress NetworkPolicy (separate state)
│   ├── airflow-k8s/      # #32 Airflow Kubernetes namespace/RBAC/NetworkPolicy (separate state)
│   ├── gke-team-access/  # #34/#46 팀원 GKE container.viewer + bastion 접속 IAM (separate state)
│   ├── monitoring-k8s/   # #78 Prometheus/Grafana monitoring namespace + Helm values (separate state)
│   ├── argocd-k8s/       # #83/#84 ArgoCD namespace + Helm release (separate state)
│   ├── mlflow-k8s/       # #94 MLflow namespace/KSA(WI)/NetworkPolicy (separate state)
│   ├── argo-rollouts-k8s/ # #88 Argo Rollouts controller (separate state)
│   ├── elastic-k8s/      # #97 ECK operator + (후속) ES/Kibana (separate state)
│   └── vault-k8s/        # #134 Vault namespace + Helm release + KMS auto-unseal (separate state)
├── bootstrap/            # #6 1회성: GCS state bucket + WIF + CI SA (local state)
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── versions.tf
├── envs/
│   └── dev/
│       ├── README.md
│       ├── artifact_registry.tf
│       ├── bastion.tf        # #47 IAP 전용 bastion host
│       ├── bigquery.tf       # #20 dev analytics/Feast offline dataset
│       ├── cloud_sql.tf      # #4 dev Cloud SQL (PostgreSQL, private IP)
│       ├── redis.tf          # #129 Feast Online Store 2-shard Redis Cluster (PSC, IAM auth/TLS)
│       ├── cloud_build.tf    # #32 Cloud Build IAM, #269 전용 build SA
│       ├── code_artifacts.tf # #238 코드 아카이브 GCS 버킷 + 업로더 SA/WIF + 파드 read IAM
│       ├── cloud_run.tf      # #27 Cloud Run proxy state/code 정합성
│       ├── dns.tf            # #48 Airflow·#244 MLflow ILB 예약 내부 IP + private DNS zone
│       ├── gke.tf            # #5 dev GKE cluster + 노드풀 + SA/WI
│       ├── github_actions.tf # #121/#157 배포 리포 GitHub Actions WIF → GAR push SA/IAM
│       ├── airflow.tf        # #32 Airflow GCP SA/WI + DB/GCS/IAM
│       ├── locals.tf
│       ├── mlflow.tf         # #91/#92 MLflow artifact GCS bucket + 전용 GSA/WI/IAM
│       ├── nat.tf            # #5 Cloud Router + Cloud NAT (private 노드 egress)
│       ├── outputs.tf
│       ├── secret_manager.tf # #5 DB 비밀번호 Secret Manager 저장
│       ├── storage.tf        # #18 dev 원본 데이터/Feast GCS bucket
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       ├── vault.tf          # #132 Vault auto-unseal용 KMS key + GSA/WI
│       ├── versions.tf
│       ├── vertex_ai.tf      # #280 BigQuery ↔ Vertex AI connection + aiplatform IAM
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
| IAM | GKE node SA에 reader, Cloud Build와 배포 리포별 pusher SA에 repository 단위 writer | app 이미지 pull 및 Autoresearch/Autoresearch-airflow 이미지 push용 |

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
| Tier | `db-g1-small` | `var.db_tier`, shared-core 1.7GiB 기본 구성 (인스턴스 비용 월 약 $26, 스토리지·백업·네트워크 별도) |
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

### Tier 변경 운영 절차 (#273)

`db-g1-small` 적용은 Cloud SQL 인스턴스 재시작을 유발하므로 배치 작업이 없는
시간에 수행한다. 적용 전 자동 백업과 PITR 상태를 확인하고, 적용 후에는 인스턴스
상태, 애플리케이션 DB 연결, CPU·메모리 지표, Airflow 수동 DAG run 1회를 확인한다.
비공개 `terraform.tfvars`에서 `db_tier`를 명시한 환경은 기본값 대신 그 값이
사용되므로, plan/apply 전에 해당 값을 `db-g1-small`으로 갱신한다. 이 파일은
커밋하지 않는다. 롤백이 필요하면 `db_tier`를 이전 값으로 되돌려 별도
`terraform apply`를 수행하며, 이 경우에도 다시 재시작이 발생한다.

**MLflow 전용 DB/user (#93)**: 같은 인스턴스에 MLflow 전용 `google_sql_database`(`mlflow`) + `google_sql_user`(`mlflow`)를 추가해 Airflow/앱과 **논리 분리**한다(8회차 "DB 외부화"). 비밀번호는 전용 `random_password` → Secret Manager `autoresearch-dev-mlflow-db-password`에 저장, MLflow GSA(`autoresearch-dev-mlflow`)에만 resource-level `secretAccessor`. MLflow 서버는 `cloudsql.client`로 private IP 접속(신규 인스턴스 없음).

## Feast Online Store Redis Cluster (#129, apply·GKE 검증 완료)

Feast Online Store는 GCP Memorystore for Redis Cluster로 구성한다. dev 학습
환경에서 primary shard 두 개에 keyspace를 분산하여 hash slot, hash tag와
multi-key command 제약을 실제로 검증한다.

| 항목 | 값 | 비고 |
|---|---|---|
| Cluster | `autoresearch-dev-redis-cluster` | `${resource_prefix}-redis-cluster` |
| Region | `asia-northeast3` | Redis Cluster 지원 서울 리전 |
| Node type | `REDIS_SHARED_CORE_NANO` | node당 총 1.4 GB, writable 1.12 GB, SLA 없음 |
| Shape | primary shard 2 × replica 0 | 총 2 data node, cluster usage unit 2, HA 없음 |
| Zone distribution | `SINGLE_ZONE` (`asia-northeast3-a`) | zonal GKE와 같은 zone, zone 장애 시 cluster 전체 영향 |
| Redis version | 서비스 관리 Redis 7.x | provider에서 버전을 고정하지 않음 |
| Persistence | disabled | 장애/flush 후 Feast 재-materialize 필요 |
| Network | 기존 dev VPC + 전용 PSC `/29` | `10.10.16.0/29`, public endpoint 없음 |
| 인증 | IAM auth | app GSA의 단기 access token, 정적 token 저장 안 함 |
| 전송 암호화 | server authentication TLS | per-instance CA bundle만 Secret Manager 저장 |
| deletion protection | `false` | dev 기본, 삭제 전 별도 plan/승인 필요 |

### PSC와 NetworkPolicy

`autoresearch-dev-redis-psc` subnet과 같은 이름의 Service Connection Policy를
서울 리전에 만들고 service class `gcp-memorystore-redis`, connection limit 2를
사용한다. Cloud SQL의 PSA `192.168.0.0/20`과 Redis PSC `10.10.16.0/29`는 목적과
state address가 다른 별도 네트워크다.

Redis Cluster client는 discovery endpoint TCP 6379로 topology를 조회한 뒤 PSC
subnet의 data node TCP 11000-13047로 직접 연결한다. 따라서
`terraform/admin/autoresearch-k8s` NetworkPolicy는 다음을 별도 egress rule로
허용한다.

- Cloud SQL PSA CIDR: TCP 5432
- Redis Cluster PSC CIDR: TCP 6379, TCP 11000-13047

관련 output은 `redis_cluster_name`, `redis_discovery_address`,
`redis_discovery_port`, `redis_psc_subnet_cidr`, `redis_server_ca_secret_id`다.

### 인증과 애플리케이션 연계

app GSA에는 `roles/redis.dbConnectionUser`를 부여하되 IAM condition의
`resource.name`을 dev Redis Cluster full resource name으로 제한한다. pod는
Workload Identity로 IAM access token을 런타임 발급하고 Redis `AUTH`에 사용한다.
token은 Terraform state, Secret Manager, output, 로그에 저장하지 않는다.

TLS CA bundle은 `autoresearch-dev-redis-server-ca` Secret Manager secret에
저장하고 app GSA에 해당 secret의 `roles/secretmanager.secretAccessor`만 부여한다.
CA payload는 Terraform state에 포함되므로 GCS backend IAM을 최소화한다.

`SKYAHO/Autoresearch` 후속 작업은 다음을 구현해야 한다.

- topology refresh와 `MOVED`를 처리하는 cluster-aware Redis client
- Workload Identity IAM token 자동 재발급과 새 connection 재인증
- TLS CA 주입 및 server certificate 검증
- 함께 `MGET`할 Feature key가 같은 `{entity-id}` hash tag를 공유하는 key schema
- 모든 key를 하나의 tag로 몰아 shard hot spot을 만들지 않는 분산 검증

### 적용 및 검증 순서

1. `redis.googleapis.com`, `networkconnectivity.googleapis.com`,
   `serviceconsumermanagement.googleapis.com`을 수동 활성화한다.
2. Redis Cluster regional usage unit quota가 2 이상인지 확인한다.
3. dev root plan에서 PSC subnet/policy, Redis Cluster, 조건부 IAM, CA secret의
   add/change/delete/replace를 확인한다.
4. 사용자 승인 후 dev root를 apply한다.
5. live `autoresearch` namespace/KSA가 이미 있으면 admin state로 import한다.
6. admin root plan에서 Redis PSC 포트와 기존 egress 영향을 확인하고 별도 승인 후
   apply한다.
7. GKE 내부 검증 pod에서 IAM token과 CA로 `PING`, `CLUSTER SHARDS`를 확인한다.
8. 아래 key를 생성해 `CLUSTER KEYSLOT` 결과와 `MGET`을 확인한다.

```text
feature:{user:100}:age
feature:{user:100}:watch_time
feature:{user:200}:age
```

앞의 두 key는 같은 slot이어야 하고 단일 `MGET`이 성공해야 한다. `{user:100}`과
`{user:200}`이 실제로 다른 slot이면 둘을 한 `MGET`으로 요청할 때 `CROSSSLOT`이
발생해야 한다. 상세 명령은 `terraform/admin/autoresearch-k8s/README.md`를 따른다.

### 장애 복구와 롤백

single zone, replica 0, persistence disabled 구성은 선택한 zone이나 node 장애 후
Online Store 가용성과 데이터를 보장하지 않는다. 복구 시 write/read 트래픽을
중지하고 두 primary shard의 ready 상태를 확인한 뒤 앱 저장소에서 offline store 기준
`feast materialize <START_TIMESTAMP> <END_TIMESTAMP>`를 실행한다. 대표 entity의
online feature 조회와 동일 tag `MGET`을 검증한 후 트래픽을 재개한다.

인프라 롤백은 앱의 Redis 사용을 먼저 중지하고 NetworkPolicy 규칙 제거 plan과
Redis Cluster/PSC 제거 plan을 따로 검토한다. 실제 삭제와 state 조작은 별도 사용자
승인 후에만 수행한다.

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
| YouTube KR trending 원본 | `data_lake/youtube_trending_kr/` | `data_lake/youtube_trending_kr/dt=2026-07-07/part-0.parquet` |
| 가상 유저 | `asset/virtual_user/` | `asset/virtual_user/vu_1000.parquet` |
| 액션 로그 원본 | `data_lake/action_log/` | `data_lake/action_log/dt=2026-07-07/part-0.parquet` |
| 액션 로그 격리 | `data_lake/action_log_quarantine/` | `data_lake/action_log_quarantine/dt=2026-07-07/quarantine.jsonl` |
| 페르소나 원본 스냅샷 | `data/raw/personas/` | `data/raw/personas/nvidia_personas_kr.jsonl` |

이 prefix들은 `locals.raw_data_prefixes`와 `output.raw_data_prefixes`로도 노출된다.
IAM 조건은 아니며, 앱 DAG와 운영 문서가 같은 경로를 보도록 맞춘 문서/출력용
표준이다. 기존 output 소비자가 깨지지 않도록 `youtube_raw`, `users_raw`,
`action_logs_raw`, `personas_raw` key는 같은 값의 호환 alias로 유지한다.

페르소나 원본 스냅샷은 현재 Airflow DAG가 직접 GCS에 쓰는 경로가 아니라,
앱 저장소 virtual user 생성 설정의 기본 raw snapshot 경로
(`data/raw/personas/nvidia_personas_kr.jsonl`)를 기준으로 둔 GCS 적재 표준이다.

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
| Feast offline store | `feast_offline_store` | Feast feature table 전용 dataset (#285에서 raw 분리) |
| Data lake raw | `data_lake_raw` | GCS 원천 적재(raw) 테이블 전용 dataset (#285) |
| Location | `asia-northeast3` | `var.bigquery_location`, GCS raw bucket과 동일 리전 |
| 용도 | 구조화 분석 데이터 | GCS raw에서 적재/정제된 테이블 저장 |
| Destroy 보호 | `prevent_destroy=true` | 분석 테이블 유실 방지 |
| delete_contents_on_destroy | false | table/view가 있으면 dataset 삭제 실패 |
| GKE app SA 권한 | dataset `dataEditor` + project `jobUser` | app/배치가 load/query job 실행 가능 |

> `roles/bigquery.jobUser`는 query/load job 실행에 필요하지만 project-level job 실행 권한이다. dev app/배치는 쿼리 실행 시 `maximum_bytes_billed` 같은 job-level 비용 제한을 함께 설정해야 한다. infra 차원의 quota/reservation 가드는 #22에서 조사했으나 dev 규모상 적용하지 않기로 결정하고 close했다(필요 시 앱 레벨 `maximum_bytes_billed` 권장).

### GCS와 BigQuery 역할

| 데이터 | 원본 보관 | 분석/조회 |
|---|---|---|
| YouTube KR trending 원본 | GCS `data_lake/youtube_trending_kr/` | BigQuery `dt` 일 단위 partitioned table로 정제 적재 (#199) |
| 가상 유저 | GCS `asset/virtual_user/` | feature/user dimension 후보 |
| 액션 로그 원본 | GCS `data_lake/action_log/` | BigQuery `dt` 일 단위 partitioned table (#199) |
| 액션 로그 격리 | GCS `data_lake/action_log_quarantine/` | 품질 점검·재처리 후보 |
| 페르소나 원본 스냅샷 | GCS `data/raw/personas/` | BigQuery dimension/reference table 후보 |

GCS는 원본 파일 보존, BigQuery는 SQL 분석과 downstream feature 생성을 담당한다.

### raw / feature layer 분리 (#285)

BigQuery dataset을 계층별로 나눈다. 이름과 내용이 어긋나지 않게 하고, dataset
단위 IAM·비용·수명주기 정책을 계층별로 다르게 걸기 위해서다.

| Dataset | 계층 | 테이블 |
| --- | --- | --- |
| `data_lake_raw` | raw | `data_lake_action_log`, `data_lake_youtube_trending_kr` |
| `feast_offline_store` | feature | `user_static_feature`, `user_dynamic_feature`, `video_feature`, `user_category_similarity` |
| `autoresearch_dev_analytics` | analytics | 분석/집계 테이블 |

dataset 이전으로 접근 주체가 권한을 잃지 않도록, `feast_offline_store`가 가진
dataset 레벨 IAM 주체를 `data_lake_raw`에 **그대로 복제**한다.

| 주체 | 역할 | 정의 위치 |
| --- | --- | --- |
| GKE app SA | `roles/bigquery.dataEditor` | `bigquery.tf` |
| Airflow SA | `roles/bigquery.dataEditor` | `airflow.tf` |
| Airflow batch SA | `roles/bigquery.dataEditor` | `airflow.tf` |
| 팀원 계정 | `roles/bigquery.dataEditor` | `terraform/admin/gke-team-access` (**별도 state, 별도 apply**) |

연동 저장소는 dataset 이름을 환경변수/Airflow Variable로 참조하므로 cutover 시
아래 값을 함께 바꾼다. `FEAST_BQ_DATASET`(feast materialize)는 피처 테이블만
읽으므로 `feast_offline_store` 그대로 둔다.

| 저장소 | 설정 | 변경 후 |
| --- | --- | --- |
| `SKYAHO/Autoresearch-airflow` | Airflow Variable `LAKE_TO_BQ_DATASET` | `data_lake_raw` |
| `SKYAHO/Autoresearch` | `BQ_DATASET` (`scripts/load_raw_to_bigquery.py`) | `data_lake_raw` |
| `SKYAHO/Autoresearch` | `CTR_TRAINING_BQ_DATASET` (raw 테이블 참조분) | `data_lake_raw` |

### raw/feature layer 분리 state 재조정 (#285)

`data_lake_raw` dataset과 하위 raw 테이블 2종은 **운영자가 `bq`로 이미 생성·복사해
둔 실물**이다. Terraform이 이를 신규 생성하려 하면 `Already Exists`로 실패하고,
구 주소는 `deletion_protection = true`라 destroy 시도 자체가 실패한다. 따라서
apply 전에 반드시 아래 state 재조정을 먼저 수행한다.

```bash
cd terraform/envs/dev
terraform init

# 1. 신규 dataset을 state에 편입
terraform import google_bigquery_dataset.data_lake_raw \
  projects/ar-infra-501607/datasets/data_lake_raw

# 2. 이전된 raw 테이블 2종을 새 주소로 편입
terraform import google_bigquery_table.data_lake_action_log \
  projects/ar-infra-501607/datasets/data_lake_raw/tables/data_lake_action_log
terraform import google_bigquery_table.data_lake_youtube_trending_kr \
  projects/ar-infra-501607/datasets/data_lake_raw/tables/data_lake_youtube_trending_kr
```

> `terraform import`는 리소스 주소가 이미 state에 있으면 실패한다. 위 2번은
> 같은 주소(`google_bigquery_table.data_lake_action_log`)가 구 dataset을 가리킨
> 채 state에 남아 있으므로, **아래 `state rm`을 먼저 실행한 뒤 import**한다.

```bash
# 0. (2번보다 먼저) 구 주소를 state에서만 분리 — 실제 테이블은 그대로 남는다
terraform state rm google_bigquery_table.data_lake_action_log
terraform state rm google_bigquery_table.data_lake_youtube_trending_kr
```

정리하면 실행 순서는 **`state rm` 2건 → `import` 3건**이다.

- `state rm`은 state에서만 분리하며 GCP 리소스를 삭제하지 않는다.
- `deletion_protection = true`이므로 `state rm` 없이 apply하면 구 테이블 destroy
  시도가 오류로 중단된다. 반드시 선행한다.
- **물리 구 테이블(`feast_offline_store.data_lake_*`) 삭제는 Terraform이 하지
  않는다.** cutover 확인 후 운영자가 수동 `bq rm`으로 수행한다.

재조정 후 검증 기준:

```bash
terraform plan
```

- raw 테이블 2종에 `create`/`destroy`가 **나오면 안 된다** (no-op이어야 한다).
- 허용되는 diff는 `google_bigquery_dataset_iam_member` 추가분뿐이다
  (`data_lake_raw`의 gke_app / airflow / airflow_batch dataEditor 3건).
  dataset 자체가 `labels`/`friendly_name` 차이로 in-place update로 잡히면 정의와
  실물을 대조한 뒤 진행한다.
- 팀원 dataEditor는 별도 root에서 적용한다.

```bash
cd terraform/admin/gke-team-access
terraform init && terraform plan   # team_bigquery_data_lake_raw_data_editors 추가분만
```

롤백은 `dataset_id`를 `feast_offline_store`로 되돌린 뒤 같은 방식으로 state를
재조정하면 된다. 구 테이블을 물리적으로 삭제하기 전까지 원본 데이터가 남아 있어
되돌리기가 가능하므로, `bq rm`은 cutover 검증이 끝난 뒤에만 수행한다.

### data lake 테이블 dt 파티션 (#199)

`data_lake_raw` dataset(#285 이전에는 `feast_offline_store`)의
`data_lake_action_log`, `data_lake_youtube_trending_kr`는 Terraform이 존재와
`dt` 일 단위 파티셔닝을 보장한다 (`google_bigquery_table`,
`deletion_protection = true`).

| 소유권 | 주체 | 내용 |
| --- | --- | --- |
| 구조 | 이 저장소 (Terraform) | 테이블 존재, `time_partitioning(DAY, dt)`, labels |
| 스키마/데이터 | `SKYAHO/Autoresearch` | `scripts/load_raw_to_bigquery.py`가 autodetect + WRITE_TRUNCATE로 관리, Terraform은 `ignore_changes = [schema]` |

파티셔닝 변경은 테이블 교체를 유발하므로 `deletion_protection` 해제와 재적재
계획 없이는 수행하지 않는다.

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

### Feast 피처 테이블 스키마 소유권 (#280)

`data_lake_*` 테이블과 달리, 아래 4개 Feast 피처 테이블은 **스키마를 Terraform이
소유**한다. Feast `FeatureView`(`SKYAHO/Autoresearch`
`feature_repo/feature_definitions.py`)가 컬럼명·타입·mode를 계약으로 선언하고
있어, 계약 위반을 `terraform plan` 단계에서 잡기 위해서다.

| 테이블 | 파티셔닝 | Feast FeatureView |
| --- | --- | --- |
| `user_static_feature` | 없음 | `UserStaticView` |
| `user_dynamic_feature` | `event_timestamp` DAY | `UserDynamicView` |
| `video_feature` | `event_timestamp` DAY | `VideoFeatureView` |
| `user_category_similarity` | 없음 | `UserCategorySimilarityView` |

`user_static_feature`와 `user_category_similarity`는 `event_timestamp`가
`1970-01-01` 고정값(정적 피처가 모든 action log보다 먼저 유효하다는 규약)이라
파티셔닝하지 않는다.

| 소유권 | 주체 | 내용 |
| --- | --- | --- |
| 구조 + 스키마 | 이 저장소 (Terraform) | 테이블 존재, 컬럼·타입·mode, 파티셔닝, labels |
| 데이터 | `SKYAHO/Autoresearch` | `autoresearch.jobs.feature_store_build`가 `createDisposition=CREATE_NEVER`로 적재 |

> **주의 — 적재는 `WRITE_TRUNCATE`가 아니라 `TRUNCATE` + `INSERT INTO`를 쓴다.**
> `WRITE_TRUNCATE`는 대상 테이블의 스키마까지 결과 스키마로 덮어쓴다
> (`CREATE_NEVER`는 테이블 신규 생성만 막는다). 2026-07-21 실측에서 `REQUIRED`
> 컬럼이 `NULLABLE`로 파괴되는 것을 확인했다. 그대로 두면 job ↔ Terraform 간 영구
> drift가 발생한다.

적재 job은 아래 형태로 결과를 저장한다. DML은 대상 테이블 스키마를 변경하지 않아
Terraform 소유 스키마가 보호되고, `REQUIRED` 컬럼에 NULL이 들어오면 BigQuery가
거부해 불량 데이터도 차단된다. `TRUNCATE`와 `INSERT` 사이에 Feast가 빈 테이블을
읽지 않도록 트랜잭션으로 묶는다.

```sql
BEGIN TRANSACTION;
TRUNCATE TABLE `<project>.feast_offline_store.<table>`;
INSERT INTO `<project>.feast_offline_store.<table>`
<SELECT ...>;
COMMIT TRANSACTION;
```

아래 3개는 임베딩 모델·차원 변경 시 스키마가 따라 바뀌고 Feast가 직접 읽지
않으므로 Terraform 관리에서 제외한다. 배치 job이 `CREATE OR REPLACE`로 관리한다:
`user_topic_embedding`, `category_embedding`, `training_entity`.

### BigQuery ↔ Vertex AI connection (#280)

한국어 페르소나 키워드와 카테고리 설명문 간 코사인 유사도
(`user_category_similarity.topic_similarity`) 계산에 다국어 임베딩이 필요하다.
BigQuery ML `ML.GENERATE_EMBEDDING`이 Vertex AI를 호출하는 경로를 `vertex_ai.tf`가
관리한다.

| 항목 | 값 | 비고 |
| --- | --- | --- |
| Connection | `autoresearch-dev-vertex-ai` | `CLOUD_RESOURCE` 타입 |
| Location | `asia-northeast3` | `var.bigquery_location`. `feast_offline_store` dataset과 **반드시 동일**해야 remote model이 동작한다 |
| Connection service agent | 자동 생성 | `roles/aiplatform.user` (project) |
| Airflow SA / Airflow batch SA | 기존 GSA | `roles/aiplatform.user` 추가 (BigQuery 권한은 `airflow.tf`에 기존 보유) |
| 필요 API | `aiplatform.googleapis.com`, `bigqueryconnection.googleapis.com` | `local.required_services`에 기록 |

remote model(`CREATE MODEL ... REMOTE WITH CONNECTION`)은 배치 job이 멱등하게
생성한다. 이 저장소 범위는 connection과 IAM까지다. 배치가 참조할 값은
`vertex_ai_connection_id` output으로 노출한다.

**사용 모델은 `text-multilingual-embedding-002`다** (#280). connection은 모델명을
담지 않으므로 모델 교체 시 Terraform 변경은 필요 없고, 배치 job의 `ENDPOINT` 값만
바꾸면 된다. 신형 `gemini-embedding-001`도 서울 리전에서 동작하지만 요청당 1건만
허용해(다건 요청 시 429) 순차 약 100건/분에 그치므로 채택하지 않았다.

## Monitoring Kubernetes root (#78/#79, #183 ArgoCD 이관)

Prometheus/Grafana는 dev GCP root가 아니라 `terraform/admin/monitoring-k8s`에서
별도 state로 관리한다. **#183 이후 `kube-prometheus-stack` chart는 ArgoCD
Application `deploy/monitoring`이 관리**하고, 이 root는 `monitoring` namespace와
port-forward RBAC 경계만 남긴다(chart/version/retention/PVC 값은 ArgoCD source의
umbrella chart values에서 관리). chart 버전·관측 파이프라인 운영은
[`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md)와
[`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md)를 따른다.

| 항목 | 값 | 비고 |
|---|---|---|
| Namespace | `monitoring` | `kubernetes_namespace_v1.monitoring`(이 root 관리) |
| port-forward RBAC | `monitoring_port_forward_user_emails` | 팀원 Grafana 접근 경계(이 root 관리) |
| Helm chart | `kube-prometheus-stack` | **ArgoCD Application `deploy/monitoring`이 관리(#183)** |
| Grafana admin credential | 기존 Kubernetes Secret 참조 | payload는 Terraform state에 저장하지 않음 |

Grafana admin Secret은 운영자가 `monitoring` namespace에 직접 만든다(operator 주입).

비밀번호를 명령행 인수(셸 히스토리·프로세스 목록에 노출)에 두지 않도록,
`read -s`로 입력받아 권한 제한 임시 파일(`--from-env-file`)로 주입한다.

```bash
umask 077                                   # 이후 생성 파일은 0600
env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT               # 오류 포함 종료 시 폐기

read -rs -p 'admin-password: ' APW; echo    # 화면·히스토리에 남지 않음
printf 'admin-user=admin\nadmin-password=%s\n' "$APW" > "$env_file"
unset APW

kubectl create secret generic grafana-admin-credentials \
  -n monitoring \
  --from-env-file="$env_file"

rm -f "$env_file"; trap - EXIT              # 즉시 삭제
```

secret payload는 Git, PR, Terraform state에 남기지 않는다. Helm release는 Secret
이름과 key만 참조한다.

## ArgoCD Kubernetes root (#83/#84/#85)

ArgoCD는 dev GCP root가 아니라 `terraform/admin/argocd-k8s`에서 별도 state로
관리한다. #83에서 `argocd` namespace와 values 위치를, #84에서 argo-cd Helm
release를, #85에서 AppProject(`autoresearch-dev`)와 샘플 Application을 추가했다.
**#183/#186에서 monitoring·argo-rollouts를 이 AppProject의 ArgoCD Application으로
이관하고, 검증용 샘플(`sample-guestbook`)과 `argocd-sample` namespace는 제거했다.**

| 항목 | 값 | 비고 |
|---|---|---|
| Namespace | `argocd` | `kubernetes_namespace_v1.argocd` |
| Helm chart | `argo-cd` `10.1.3` (ArgoCD v3.4.5) | `var.argo_cd_chart_version` pin |
| Release name | `argo-cd` | `var.argo_cd_release_name` |
| server Service | `ClusterIP` | 외부 공개 금지. UI는 `kubectl port-forward` 접근 |
| NetworkPolicy | deny-by-default ingress/egress (#116) | 같은 namespace + kube-system + 노드 대역(8080, port-forward)만 ingress 허용. egress는 같은 namespace + DNS + 443 |
| dex / notifications | disabled | 최소 설치. 사용 시점(후속 이슈)에 활성화 |
| applicationSet | replicas 0 (중지) | chart 8.0부터 enabled 키 제거(#115). ApplicationSet CR 사용 시 복원 |
| AppProject | `autoresearch-dev` (#85, #183) | sourceRepos: infra repo, destinations: `monitoring`·`kube-system`, cluster-wide는 필요한 kind만 허용(CRD/ClusterRole/ClusterRoleBinding/webhook) |
| Application | `monitoring`(#183), `argo-rollouts`(#186) | infra repo `deploy/*` umbrella chart, manual sync, `ServerSideApply`. 샘플(`sample-guestbook`)은 검증 후 제거 |
| Secret payload | Terraform/Git 밖에서 관리 | repo credential, admin password, webhook secret 등 |

UI 접근(port-forward)과 초기 admin credential 처리 절차는
[`terraform/admin/argocd-k8s/README.md`](../terraform/admin/argocd-k8s/README.md)를
단일 원본으로 한다.

## dev Bastion Host (#47)

| 항목 | 값 | 비고 |
|---|---|---|
| Instance | `autoresearch-dev-bastion` | `bastion.tf`, `var.bastion_enabled`로 on/off |
| 머신/디스크 | e2-micro, pd-standard 10GB | 터널 종단 용도 최소 사양 |
| 네트워크 | dev subnet, **외부 IP 없음** | egress는 Cloud NAT |
| SSH 진입 | **IAP TCP forwarding만** | 기존 `ssh-iap` 태그 firewall 재사용 (35.235.240.0/20 → 22) |
| 로그인 | OS Login (`enable-oslogin=TRUE`) | SSH 키 배포 없이 IAM으로 통제 |
| SA | **없음** | GCP API 호출 없음. SA를 붙이면 SSH에 serviceAccountUser가 추가로 필요 |
| 보안 | Shielded VM (secure boot/vTPM/integrity) | |
| 팀원 IAM | `iap.tunnelResourceAccessor` + `compute.osLogin` + `compute.viewer` | `terraform/admin/gke-team-access`에서 관리 |
| 용도 | Airflow UI(#48) 등 VPC 내부 서비스 접근 터널 | kubectl은 #45 DNS 엔드포인트 사용 — bastion 불필요 |

### 사용법 (팀원)

팀원에게 공유할 실제 명령은
[`docs/TEAM_OPERATIONS_RUNBOOK.md`](TEAM_OPERATIONS_RUNBOOK.md)를 단일 원본으로 한다.
요약하면 SSH 단독 접속은 점검용, Airflow UI 로그인은 `-L 8080` 포트 포워딩 후
`http://localhost:8080`, SOCKS 프록시는 내부 DNS 비로그인 확인용 보조 경로다.

### 비용/롤백

- VM e2-micro 서울 ~$7–9/월 + 디스크 ~$0.5 + **Cloud NAT VM당 몫 ~$32/월 상한**(bastion이 NAT를 쓰는 시간 기준).
- 장기 미사용 시: `gcloud compute instances stop` 또는 tfvars에서 `bastion_enabled=false` 후 apply.
- 롤백: `bastion_enabled=false` apply → VM 삭제. 상태ful 데이터 없음.

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
| 인증 | public access 없음, `roles/run.invoker`만 | Airflow batch GSA는 기본 허용, 추가 호출 주체는 `var.proxy_invoker_members`로 확장 |
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

### 호출 방법 (Airflow batch / collector)

현재 기본 호출 주체는 Airflow KubernetesPodOperator batch pod가 가장하는
`autoresearch-dev-airflow-batch@...` GSA다. 이 GSA에는 `autoresearch-dev-proxy`
Cloud Run 서비스 단위 `roles/run.invoker`만 부여한다. 프로젝트 전체 Cloud Run
권한이나 public access는 열지 않는다.

```bash
# invoker 권한이 있는 SA의 ID token으로 호출
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "$(terraform -chdir=terraform/envs/dev output -raw proxy_service_uri)/health"
```

### 비용/롤백

- min 0 + 일 수 회 호출 → 사실상 무과금. 콜드 스타트(수 초)는 dev에서 허용.
- 롤백: `cloud_run.tf` 리소스 제거 후 apply(또는 `-target` destroy). 상태ful 데이터 없음.

## Airflow UI 내부 노출 (#48)

| 항목 | 값 | 비고 |
|---|---|---|
| ILB 예약 내부 IP | `autoresearch-dev-airflow-ilb` | dev subnet 내부 예약, `output.airflow_ilb_ip` |
| Private DNS zone | `dev.autoresearch.internal` | `var.internal_dns_domain`. VPC 내부에서만 조회 가능 |
| 레코드 | `airflow.dev.autoresearch.internal` → ILB IP | A, TTL 300 |
| NetworkPolicy | dev subnet(10.10.0.0/20) → 8080 허용 추가 | `terraform/admin/airflow-k8s`, `var.ui_ingress_source_cidr` |
| 노출 범위 | **VPC 내부 전용** | 인터넷 노출 없음. 접근은 Bastion(#47) 터널 경유 |

## MLflow UI 내부 노출 (#244)

Airflow(#48)와 동일 패턴. 단 인증 유지를 위해 ILB는 **oauth2-proxy(4180)**
앞단에만 붙이고 `mlflow`(5000)은 ClusterIP 내부 전용을 유지한다.

| 항목 | 값 | 비고 |
|---|---|---|
| ILB 예약 내부 IP | `autoresearch-dev-mlflow-ilb` | dev subnet 내부 예약, `output.mlflow_ilb_ip` |
| 레코드 | `mlflow.dev.autoresearch.internal` → ILB IP | A, TTL 300. 기존 `internal` zone 재사용 |
| LB 대상 | oauth2-proxy Service(4180) | `deploy/mlflow`(ArgoCD). `mlflow:5000`은 미노출 |
| 인증 | oauth2-proxy(Google + 허용 이메일) 유지 | redirect URI `localhost:4180` **불변**(터널 접속이라 콘솔 재등록 불필요) |
| 노출 범위 | **VPC 내부 전용** | 인터넷 노출 없음. 접근은 Bastion(#47) 터널 경유 |

단계: (1) 예약 IP + DNS apply(dev root, IP `10.10.0.22`) → (2) oauth2-proxy
Service를 internal LB로 flip(ArgoCD sync). Airflow #48과 동일하게 브라우저는
Bastion 터널로 `localhost:4180`에 접속하므로 redirect URI는 그대로다. 상세는
`docs/superpowers/specs/2026-07-18-mlflow-internal-ilb-design.md`.

### private googleapis DNS zone (#138)

`googleapis.com.` private zone(A `private.googleapis.com` → 199.36.153.8~11,
CNAME `*.googleapis.com`)이 VPC 전체의 Google API 해석을 고정 VIP로 유도한다.
이 덕분에 Google API만 필요한 namespace(vault)는 egress 443을
`199.36.153.8/30`으로 좁힌다. `pkg.dev`(노드 이미지 pull), `run.app`
(Cloud Run proxy), metadata 경로는 zone 범위 밖이라 영향이 없다.
argocd(GitHub)·airflow(OpenRouter 등)는 외부 endpoint 의존으로
`0.0.0.0/0:443`을 유지한다(설계:
`docs/superpowers/specs/2026-07-13-private-googleapis-egress-design.md`).

### Airflow Helm values 가이드 (Autoresearch-airflow 저장소에서 설정)

webserver Service를 internal LB로 만들고 Terraform output의 예약 IP를 지정한다.
values는 [`SKYAHO/Autoresearch-airflow`](https://github.com/SKYAHO/Autoresearch-airflow)
저장소가 관리하며, 인프라는 IP/DNS/방화벽 경계만 제공한다.

```yaml
webserver:
  # Local 정책의 단절 창 제거: pod 하나가 재시작해도 나머지가 트래픽 수신.
  # 주의: replica > 1이면 세션 일관성을 위해 webserverSecretKey를 고정해야 한다
  # (값은 Secret으로 관리, values에 평문 금지).
  replicas: 2

  podDisruptionBudget:
    enabled: true
    config:
      maxUnavailable: 1

  # 두 replica를 가급적 서로 다른 노드에 분산 (soft anti-affinity).
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                component: webserver

  service:
    type: LoadBalancer
    loadBalancerIP: "<terraform output airflow_ilb_ip>"
    annotations:
      networking.gke.io/load-balancer-type: "Internal"
    ports:
      - name: airflow-ui
        port: 8080
    # 필수: 클라이언트 source IP 보존. 기본값(Cluster)이면 노드 IP로 SNAT되어
    # NetworkPolicy의 소스 CIDR 제한이 실효를 잃는다 (리뷰 반영).
    externalTrafficPolicy: Local
```

스케줄러 파드 안에서 Google provider 오퍼레이터를 직접 실행하는 DAG
(`lake_to_bigquery_incremental`)를 위해, Helm chart가 생성하는 스케줄러
KSA(`airflow/airflow-scheduler`)에 GSA annotation을 values로 주입한다(#240).
GSA 측 `roles/iam.workloadIdentityUser` 바인딩은 이 저장소 Terraform
(`airflow.tf`의 `airflow_scheduler_wi`)이 관리한다.

```yaml
scheduler:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: autoresearch-dev-airflow@ar-infra-501607.iam.gserviceaccount.com
```

> `externalTrafficPolicy: Local`에서는 webserver pod가 있는 노드만 LB 헬스체크를
> 통과한다. 위처럼 **replica 2 + PDB**를 두면 pod 재시작(가장 흔한 단절 원인)
> 중에도 다른 replica가 트래픽을 받아 단절이 없다. 단 현재 airflow 노드풀이
> 1대(min=max=1)라 두 replica가 같은 노드에 놓일 수 있고, 이 경우 **노드
> 업그레이드/교체 시**에는 짧은 단절이 남는다(dev 허용). 이것까지 없애려면
> `airflow_gke_node_count_max`를 2로 올려 노드 분산을 보장한다.
> `ui_ingress_source_cidr`를 Bastion IP `/32`로 좁히는 것도 Local 정책일 때만
> 의미가 있다.
>
> `google_compute_address.airflow_ilb`는 현재 dev subnet에서 예약된 내부 IP를
> output으로 제공한다. `address` 인자를 하드코딩하지 않았으므로 주소 리소스가
> 삭제·재생성되면 같은 숫자 IP가 다시 배정된다고 가정하지 않는다. Helm
> `loadBalancerIP`와 운영 문서는 항상 `terraform output airflow_ilb_ip` 값을
> 기준으로 맞춘다.
>
> **운영 전환 시**: passthrough ILB 대신 container-native(L7 internal ALB + NEG)로
> 전환해 노드 경유(SNAT/Local 딜레마)를 구조적으로 제거하고, IP 기반 제한 대신
> 인증 계층(IAP/OAuth)을 주 방어로 둔다. Envoy proxy 고정비 때문에 dev에는
> 적용하지 않는다.

### 접속 방법 (팀원)

팀원에게 공유할 실제 접속 명령은
[`docs/TEAM_OPERATIONS_RUNBOOK.md`](TEAM_OPERATIONS_RUNBOOK.md)를 따른다. 운영 기준은
Bastion(#47) 포트 포워딩 → `http://localhost:8080`이며, Google OAuth 로그인은
localhost redirect URI 기준(#54)으로만 동작한다. SOCKS 프록시는 내부 DNS 비로그인
확인용 보조 경로다.

### 비용/롤백

- 예약 내부 IP·private DNS zone: 무시 가능한 수준(zone $0.20/월 + 쿼리 과금 미미).
  internal passthrough LB 자체는 무과금(트래픽 처리 요금만).
- 롤백: `dns.tf` 리소스 제거 + NetworkPolicy ingress 블록 제거 후 apply.
  Helm Service를 ClusterIP로 되돌리면 ILB도 제거된다.

## dev GKE (#5)

| 항목 | 값 | 비고 |
|---|---|---|
| Cluster | `autoresearch-dev-gke` | Standard, zonal `asia-northeast3-a` |
| Endpoint | `34.64.97.177` (IP) + **DNS 엔드포인트(#45)** | DNS 경로는 IAM 검증(IP 등록 불필요), IP 경로는 authorized networks 예비 |
| `master_authorized_networks` | `[]` (비어 있음) | #279에서 개인 동적 IP 제거. 기본 경로는 DNS(IAM)라 등록 불필요. IP 예비 경로가 필요하면 고정 IP를 등록 |
| 모드 | private nodes, public endpoint | 노드 공인 IP 없음. 마스터 접근: DNS(IAM) 기본 + IP allowlist 예비(현재 비어 있음) |
| Master CIDR | `172.16.0.0/28` | 현재 dev apply 값. dev subnet/private services와 미중복 |
| Pods/Services 대역 | `172.16.64.0/20` / `172.16.128.0/24` | 서브넷 2차 대역, VPC-native(alias IP) |
| Control plane | GKE 관리형 | CPU/RAM 직접 지정 불가. Google이 control plane을 관리 |
| 노드풀 | `dev-default`, e2-standard-4, pd-standard 30GB | autoscaling min=1/max=2. GKE system/GMP pod 여유를 위해 live resize 값을 Terraform에 반영 |
| Airflow 노드풀 | `airflow-dev`, e2-standard-2, pd-standard 30GB | autoscaling min=1/max=1. Airflow Helm component 전용 |
| 노드 SA | `autoresearch-dev-gke-nodes@ar-infra-501607.iam.gserviceaccount.com` | AR reader + logging/metric writer |
| app SA(WI) | `autoresearch-dev-app@ar-infra-501607.iam.gserviceaccount.com` | app KSA 전용. Cloud SQL client + DB password secret accessor |
| app WI principal | `ar-infra-501607.svc.id.goog[autoresearch/autoresearch-app]` | Terraform에서 GCP SA IAM binding까지 생성 |
| Airflow batch SA(WI) | `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com` | batch KSA 전용. API key secrets, raw_data, Feast 권한 |
| Airflow batch WI principal | `ar-infra-501607.svc.id.goog[airflow/autoresearch-batch]` | Airflow batch KSA가 batch GSA를 가장 |
| Airflow scheduler WI principal | `ar-infra-501607.svc.id.goog[airflow/airflow-scheduler]` | #240 스케줄러 파드 내 직접 실행 오퍼레이터용. airflow GSA를 가장. KSA annotation은 Airflow 저장소 Helm values에서 관리 |
| Egress | Cloud NAT(`autoresearch-dev-nat`) | private 노드 AR(`*.pkg.dev`) pull |
| NetworkPolicy enforcement | Calico enabled (#116) | admin root들의 NetworkPolicy 강제. 활성화 apply 시 노드풀 롤링 재생성 |
| deletion_protection | false (dev) | 운영 전환 시 true |

### kubectl 접근

팀원 로컬 접근은 GCP IAM으로 `roles/container.viewer`를 부여해(#31, #45에서
clusterViewer→viewer로 확대) `gcloud container clusters get-credentials`를 실행할
수 있게 한다. #45부터 기본 접속 경로는 **DNS 기반 컨트롤 플레인 엔드포인트**로,
`container.clusters.connect` 권한만 있으면 IP 등록 없이 어디서든 접속된다.
이 권한은 GKE 클러스터 조회/연결용이며, Kubernetes namespace 내부 작업 권한은
#32의 RBAC에서 별도로 정한다.

대상 Google 계정은 dev 루트가 아니라 `terraform/admin/gke-team-access`에서 별도 state로
관리한다. 실제 이메일은 해당 경로의 로컬 `terraform.tfvars`에만 기입하며(repo 노출 방지),
일반 PR Terraform plan에는 팀원 이메일과 사람 IAM 변경이 나오지 않게 분리한다.

#215부터 같은 admin root가 팀원에게 프로젝트 수준 `roles/bigquery.jobUser`와
`autoresearch_dev_analytics`·`feast_offline_store`·`data_lake_raw`
(#285에서 추가) 세 dataset의
`roles/bigquery.dataEditor`를 함께 관리한다. `dataEditor`는 dataset 단위로만
부여하며 프로젝트 수준 Data Editor/Editor/Owner를 부여하지 않는다. `jobUser`는
프로젝트 범위의 job 생성 권한이므로 query/load job은 `maximum_bytes_billed` 같은
job 수준 비용 제한을 사용한다.

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
# 기본 경로(#45): DNS 엔드포인트 — IP 등록 불필요
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --dns-endpoint

kubectl config current-context
kubectl get ns
```

접근이 실패하면 아래를 순서대로 확인한다.

- **IAM 오류**: `roles/container.viewer`가 해당 Google 계정에 부여되어 있는지 확인한다
  (DNS 엔드포인트는 `container.clusters.connect` 필요 — 구 clusterViewer에는 없음).
- **네트워크 오류/timeout**: `--dns-endpoint` 없이 IP 기반 kubeconfig를 쓰는 경우에만
  `master_authorized_networks` 등록이 필요하다. 기본 경로는 `--dns-endpoint`로 재발급.
- **Kubernetes RBAC 오류**: kubeconfig를 받았더라도 namespace 안에서 Helm install/update를
  하려면 Kubernetes RBAC가 필요하다. `airflow` namespace 작업 권한은 #32에서 별도로
  구성한다.
- **잘못된 context**: `kubectl config current-context`가
  `gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke` 계열인지 확인한다.

**Off-boarding**: `terraform/admin/gke-team-access/terraform.tfvars`의
`team_member_emails`에서 이메일을 제거하고 apply하면 GKE·Bastion의 project IAM과
BigQuery의 project/dataset IAM member가 해당 계정에 대해서만 제거된다
(non-authoritative). 단, 이미 발급받은 access token은 만료(최대 ~1시간)까지 유효하므로
**즉시 차단이 아니다**. 긴급 차단이 필요하면 해당 Google 계정의 GCP 세션을 별도로 종료해야
한다. kubeconfig 자체는 로컬에 남지만 다음 인증 시 403.

기존 dev state에 `google_project_iam_member.gke_kubectl_users[...]`가 남아 있으면
실제 IAM을 destroy하지 않는다. 이 리소스는 `terraform/admin/gke-team-access`가
소유하므로 dev root에서는 `terraform state rm`으로 state에서만 분리한다.

팀원에게 공유할 실제 로컬 설정 절차와 dev 내부망 접근 전략(Bastion/VPN 비교,
Cloud SQL private IP / 내부 서비스 접근 경로)은
[docs/TEAM_OPERATIONS_RUNBOOK.md](TEAM_OPERATIONS_RUNBOOK.md)를 참조한다.

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

### Airflow dev runtime (#32)

Airflow Helm release는 Autoresearch-airflow 저장소의
`helm/values-gke-dev.yaml`을 기준으로 `airflow` namespace에 배포한다.
Terraform은 GCP-side 리소스(node pool, IAM, Workload Identity binding)를
관리하고, Kubernetes namespace/KSA는 GKE API 접근이 필요한 운영 전 단계로
관리한다. Terraform CI plan이 GKE master authorized networks에 막히지
않도록 Kubernetes provider는 이 루트 모듈에 추가하지 않는다.

사전 리소스:

```bash
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount autoresearch-batch -n airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount autoresearch-batch -n airflow \
  iam.gke.io/gcp-service-account=autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com \
  --overwrite
```

`#62`부터 `airflow/autoresearch-batch` KSA는 app GSA가 아니라 batch 전용
GSA(`autoresearch-dev-airflow-batch`)를 가장한다. 따라서 dev root apply 전에
실제 클러스터의 `autoresearch-batch` KSA annotation이 위 값으로 바뀌어 있어야
한다. annotation이 여전히 app GSA를 가리키는 상태에서 기존 app GSA
Workload Identity binding과 Airflow API key accessor가 제거되면 batch pod는
토큰 교환 또는 secret 접근 단계에서 403으로 실패할 수 있다.

batch GSA에는 Cloud SQL client와 Airflow DAG/log bucket objectAdmin을 부여하지
않는다. Airflow metadata DB 접근과 remote log 업로드는 Airflow component
pod(`airflow` KSA → `autoresearch-dev-airflow` GSA)가 담당하고, batch pod는
원본 데이터·Feast·API key secret만 소비한다.

API key secret:

Terraform은 Secret Manager secret metadata와 resource-level IAM만 관리한다.
`google_secret_manager_secret_version`은 payload가 state에 평문 저장될 수
있으므로 YouTube/OpenRouter API key 값은 Terraform으로 관리하지 않는다.

| 용도 | Secret Manager secret | Kubernetes Secret key |
|---|---|---|
| YouTube Data API v3 | `autoresearch-dev-youtube-api-key` | `YOUTUBE_API_KEYS`, `YOUTUBE_API_KEY` |
| OpenRouter Mistral Nemo | `autoresearch-dev-openrouter-api-key` | `OPENROUTER_API_KEY` |

Secret value는 운영자가 별도 주입한다.

```bash
gcloud secrets versions add autoresearch-dev-youtube-api-key \
  --project ar-infra-501607 \
  --data-file=-

gcloud secrets versions add autoresearch-dev-openrouter-api-key \
  --project ar-infra-501607 \
  --data-file=-
```

Airflow DAG은 KPO pod에 Kubernetes Secret
`autoresearch-airflow-env`를 env var로 주입한다. Secret Manager version을
추가/교체한 뒤 아래처럼 K8s Secret을 materialize한다. 값은 출력하지 않는다.

값을 명령행 인수(프로세스 목록에 노출)에 두지 않도록, ACL 제한 임시 파일에
써서 `--from-env-file`로 주입하고 `finally`에서 폐기한다.

```powershell
$YouTubeApiKey = gcloud secrets versions access latest `
  --secret autoresearch-dev-youtube-api-key `
  --project ar-infra-501607
$OpenRouterApiKey = gcloud secrets versions access latest `
  --secret autoresearch-dev-openrouter-api-key `
  --project ar-infra-501607

$envFile = New-TemporaryFile
try {
  # 현재 사용자만 접근하도록 상속 제거 + 본인 권한만 부여
  icacls $envFile.FullName /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
  @(
    "YOUTUBE_API_KEYS=$YouTubeApiKey",
    "YOUTUBE_API_KEY=$YouTubeApiKey",
    "OPENROUTER_API_KEY=$OpenRouterApiKey"
  ) | Set-Content -Path $envFile.FullName -Encoding ascii

  kubectl create secret generic autoresearch-airflow-env -n airflow `
    --from-env-file=$envFile.FullName `
    --dry-run=client -o yaml | kubectl apply -f -
}
finally {
  Remove-Item $envFile.FullName -Force -ErrorAction SilentlyContinue
  Remove-Variable YouTubeApiKey, OpenRouterApiKey -ErrorAction SilentlyContinue
}
```

Helm 배포/재현:

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update
helm upgrade --install airflow apache-airflow/airflow \
  --version 1.16.0 \
  --namespace airflow \
  --values <Autoresearch-airflow 저장소>/helm/values-gke-dev.yaml
```

기대 상태:

```bash
helm status airflow -n airflow
kubectl get pods -n airflow -o wide
```

Airflow core pods(`airflow-postgresql`, `airflow-scheduler`,
`airflow-webserver`)는 `cloud.google.com/gke-nodepool=airflow-dev` 노드에
배치되어야 한다. Airflow metadata DB로 배포되는 PostgreSQL은 데이터
레이크가 아니라 Airflow 내부 metadata 저장소다.

### Airflow action log DAG smoke

수동 trigger 전에 입력 파일을 확인한다.

```bash
gcloud storage ls gs://ar-infra-501607-autoresearch-dev-raw-data/data_lake/youtube_trending_kr/dt=2026-07-07/part-0.parquet
gcloud storage ls gs://ar-infra-501607-autoresearch-dev-raw-data/asset/virtual_user/vu_1000.parquet
```

출력 partition이 이미 있으면 DAG는 overwrite 없이 skip한다.

```bash
gcloud storage ls gs://ar-infra-501607-autoresearch-dev-raw-data/data_lake/action_log/dt=2026-07-07/part-0.parquet
```

입력이 있고 출력이 없으면 Airflow UI 또는 CLI에서
`youtube_gcs_action_log_pipeline`을 `partition_date=2026-07-07`,
`overwrite=false`로 1회 trigger해 `ensure_action_log_partition` 성공과
GCS output 생성을 확인한다.

2026-07-08 초기 smoke에서는 KPO `serviceAccountName`/`imagePullPolicy`
필드에 Jinja literal이 남아 pod 생성 전 403이 발생했다. Autoresearch-airflow
`bb39385`에서 해당 필드를 DAG parse 시점 `Variable.get(...)` 값으로
해결하도록 수정했고, git-sync 반영 후 DAG run
`manual__smoke_2026-07-07T20260707T165929Z`가 성공했다. 출력 파일
`gs://ar-infra-501607-autoresearch-dev-raw-data/data_lake/action_log/dt=2026-07-07/part-0.parquet`
생성도 확인됐다.

### Live drift state 반영

`airflow-dev` node pool은 live GKE에 먼저 생성됐기 때문에 Terraform
resource 추가 후 state import를 수행했다.

```bash
terraform -chdir=terraform/envs/dev import \
  google_container_node_pool.airflow \
  projects/ar-infra-501607/locations/asia-northeast3-a/clusters/autoresearch-dev-gke/nodePools/airflow-dev
```

같은 작업에서 Airflow Workload Identity member와 Cloud Build IAM member도
remote state로 import했다. kubectl 사용자 IAM binding은 최신 main의 #39
cleanup 기준으로 dev root 소유가 아니며, `terraform/admin/gke-team-access`에서
관리한다. remote state에 이미 있던 Cloud Run proxy는 코드에 재도입해 full plan
destroy 리스크를 제거했다. `dev-default` node pool의 live machine type은
`e2-standard-4`로 확인되어 다음 apply가 `e2-small`로 되돌리지 않도록 Terraform
변수 기본값도 live에 맞췄다.

2026-07-08 기준 `terraform apply` 결과는 Airflow API key Secret Manager
metadata와 resource-level IAM만 `4 added, 0 changed, 0 destroyed`로
완료됐다. Secret payload version은 Terraform state에 넣지 않고 별도
운영 명령으로 추가한다. 후속 `terraform plan -detailed-exitcode`는
`No changes`로 종료됐다.

### 비용/롤백
- 예상: 기본 `dev-default` e2-standard-4 1대는 asia-northeast3 on-demand 기준
  대략 $95~100/월/노드, Airflow 전용 `airflow-dev` e2-standard-2 1대는 대략
  $45~50/월/노드 수준(할인, 환율, 가격 변경 제외)이다. 여기에 pd-standard disk와
  Cloud NAT 고정비(대략 $30대/월)가 추가된다. `gke_node_count_min = 1`과
  `airflow_gke_node_count_min = 1`이라 미사용 시에도 최소 노드 2대가 상시 과금된다.
  Standard control plane은 직접 과금/사양 지정 대상이 아니다. 정확한 비용은
  apply 전 Google Cloud Pricing Calculator로 확인한다.
- 절감: 장기 미사용 시 Airflow Helm release 중지 후 `airflow-dev` node pool min/max를 0으로 내리는 별도 변경을 검토한다. NAT 고정비는 노드 0화로 사라지지 않는다.
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

Airflow 구성요소가 배포되는 GKE namespace 경계와, 거기에 물릴 GCP 권한(Cloud SQL / GCS / BigQuery)을 IaC로 관리한다. Airflow Helm chart values, executor, fernet key, DAG, image 설정은 이 저장소 범위 밖이며 [`SKYAHO/Autoresearch-airflow`](https://github.com/SKYAHO/Autoresearch-airflow)에서 관리한다.

Airflow는 두 Terraform root로 나눈다.

- `terraform/envs/dev`: GCP 리소스만 관리한다. GCP SA, Workload Identity IAM member, Cloud SQL database, GCS bucket/IAM, BigQuery IAM이 여기 있다.
- `terraform/admin/airflow-k8s`: Kubernetes namespace/RBAC/ResourceQuota/LimitRange/NetworkPolicy만 관리한다. GKE API 서버가 `master_authorized_networks`로 제한되어 있어, GitHub Actions PR plan이 이 root를 실행하지 않는다. apply는 허용된 관리자 네트워크에서 수행한다.
- `terraform/admin/argocd-k8s`: ArgoCD namespace와 argo-cd Helm release를 관리한다. AppProject/Application 리소스는 #85에서 추가한다.

| 항목 | 값 | 비고 |
|---|---|---|
| Namespace | `airflow` | `var.airflow_k8s_namespace`. GKE 클러스터 내 신규 namespace |
| KSA | `airflow` | `var.airflow_k8s_service_account`. `iam.gke.io/gcp-service-account` annotation으로 GCP SA 매핑 |
| GCP SA | `autoresearch-dev-airflow` | `${resource_prefix}-airflow`. WI 전용, JSON 키 미발급 |
| WI principal | `ar-infra-501607.svc.id.goog[airflow/airflow]` | KSA annotation으로 사용 |
| RBAC(Role) | `airflow-components` (namespace-scoped) | pods/configmaps/secrets/services, apps, batch 전 동사. KSA에 바인딩 |
| 설치자 RBAC | `installer-admin`(for_each) | `terraform/admin/airflow-k8s/terraform.tfvars`의 `installer_user_emails` 팀원에게 namespace 내 `admin` ClusterRole 바인딩. Helm 설치 경로 |
| 자동 배포 RBAC | `airflow-deployer-admin` | GitHub Actions deployer GSA에만 namespace 내 `admin` ClusterRole 바인딩. cluster-wide 권한 없음 |
| ResourceQuota | cpu 4 / mem 8Gi / pods 20 / pvc 4 | namespace 자원 한도 |
| LimitRange | default 500m/512Mi, request 250m/256Mi | Container 기본 request/limit |
| NetworkPolicy(ingress) | 같은 namespace + kube-system만 | deny-by-default |
| NetworkPolicy(egress) | 같은 namespace(#116), **services CIDR VIP 53/5432(#122)**, DNS(53), Cloud SQL(private_services_cidr 5432), GKE metadata server(169.254.169.254:80, 169.254.169.252:987/988), HTTPS(443) | 현재 Standard + Calico의 WI 토큰 교환은 169.254.169.252:987/988을 사용한다. Dataplane V2 metadata endpoint 경로인 169.254.169.254:80도 유지한다. 외부 API/googleapis 호출은 443으로 허용한다. |
| NetworkPolicy enforcement | #116부터 Calico로 실제 강제 | 그 이전에는 enforcement가 꺼져 있어 위 정책들이 선언만 된 상태였다 |
| egress 규칙 주의(#122) | service VIP 트래픽은 selector가 아니라 **services CIDR ipBlock**으로 허용 | 이 클러스터의 Calico는 egress를 DNAT 이전(VIP 기준)에 평가한다 |
| Cloud SQL DB | `airflow` | 기존 dev 인스턴스 내 신규 database(metadata DB) |
| Secret Manager | `autoresearch-dev-youtube-api-key`, `autoresearch-dev-openrouter-api-key` | secret payload는 Terraform 밖에서 주입. secret metadata와 Airflow SA/batch SA accessor만 Terraform 관리 |
| GCS buckets | `ar-infra-501607-autoresearch-dev-airflow-dags`, `...-airflow-logs` | DAG 버전관리 / task log 영속화. `prevent_destroy=true` |
| Airflow SA 접근 권한 | Cloud SQL client, Secret Manager accessor(Airflow API/OAuth secrets), BigQuery jobUser(project), GCS objectAdmin(dags/logs/feast_registry/feast_staging), GCS objectViewer+objectCreator(raw_data), BigQuery dataEditor(feast_offline_store, data_lake_raw) | raw_data는 읽기+새 객체 생성만 허용해 기존 원본 삭제/덮어쓰기를 차단 |
| Airflow batch SA 접근 권한 | Secret Manager accessor(YouTube/OpenRouter), BigQuery jobUser(project), GCS objectViewer+objectCreator(raw_data), GCS objectAdmin(feast_registry/feast_staging), BigQuery dataEditor(feast_offline_store, data_lake_raw) | app GSA에서 Airflow API key 접근권을 제거하고 batch 실행에 필요한 권한만 분리 |

### 설치 담당자 Helm 적용 경로

`terraform/admin/airflow-k8s`의 `installer-admin` RoleBinding이 팀원에게 `airflow` namespace 내 `admin` 권한을 준다. 이 root는 GKE API 서버에 접근 가능한 관리자 네트워크에서만 apply한다. 절차:

```bash
# 1) roles/container.viewer가 있는지 확인 (#45: DNS 엔드포인트면 IP 등록 불필요)
# 2) credentials 획득
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a --project ar-infra-501607 --dns-endpoint
# 3) K8s 경계 root 적용(관리자만)
cd terraform/admin/airflow-k8s
terraform init
terraform apply
# 4) namespace 확인
kubectl -n airflow get all
# 5) Helm으로 Airflow 설치(values/executor는 SKYAHO/Autoresearch-airflow에서 관리)
helm install airflow airflow/airflow -n airflow -f values.yaml
```

KSA(`airflow`)와 WI 매핑은 Terraform이 생성하므로 Helm values에서 별도 ServiceAccount 생성은 끄고, 위 KSA를 `existingServiceAccountName`로 지정한다.

### GitHub Actions Helm 자동 배포 경로 (#187)

`Autoresearch-airflow`의 `main`에서만 전용
`autoresearch-dev-airflow-cd` GSA를 WIF로 가장할 수 있다. GSA에는 GKE DNS
endpoint 접속에 필요한 project `roles/container.clusterViewer`만 부여한다. 실제
리소스 변경은 `airflow-deployer-admin` RoleBinding이 `airflow` namespace 안에서만
허용한다. GitHub-hosted runner는 DNS endpoint를 사용하므로 control plane IP
allowlist를 넓히지 않는다.

Airflow 저장소의 GitHub Actions variable은 다음 dev output과 고정 인프라 값을
사용한다.

| Variable | 값 |
| --- | --- |
| `GCP_PROJECT_ID` | `ar-infra-501607` |
| `GKE_CLUSTER` | dev output `gke_cluster_name` |
| `GKE_LOCATION` | `asia-northeast3-a` |
| `GKE_DEPLOYER_SA` | dev output `github_actions_airflow_deployer_service_account_email` |
| `WIF_PROVIDER_ID` | bootstrap output `wif_provider_name` |

적용 순서는 bootstrap → dev → `admin/airflow-k8s`이다. 세 root가 적용되고
repository variable이 설정된 뒤에만 Airflow 수동 배포 workflow로 현재 digest를
검증한다. apply 전에는 자동 배포 workflow 실행을 기대하지 않는다.

2026-07-08 최초 apply 때 `airflow` namespace는 클러스터에 이미 존재했다. 삭제/재생성하지 않고
`terraform -chdir=terraform/admin/airflow-k8s import kubernetes_namespace_v1.airflow airflow`
로 state에 편입한 뒤 나머지 RBAC/ResourceQuota/LimitRange/NetworkPolicy를 적용했다.

### 비용/롤백

- namespace/RBAC/NetworkPolicy 자체는 비용 발생 안 함. GCS 버킷 2개(DAG/log)는 객체 크기에 따라 과금.
- `prevent_destroy=true`: dev 전체 destroy에서도 버킷 삭제 차단. 삭제 필요 시 lifecycle 해제 후 별도 apply.
- Cloud SQL database `airflow`는 기존 인스턴스 비용에 포함(db-g1-small 공유).
- 롤백: `terraform/envs/dev/airflow.tf`의 GCP 리소스와 `terraform/admin/airflow-k8s`의 K8s 리소스를 각각 제거 후 apply. 단 GCS 버킷은 prevent_destroy로 보호됨.

### Airflow Google OAuth 클라이언트 자격증명 (#54)

Airflow 웹 로그인(Google OAuth)의 client ID/secret을 Secret Manager로 전달한다.
OAuth 동의 화면(External, 팀원 5명 테스트 사용자)과 클라이언트(웹, redirect URI
`http://localhost:8080/oauth-authorized/google` 및 `/auth/oauth-authorized/google`)는
콘솔에서 수동 생성했다.

| 항목 | 값 |
|---|---|
| Secret | `autoresearch-dev-airflow-oauth-client-id`, `...-client-secret` |
| 접근 | Airflow SA에만 `secretAccessor` (webserver 소비) |
| Payload | Terraform 밖에서 관리 — 아래 명령으로 관리자가 등록 |

```bash
# 값이 셸 히스토리에 남지 않도록 stdin으로 입력 (실행 → 값 붙여넣기 → Enter → Ctrl+D)
gcloud secrets versions add autoresearch-dev-airflow-oauth-client-id \
  --project ar-infra-501607 --data-file=-
gcloud secrets versions add autoresearch-dev-airflow-oauth-client-secret \
  --project ar-infra-501607 --data-file=-
```

Airflow 담당은 이 두 secret을 읽어 FAB `AUTH_OAUTH`(Google provider)를 구성하고
팀원 5명 이메일 allowlist를 설정한다(`SKYAHO/Autoresearch-airflow`). 값 회전 시
새 version 추가 후 webserver를 재시작한다.

## Autoresearch-airflow Cloud Build (#32)

Autoresearch-airflow 이미지는 해당 저장소의 `cloudbuild.yaml`로 빌드하고
Artifact Registry `autoresearch-dev-docker`에 push한다. Terraform은 Cloud
Build API를 enable하지 않고, API 활성화와 기본 bucket 생성 후 필요한
최소 IAM만 관리한다.

| 항목 | 값 | 비고 |
|---|---|---|
| API | `cloudbuild.googleapis.com` | 수동 활성화 |
| Build SA | `185508640491-compute@developer.gserviceaccount.com` | Cloud Build에서 사용하는 Compute default SA |
| Artifact Registry 권한 | `roles/artifactregistry.writer` on `autoresearch-dev-docker` | 이미지 push |
| Cloud Build bucket 권한 | `roles/storage.objectViewer` on `ar-infra-501607_cloudbuild` | build staging object 조회 |
| Logging 권한 | `roles/logging.logWriter` on project | build log 기록 |

### 사람이 제출하는 빌드용 전용 SA (#269)

MLflow·Feast·batch 이미지처럼 운영자가 `gcloud builds submit`으로 직접 빌드하는
경로는 기본 compute SA 대신 **전용 build SA**를 사용한다. 기본 compute SA는 프로젝트의
모든 build가 공유하는 주체라, 사람에게 `roles/cloudbuild.builds.editor`를 부여하면(#266)
기본 SA의 GAR writer를 빌드로 빌려 쓰는 간접 push 경로가 열리기 때문이다. 전용 SA를
쓰면 "빌드 제출 권한"과 "push 권한"이 분리된다.

| 항목 | 값 | 비고 |
|---|---|---|
| Build SA | `autoresearch-cloud-build@ar-infra-501607.iam.gserviceaccount.com` | `cloud_build.tf`가 관리 |
| Artifact Registry 권한 | `roles/artifactregistry.writer` on `autoresearch-dev-docker` | push 대상은 dev 저장소 하나로 제한 |
| Cloud Build bucket 권한 | `roles/storage.objectViewer` + `roles/storage.legacyBucketReader` on `ar-infra-501607_cloudbuild` | **source 읽기 전용**. 로그는 Cloud Logging으로 보내므로 공유 버킷 쓰기·삭제 권한이 없다. `objectViewer`에는 `storage.buckets.get`이 없어 legacyBucketReader가 함께 필요하다(#204 교훈) |
| Logging 권한 | `roles/logging.logWriter` on project | build log 기록 |
| 팀원 권한 | 전용 SA에 대한 `roles/iam.serviceAccountUser` | `gke-team-access`가 관리. SA 키 발급·권한 변경 권한은 아님 |

빌드 제출 명령. 사용자 지정 SA로 실행하는 build는 **로그 대상을 명시해야 하므로**
build config에 `options.logging: CLOUD_LOGGING_ONLY`를 넣는다(`--tag` 단축 형태로는
지정할 수 없어 config 파일을 쓴다).

```yaml
# cloudbuild.yaml
steps:
  - name: gcr.io/cloud-builders/docker
    args: ["build", "-t", "${_IMAGE}", "."]
images: ["${_IMAGE}"]
options:
  logging: CLOUD_LOGGING_ONLY
```

```bash
gcloud builds submit \
  --project=ar-infra-501607 \
  --service-account=projects/ar-infra-501607/serviceAccounts/autoresearch-cloud-build@ar-infra-501607.iam.gserviceaccount.com \
  --config=cloudbuild.yaml \
  --substitutions=_IMAGE=asia-northeast3-docker.pkg.dev/ar-infra-501607/autoresearch-dev-docker/<image>:<tag> .
```

빌드 로그는 Cloud Logging에서 본다(`gcloud beta builds submit`을 쓰면 스트리밍도 된다).

> 검증(2026-07-20): 위 구성으로 smoke build를 제출해 GAR push 성공을 확인했다
> (테스트 이미지는 삭제). GCS 로그 경로(`--gcs-log-dir`)를 쓰면 SA에 공유 버킷
> 쓰기 권한이 필요해지므로 채택하지 않았다.

기본 compute SA의 GAR writer는 아직 유지한다 — 회수하려면 이 경로를 쓰는 모든
호출부(앱 저장소 runbook 포함)가 전용 SA로 전환됐는지 먼저 확인해야 한다(#269).

## GitHub Actions GAR push (#121, #157)

Autoresearch와 Autoresearch-airflow 저장소의 GitHub Actions가 SA key 없이
WIF로 GCP에 인증해 Artifact Registry `autoresearch-dev-docker`에 이미지를
push하는 경로다(`github_actions.tf`). 저장소별 서비스 계정을 분리해 한 저장소가
다른 저장소의 배포 신원을 가장할 수 없게 한다. 기존 Cloud Build 경로(#32)는
현재 병존하며, GitHub Actions 경로 end-to-end 검증 후 정리 여부를 별도 이슈로
결정한다(PR #128 코멘트 참조).

| 저장소 | 전용 SA | WI 가장 허용 | GAR 권한 |
|---|---|---|---|
| `SKYAHO/Autoresearch-airflow` | `autoresearch-dev-gar-pusher` | 저장소 **+ 승인 ref**(`repository_ref`) principalSet만 허용(#175) | `roles/artifactregistry.writer` on `autoresearch-dev-docker` |
| `SKYAHO/Autoresearch` | `autoresearch-dev-app-pusher` | `workflow_dispatch`는 정확한 release workflow + `main` source ref(`workflow_ref`), tag 기반 `release:published`는 `release` 이벤트 + 정확한 workflow 경로(`workflow_event_path`)만 허용 (#221) | `roles/artifactregistry.writer` on `autoresearch-dev-docker` |

전제: bootstrap WIF provider의 `attribute_condition`이 두 배포 리포의 토큰
발급을 허용해야 한다(`allowed_github_repositories`,
[TERRAFORM_BOOTSTRAP.md](TERRAFORM_BOOTSTRAP.md)의 허용 목록 참조).
provider 허용 목록과 SA별 principalSet을 모두 통과해야 한다. Airflow pusher SA는
`repository_ref`(repo@ref)로 제한한다. application pusher SA는 수동 실행을
`workflow_ref`(repo/workflow@workflow-source-ref)의 `main`으로 제한하고, tag 기반
release는 `event_name`과 ref를 제거한 workflow 경로를 조합한
`workflow_event_path`로 제한한다. 따라서 임의 브랜치의 `workflow_dispatch`는
SA를 가장할 수 없으며, `release:published`에서만 tag ref를 허용한다.
`terraform-ci` SA 가장은 여전히 infra 리포만 가능하다(2단 경계).

배포 저장소 workflow에 필요한 값:

| 항목 | Autoresearch-airflow | Autoresearch |
|---|---|---|
| `workload_identity_provider` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github/providers/github` | 동일 |
| `service_account` (secrets `GAR_PUSHER_SA`) | dev output `github_actions_gar_pusher_service_account_email` | dev output `github_actions_app_pusher_service_account_email` |
| workflow `permissions` | `id-token: write` | `id-token: write` |

적용 순서는 bootstrap provider attribute mapping 갱신 후 dev root IAM 추가다.
직접 비용이나 새 리전 리소스는 없고, 기존 서울 리전 GAR를 그대로 사용한다.
롤백할 때는 대상 release workflow를 비활성화한 뒤 해당 저장소의 pusher SA와
repository IAM을 제거하고 마지막으로 bootstrap 허용 목록에서 저장소를 뺀다.

## 코드 아카이브 배포 (#238)

Autoresearch가 main 머지/`workflow_dispatch` 시 코드 tar.gz를 GCS에 올리고
(`code/<sha>.tar.gz`, `code/latest.txt` 갱신), GKE `autoresearch-app` 파드가 시작
시 아카이브를 내려받아 실행하는 경로다(`code_artifacts.tf`). 앱 구현은
`SKYAHO/Autoresearch#180`·`#182`, 워크플로우는 `code-archive.yml`.

| 항목 | 값 | 비고 |
|---|---|---|
| 버킷 | `ar-infra-501607-code-artifacts`(서울) | UBLA + public access 차단, versioning 없음. output `code_artifacts_bucket_name` |
| 업로더 SA | `autoresearch-dev-code-uploader` | GitHub Actions가 WIF로 가장. output `code_uploader_service_account_email` |
| WI 가장 허용 | `workflow_ref` = `…/code-archive.yml@refs/heads/main`만 | push(main)·dispatch(main) 모두 이 ref. 임의 브랜치·워크플로우 차단(#175/#221 관례) |
| 업로더 권한 | 버킷 한정 `roles/storage.objectAdmin` | `latest.txt` 덮어쓰기 필요. 프로젝트 수준 아님 |
| 파드 read | `gke_app` GSA에 버킷 한정 `roles/storage.objectViewer` | 아카이브 다운로드 |

앱 리포 GitHub secret 등록(앱팀 수행): `CODE_ARTIFACTS_BUCKET` = 버킷명,
`GCS_CODE_UPLOADER_SA` = 업로더 SA email(위 두 output). `SKYAHO/Autoresearch`는
이미 WIF 허용 목록에 있어 bootstrap 변경은 불필요하다. 비용 영향 미미(수 MB
아카이브, 머지마다 1객체). 롤백은 `code_artifacts.tf` 리소스 제거 후 apply.

## Vault auto-unseal 기반 (#132)

HashiCorp Vault dev 도입 1단계(설계:
`docs/superpowers/specs/2026-07-12-vault-dev-design.md`). Vault 설치는
`terraform/admin/vault-k8s`(2단계 #134, 완료)에서 별도 state로 관리하고, dev
root는 GCP 측 기반(`vault.tf`)만 담당한다. 다만 실 secret 이관은 하지 않기로
결정했고(Secret Manager로 충분), vault-k8s는 샌드박스로 남긴다.

| 항목 | 값 | 비고 |
|---|---|---|
| KMS keyring / key | `autoresearch-dev-vault` / `vault-unseal` | rotation 90d, key `prevent_destroy`. keyring은 GCP 특성상 삭제 불가 |
| GSA | `autoresearch-dev-vault@…` | gcpckms seal 전용, 다른 권한 없음 |
| WI 바인딩 | `vault/vault` KSA | namespace/KSA는 vault-k8s root가 생성 |
| KMS 권한 | custom role `vaultUnsealKmsAccess`(cryptoKeys.get + useToEncrypt/useToDecrypt) key-level | 사전 정의 role은 `cryptoKeys.get` 미포함이라 부족 |

주의: unseal key를 제거하면 Vault Raft 데이터 복호화가 불가능해진다. Vault
release 제거(2단계 롤백) 후에만 key를 정리한다.

## 필수 GCP API

아래 API는 현재 dev stack과 CI plan에 필요한 서비스입니다. 이 루트 모듈은 `google_project_service`로 API enable을 관리하지 않으므로, 새 프로젝트에 재구성할 때는 apply 전에 별도로 활성화합니다.

| API | 사용 예정 |
|---|---|
| `serviceusage.googleapis.com` | GCP API enable 관리 |
| `cloudbuild.googleapis.com` | Autoresearch-airflow 이미지 build/push |
| `cloudresourcemanager.googleapis.com` | project metadata 조회 및 관리 |
| `compute.googleapis.com` | VPC/subnet, GKE 기반 네트워크 |
| `bigquery.googleapis.com` | dev 분석 dataset |
| `artifactregistry.googleapis.com` | Docker image repository |
| `sqladmin.googleapis.com` | Cloud SQL |
| `redis.googleapis.com` | Feast Online Store Memorystore for Redis Cluster (#129) |
| `networkconnectivity.googleapis.com` | Redis Cluster PSC Service Connection Policy (#129) |
| `serviceconsumermanagement.googleapis.com` | Redis Cluster service connectivity automation (#129) |
| `container.googleapis.com` | GKE |
| `cloudkms.googleapis.com` | Vault auto-unseal KMS key (#132) |
| `dns.googleapis.com` | 내부 private DNS zone (#48) |
| `iap.googleapis.com` | bastion IAP TCP forwarding (#47) |
| `oslogin.googleapis.com` | bastion OS Login SSH (#47) — 미활성 시 publickey 거부(#57) |
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

PR 이 열리면 GitHub Actions(`.github/workflows/terraform-plan.yml`)가 자동으로 `terraform fmt/validate/plan` 을 실행하고 결과를 PR 댓글로 게시한다. 저장소가 공개라 **댓글에는 변경 리소스 주소와 create/update/delete 요약만** 올리고, plan 원문(속성 diff)은 게시하지 않는다(#211). 상세는 Actions 실행 로그에서 확인한다. plan 오류 시에는 오류 원문 대신 Actions 링크와 exit code만 남긴다.

- **인증**: SA key 없이 GitHub OIDC + Workload Identity Federation(WIF). CI SA(`terraform-ci`)는 현재 dev plan에 필요한 `roles/viewer`와 state bucket 접근 권한만 가진다. Secret payload를 읽는 data source는 사용하지 않는다.
- **state**: GCS 원격 backend(`autoresearch-dev-tfstate`). 부트스트랩 절차는 [docs/TERRAFORM_BOOTSTRAP.md](TERRAFORM_BOOTSTRAP.md) 참조.
- **제한**: WIF `attribute_condition` 은 허용 리포 목록(`allowed_github_repositories` — 현재 infra + Autoresearch-airflow + Autoresearch, #121/#157) 기반이지만, CI SA(`terraform-ci`) 가장 바인딩은 infra 저장소만 허용한다. workflow job guard로 fork PR이 아닌 내부 브랜치 PR에서만 plan을 실행한다.
- **apply 자동화는 범위 밖**(별도 이슈). 본 워크플로는 plan 만 게시한다.
- **drift 감지(#153)**: `.github/workflows/terraform-drift.yml`이 매일 09:23 KST에 dev root `plan -detailed-exitcode`를 실행하고, drift/오류 시 `[DRIFT]` 이슈를 생성(중복 시 코멘트)한다. 공개 이슈에는 리소스 주소·요약만 올리고 plan 원문은 게시하지 않는다(#211). CI SA viewer 권한만 사용 — apply 권한 없음. admin root는 master 접근 불가로 대상 외이며 운영자 로컬 plan으로 확인한다.

필요 GitHub variables(4개, secret 아님): `GCP_PROJECT_ID`, `WIF_POOL_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`.

## State drift 정리 기록 (#39)

#39에서 dev state에만 남아 있던 Cloud Build 기본 compute SA 권한, legacy
`airflow-dev` node pool, legacy Airflow batch Workload Identity binding, 추가
GKE master authorized network CIDR을 정리했다. 판단 기준은
[docs/CHANGE_HISTORY.md](CHANGE_HISTORY.md)의 dev state drift cleanup 기록에
요약한다.

이 저장소에서는 drift를 숨기기 위해 state만 제거하지 않는다. 유지 근거가 없는 IAM
grant, node pool, network allowlist는 실제 GCP 리소스까지 정리하거나, 유지 대상이면
Terraform configuration으로 복원한다.
