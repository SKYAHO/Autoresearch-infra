# Airflow 스케줄러 KSA Workload Identity 바인딩 추가 구현 계획

> **For agentic workers:** 소규모 IAM 단건 변경으로 스레드 내 진행. 체크박스로
> 진행을 추적한다.
>
> Issue: #240 (관련: Autoresearch-airflow PR #74 — `google_cloud_default`
> connection 주입)

**목표:** `lake_to_bigquery_incremental` DAG가 스케줄러 파드 안에서 직접
실행하는 Google provider 오퍼레이터(GCS 센서, BigQuery load/query job)가
Workload Identity ADC로 `autoresearch-dev-airflow@` GSA 권한을 얻게 한다.

**아키텍처 결정:** 스케줄러 KSA(`airflow/airflow-scheduler`)는 Airflow Helm
chart가 생성하므로, KSA annotation(`iam.gke.io/gcp-service-account`)은
Autoresearch-airflow 저장소 Helm values(`scheduler.serviceAccount.annotations`)
에서 관리한다. Terraform이 Helm 소유 리소스에 annotation을 주입하면 필드
소유권 충돌(helm upgrade 시 되돌림) 위험이 있다. 이 저장소는 GCP 측
바인딩(GSA의 `roles/iam.workloadIdentityUser` 멤버)만 소유한다 — 기존
`airflow`/`autoresearch-batch` KSA 바인딩과 동일한 경계.

---

## Task 1: Terraform 변경 (envs/dev)

- [x] `variables.tf`: `airflow_scheduler_k8s_service_account`
  (default `"airflow-scheduler"`) 추가.
- [x] `locals.tf`: `airflow_scheduler_workload_identity_principal` 추가.
- [x] `airflow.tf`: `google_service_account_iam_member.airflow_scheduler_wi`
  추가 — `google_service_account.airflow`에
  `roles/iam.workloadIdentityUser`, member
  `serviceAccount:ar-infra-501607.svc.id.goog[airflow/airflow-scheduler]`.
- [x] `outputs.tf`: `airflow_scheduler_workload_identity_principal` output 추가.

## Task 2: 권한 전제 확인 (이슈 3번 항목)

- [x] GSA `autoresearch-dev-airflow@`의 raw-data 버킷 읽기 권한은 이미
  Terraform이 관리 중임을 확인 — `airflow.tf`의 `airflow_raw_data_viewer`
  (`roles/storage.objectViewer`) + `airflow_raw_data_creator`
  (`roles/storage.objectCreator`). BigQuery는 이슈에서 확인 완료
  (`roles/bigquery.jobUser` + `feast_offline_store` WRITER).

## Task 3: 문서 갱신

- [x] `docs/TERRAFORM_DEV.md`: GKE 요약 표에 scheduler WI principal 행 추가,
  Airflow Helm values 가이드에 `scheduler.serviceAccount.annotations` 예시 추가.
- [x] 이 plan 문서 작성.

## Task 4: 검증

- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- [x] `terraform -chdir=terraform/envs/dev validate`
- [x] `git diff --check`
- [ ] merge 후 apply(사용자 승인 필요) → 이슈의 완료 확인 방법 수행:
  KSA annotation 확인(Airflow 저장소 values 반영 후), 파드 내 metadata
  서버가 GSA 이메일을 반환하는지 확인, DAG 수동 트리거로 센서 poke 확인.

## 롤백

`airflow_scheduler_wi` 리소스 제거 후 apply — 단건 IAM 멤버 삭제로 다른
리소스에 영향 없음. Helm values annotation은 Airflow 저장소에서 별도 롤백.

## 비용/보안 영향

- 비용: 없음 (IAM 바인딩).
- 보안: 신규 GSA·role 부여 없음. 기존 `airflow` GSA를 가장할 수 있는 KSA가
  `airflow/airflow` 1개에서 `airflow/airflow-scheduler` 포함 2개로 확대.
  스케줄러는 이미 DAG 코드를 실행하는 신뢰 경계 내 컴포넌트로, 권한 상승이
  아니라 동일 경계 내 정합화다.
