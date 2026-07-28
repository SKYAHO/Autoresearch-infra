# Airflow Kubernetes Targeted Apply Design (#387)

> 작성: 2026-07-27 | 상태: 승인됨
> 연계: #373, Autoresearch-airflow#159

## 목표

`terraform/admin/airflow-k8s`의 VPA RBAC 변경을 다른 admin root와 분리해,
plan 요약과 Environment 승인 뒤에만 적용한다.

## 설계

새 `.github/workflows/airflow-k8s-apply.yml`은 `workflow_dispatch`만 허용한다. 기존
보안 메커니즘과 같은 OIDC/WIF, private GCS plan binary, GitHub Secret 변수 주입 패턴을
쓰되 `terraform/admin/airflow-k8s` root만 plan/apply한다. 기존 admin apply SA의 WIF
principalSet은 `admin-apply.yml@refs/heads/main` 및
`airflow-k8s-apply.yml@refs/heads/main` 두 정확한 workflow ref만 허용하며 wildcard나
repo 단위 ref는 허용하지 않는다. apply job은 `airflow-k8s-apply` Environment의
required reviewer 승인을 받고 plan job이 만든 동일한 binary plan만 적용한다. 새 plan
job은 시작 시 `airflow-k8s-apply-plans/**`만 정리해 미승인 run의 stale plan을 제거한다.

운영자는 workflow dispatch 전에 required reviewers가 설정된 GitHub Environment
`airflow-k8s-apply`를 반드시 생성해야 한다. workflow YAML의 `environment:` 선언은 이미
존재하는 Environment를 선택할 뿐, Environment 또는 그 protection을 생성할 수 없다.

기존 8-root `admin-apply.yml`, 다른 root의 state, admin apply SA의 기존 역할,
Secret payload는 변경하지 않는다. 새 workflow ref의 최소 WIF principalSet member와
`AIRFLOW_INSTALLER_USER_EMAILS` Secret만 기존과 동일하게 사용한다.

## 적용 순서

1. #387을 병합한 뒤, 명시적으로 승인된 첫 `dev-apply`가 정확한
   `airflow-k8s-apply.yml@refs/heads/main` WIF allowlist와 observation-only GKE VPA
   addon을 함께 적용한다. VPA CR이 없으면 addon은 scheduler Pod를 변경하지 않는다.
2. GKE operation 완료를 확인한 뒤 운영자가 `airflow-k8s-apply.yml`을 dispatch해
   `airflow-k8s` RBAC plan 요약을 검토하고, `airflow-k8s-apply` Environment reviewer가
   승인한다.
3. apply 성공 뒤 CRD 생성·Established·served VPA API와 Helm deployer/installer의 VPA
   lifecycle RBAC evidence를 모두 확인한다.
4. 이 evidence가 갖춰진 뒤에만 Autoresearch-airflow가 scheduler VPA CR을 배포한다.

## 비목표

- 기존 `admin-apply.yml`의 다중 root 동작 변경
- GKE VPA addon 또는 Airflow Helm manifest 정의 변경
- local Terraform apply 경로 추가
- cluster-wide RBAC 또는 GCP IAM 권한 확대

## 검증과 롤백

workflow YAML은 actionlint와 `git diff --check`로 검증한다. plan summary가
`airflow-k8s` root만 가리키고 apply가 승인 전 실행되지 않는지 확인한다. 문제 시
workflow 파일을 되돌리고, 적용된 VPA Role/RoleBinding은 같은 승인 workflow로 제거한다.
