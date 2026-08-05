# dev Terraform State Drift 정리 설계

## 배경

이슈 #39는 `terraform/envs/dev` plan에 나타난 현재 구성과 무관한 변경을
추적합니다. PR #34에서 사람 GKE 접근 IAM을 `terraform/admin/gke-team-access`로
옮긴 뒤에도, dev root는 현재 구성에 없는 변경을 계속 계획했습니다.

확인된 drift:

- `google_artifact_registry_repository_iam_member.cloud_build_compute_ar_writer`
- `google_project_iam_member.cloud_build_compute_logging`
- `google_storage_bucket_iam_member.cloud_build_compute_bucket_object_viewer`
- `google_container_node_pool.airflow`
- `google_service_account_iam_member.gke_app_airflow_batch_wi`
- 현재 관리 입력값에는 없는 추가 GKE `master_authorized_networks` CIDR
  (`<unmanaged-extra-operator-ip>/32`)

## 결정

위 리소스는 dev root로 복원할 대상이 아니라 정리할 대상으로 간주합니다.

근거:

- `main`에는 대응되는 Terraform 구성이 없습니다.
- Git 기록에서도 이 리소스들이 의도적으로 머지된 설계였다는 근거가 없습니다.
- Cloud Build IAM binding은 현재 workflow 소유자가 없는 상태에서 기본 compute
  service account에 write/logging/bucket 권한을 부여합니다.
- 정리 전 소유자 확인 결과:
  - `.github/`, `terraform/`, `docs/`에서 Cloud Build trigger, Cloud Deploy
    pipeline, 기본 compute service account 소유자를 찾지 못했습니다.
  - `gcloud builds triggers list --project ar-infra-501607` 결과 trigger가
    없었습니다.
  - `ar-infra-501607`에서 Cloud Deploy API가 비활성화되어 있어, 현재 Cloud Deploy
    delivery pipeline이 제거 대상 기본 compute service account binding에 의존할 수
    없습니다.
  - GKE node는 프로젝트 기본 compute service account가 아니라 전용
    `autoresearch-dev-gke-nodes` service account를 사용합니다.
- `airflow-dev` node pool은 지속적인 GKE 비용을 만들며, #32 방향성인 Airflow 설치
  경계 구성으로 대체되었습니다.
- `gke_app_airflow_batch_wi` binding은 Airflow namespace principal이 애플리케이션
  GCP service account를 가장하게 합니다. #32에서는 대신 전용 Airflow service
  account를 사용합니다.
- `MASTER_AUTHORIZED_NETWORKS`는 현재 관리되는 운영자 CIDR
  (`<managed-operator-ip>/32`)만 포함하며, 추가
  `<unmanaged-extra-operator-ip>/32` 항목은 관리되지 않는 네트워크 접근입니다.
- 추가 CIDR의 정확한 출처는 Terraform state만으로 증명할 수 없습니다. 이전 로컬
  tfvars apply나 콘솔 수동 편집에서 왔을 수 있습니다. 정리 기준은 해당 CIDR이 현재
  관리 입력값에 없고 문서화된 소유자도 없다는 점입니다.

## 보안 메모

- state만 제거하지 않습니다. 관리되지 않는 IAM grant나 node pool을 GCP에 남기면
  Terraform에서 보안·비용 노출이 숨겨집니다.
- drift 정리에만 한정한 Terraform plan/apply를 사용합니다. 무관한 리소스 변경과
  섞지 않습니다.
- 로컬 tfvars나 plan output에 있는 실제 운영자 IP를 커밋하지 않습니다. 문서와 PR
  본문에는 placeholder를 사용합니다.
- 최종 full `terraform/envs/dev plan`에 무관한 destroy 또는 replace action이 더
  이상 없는지 확인합니다.

## 롤백

나중에 정리한 항목이 다시 필요하다고 확인되면:

- Cloud Build AR writer: 명시적으로 범위를 좁힌 repository IAM member를
  Terraform에 다시 추가하고 apply합니다.
- Cloud Build logging: Cloud Build workflow 소유자가 문서화된 경우에만 프로젝트
  수준 `roles/logging.logWriter`를 다시 추가합니다.
- Cloud Build bucket viewer: 기본 Cloud Build bucket이 여전히 필요할 때만 bucket
  수준 object viewer를 다시 추가합니다.
- `airflow-dev` node pool: 전용 Terraform 리소스 또는 향후 #32 Airflow 경로로 node
  pool을 다시 만듭니다.
- `gke_app_airflow_batch_wi`: #32의 전용 Airflow GCP service account를 우선합니다.
  문서화된 필요가 있을 때만 app SA impersonation을 다시 부여합니다.
- 추가 master authorized network: `MASTER_AUTHORIZED_NETWORKS`/로컬 tfvars로 CIDR을
  다시 추가하고 소유자를 문서화합니다.
