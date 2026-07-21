# Feast 피처 테이블 IaC 편입 + BigQuery ↔ Vertex AI connection 설계

> 관련 이슈: #280

## 목적

CTR 피처 스토어를 더미 데이터에서 실데이터로 전환하기 위해, `data_lake_*` raw
테이블에서 Feast 피처 테이블을 생성하는 배치 파이프라인(`SKYAHO/Autoresearch`)이
필요로 하는 인프라 2건을 선행 구축한다.

1. BigQuery ML `ML.GENERATE_EMBEDDING`이 Vertex AI를 호출할 `CLOUD_RESOURCE`
   connection과 IAM
2. Feast 피처 테이블 4종의 Terraform 편입

## 변경 결정

### 스키마를 Terraform이 소유한다

`data_lake_*` 테이블은 `ignore_changes = [schema]`로 스키마를 적재 job에 위임한다.
반면 Feast 피처 테이블 4종은 스키마를 Terraform이 소유한다. Feast
`FeatureView`(`feature_repo/feature_definitions.py`)가 컬럼명·타입·mode를 계약으로
선언하고 있어, 계약 위반을 `terraform plan` 단계에서 잡기 위해서다.

| 테이블 | 파티셔닝 | Feast FeatureView |
| --- | --- | --- |
| `user_static_feature` | 없음 | `UserStaticView` |
| `user_dynamic_feature` | `event_timestamp` DAY | `UserDynamicView` |
| `video_feature` | `event_timestamp` DAY | `VideoFeatureView` |
| `user_category_similarity` | 없음 | `UserCategorySimilarityView` |

파티셔닝 판단 근거: `user_dynamic_feature`는 일 단위 snapshot이 누적되고 Feast
`materialize`가 timestamp 범위로 스캔하므로 DAY 파티션이 스캔 비용에 직접
기여한다. `video_feature`도 동일하다. `user_static_feature`와
`user_category_similarity`는 `event_timestamp`가 `1970-01-01` 고정값(정적 피처가
모든 action log보다 먼저 유효하다는 규약)이라 파티셔닝이 무의미하다.

### 기존 더미 테이블은 drop 후 재생성한다

2026-07-15 데이터 생성 스크립트가 만든 동명 테이블 4개가 이미 존재한다. 실물
스키마를 확인한 결과 요청안과 아래가 달라 **in-place 변경이 불가능**하다.

- 모든 컬럼이 `NULLABLE`. BigQuery는 `NULLABLE → REQUIRED` 승격을 지원하지 않는다.
- `user_dynamic_feature`·`video_feature`에 파티션이 없다. 기존 테이블에 파티셔닝을
  추가할 수 없다.
- `user_category_similarity`는 컬럼이 5개뿐이다(요청안 11개).

데이터는 100~300행 더미로 유실되어도 무방하므로, `bq rm`으로 drop 후 Terraform이
재생성한다. `terraform import` 후 조정하는 경로는 `deletion_protection = true`와
replace가 충돌해 결국 수동 개입이 필요하므로 채택하지 않는다.

### BigQuery ↔ Vertex AI connection

| 항목 | 값 | 근거 |
| --- | --- | --- |
| Connection id | `autoresearch-dev-vertex-ai` | `local.resource_prefix` 규약 |
| Type | `cloud_resource {}` | BigQuery ML remote model 요구사항 |
| Location | `var.bigquery_location` (`asia-northeast3`) | remote model은 connection과 데이터셋이 동일 리전일 때만 동작한다 |
| Connection service agent | `roles/aiplatform.user` (project) | Vertex AI 호출 |
| Airflow SA / Airflow batch SA | `roles/aiplatform.user` (project) | 피처 빌드 BigQuery job 실행 주체. BigQuery `dataEditor`·`jobUser`·`readSessionUser`는 `airflow.tf`에서 이미 보유 |

`aiplatform.googleapis.com`은 현재 프로젝트에서 비활성이므로 활성화가 필요하다.
`bigqueryconnection.googleapis.com`은 이미 활성 상태다. 두 API 모두
`local.required_services`에 기록한다(이 local은 문서용 output이며 API를 실제로
활성화하지 않는다).

## 서울 리전 임베딩 모델 제공 여부 — 확인 완료 (2026-07-21)

`text-multilingual-embedding-002`는 `asia-northeast3`에서 **제공된다.** 공개
문서에 리전별 제공 표가 없어 실호출로 판정했다.

