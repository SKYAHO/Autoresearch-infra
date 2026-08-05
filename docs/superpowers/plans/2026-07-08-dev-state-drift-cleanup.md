# dev Terraform State Drift 정리 계획

## 이슈

Closes #39.

## 범위

- drift 리소스를 유지할지 삭제할지 결정합니다.
- 보안·롤백 근거를 문서화합니다.
- drift 정리 대상만 apply합니다.
- 전체 dev Terraform plan에 무관한 destroy action이 더 이상 없는지 확인합니다.

## 대상 정리

Terraform target:

- `google_artifact_registry_repository_iam_member.cloud_build_compute_ar_writer`
- `google_project_iam_member.cloud_build_compute_logging`
- `google_storage_bucket_iam_member.cloud_build_compute_bucket_object_viewer`
- `google_container_node_pool.airflow`
- `google_service_account_iam_member.gke_app_airflow_batch_wi`
- `google_container_cluster.dev`

예상 plan:

- `5 destroy`
- `1 update in-place`
- `0 add`

## Apply 결과

- 대상 정리 plan 검토 결과: `0 add`, `1 change`, `5 destroy`.
- drift IAM binding, legacy `airflow-dev` node pool, legacy Airflow Workload
  Identity binding, 관리되지 않는 GKE master authorized network CIDR 정리 apply를
  완료했습니다.
- 후속 full apply는 오래된 Terraform output 변경만 state에 저장했으며 `0 added`,
  `0 changed`, `0 destroyed`였습니다.
- 최종 full plan 결과: `No changes. Your infrastructure matches the configuration.`

## 검증 체크리스트

- [x] apply 전 대상 plan 검토
- [x] 대상 apply 완료
- [x] 전체 `terraform -chdir=terraform/envs/dev plan -no-color -input=false`에
      무관한 destroy/replace action 없음
- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive -no-color` 통과
- [x] `git diff --check` 통과
- [x] secret, state, plan, 실제 tfvars 값 커밋 없음
