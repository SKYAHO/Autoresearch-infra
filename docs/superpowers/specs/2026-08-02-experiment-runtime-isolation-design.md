# 실험 runtime dev Feast IAM·격리 실행 경계 설계

> 관련 이슈: #485
> 상태: 설계 승인됨, 구현 계획 작성 전 사용자 검토 대기

## 목적

Airflow가 실행하는 paired Feast 실험을 기존 Airflow 일반 배치, production Feast 및
#484 API 주도 실험 Job과 분리한다. 이 첫 변경은 실험 runtime이 dev Feast 좌표와
자기 실험 결과에만 접근하도록 KSA/GSA, Kubernetes namespace, GCS IAM, BigQuery IAM,
NetworkPolicy 및 실행 한도를 제공한다.

BigQuery source feature schema·backfill과 promotion evidence는 독립된 데이터 변경 및
보존 정책 결정을 요구하므로 후속 이슈·PR로 분리한다. 이 변경은 Terraform apply,
schema migration, 실제 backfill, production Redis materialize를 수행하지 않는다.

## 현재 문제

- `airflow_batch` GSA는 일반 Airflow 배치와 Feast apply의 실행 경로에 사용된다.
  이 GSA에 실험 권한을 추가하면 workload별 권한 회수·감사·사고 격리가 불가능하다.
- dev/prod Feast apply는 GSA·namespace·KSA·registry/staging·Redis egress를 환경별로
  분리했지만, paired 실험에는 comparison·condition·source SHA 별 객체 경계와
  Airflow 전용 Job RBAC가 필요하다.
- `feast_offline_store_dev`의 실험 PIT 조회에는 BigQuery Job 생성과 dataset 읽기가
  필요하지만, production dataset과 source schema 변경 권한은 필요하지 않다.
- Redis PSC egress와 Redis CA Secret accessor를 누락하는 것만으로는 충분하지 않다.
  별도 GSA, namespace, KSA와 default-deny NetworkPolicy를 함께 사용해야 한다.

## 결정

### 전용 runtime identity와 Kubernetes 경계

`experiment-runtime` namespace, `experiment-runtime` KSA,
`autoresearch-dev-experiment-runtime` GSA를 새로 정의한다. GSA account ID는 GCP의
6~30자 제한을 만족하도록 `resource_prefix`에서 파생하고, namespace/KSA/GSA는
Terraform output 하나에서 함께 공개한다.

namespace에는 `restricted` Pod Security Admission enforce/audit/warn label을 적용한다.
Airflow의 기존 GSA만 이 namespace에서 `batch/jobs`의 get/list/watch/create/delete 및
실패 분석에 필요한 pod/pod-log read 권한을 갖는다. 실험 KSA에는 Kubernetes RBAC를
부여하지 않는다. Role은 secrets, exec, attach, port-forward, update, patch 및
cluster-scoped resource를 포함하지 않는다.

ResourceQuota는 Job·Pod 동시 개수를 각각 4개로, 요청 합계를 2 vCPU/4 GiB로,
limit 합계를 4 vCPU/8 GiB로 제한한다. LimitRange는 컨테이너별 request 250m/512Mi,
limit 2 vCPU/4 GiB를 기본값 및 상한으로 한다. 각 Job manifest는
`activeDeadlineSeconds`, `backoffLimit=0`, `ttlSecondsAfterFinished`를 명시해야 하며,
Airflow는 고정 템플릿 외 임의 Pod 사양을 제출하지 않는다.

모든 ingress는 차단한다. egress는 kube-dns, Workload Identity metadata server,
Private Google APIs HTTPS에만 허용한다. Redis PSC CIDR, Cloud SQL private CIDR,
MLflow Service, 외부 인터넷 목적지는 허용하지 않는다.

### GCS 최소권한과 객체 계약

새 실험 artifact 버킷을 만들지 않는다. 첫 PR의 결과는 기존 MLflow artifact bucket의
`experiments/` prefix에 한정한다. 이 버킷은 이미 public access prevention과 uniform
bucket-level access를 적용하므로, 새 IAM binding은 조건식으로 object name을 좁힌다.

실험 GSA에는 다음 권한만 부여한다.

| 대상 | 권한 | IAM 조건 |
| --- | --- | --- |
| dev registry bucket | object viewer | `experiments/` registry root 아래의 실험 registry 객체만 읽기 |
| dev staging bucket | object creator/viewer | `experiments/` prefix의 자기 실험 staging 객체만 생성·조회 |
| code artifacts bucket | object viewer | `code/<source_sha>.tar.gz`만 읽기 |
| MLflow artifact bucket | object creator/viewer | `experiments/` 결과 prefix만 생성·조회 |

GCS IAM Conditions는 comparison ID 또는 source SHA처럼 요청마다 바뀌는 값을 IAM에
직접 주입할 수 없으므로, 첫 PR에서는 `experiments/` 루트까지를 Terraform 경계로
강제한다. comparison/condition/source SHA 세분화는 Airflow의 고정 Job 템플릿과
사전 검증으로 강제하며, 요청 단위 IAM binding 생성은 하지 않는다. 이 제약과 검증
책임은 runbook에 명시한다.

