# Airflow 운영 인프라 경계 구현 계획 (#32)

> **에이전트 작업자 안내:** 수정 전에 저장소 템플릿과 보안 가이드를 따릅니다. 실제
> 이메일, tfvars, state, plan, 자격 증명은 git에 넣지 않습니다.

**목표:** dev GKE 클러스터에 Airflow를 설치할 수 있도록 GCP 리소스와 Kubernetes
namespace 경계를 Terraform으로 구성한다.

**아키텍처:** PR review 반영 후 root를 분리한다. `terraform/envs/dev`는 GitHub
Actions PR plan 대상이므로 GCP 리소스만 관리한다. `terraform/admin/airflow-k8s`는
GKE API 접근이 필요한 Kubernetes 리소스만 관리하며, `master_authorized_networks`에
허용된 관리자 네트워크에서 수동 apply한다.

**기술 스택:** Terraform, Google provider, Kubernetes provider(admin root only),
GKE, Cloud SQL, GCS, BigQuery, Workload Identity, Kubernetes RBAC/NetworkPolicy.

## 전역 제약

- 커밋/PR/이슈는 저장소 템플릿을 따른다.
- 모든 인프라 변경은 관련 `.md` 문서를 같이 갱신한다.
- 보안 우선: JSON key 발급 금지, real `terraform.tfvars` 커밋 금지, bucket/project
  전체 권한 지양.
- `terraform/envs/dev`에는 Kubernetes provider를 두지 않는다. CI runner가 GKE API
  서버 허용 CIDR에 없기 때문이다.
- Airflow KSA annotation key는 `iam.gke.io/gcp-service-account`를 사용한다.
- GKE metadata server egress는 `169.254.169.254/32` TCP 80을 허용한다.
- raw_data bucket은 `objectViewer` + `objectCreator`만 허용하고 `objectAdmin`은 주지
  않는다.
- Airflow API secret payload는 Terraform으로 관리하지 않는다. Terraform은 secret
  metadata와 Airflow SA/batch SA accessor만 관리한다.

## 파일 구조

| 파일 | 책임 | 상태 |
|---|---|---|
| `terraform/envs/dev/airflow.tf` | Airflow GCP SA/WI IAM, Cloud SQL DB, GCS, BigQuery IAM | 수정 |
| `terraform/envs/dev/versions.tf` | dev root provider 목록. Kubernetes provider 없음 | 수정 |
| `terraform/envs/dev/outputs.tf` | Airflow GCP 출력 | 수정 |
| `terraform/admin/airflow-k8s/` | Airflow namespace/RBAC/Quota/LimitRange/NetworkPolicy | 신규 |
| `docs/TERRAFORM_DEV.md` | 운영 runbook과 root 분리 설명 | 수정 |
| `docs/superpowers/specs/2026-07-08-airflow-namespace-rbac-design.md` | 설계 최신화 | 수정 |

## 작업 1: dev root GCP 리소스 정리

- [x] Airflow GCP service account 생성
- [x] Workload Identity IAM member 생성
- [x] Cloud SQL `airflow` database 생성
- [x] Airflow API key Secret Manager metadata 보존
- [x] Airflow API key accessor를 전용 Airflow SA와 batch SA로 축소
- [x] DAG/log GCS bucket 생성 및 `prevent_destroy` 적용
- [x] Airflow SA에 DAG/log bucket-scoped `roles/storage.objectAdmin` 부여
- [x] raw_data bucket 권한을 `roles/storage.objectViewer` +
      `roles/storage.objectCreator`로 제한
- [x] Feast registry/staging bucket은 registry 갱신과 임시 파일 삭제가 필요하므로
      bucket-scoped `roles/storage.objectAdmin` 유지
- [x] BigQuery `feast_offline_store` dataset `roles/bigquery.dataEditor`와 project-level
      `roles/bigquery.jobUser` 부여
- [x] dev root에서 Kubernetes provider와 data source 제거
- [x] 후속 #62에서 batch KSA용 전용 GSA를 만들고 app GSA의 Airflow API key
      accessor를 제거

## 작업 2: admin root K8s 리소스 추가

- [x] `terraform/admin/airflow-k8s` root 추가
- [x] 별도 GCS backend prefix `admin/airflow-k8s/` 사용
- [x] 기존 dev GKE cluster를 data source로 조회
- [x] `airflow` namespace 생성
- [x] KSA `airflow` 생성 및 `iam.gke.io/gcp-service-account` annotation 적용
- [x] Airflow component Role/RoleBinding 생성
- [x] 설치 담당자용 namespace-scoped `admin` RoleBinding 생성
- [x] ResourceQuota와 LimitRange 생성
- [x] NetworkPolicy ingress: 같은 namespace + `kube-system`
- [x] NetworkPolicy egress: DNS 53, Cloud SQL private CIDR 5432,
      metadata server `169.254.169.254:80`, HTTPS 443

## 작업 3: 문서와 리뷰 반영

- [x] `docs/TERRAFORM_DEV.md`에 두 root 운영 절차 추가
- [x] design spec을 root 분리 구조로 갱신
- [x] plan 문서를 최신 구현 기준으로 갱신
- [x] PR review thread별 답변 준비
  - WI annotation 오타 수정
  - dev root에서 K8s provider 제거해 CI/GKE API 접근 문제 해결
  - metadata server egress 추가
  - raw_data 권한 최소화

## 검증 명령

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/admin/airflow-k8s fmt -check -recursive
terraform -chdir=terraform/admin/airflow-k8s validate
git diff --check
```

실제 apply 순서:

```bash
terraform -chdir=terraform/envs/dev apply
terraform -chdir=terraform/admin/airflow-k8s apply
```

`terraform/admin/airflow-k8s/terraform.tfvars`에는 실제 팀원 이메일과 CIDR을 넣지만
커밋하지 않는다.

## Apply 결과

- `terraform/envs/dev apply`: `16 added, 0 changed, 7 destroyed`
  - Airflow GCP SA/IAM, metadata DB, DAG/log bucket, BigQuery/GCS/Secret 권한 생성
  - legacy Cloud Build default compute SA 권한, legacy `airflow-dev` node pool,
    legacy Airflow batch WI, 기존 app SA의 Airflow API secret accessor 정리
- 이후 #43에서 Airflow GKE runtime drift를 코드화하고 state/import를 맞췄다.
- `terraform/admin/airflow-k8s apply`: 기존 `airflow` namespace가 있어 최초 apply가
  namespace already exists로 중단됨
  - 삭제/재생성 대신 `terraform import kubernetes_namespace_v1.airflow airflow`로
    기존 namespace를 state에 편입
  - 재실행 결과: `11 added, 1 changed, 0 destroyed`
- 최종 검증: `terraform/envs/dev`와 `terraform/admin/airflow-k8s` 모두 `No changes`

## 롤백

1. admin root에서 Kubernetes 리소스를 제거 후 apply한다.
2. dev root에서 GCP 리소스를 제거 후 apply한다.
3. DAG/log bucket은 `prevent_destroy`가 있으므로 삭제가 필요한 경우 별도 변경과
   승인 절차를 거친다.
