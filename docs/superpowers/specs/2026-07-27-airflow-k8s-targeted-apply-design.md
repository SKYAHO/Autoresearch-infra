# Airflow Kubernetes Targeted Apply Design (#387)

> 작성: 2026-07-27 | 상태: 승인됨
> 연계: #373, Autoresearch-airflow#159

## 목표

`terraform/admin/airflow-k8s`의 VPA RBAC 변경을 다른 admin root와 분리해,
plan 요약과 Environment 승인 뒤에만 적용한다.

## 설계

새 `airflow-k8s-apply.yml`은 `workflow_dispatch`만 허용한다. 기존
`admin-apply.yml`과 같은 OIDC/WIF, private GCS plan binary, GitHub Secret 변수
주입 패턴을 쓰되 `terraform/admin/airflow-k8s` root만 plan/apply한다. apply job은
`airflow-k8s-apply` Environment의 required reviewer 승인을 받고 plan job이 만든
동일한 binary plan만 적용한다.

기존 8-root `admin-apply.yml`, 다른 root의 state, GCP IAM, Secret payload는
변경하지 않는다. `AIRFLOW_INSTALLER_USER_EMAILS` Secret만 기존과 동일하게
주입한다.

## 적용 순서

1. #373 VPA RBAC 변경을 병합한다.
2. 운영자가 `airflow-k8s-apply.yml`을 dispatch해 plan 요약을 검토한다.
3. `airflow-k8s-apply` Environment reviewer가 승인한다.
4. apply 성공 뒤 Airflow deploy workflow WIF preflight가 VPA lifecycle 권한을 확인한다.
5. 이후에만 GKE VPA addon `dev-apply`를 진행한다.

## 비목표

- 기존 `admin-apply.yml`의 다중 root 동작 변경
- GKE VPA addon 또는 Airflow Helm manifest 적용
- local Terraform apply 경로 추가
- cluster-wide RBAC 또는 GCP IAM 권한 확대

## 검증과 롤백

workflow YAML은 actionlint와 `git diff --check`로 검증한다. plan summary가
`airflow-k8s` root만 가리키고 apply가 승인 전 실행되지 않는지 확인한다. 문제 시
workflow 파일을 되돌리고, 적용된 VPA Role/RoleBinding은 같은 승인 workflow로 제거한다.