`roles/storage.objectCreator`는 기존 객체 overwrite를 막지만, create precondition을
대신하지 않는다. application/Airflow는 `ifGenerationMatch=0`을 사용하고 412를
실패로 처리한다. 이 첫 PR은 promotion-evidence object를 만들지 않는다.

### BigQuery 최소권한

실험 GSA에는 프로젝트 수준 `roles/bigquery.jobUser`와
`roles/bigquery.readSessionUser`, `feast_offline_store_dev` dataset 수준
`roles/bigquery.dataViewer`만 부여한다. production `feast_offline_store`,
`data_lake_raw`, analytics/source dataset의 IAM binding은 추가하지 않는다.

이 권한은 dev offline PIT query와 BigQuery Storage Read API만 허용한다. source table
DDL/DML, BigQuery dataset 생성·삭제, production query, 예약 슬롯 관리 권한은 포함하지
않는다. 쿼리 bytes billed 상한, backfill partition, temporary table lifecycle은 source
schema/backfill 후속 변경에서 별도로 설계한다.

### Airflow 및 output 계약

dev root output `experiment_runtime_contract`와 admin root output
`experiment_runtime_kubernetes_contract`를 추가한다. 두 output에는 secret, token,
state 값 없이 다음 좌표만 담는다.

- namespace, KSA, GSA email 및 Airflow Job runner Role 이름
- dev registry/staging/artifact의 `experiments/` root URI
- code archive object URI 형식 `gs://<bucket>/code/<source_sha>.tar.gz`
- `feast_offline_store_dev` dataset ID
- 동시 실행·resource limit과 Job TTL 계약

Airflow 저장소 #209는 이 output을 승인된 변수로 등록한 뒤에만 해당 KSA로 Job을
만들어야 한다. runtime Job은 immutable image digest, comparison ID, condition,
`CODE_ARCHIVE_SHA`, registry URI와 결과 URI를 audit log에 남기되 token·Secret 값은
남기지 않는다.

## 권한 행렬

| 주체 | dev registry/staging | code archive | dev offline store | 결과 artifact | prod registry/BQ/Redis/CA |
| --- | --- | --- | --- | --- | --- |
| experiment runtime GSA | 실험 `experiments/` root만 | SHA archive 읽기 | PIT read + job | 실험 결과 create/read | 없음 |
| Airflow GSA | namespace Job 관찰·생성만 | 기존 권한 유지 | 기존 권한 유지 | 기존 권한 유지 | 이 변경에서 추가 없음 |
| existing airflow_batch GSA | 기존 경로 유지 | 기존 권한 유지 | 기존 권한 유지 | training snapshot 경로만 | 이 변경에서 추가 없음 |

## 검증과 음성 테스트

로컬 검증은 dev/admin root 각각 `terraform fmt -check -recursive`,
`terraform init -backend=false -input=false`, `terraform validate`, `git diff --check`를
수행한다. Terraform plan은 실제 승인된 인증과 tfvars가 있을 때만 수행한다.

apply 뒤 승인된 운영자는 다음을 검증한다.

1. runtime KSA가 dev registry/staging/artifact와 dev PIT query에 성공한다.
2. runtime GSA로 prod registry, `feast_offline_store`, Redis CA Secret 접근이 403/권한
   거부로 실패한다.
3. namespace RoleBinding subject가 Airflow GSA 하나이며, runtime KSA에는 Job 생성 권한이
   없음을 `kubectl auth can-i`로 확인한다.
4. Redis PSC, Cloud SQL, MLflow 목적지 TCP 연결이 NetworkPolicy로 실패한다.
5. ResourceQuota를 넘는 다섯 번째 Job 또는 LimitRange 상한 초과 Pod가 admission에서
   거부되고, 종료 Job이 TTL 후 정리되는지 확인한다.

## 롤백과 비용

apply 전에는 리소스가 없으므로 이 변경의 rollback은 Airflow에서 실험 Job 생성 중단 후,
승인된 Terraform apply로 새 runtime IAM·namespace·KSA/GSA를 제거하는 것이다. 기존
Airflow, Feast apply, production registry, BigQuery dataset, Redis는 변경하지 않는다.

새 GSA·IAM·Kubernetes 제어 리소스의 직접 비용은 없다. 실험 Job의 CPU/메모리 및
BigQuery scan 비용은 quota와 후속 query 비용 상한으로 통제하며, 첫 PR은 실제 Job을
배포하거나 쿼리를 실행하지 않는다.

## 비범위와 후속 분리

- BigQuery source feature table schema, backfill DML identity, partition/cluster, 비용
  상한, idempotency와 rollback
- write-once promotion evidence bucket/prefix, plan publisher·training runtime·verifier
  identity 분리, retention 및 generation receipt 검증
- application/Airflow의 Job 템플릿과 paired experiment business logic
- Terraform apply/destroy, GCP API 활성화, state migration, production resource 변경