```
POST https://asia-northeast3-aiplatform.googleapis.com/v1/projects/ar-infra-501607
     /locations/asia-northeast3/publishers/google/models/text-multilingual-embedding-002:predict
→ HTTP 200, 768차원 임베딩 반환
```

한국어 의미 판별도 정상이다. 페르소나 키워드가 올바른 카테고리에서 최고 유사도를
보였다.

| 키워드 | 음식·맛집 | 게임·e스포츠 | 정치·시사 |
| --- | --- | --- | --- |
| 노포 맛집 탐방 | **0.7221** | 0.5413 | 0.5529 |
| 리그 오브 레전드 | 0.4681 | **0.6417** | 0.4754 |

`feast_offline_store`와 동일 리전이므로 BigQuery ML remote model 경로가 성립한다.
임베딩 전용 데이터셋 US 분리나 Python 배치 전환 같은 대안 설계는 불필요하다.

### 배치 측 참고 — 코사인 유사도 바닥값이 높다

무관한 카테고리 조합에서도 유사도가 0.47~0.55로 나온다. 이 모델의 특성이며,
`topic_similarity`를 원값 그대로 피처로 쓰면 변별력이 낮다. 카테고리별 정규화
(z-score)나 순위 기반 변환을 배치 측에서 검토해야 한다. 인프라 범위 밖이다.

### 검토 후 기각한 대안 — `gemini-embedding-001`

더 신형인 `gemini-embedding-001`도 후보로 실측했다. `asia-northeast3`에서
제공되지만(HTTP 200, 3072차원, `outputDimensionality`로 768 축소 가능) **처리량
때문에 기각했다.**

| 항목 | `text-multilingual-embedding-002` (채택) | `gemini-embedding-001` (기각) |
| --- | --- | --- |
| 한 요청 5건 배치 | 5건 반환 | **HTTP 429** — 요청당 1건만 허용 |
| 순차 처리량 | — | 약 100건/분 (0.6초/건) |
| 판별 격차 (최고−차순위) | 0.166~0.169 | 0.072~0.104 |
| 유사도 바닥값 | 0.47~0.55 | 0.77~0.78 |

`gemini-embedding-001`은 요청당 1건만 받아 `ML.GENERATE_EMBEDDING`이 행마다 개별
요청을 보내게 되고, 순차 기준 2,000건에 약 20분, 10,000건에 약 100분이 걸린다.
데이터 규모가 커질수록 배치 실행 시간이 선형으로 늘어 채택하지 않았다.

판별 격차도 `text-multilingual-embedding-002`가 1.6~2.3배 넓었다(`task_type`은
`SEMANTIC_SIMILARITY` 적용). 다만 문장 5개 표본이라 벤치마크는 아니다.

## 영향 및 제외 범위

- 기존 4개 테이블의 더미 데이터 300~600행이 소실된다(요청자 승인 완료).
- `roles/aiplatform.user`는 project 수준 권한이다. Vertex AI에 dataset 수준 IAM이
  없어 최소 단위가 project다. `aiplatform.admin`이 아닌 `user`로 제한한다.
- 아래 3개는 임베딩 모델·차원 변경 시 스키마가 따라 바뀌고 Feast가 직접 읽지 않아
  계약이 아니므로 Terraform 관리에서 제외한다. 배치 job이 `CREATE OR REPLACE`로
  관리한다: `user_topic_embedding`, `category_embedding`, `training_entity`.
- BigQuery ML remote model(`CREATE MODEL ... REMOTE WITH CONNECTION`)도 배치 job이
  멱등하게 생성한다.

## 적재 방식 — `WRITE_TRUNCATE` 금지, `TRUNCATE` + `INSERT INTO` 사용

### 검증 결과 (2026-07-21, 임시 테이블 실측)

`feast_offline_store`에 `user_id`/`event_timestamp`를 `REQUIRED`로 선언한 임시
테이블을 만들어 적재 방식별 스키마 영향을 실측했다.

| 실험 | 방식 | 스키마 결과 |
| --- | --- | --- |
| 1 | `WRITE_TRUNCATE` query job | `REQUIRED` → **`NULLABLE` 파괴** |
| 2 | `BEGIN TRANSACTION` + `TRUNCATE TABLE` + `INSERT INTO` | **보존** |
| 3 | 위 방식으로 `user_id = NULL` 삽입 시도 | **거부됨** (`Required field user_id cannot be null`) |
| 4 | 실험 2 재실행 | 전체 교체 정상 동작 |
| 5 | `WRITE_APPEND` query job | 보존 |

