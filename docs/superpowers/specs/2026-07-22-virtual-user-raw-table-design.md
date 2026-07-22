# data_lake_raw 가상 유저 raw 테이블 Terraform 관리 설계

> Issue: #300
> 계획: `docs/superpowers/plans/2026-07-22-virtual-user-raw-table.md`
> 상태: 설계 (구현 전)

## 배경

`SKYAHO/Autoresearch`의 가상 유저 페르소나 원본은 GCS raw data bucket
`asset/virtual_user/vu_1000.parquet`(정적 자산, 비 hive-partition)으로 보관된다.
이 파일을 BigQuery로 적재하는 경로는 `scripts/load_raw_to_bigquery.py`이며,
`LoadTarget(key="virtual_user", source_path="asset/virtual_user/vu_1000.parquet",
table_name="asset_virtual_user_vu_1000", hive_partitioned=False)`로 선언돼 있다.
적재는 `WRITE_TRUNCATE` + parquet autodetect, hive partitioning 미사용으로 동작한다.

`data_lake_raw` dataset(#285)은 raw 적재 테이블의 집합층이며, 현재
`data_lake_action_log`, `data_lake_youtube_trending_kr` 두 일 단위 파티션
테이블이 Terraform으로 관리되고 있다(#199). 이 두 테이블은 hive partitioned
소스라 `dt DATE` 파티션을 갖지만, 가상 유저 테이블은 정적 자산이라 파티션이
없다.

다운스트림 사용처:

- `autoresearch.jobs.feature_materialize`가 raw 테이블에서 컬럼을 읽어 Feast
  피처 테이블을 materialize한다. LIST<string> 필드는 BigQuery parquet load
  시 wrapper 구조(`RECORD NULLABLE { list: RECORD REPEATED { element: STRING
  NULLABLE } }`)로 적재되며, `_string_array()` 헬퍼가
  `ARRAY(SELECT item.element FROM UNNEST(<col>.list) AS item)`로 언래핑한다.

## 문제

가상 유저 raw 테이블 `asset_virtual_user_vu_1000`이 Terraform으로 관리되지
않는다. 테이블이 삭제된 뒤 파티셔닝이나 라벨 없이 임의 경로로 재생성되면,
인프라 차원의 관리 메타데이터(`managed_by=terraform`, `owner=infra`)와
삭제 보호 정책이 사라진다. 이슈 #300의 인수 조건은 테이블 메타데이터에
해당 라벨이 있을 것, WRITE_TRUNCATE 적재가 동작할 것, 그리고 feature
materialization 워크로드가 SELECT 권한을 가질 것을 요구한다.

## 결정 사항

### 1. `google_bigquery_table` 리소스를 dev root에 추가

`terraform/envs/dev/bigquery.tf`에 `asset_virtual_user_vu_1000` 리소스를
추가한다. `data_lake_raw` dataset에 속하며, 정적 자산이므로 `time_partitioning`
블록 없이 생성한다. 다른 raw 테이블과 동일한 `deletion_protection = true`로
데이터 유실을 방지한다.

### 2. 스키마 소유권은 앱, 구조 소유권은 인프라

적재 스크립트가 parquet autodetect + `WRITE_TRUNCATE`로 스키마를 소유하므로
Terraform은 스키마를 소유하지 않는다(#199과 동일한 경계).

- Terraform은 존재 보장용 최소 seed 컬럼(`user_id STRING NULLABLE`)만 둔다.
  seed는 테이블 생성 요건(빈 스키마 거부)을 만족하기 위함이며, 필드 의미는
  적재 job이 결정한다.
- `lifecycle { ignore_changes = [schema] }`로 적재 후 스키마 드리프트를
  무시한다. 전체 wrapper 스키마를 Terraform에 복제하는 대안은 앱 스키마
  변경마다 양쪽 저장소 동기화가 필요해 기각했다.

**기대되는 BigQuery wrapper 스키마(참고용, Terraform이 관리하지 않음):**

parquet의 LIST<string> 필드는 BigQuery load 시 flat `ARRAY<STRING>`이 아니라
wrapper record로 적재된다. 예상 구조:

```
<list_field_name> RECORD NULLABLE
  └─ list RECORD REPEATED
       └─ element STRING NULLABLE
```

이 wrapper는 `feature_materialize.py`의 `_string_array()` 헬퍼가
`UNNEST(<col>.list)`로 언래핑하는 계약과 일치한다. 주의: `feature_store_build.py`
(별도 모듈, PR #243)는 flat `ARRAY<STRING>`으로 읽는 계약 차이가 존재하며,
이 설계는 feature materialization 경로의 wrapper 계약을 따른다.

### 3. 라벨로 관리 주체 명시

이슈 #300 인수 조건이 `managed_by=terraform`, `owner=infra` 라벨을 요구한다.
기존 raw 테이블이 `data_class=raw`, `purpose=data-lake-raw`만 가지는 것과
달리, 이 테이블은 두 관리 라벨을 추가로 부여한다:

```hcl
labels = {
  data_class   = "raw"
  purpose      = "data-lake-raw"
  managed_by   = "terraform"
  owner        = "infra"
}
```

기존 raw 테이블들에 역으로 라벨을 추가하는 작업은 이슈 범위 밖이며 별도
정리 대상으로 둔다.

### 4. IAM은 dataset 레벨에서 이미 충족

`data_lake_raw` dataset은 #285에서 `roles/bigquery.dataEditor`를 GKE app SA,
Airflow SA, Airflow batch SA에 부여한다. dataEditor는 SELECT을 포함하므로,
feature materialization(Airflow 경유 실행)은 이미 raw 테이블 SELECT 권한을
가진다. WRITE_TRUNCATE 적재 워크로드 역시 dataEditor로 커버된다. 따라서
새 IAM 리소스는 필요 없다.

### 5. 보호 및 비용

- `deletion_protection = true` — 다른 raw 테이블과 동일 기준.
- 비용 영향 없음: 테이블 리소스 자체는 무과금, 파티셔닝이 없어 추가 스캔
  비용도 발생하지 않는다. 리전은 dataset 기본값 `asia-northeast3`를 따른다.

## 롤백

`terraform state rm`으로 리소스를 state에서만 제거하고 코드를 revert한다.
테이블과 데이터는 유지되며, 적재 스크립트 동작에는 영향이 없다.
