# Airflow GKE Runtime Drift 설계

- 이슈: [#32 [FEAT] Airflow 설치용 Kubernetes namespace 및 RBAC 경계 구성](https://github.com/SKYAHO/Autoresearch-infra/issues/32)
- 작성일: 2026-07-08
- 대상: `ar-infra-501607` dev GKE(`autoresearch-dev-gke`, `asia-northeast3-a`)

## 1. 목적

Airflow 배포 과정에서 live GCP/GKE에 추가된 런타임 변경사항을
Terraform과 운영 문서에 반영해, 다음 `terraform apply` 때 의도하지 않은
drift가 발생하지 않도록 한다. 우선순위는 Airflow dev 배포 재현성과 최소
권한 유지다.

## 2. Live Drift 분류

| 항목 | 분류 | 결정 |
|---|---|---|
| GKE node pool `airflow-dev` | 코드화 | Airflow Helm component 전용 capacity로 Terraform 관리 |
| `dev-default` node pool autoscaling max `2 -> 3` | 원복 | Airflow 전용 node pool이 생겼으므로 기존 `max=2` 유지 |
| `dev-default` node pool machine `e2-small -> e2-standard-4` | 코드화 | live resize가 적용되어 있고 system/GMP pod가 기본 pool에 배치되어 다음 apply의 downsize 방지 |
| `master_authorized_networks` 개인 IP 추가 | 문서화 | 개인/임시 접근 값은 `terraform.tfvars`에서 운영 |
| `cloudbuild.googleapis.com` 활성화 | 문서화 | API 수동 활성화 정책 유지, required services/docs에 추가 |
| Cloud Build compute SA Artifact Registry writer | 코드화 | Airflow 이미지 build/push 재현에 필요 |
| Cloud Build compute SA Cloud Build bucket objectViewer | 코드화 | Cloud Build staging bucket 조회 권한을 bucket 단위로 관리 |
| Cloud Build compute SA project logging.logWriter | 코드화 | build log 기록에 필요 |
| GSA `autoresearch-dev-app` WI member `airflow/autoresearch-batch` | 코드화 | Airflow KPO batch pod가 GCS/BigQuery 권한을 사용 |
| Kubernetes namespace `airflow` | 문서화 | Terraform CI plan이 GKE API 네트워크 접근에 묶이지 않도록 runbook/Helm 전 단계로 관리 |
| Kubernetes serviceaccount `airflow/autoresearch-batch` | 문서화 | KSA manifest는 Airflow 배포 절차에서 적용, GCP-side IAM만 Terraform 관리 |
| Kubernetes Secret `airflow/autoresearch-airflow-env` | 부분 코드화 + 문서화 | Secret Manager secret metadata/IAM은 Terraform, secret payload와 K8s Secret materialization은 runbook으로 관리 |

## 2.1 추가 발견 리스크

2026-07-08 실제 remote state plan 중 Airflow 범위 밖 불일치가 확인됐다.
remote state에는 `google_cloud_run_v2_service.proxy`,
`google_service_account.proxy`, `google_project_iam_member.gke_kubectl_users`
리소스가 있으나 현재 main 구성에는 없어, full apply 시 Cloud Run proxy와
kubectl 사용자 IAM binding destroy가 계획됐다.

이 리스크는 같은 브랜치에서 `cloud_run.tf`와 `gke_access.tf`를 재도입해
해소했다. 2026-07-08 재확인 중 live에 이미 존재하던 Airflow node pool,
Airflow Workload Identity, Cloud Build IAM, kubectl 사용자 IAM binding이
state에 빠져 있음을 발견했고 모두 remote state에 import했다. 이후 남은
변경은 Airflow API key Secret Manager metadata/IAM `4 added, 0 changed,
0 destroyed`였으며 apply 완료했다. 후속 plan은 `No changes`로 종료됐다.

## 3. Terraform 설계

### Airflow 전용 Node Pool

- 리소스: `google_container_node_pool.airflow`
- 이름: `airflow-dev`
- cluster/location: 기존 `google_container_cluster.dev`, `var.zone`
- machine: `e2-standard-2`
- autoscaling: min `1`, max `1`
- disk: `30GB`, `pd-standard`
- service account: 기존 GKE node SA
- workload metadata: `GKE_METADATA`
- lifecycle: `node_count` ignore

기존 `dev-default`는 애플리케이션 기본 워크로드용으로 유지한다. live에서
임시로 올린 max=3은 전용 node pool 도입 후 불필요하므로 Terraform 값
`var.gke_node_count_max = 2`로 원복한다.

### Workload Identity

기존 app GSA(`autoresearch-dev-app`)는 raw GCS, BigQuery, Feast 권한을
가지고 있다. Airflow KPO batch pod가 같은 권한을 사용해야 하므로,
GSA IAM binding에 아래 member를 추가한다.

```text
serviceAccount:ar-infra-501607.svc.id.goog[airflow/autoresearch-batch]
```

Kubernetes namespace/KSA 자체는 Terraform에서 직접 관리하지 않는다. 현재
CI Terraform plan은 외부 GitHub Actions에서 실행될 수 있고, GKE master
authorized networks에 의해 Kubernetes API 접근이 제한될 수 있기 때문이다.
따라서 KSA manifest는 Airflow 배포 runbook에서 관리하고, GCP-side
impersonation 권한만 Terraform state에 둔다.

### Cloud Build

Autoresearch-airflow의 Cloud Build가 dev Artifact Registry에 이미지를
push하려면 Compute default SA에 아래 권한이 필요하다.

- `roles/artifactregistry.writer`: `autoresearch-dev-docker` repository
- `roles/storage.objectViewer`: `gs://ar-infra-501607_cloudbuild`
- `roles/logging.logWriter`: project

`cloudbuild.googleapis.com` API는 기존 정책대로 Terraform 리소스로 enable하지
않고, required service 목록과 문서에 기록한다.

### Airflow API key Secret

운영 DAG smoke에서 `autoresearch-airflow-env` Kubernetes Secret의
`YOUTUBE_API_KEYS`, `YOUTUBE_API_KEY`, `OPENROUTER_API_KEY` 값이 비어 있으면
KPO pod가 실제 YouTube API/OpenRouter 호출 전에 실패한다는 점이 확인됐다.
다만 secret payload를 Terraform으로 관리하면 `google_secret_manager_secret_version`
값이 state에 저장될 수 있으므로 payload는 Terraform 범위에서 제외한다.

Terraform은 아래 Secret Manager secret metadata와 resource-level IAM만
관리한다.

- `autoresearch-dev-youtube-api-key`
- `autoresearch-dev-openrouter-api-key`
- `autoresearch-dev-app` GSA의 각 secret `roles/secretmanager.secretAccessor`

Kubernetes Secret `autoresearch-airflow-env`는 Airflow 배포 runbook에서
Secret Manager latest version을 읽어 materialize한다.

## 4. 운영 문서

`docs/TERRAFORM_DEV.md`에 다음을 반영한다.

- Airflow node pool 구성과 Helm chart/release 정보
- `airflow` namespace와 `autoresearch-batch` KSA 사전 준비 절차
- YouTube/OpenRouter API key Secret Manager와 K8s Secret 동기화 절차
- Helm upgrade 재현 명령
- DAG smoke 전 GCS 입력 확인 경로
- 개인 IP `master_authorized_networks`는 tfvars 운영 값임을 명시

## 5. 검증 기준

- `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- `terraform -chdir=terraform/envs/dev init -backend=false`
- `terraform -chdir=terraform/envs/dev validate`
- 가능하면 `terraform -chdir=terraform/envs/dev plan`
- plan에서 Airflow 범위 밖 destroy가 있으면 apply 금지 및 별도 이슈/PR로 분리
- `git diff --check`
- GCS 입력 확인:
  - `data_lake/youtube_trending_kr/dt=<date>/part-0.parquet`
  - `asset/virtual_user/vu_1000.parquet`
- 입력이 있으면 Airflow DAG smoke trigger 후 task 성공 확인