`WRITE_TRUNCATE`는 BigQuery가 대상 테이블의 **스키마까지** 결과 스키마로 교체한다.
`createDisposition = CREATE_NEVER`는 테이블 신규 생성만 막을 뿐 스키마 교체는 막지
못한다. 이대로 두면 job 실행 → Terraform이 `REQUIRED`로 되돌림 → 다음 job이 다시
`NULLABLE`로 만드는 **영구 drift**가 발생하고, "스키마를 Terraform이 소유해 계약
위반을 plan에서 잡는다"는 이번 작업의 목적 자체가 무력화된다.

### 배치 팀에 요청할 사항

`SKYAHO/Autoresearch` `autoresearch.jobs.feature_store_build`가 결과를 저장하는
방식을 job 설정(`write_disposition`)이 아니라 DML로 바꾼다. `SELECT` 부분은 그대로
둔다.

```sql
BEGIN TRANSACTION;
TRUNCATE TABLE `<project>.feast_offline_store.<table>`;
INSERT INTO `<project>.feast_offline_store.<table>`
<기존 SELECT 그대로>;
COMMIT TRANSACTION;
```

- DML은 대상 테이블 스키마를 변경하지 않으므로 Terraform 소유 스키마가 보호된다.
- `REQUIRED` 컬럼에 NULL이 들어오면 BigQuery가 거부한다. 불량 데이터 차단이라는
  본래 목적이 함께 달성된다.
- `TRUNCATE`와 `INSERT`는 별개 문장이라 그 사이에 Feast가 읽으면 빈 테이블을 보게
  된다. `BEGIN TRANSACTION`으로 묶어 원자적 교체로 만든다.

`WRITE_APPEND`도 스키마를 보존하지만 전체 교체가 아니므로 별도 `DELETE` 문이
필요하고, 트랜잭션으로 묶지 않으면 같은 빈틈이 생긴다. `TRUNCATE` + `INSERT`가
더 낫다.

### 대안으로 검토했다 기각한 방법

- **job에 스키마를 명시 전달**: `configuration.load.schema`는 load job에만 있고
  query job에는 스키마 필드 자체가 없다. 이 파이프라인은 `data_lake_*`에서 SQL로
  집계하는 query job이라 적용 불가. 설령 가능해도 스키마 선언이 Feast·Terraform·
  배치 3곳으로 중복돼 어긋날 지점이 늘어난다.
- **Python에서 계산 후 parquet를 load job으로 적재**: load job이므로 스키마 명시가
  가능해지지만, BigQuery 데이터를 워커로 전부 꺼냈다 다시 올리는 왕복이 생기고
  메모리에 묶인다. `ML.GENERATE_EMBEDDING`은 BigQuery 함수라 밖에서 호출할 수도
  없다.
- **`REQUIRED` 포기 후 전 컬럼 `NULLABLE`**: 가장 간단하지만 `user_id`가 빈 불량
  데이터를 막지 못한다. 위 방법이 실측으로 확인됐으므로 채택하지 않는다.

## 롤백

- 테이블: `deletion_protection = true`를 해제하고 `terraform destroy -target`으로
  제거한 뒤, 필요하면 데이터 생성 스크립트로 더미 테이블을 재생성한다.
- connection·IAM: 해당 리소스 정의를 되돌리고 apply한다. connection 삭제 시
  service agent도 함께 사라지므로 IAM binding을 별도로 정리할 필요는 없다.
  remote model이 남아 있으면 참조가 끊기므로 배치 측 model도 함께 정리한다.

## 비용 영향

- BigQuery connection과 IAM: 무료.
- 테이블 저장: 실데이터 규모에 비례. `user_dynamic_feature`·`video_feature`의 DAY
  파티션이 Feast `materialize` 시 스캔량을 줄여 쿼리 비용을 절감한다.
- Vertex AI 임베딩: `text-multilingual-embedding-002` 호출량에 비례. 사용자 수
  100명 규모 dev에서는 미미하나, 배치 재실행 시 중복 호출을 피하도록 배치 측이
  임베딩 결과를 `user_topic_embedding`·`category_embedding`에 캐시한다.
