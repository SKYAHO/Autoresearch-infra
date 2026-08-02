# Dev Terraform 환경

`terraform/envs/dev`는 AutoResearch dev GCP 인프라의 Terraform root module입니다.

현재 dev 스택은 GCS 원격 backend를 사용하며, 2026-07-08 기준 GCP 프로젝트 `autoresearch-503903`에 apply 완료되었습니다.

## 포함 범위

- Google provider 설정
- dev 환경 공통 변수
- 리소스 naming/label 공통값
- GCS backend(`autoresearch-503903-dev-tfstate`, prefix `dev/`)
- dev VPC/subnet, Cloud Router/NAT, IAP SSH firewall
- Artifact Registry Docker repository
- Cloud SQL PostgreSQL(private IP only), DB/user, DB password Secret Manager 저장
- Feast Online Store single-zone 2-shard Memorystore for Redis Cluster(PSC, IAM auth/TLS), CA Secret Manager 저장 (#129, apply·검증 완료)
- dev 원본 데이터 GCS bucket(YouTube/user/action-log/persona raw)
- 환경별 Feast registry/staging GCS bucket
- dev BigQuery analytics dataset 및 Feast prod/dev offline store dataset
- Feast 피처 테이블 4종(스키마를 Terraform이 소유, `deletion_protection`) (#280)
- BigQuery ↔ Vertex AI `CLOUD_RESOURCE` connection과 `roles/aiplatform.user` IAM (#280)
- GKE Standard private-node cluster, node pool, node/app service account, Workload Identity binding
- Airflow GCP 리소스: 전용 GCP SA/WI IAM, batch 전용 GCP SA, metadata DB, DAG/log bucket, BigQuery/GCS IAM
- Airflow 전용 GKE node pool(`airflow-dev`)과 batch KSA Workload Identity binding
- Airflow YouTube/OpenRouter API key용 Secret Manager secret metadata
- Airflow Kubernetes namespace/RBAC/NetworkPolicy는 `terraform/admin/airflow-k8s`에서 별도 state로 관리
- 일반 앱 namespace/KSA/NetworkPolicy는 `terraform/admin/autoresearch-k8s`에서 별도 state로 관리 (#129, apply·검증 완료)
- Autoresearch-airflow Cloud Build image push용 최소 IAM
- Cloud Run proxy state/code 정합성
- GKE 컨트롤 플레인 DNS 엔드포인트 — IAM 기반 kubectl 접속 (#45/#46)
- IAP 전용 bastion host(`bastion.tf`, 외부 IP 없음) (#47/#50)
- Airflow internal ILB 예약 내부 IP(`terraform output airflow_ilb_ip`)와 private DNS zone `dev.autoresearch.internal`(`dns.tf`) (#48/#51)
- Airflow Google OAuth client 자격증명용 Secret Manager secret metadata (#54/#55)
- Vault dev auto-unseal 잔여 구성(`vault.tf`, #132): 운영 경로는 #412에서 폐기됐고 코드·state·IAM 정리는 #478에서 진행
- Elasticsearch GCS snapshot 기반(`elastic.tf`): snapshot bucket, snapshot GSA + Workload Identity, bucket IAM (#102)
- GitHub Actions WIF pusher SA(`github_actions.tf`): GAR/app image push, Airflow deployer
  (#121/#157/#187), 환경별 Feast apply SA(#424)
- 코드 아카이브 배포 GCS 버킷 + 업로더 SA/WIF + 파드 read IAM(`code_artifacts.tf`, #238)
- MLflow artifact GCS 버킷의 immutable content-addressed training snapshot registry
  (`mlflow.tf`, `training-snapshots/`, #464)
- Auto Research 실험 결과 전용 GCS 버킷과 실험 Job Workload Identity
  (`experiment_jobs.tf`, 객체 생성 전용 권한)
- GitHub Actions plan용 bootstrap 리소스는 `terraform/bootstrap`에서 별도 관리

## 로컬 실행

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
scripts/terraform-env --environment dev --root terraform/envs/dev init
scripts/terraform-env --environment dev --root terraform/envs/dev validate
```

plan/apply를 실행할 때는 로컬 전용 변수 파일을 만듭니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
scripts/terraform-env --environment dev --root terraform/envs/dev plan
scripts/terraform-env --environment dev --root terraform/envs/dev apply
```

`terraform.tfvars`에는 실제 GCP project id가 들어갈 수 있으므로 커밋하지 않습니다.

## Terraform이 관리하는 주요 리소스

아래 표는 현재 Terraform 구성의 관리 대상을 요약합니다. #424의 환경별 Feast
apply 경계는 코드에 구성되었지만 이 변경에서 실제 GCP/Kubernetes apply나
`SKYAHO/Autoresearch` GitHub Environment 설정·검증을 수행하지 않았습니다.

| 영역 | 리소스 |
|---|---|
| Network | `autoresearch-dev-vpc`, `autoresearch-dev-subnet`, `autoresearch-dev-router`, `autoresearch-dev-nat` |
| Artifact Registry | `autoresearch-dev-docker` |
| Cloud SQL | `autoresearch-dev-pg`, DB `autoresearch`, user `app`, private IP `192.168.0.3` |
| GCS | raw data, prod Feast registry/staging, dev Feast registry/staging(`-dev`), Airflow DAG/log, `code-artifacts`, MLflow artifact/training snapshot, Auto Research 실험 결과 전용 bucket |
| BigQuery | `autoresearch_dev_analytics`, `feast_offline_store`, `feast_offline_store_dev` |
| BigQuery connection | `autoresearch-dev-vertex-ai` (`CLOUD_RESOURCE`, `asia-northeast3`, #280) |
| Secret Manager | `autoresearch-dev-db-password`, `autoresearch-dev-youtube-api-key`, `autoresearch-dev-openrouter-api-key`, `autoresearch-dev-airflow-oauth-client-id`, `autoresearch-dev-airflow-oauth-client-secret` |
| GKE | `autoresearch-dev-gke`, node pools `dev-default`, `airflow-dev`, 컨트롤 플레인 DNS 엔드포인트(#45/#46) |
| Bastion | `autoresearch-dev-bastion` (IAP 전용, 외부 IP 없음, #47/#50) |
| DNS/ILB | private DNS zone `dev.autoresearch.internal`, Airflow ILB 예약 내부 IP `terraform output airflow_ilb_ip` (#48/#51) |
| IAM | GKE node SA, app SA, Airflow SA, Airflow batch SA, 실험 Job SA, Cloud SQL/Secret/BigQuery/GCS/Workload Identity 권한 |
| KMS/Vault | key ring `vault`, crypto key `vault_unseal`, Vault GSA + unseal custom role (#132) |
| Elastic snapshot | ES snapshot GCS bucket, snapshot GSA + Workload Identity (#102) |
| CI pusher | GAR pusher SA, app image pusher SA, Airflow deployer SA, 코드 아카이브 업로더 SA, dev/prod Feast apply SA(WIF, #121/#157/#187/#238/#424) |

Issue #129의 `autoresearch-dev-redis-cluster`, 전용 PSC subnet/policy와
`terraform/admin/autoresearch-k8s`는 apply 완료됐고, #203/#204에서 Feast ↔ Redis
Cluster GKE 실연결·materialize까지 검증됐습니다.

## Airflow batch Feast materialize 권한 (#263)

Feast online store materialize DAG는 KubernetesPodOperator가 KSA
`airflow/autoresearch-batch`(GSA `autoresearch-dev-airflow-batch`)로 실행합니다.
BigQuery job/read session, Feast registry/staging bucket 권한은 기존에 있고, 이
이슈에서 다음 IAM 3개를 추가했습니다. 모두 프로젝트 전체가 아니라 리소스 단위
또는 IAM condition으로 제한합니다.

| 대상 | Role | 범위 | 용도 |
|---|---|---|---|
| `autoresearch-503903-code-artifacts` bucket | `roles/storage.objectViewer` | 버킷 단위 (`code_artifacts.tf`) | Feast 이미지 entrypoint가 `code/latest.txt`, `code/<sha>.tar.gz` 다운로드 |
| project (condition 제한) | `roles/redis.dbConnectionUser` | `projects/<project>/locations/asia-northeast3/clusters/autoresearch-dev-redis-cluster` 한정 (`redis.tf`) | Redis Cluster IAM 인증 토큰 발급 |
| `autoresearch-dev-redis-server-ca` secret | `roles/secretmanager.secretAccessor` | secret 단위 (`secret_manager.tf`) | TLS(`SERVER_AUTHENTICATION`) 검증용 CA 조회 |

기존 app GSA(`gke_app`)의 Redis/CA/코드 아카이브 권한은 변경하지 않았습니다.

## MLflow training snapshot registry (#464)

기존 MLflow artifact bucket을 재사용하며 새 bucket은 만들지 않습니다. 앱이 생성한
학습 CSV는 다음 canonical prefix에 SHA-256으로 주소화합니다.

```text
gs://<mlflow_artifacts_bucket>/training-snapshots/sha256=<64자리 hex>/training_dataset.csv
gs://<mlflow_artifacts_bucket>/training-snapshots/sha256=<64자리 hex>/snapshot_manifest.json
```

`airflow/autoresearch-batch`의 GSA에는 이 prefix에 한해 `objectCreator`와
`objectViewer`가 부여됩니다. creator 권한으로 기존 객체 overwrite를 막으므로
publisher는 generation `0` create-if-absent로 업로드하고, 재실행 시 기존 CSV를
읽어 SHA-256·generation을 검증한 뒤 재사용해야 합니다. 기본
`mlflow_training_snapshot_retention_days = 0`은 age 기반 자동 삭제를 비활성화하며,
bucket versioning과 기존 7일 soft delete가 복구층으로 유지됩니다.

## Feast apply 환경별 런타임 경계 (#424)

단일 `autoresearch-dev-feast-apply` GSA와 단일 `feast-apply` namespace 계약은
현재 구성에서 제거되었습니다. GitHub Environment부터 WIF provider, GSA,
데이터 좌표, namespace, KSA까지 다음 튜플을 함께 사용해야 합니다.

| 환경 | WIF provider | GSA | registry / staging / BQ | namespace / KSA | Redis / CA |
|---|---|---|---|---|---|
| `dev` | `github-feast-dev` | `autoresearch-dev-feast-dev@<project>.iam.gserviceaccount.com` | `gs://<project>-feast-registry-dev/registry.db` / `gs://<project>-feast-staging-dev/` / `feast_offline_store_dev` | `feast-apply-dev` / `feast-apply` | 권한 없음 |
| `prod` | `github-feast-prod` | `autoresearch-dev-feast-prod@<project>.iam.gserviceaccount.com` | `gs://<project>-feast-registry/registry.db` / `gs://<project>-feast-staging/` / `feast_offline_store` | `feast-apply-prod` / `feast-apply` | Redis 연결과 CA 조회 허용 |

두 GSA는 각 환경 GCS 버킷과 BigQuery dataset에만 Feast apply 권한을 가지며,
prod GSA에만 Redis `dbConnectionUser`와 Redis CA secret `secretAccessor`가
부여됩니다. 두 GSA의 공용 `code-artifacts` bucket `objectViewer`는 선택한
2-SA 모델에서 이미지 부트스트랩 코드를 읽기 위한 의도된 공유 권한입니다.
이 bucket은 Feast 환경 데이터 저장소 경계가 아닙니다.

환경 전용 WIF provider의 조건은
`SKYAHO/Autoresearch` repository, 정확한 `dev` 또는 `prod` Environment,
`feast-apply.yml@refs/heads/main` workflow ref를 AND로 함께 검사합니다. GSA의
Workload Identity User binding은 일치하는 `attribute.environment`
principalSet 하나만 사용합니다. IAM member 여러 개는 OR로 평가되므로 workflow
ref를 별도 member로 추가하면 안 됩니다. 기존 범용 `github` provider는
`attribute.environment`를 mapping하지 않아 이 GSA를 가장할 수 없습니다.

namespace·KSA·RBAC·NetworkPolicy는 `terraform/admin/autoresearch-k8s`가 환경별로
관리합니다. dev GSA는 `feast-apply-dev` namespace에만, prod GSA는
`feast-apply-prod` namespace에만 RoleBinding됩니다. Redis PSC discovery/data-node
egress는 prod NetworkPolicy에만 있습니다.

실제 GitHub Environment 변수, 적용 순서, 적용 후 검증과 롤백 계약은
`docs/TERRAFORM_DEV.md`의 "Feast apply 환경별 런타임 경계 (#424)" 절을
따릅니다.

## 기본 리전

dev 기본 리전은 `asia-northeast3`로 둡니다. 다른 리전을 사용할 경우 `region`, `zone` 변수를 변경합니다.
