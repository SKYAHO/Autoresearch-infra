# BigQuery data lake 테이블 dt 파티션 Terraform 관리 설계

> Issue: #199
> 계획: `docs/superpowers/plans/2026-07-15-bigquery-dt-partition-tables.md`
> 상태: 구현 완료 (PR #200, `terraform import`는 merge 후 수행)

## 배경

`SKYAHO/Autoresearch` PR #115(커밋 `6cd559c`)에서 GCS 데이터 레이크 raw parquet을
BigQuery로 적재하는 스크립트 `scripts/load_raw_to_bigquery.py`가 추가되었다.
적재 대상 3종 중 hive partitioned 소스 2종은 `dt` 컬럼 기준 일 단위 파티션
테이블로 생성된다:

| 키 | GCS 소스 | BigQuery 테이블 | 파티션 |
| --- | --- | --- | --- |
| `action_log` | `data_lake/action_log/dt=*` | `data_lake_action_log` | DAY / `dt` |
| `youtube_trending_kr` | `data_lake/youtube_trending_kr/dt=*` | `data_lake_youtube_trending_kr` | DAY / `dt` |

스크립트 동작 계약(앱 저장소 소유):

- `WRITE_TRUNCATE`로 전체 재적재, 재실행 멱등
- Parquet autodetect 스키마 + `HivePartitioningOptions(mode=AUTO)`로 `dt` 복원
- `TimePartitioning(type=DAY, field="dt")`를 load job에 지정
- 기본 dataset은 `.env`의 `BQ_DATASET` 미설정 시 `feast_offline_store`

## 문제

테이블이 적재 스크립트 실행 시점에만 생성되고 Terraform이 관리하지 않는다.
테이블이 삭제된 뒤 파티셔닝 없이 다른 경로(콘솔, ad-hoc 쿼리)로 재생성되면
load job의 파티션 스펙과 충돌하거나, 파티셔닝 없는 테이블로 남을 수 있다.
인프라 차원에서 "이 두 테이블은 언제나 dt 일 단위 파티션"임을 보장해야 한다.

## 결정 사항

### 1. `google_bigquery_table` 리소스 2개를 dev root에 추가

`terraform/envs/dev/bigquery.tf`에 테이블 리소스를 추가하고
`time_partitioning { type = "DAY", field = "dt" }`를 고정한다. 파티셔닝은
테이블 교체 없이는 변경할 수 없는 속성이므로, Terraform이 존재+파티셔닝을
보장하면 재생성 시에도 항상 파티션 테이블이 된다.

### 2. 스키마 소유권은 앱, 구조 소유권은 인프라

적재 스크립트가 autodetect + `WRITE_TRUNCATE`로 스키마를 관리하므로 Terraform은
스키마를 소유하지 않는다:

- Terraform은 파티션 필드 요건을 만족하는 최소 스키마(`dt DATE`)만 정의한다
  (파티션 필드는 생성 시점 스키마에 반드시 존재해야 함).
- `lifecycle { ignore_changes = [schema] }`로 적재 후 스키마 드리프트를
  무시한다. 전체 스키마를 Terraform에 복제하는 대안은 앱 스키마 변경마다
  저장소 간 동기화가 필요해 기각했다.

### 3. dataset은 실제 위치 확인 후 확정 (기본 가정: `feast_offline_store`)

스크립트 기본값이 `feast_offline_store`이므로 이를 기본 가정으로 하되,
구현 시 `bq ls`로 실제 테이블 위치를 확인해 확정한다. `analytics` dataset에
있다면 참조만 `google_bigquery_dataset.analytics`로 바꾼다.

> 확인 결과(2026-07-15): 두 테이블 모두 `feast_offline_store`에 존재하며 이미
> DAY/`dt` 파티셔닝 상태였다. 기본 가정 그대로 확정한다.

### 4. 기존 테이블은 import로 편입

테이블이 이미 존재하면 `terraform import`로 state에 편입한다(생성 시도는
409 충돌). import 전 `bq show`로 기존 파티셔닝을 확인한다:

- 파티셔닝이 DAY/`dt`로 일치 → import 후 plan no-op 확인
- 파티셔닝 불일치/없음 → in-place 변경 불가. 사용자 승인 하에 테이블 삭제 후
  Terraform apply로 재생성하고 적재 스크립트를 재실행한다(WRITE_TRUNCATE
  멱등이므로 데이터 손실 없음, 원본은 GCS에 보존).

### 5. 보호 및 비용

- `deletion_protection = true` — dataset의 `prevent_destroy`와 일관된 기준.
- `require_partition_filter`는 설정하지 않는다(적재/조회 경로가 아직 강제
  필터를 전제하지 않음, YAGNI).
- 비용 영향 없음: 테이블 리소스 자체는 무과금, 파티셔닝은 쿼리 스캔 비용을
  줄이는 방향.

## 롤백

`terraform state rm`으로 두 리소스를 state에서만 제거하고 코드를 revert한다.
테이블과 데이터는 유지되며, 적재 스크립트 동작에는 영향이 없다.
