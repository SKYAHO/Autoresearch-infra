# Airflow 운영 인프라 경계 설계 (#32)

> Status: Draft | Issue: #32 | Last Updated: 2026-07-08

## 목적

dev GKE 클러스터에 Airflow를 **실제 운영 수준**으로 설치·운영할 수 있는 인프라
경계를 구성한다. 이 저장소가 담당하는 영역은 GCP/K8s **인프라 리소스와 접근
권한**까지이며, Airflow Helm values 자체(앱 설정, OAuth, DAG 내용)는 앱 저장소
(`SKYAHO/Autoresearch`) 범위로 둔다.

완료 시 설치 담당자가 `airflow` namespace에서 Helm으로 Airflow를 설치할 수 있고,
설치된 Airflow 컴포넌트가 Workload Identity로 Cloud SQL·GCS·BigQuery에 접근할 수
있다.

## 전제

- GKE 클러스터(`google_container_cluster.dev`): private nodes + public endpoint,
  Workload Identity 활성(`workload_pool = <project>.svc.id.goog`). PR #34로 팀원은
  `roles/container.clusterViewer`로 cluster get/list + connect 가능.
- terraform에 `kubernetes` provider가 없어 현재 K8s namespace/RBAC는 IaC로 관리
  안 됨 → 이 설계에서 provider 추가.
