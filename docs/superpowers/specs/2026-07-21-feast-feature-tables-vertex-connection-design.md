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

## 영향 및 제외 범위

- 기존 4개 테이블의 더미 데이터 300~600행이 소실된다(요청자 승인 완료).
- `roles/aiplatform.user`는 project 수준 권한이다. Vertex AI에 dataset 수준 IAM이
  없어 최소 단위가 project다. `aiplatform.admin`이 아닌 `user`로 제한한다.
- 아래 3개는 임베딩 모델·차원 변경 시 스키마가 따라 바뀌고 Feast가 직접 읽지 않아
  계약이 아니므로 Terraform 관리에서 제외한다. 배치 job이 `CREATE OR REPLACE`로
  관리한다: `user_topic_embedding`, `category_embedding`, `training_entity`.
- BigQuery ML remote model(`CREATE MODEL ... REMOTE WITH CONNECTION`)도 배치 job이
  멱등하게 생성한다.

## 리스크 — `WRITE_TRUNCATE`가 Terraform 소유 스키마를 덮어쓴다

적재 job이 `WRITE_TRUNCATE`를 쓰면 BigQuery는 대상 테이블의 **스키마까지** 결과
스키마로 교체한다. `createDisposition = CREATE_NEVER`는 테이블 신규 생성만 막을 뿐
스키마 교체는 막지 못한다.

특히 `REQUIRED` mode는 쿼리 결과에서 일반적으로 `NULLABLE`로 산출되므로, job 실행
→ Terraform이 `REQUIRED`로 되돌림 → 다음 job이 다시 `NULLABLE`로 만드는 **영구
drift**가 발생할 가능성이 높다. 이는 "스키마를 Terraform이 소유해 계약 위반을
plan에서 잡는다"는 이번 작업의 목적 자체를 무력화한다.

배치 팀(`SKYAHO/Autoresearch`)과 아래 중 하나를 합의해야 한다.

1. job이 대상 테이블 스키마를 명시 전달하고 스키마 갱신 옵션을 쓰지 않는다.
2. `WRITE_TRUNCATE` 대신 `DELETE` + `WRITE_APPEND`로 전환한다(기존 스키마 보존).
3. `REQUIRED` 요구를 포기하고 전 컬럼을 `NULLABLE`로 정의한다.

합의 전까지는 첫 apply 이후 `terraform plan`으로 drift 발생 여부를 관찰한다.

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
