# Paired Feast 실험 runtime 운영 계약

> 관련 이슈: #485
> 범위: dev 전용. 첫 적용 전 계약이며, 실제 Terraform apply와 Airflow Job 생성은 이 문서만으로 승인되지 않습니다.

## 현재 상태: Job 생성 fail-closed

`experiment_runtime_contract.job_creation_enabled`와
`experiment_runtime_kubernetes_contract.job_creation_enabled`의 현재 값은 모두
`false`입니다. Airflow는 두 output의 identity 좌표가 일치하는지 확인한 뒤에도,
이 값이 `false`이면 **Job manifest를 만들거나 Kubernetes API에 create 요청을 보내지
않고** 해당 실행을 중단해야 합니다. 관찰용 Airflow Role은 실제 in-cluster
`airflow/airflow` KSA 하나에만 Job/Pod의 get/list/watch 및 Pod log get을 허용하며,
그 observer KSA와 runtime KSA 모두 `jobs.create` 권한이 없습니다.

이 상태에서 Airflow가 전달받아 보관할 비시크릿 계약은 다음과 같습니다. 실제 버킷
이름·GSA email·프로젝트 값은 승인된 Terraform output에서만 읽으며, 문서나 DAG
설정에 복사하지 않습니다.

| 항목 | 계약 |
| --- | --- |
| Kubernetes 좌표 | admin output `experiment_runtime_kubernetes_contract`의 `namespace`와 `service_account` (기본값: `experiment-runtime` / `experiment-runtime`) |
| Airflow observer | 같은 admin output의 `airflow_observer_subject` (기본값: `ServiceAccount` `airflow/airflow`). `autoresearch-batch`와 `airflow-scheduler`에는 이 권한을 부여하지 않음 |
| dev registry/staging/artifact | 각 `experiment_runtime_contract`의 `*_experiments_uri`, 모두 `gs://<dev-bucket>/experiments/` root |
| comparison 경로 | `experiments/<comparison_id>/` 아래만 사용. IAM Conditions는 `experiments/` root까지만 강제하므로 `<comparison_id>`·condition·source SHA 형식 검증은 Airflow 고정 템플릿의 책임 |
| code archive | `CODE_ARCHIVE_SHA`를 검증한 뒤 `code/<CODE_ARCHIVE_SHA>.tar.gz`만 사용. 즉 output `code_archive_uri` 아래의 `gs://<bucket>/code/<sha>.tar.gz` 형식 |
| BigQuery | dev `feast_offline_store_dev` dataset만 PIT read. dataset ID는 output `feast_offline_store_dataset`에서 읽음 |

`code/` prefix의 조건부 `objectViewer`는 정확한 object name을 아는 GET에는 사용할 수
있지만, 조건 때문에 bucket-wide object LIST를 실행 경로로 가정해서는 안 됩니다.
Airflow는 `CODE_ARCHIVE_SHA`에서 결정한 정확한 `code/<sha>.tar.gz`만 GET하고 목록으로
archive를 탐색하거나 이를 위해 bucket-wide list 권한을 추가하지 않습니다.

Job 생성이 활성화되는 후속 변경에서만 immutable image digest, comparison ID,
condition, `CODE_ARCHIVE_SHA`, registry/result URI를 audit log에 남깁니다. token,
Secret payload, Terraform state, 실제 `.tfvars` 값은 로그·DAG 변수·문서에 남기지
않습니다.

## 활성화 전 apply 및 실행 승인 게이트

다음 항목은 `job_creation_enabled`를 `true`로 바꾸거나 실험 Job을 허용하기 전에
승인된 운영자가 확인할 게이트입니다. 하나라도 충족하지 않으면 Airflow trigger를
계속 중지하고 create 권한을 추가하지 않습니다.

1. dev/admin Terraform output의 namespace·KSA·GSA 및 fail-closed 값을 대조하고,
   ValidatingAdmissionPolicy가 전용 KSA, immutable image digest, restricted Pod
   사양을 강제하는지 검증합니다. 그 정책이 없으면 Job create를 활성화하지 않습니다.
2. runtime identity로 production Feast registry, production `feast_offline_store`
   BigQuery dataset, Redis server CA Secret에 각각 접근을 시도해 403 또는 동등한
   권한 거부가 나는지 확인합니다. 성공은 중대 차단 사유입니다.
3. `experiment-runtime` NetworkPolicy에 public/external HTTPS 목적지
   (`0.0.0.0/0:443`)가 없고 외부 HTTPS 연결이 실패하는지 확인합니다. 허용 경로는
   kube-dns, Workload Identity metadata 및 Private Google APIs
   `199.36.153.8/30:443`뿐입니다. Redis PSC, Cloud SQL, MLflow도 연결되면 안 됩니다.
4. live GKE node pool의 allocatable CPU·memory와 autoscaler 최대값이 namespace
   ResourceQuota(요청 4 vCPU/8 GiB, limit 8 vCPU/16 GiB, Job/Pod 각 4)를 실제로
   수용하는지 확인합니다. quota는 예약이나 autoscaler 증설 보장이 아닙니다.
5. 모든 PIT BigQuery query에 승인된 시간 범위의 partition filter와
   `maximum_bytes_billed`를 명시합니다. partition filter가 없거나 bytes 상한을
   넘는 query는 제출하지 않고 실패로 처리합니다.

## 후속 활성화 조건과 Job 수명

TTL·deadline은 현재 observer-only 경계를 풀기 위한 후속 활성화 조건입니다. 승인된
고정 Job 템플릿은 `activeDeadlineSeconds`, `backoffLimit=0`,
`ttlSecondsAfterFinished`를 명시해야 하며, ResourceQuota와 LimitRange를 우회하는
임의 Pod 사양을 Airflow가 제출해서는 안 됩니다. 이 문서의 현재 상태는 Job을
실행하거나 TTL 동작을 검증하는 단계가 아닙니다.

## 롤백

롤백은 먼저 Airflow의 해당 DAG/trigger를 중지해 새 Job 요청을 막는 것으로
시작합니다. 이어서 승인된 Terraform apply로 **이 변경에서 만든** runtime IAM,
`experiment-runtime` KSA와 namespace만 제거합니다. 기존 Airflow, Feast apply,
production registry·BigQuery dataset·Redis 및 기존 데이터는 롤백 대상이 아닙니다.
실제 apply/destroy, state 조작, secret 값 취급은 별도 사용자 승인이 필요합니다.