- Airflow는 dev 단일 인스턴스 전제. prod 전환 시 구성 재검토.
- 부수 GCP 리소스(Cloud SQL database, GCS 버킷)는 기존 dev 인스턴스/네이밍 규칙
  따름.

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| 관리 방식 | Terraform `kubernetes` provider로 namespace/RBAC를 IaC 관리 | team_access.tf(#34) GCP IAM과 동일 레이어 일관. 드리프트 감지·리뷰 가능. 인프라 저장소 정체성 부합 |
| namespace 이름 | `airflow` (`var.airflow_k8s_namespace`, 기본값 `airflow`) | 관례. dev 단일 인스턴스 |
| 설치 담당자 권한 | `admin` ClusterRole을 `airflow` namespace에 RoleBinding 바인딩. 주체 = `var.gke_kubectl_user_emails`(재사용) | Helm 설치가 namespace 내 deployments/secrets/configmaps/roles 생성. cluster-scope 리소스는 Airflow 공식 chart가 기본 요구 안 함. 주체 분리(별도 variable)는 dev에서 과설계 |
| Airflow pod 인증 | K8s SA `airflow` + GCP SA `airflow`(신규) Workload Identity 매핑 | gke_app(앱)과 역할 분리. 최소 권한 원칙(AGENTS.md). pod가 GCP 리소스 접근 시 WI로 인증 |
| Airflow K8s SA RBAC | namespace 내 `Role`(pods/configmaps/secrets/services/deployments/statefulsets/jobs/cronjobs verbs=get/list/watch/create/update/patch/delete) + RoleBinding | Airflow 컴포넌트(scheduler/webserver/worker)가 K8s 리소스 조작. Airflow Helm chart가 자체 Role을 생성하지만, 인프라 단에서 경계를 명시 |
| Cloud SQL metadata DB | dev 인스턴스에 `airflow` database 신규 생성. GCP SA에 `roles/cloudsql.client` (project) | 실제 운영 시 백업·PITR 보장. in-cluster postgres 대신 관리형 DB. 기존 dev 인스턴스 재사용 |
| GCS — DAG/log 영속화 | 신규 버킷 2개: `autoresearch-dev-airflow-dags`(versioning), `autoresearch-dev-airflow-logs`. GCP SA `roles/storage.objectAdmin`(버킷 수준) | DAG 버전관리, 로그 영속화. pod 재시작 시 데이터 보존 |
| GCS — feast 데이터 접근 | 기존 raw_data/feast_registry/feast_staging 버킷에 GCP SA `roles/storage.objectAdmin`(버킷 수준) | 데이터 파이프라인이 feast 데이터 읽고 staging 가능 |
| BigQuery | feast_offline_store dataset `roles/bigquery.dataEditor`(dataset) + `roles/bigquery.jobUser`(project) | feast offline store 쿼리. gke_app과 동일 패턴 |
| namespace 보호 | ResourceQuota(requests.cpu=4/requests.memory=8Gi/pods=20/persistentvolumeclaims=4) + LimitRange(default 512Mi/250m, defaultRequest 256Mi/100m) | dev 클러스터에서 Airflow가 자원 독점 방지. 운영 데이터 후 수치 조정 |
| 네트워크 격리 | NetworkPolicy — ingress: namespace 내 + kube-system만 허용(deny by default). egress: Cloud SQL(5432), *.googleapis.com(443), kube-dns 허용 | namespace 경계. 외부 시스템은 운영 확인 후 추가 |
| provider 인증 | `data.google_client_config.default` + `google_container_cluster.dev` endpoint/CA 참조 | apply 시 로컬 ADC / CI WIF로 cluster 접근. 별도 kubeconfig 불필요 |
| 파일 구조 | `terraform/envs/dev/airflow.tf` 단일 파일(주제 단일). 확장 시 분리 | 기존 리소스 종류별 .tf 분리 규칙 유지 |
| 삭제 보호 | 신규 GCS 버킷은 `prevent_destroy`. Cloud SQL database/SA/namespace는 dev 정책 따라 protect=false | 데이터 버킷은 gke raw/feast 버킷과 동일 정책 |

## 리소스 구성

### K8s 리소스 (`airflow.tf`, kubernetes provider)

```
kubernetes_namespace.airflow                              # name=airflow
kubernetes_service_account.airflow                        # namespace=airflow, name=airflow, WI 어노테이션
kubernetes_role.airflow_components                        # namespace=airflow, Airflow 컴포넌트용
kubernetes_role_binding.airflow_sa                        # K8s SA -> Role
kubernetes_role_binding.installer_admin                   # 팀원 -> admin ClusterRole (for_each)
kubernetes_resource_quota.airflow                         # namespace=airflow
kubernetes_limit_range.airflow                            # namespace=airflow
kubernetes_network_policy.airflow_default_deny_ingress    # namespace=airflow
kubernetes_network_policy.airflow_egress                  # namespace=airflow
```

### GCP 리소스 (`airflow.tf`)

```
google_service_account.airflow                            # account_id=<prefix>-airflow
google_service_account_iam_member.airflow_wi              # WI 매핑 (K8s SA -> GCP SA)
google_project_iam_member.airflow_cloudsql_client         # roles/cloudsql.client (project)
google_project_iam_member.airflow_bigquery_job_user       # roles/bigquery.jobUser (project)
google_sql_database.airflow                               # dev 인스턴스, name=airflow
google_storage_bucket.airflow_dags                        # prevent_destroy, versioning
google_storage_bucket.airflow_logs                        # prevent_destroy
google_storage_bucket_iam_member.airflow_dags_admin       # objectAdmin
google_storage_bucket_iam_member.airflow_logs_admin       # objectAdmin
google_storage_bucket_iam_member.airflow_raw_data_admin   # objectAdmin (raw_data)
google_storage_bucket_iam_member.airflow_feast_registry_admin   # objectAdmin
google_storage_bucket_iam_member.airflow_feast_staging_admin     # objectAdmin
google_bigquery_dataset_iam_member.airflow_feast_data_editor     # dataEditor (feast_offline_store)
```

### Workload Identity 매핑

K8s SA 어노테이션:
```
iam.gkeusercontent.com/gcp-service-account = google_service_account.airflow.email
```

GCP SA IAM member:
```
member = "serviceAccount:<project>.svc.id.goog[airflow/airflow]"
role   = "roles/iam.workloadIdentityUser"
```

## provider 설정 (`versions.tf` 추가)

```hcl
required_providers {
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = ">= 2.20"
  }
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.dev.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.dev.master_auth.0.cluster_ca_certificate)
}
```

## 변수 (`variables.tf` 추가)

| 변수 | type | default | 설명 |
|---|---|---|---|
| `airflow_k8s_namespace` | string | `"airflow"` | namespace 이름 |
| `airflow_k8s_service_account` | string | `"airflow"` | K8s SA 이름 |
| `airflow_gcp_sa_name` | string | `"${name_prefix}-${env}-airflow"` | GCP SA account_id |

`gke_kubectl_user_emails`(#34) 재사용 — 설치 담당자 주체. ResourceQuota/LimitRange 수치는 우선 로컬에서 관리(변수화는 운영 데이터 후 검토).

## outputs (`outputs.tf` 추가)

- `airflow_namespace` — namespace 이름
- `airflow_k8s_service_account` — K8s SA 이름
- `airflow_gcp_service_account_email` — GCP SA email
- `airflow_workload_identity_principal` — WI member 문자열
- `airflow_cloudsql_database` — database 이름

## 문서 (`TERRAFORM_DEV.md` 갱신)

- Airflow 설치 runbook 섹션 추가:
  - Helm values 예시(WI SA 매핑, Cloud SQL 연결 문자열, GCS 버킷 경로)
  - `helm repo add apache-airflow https://airflow.apache.org` + `helm install`
  - 검증 명령(`kubectl -n airflow get pods`, SA 어노테이션 확인)
  - 트러블슈팅(WI 토큰, NetworkPolicy 차단 시)

## 비목표 (Non-goals)

- Airflow Helm values 상세 구성(OAuth, fernet key, executor 선택, 리소스 요청값) —
  앱 저장소 범위
- DAG 내용 — 앱 저장소
- Airflow 전용 Cloud SQL 인스턴스(별도 DB 서버) — 기존 dev 인스턴스의 database로
  시작. 트래픽 증가 시 분리 검토
- prod 환경 구성
- 모니터링/알림(Grafana/Prometheus) — 별도 이슈
- 백업 자동화(DAG/log 버킷) — 버킷 versioning으로 1차 보호, 정책은 운영 후 검토

## 리스크 / 롤백

- **Cloud SQL database 생성 실패**(쿼터/인스턴스 상태) → dev 인스턴스 정상 확인 후
  apply. database는 독립 리소스라 기존 DB 영향 없음
- **NetworkPolicy로 인한 Airflow 구성요소 통신 차단** → egress 규칙에
  Cloud SQL/HTTPS/DNS 포함. 차단 시 `kubectl -n airflow exec`로 디버깅 후 규칙 추가
- **Workload Identity 매핑 누락 시 GCP 접근 실패** → SA 어노테이션과 IAM member
  양쪽 확인 runbook에 명시
- **RoleBinding 주체 이메일 오기입** → #34의 validation(`can(regex(...))`)으로
  사전 검증. 잘못된 이메일은 plan 단계에서 차단
- **롤백**: namespace/SA/IAM/버킷 제거 후 apply. 단, `prevent_destroy` GCS 버킷은
  `terraform state rm` + 수동 삭제 또는 `force_destroy=true` 변경 필요. dev 환경이므로
  데이터 손실 허용 기준

## 검증

- `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- `terraform -chdir=terraform/envs/dev init -backend=false`
- `terraform -chdir=terraform/envs/dev validate`
- `terraform plan`(실제 인증/tfvars 필요) — 리소스 생성 순서 확인
- apply 후: `kubectl -n airflow get namespace,sa,role,rolebinding,networkpolicy`
- WI 검증: Airflow pod에서 `curl -H "Metadata-Flavor: Google"` GCP 메타데이터 엔드포인트
