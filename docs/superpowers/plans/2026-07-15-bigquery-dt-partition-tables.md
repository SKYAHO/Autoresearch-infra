# BigQuery data lake 테이블 dt 파티션 Terraform 관리 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans 또는
> superpowers:subagent-driven-development로 task 단위 실행. 체크박스로 진행을
> 추적한다.
>
> 설계: `docs/superpowers/specs/2026-07-15-bigquery-dt-partition-tables-design.md`
> Issue: #199

**목표:** `data_lake_action_log`, `data_lake_youtube_trending_kr` 두 BigQuery
테이블을 `google_bigquery_table` 리소스로 편입해, 재생성 시에도 `dt` 일 단위
파티셔닝이 항상 보장되게 한다.

**아키텍처:** 구조(존재+파티셔닝)는 Terraform이, 스키마/데이터는 앱 적재
스크립트(`SKYAHO/Autoresearch` `scripts/load_raw_to_bigquery.py`)가 소유한다.
Terraform은 최소 스키마(`dt DATE`)와 `ignore_changes = [schema]`로 경계를
지킨다.

---

## Task 1: 작업 경계 확인 및 브랜치 생성

- [x] `main`이 `origin/main`과 동기화되고 clean인지 확인한다.

```bash
git -C /Users/sunghyochang/Desktop/SK_Final_Project/Autoresearch-infra fetch origin
git -C /Users/sunghyochang/Desktop/SK_Final_Project/Autoresearch-infra status
```

- [x] 이슈 #199의 `Create a branch`로 브랜치를 생성한다(이슈-브랜치 자동 연결).
  브랜치명 예: `feat/199-bigquery-dt-partition-tables`. GitHub 원격 작업이므로
  실행 전 사용자 확인을 받는다.

```bash
gh api repos/SKYAHO/Autoresearch-infra/issues/199 --jq .title  # 이슈 확인
# 브랜치 생성은 GitHub UI의 "Create a branch" 또는 아래 대체 절차(사용자 승인 후):
git -C /Users/sunghyochang/Desktop/SK_Final_Project/Autoresearch-infra switch -c feat/199-bigquery-dt-partition-tables origin/main
```

## Task 2: 실제 테이블 위치·파티셔닝 사전 확인

**전제:** GCP 자격 증명(`terraform.tfvars`의 project id, `bq` CLI 인증)이 준비된
경우에만 수행한다. 자격 증명이 없으면 설계 기본 가정(`feast_offline_store`,
테이블 미존재 또는 DAY/`dt` 파티션 존재)을 유지하고 Task 4의 import 단계에서
사용자와 함께 확인한다.

- [x] 실제 dataset 위치를 확인한다.

```bash
PROJECT_ID=$(sed -n 's/^project_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
  /Users/sunghyochang/Desktop/SK_Final_Project/Autoresearch-infra/terraform/envs/dev/terraform.tfvars)
bq ls --project_id="$PROJECT_ID" feast_offline_store
bq ls --project_id="$PROJECT_ID" "$(bq ls --project_id="$PROJECT_ID" | awk '/analytics/{print $1}')"
```

기대: 두 테이블(`data_lake_action_log`, `data_lake_youtube_trending_kr`)이
`feast_offline_store`에 있거나, 아직 어디에도 없음. `analytics`에 있다면
Task 3 코드의 dataset 참조를 `google_bigquery_dataset.analytics`로 바꾼다.

- [x] 테이블이 존재하면 파티셔닝 스펙을 확인한다.

```bash
bq show --format=prettyjson "$PROJECT_ID:feast_offline_store.data_lake_action_log" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('timePartitioning'))"
bq show --format=prettyjson "$PROJECT_ID:feast_offline_store.data_lake_youtube_trending_kr" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('timePartitioning'))"
```

기대: `{'type': 'DAY', 'field': 'dt'}` 또는 테이블 없음. 파티셔닝이 다르거나
없으면 Task 4의 "파티셔닝 불일치" 분기를 따른다.

## Task 3: Terraform 테이블 리소스 추가

**Files:**
- Modify: `terraform/envs/dev/bigquery.tf` (파일 끝에 추가)

- [x] **Step 1: 테이블 리소스 2개를 추가한다.**

```hcl
# #199 data lake 테이블 dt 파티션 고정
# 스키마/데이터는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유하고
# (autodetect + WRITE_TRUNCATE), Terraform은 존재와 dt 일 단위 파티셔닝만 보장한다.
resource "google_bigquery_table" "data_lake_action_log" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "data_lake_action_log"
  description         = "GCS data_lake/action_log raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  # 파티션 필드는 생성 시점 스키마에 존재해야 한다. 이후 스키마는 적재 job이 관리한다.
  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

resource "google_bigquery_table" "data_lake_youtube_trending_kr" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "data_lake_youtube_trending_kr"
  description         = "GCS data_lake/youtube_trending_kr raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}
```

Task 2에서 테이블이 `analytics` dataset에 있는 것으로 확인되면 두 리소스의
`dataset_id`를 `google_bigquery_dataset.analytics.dataset_id`로 바꾼다.

- [x] **Step 2: 로컬 검증을 실행한다.**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

기대: `Success! The configuration is valid.`

- [x] **Step 3: 커밋한다.**

```bash
git add terraform/envs/dev/bigquery.tf
git commit -m "feat: data lake BigQuery 테이블 2종 dt 파티션 IaC 편입 (#199)"
```

## Task 4: 기존 테이블 state 편입 (import)

**전제:** state를 변경하는 작업이므로 실행 전 사용자 승인을 받는다. GCP 자격
증명이 없으면 이 Task는 PR 본문에 "merge 후 apply 전 수행" 절차로 기록하고
건너뛴다.

- [ ] **분기 A — 테이블이 존재하고 파티셔닝이 DAY/`dt`로 일치:** import한다.

```bash
terraform -chdir=terraform/envs/dev import \
  google_bigquery_table.data_lake_action_log \
  "projects/$PROJECT_ID/datasets/feast_offline_store/tables/data_lake_action_log"
terraform -chdir=terraform/envs/dev import \
  google_bigquery_table.data_lake_youtube_trending_kr \
  "projects/$PROJECT_ID/datasets/feast_offline_store/tables/data_lake_youtube_trending_kr"
terraform -chdir=terraform/envs/dev plan
```

기대: plan에서 두 테이블에 대해 destroy/replace가 없어야 한다. description,
labels 등 in-place update(`~ update in-place`)만 허용한다.

- [ ] **분기 B — 테이블이 없음:** import 없이 진행한다. merge 후 사용자가
  명시적으로 요청할 때 `terraform apply`로 생성한다(`2 to add` 기대).

- [ ] **분기 C — 테이블이 존재하지만 파티셔닝 불일치/없음:** in-place 변경이
  불가능하므로 사용자 승인 하에 재생성한다. 원본은 GCS에 보존되고 적재는
  WRITE_TRUNCATE 멱등이므로 데이터 손실이 없다.

```bash
bq rm -f -t "$PROJECT_ID:feast_offline_store.data_lake_action_log"          # 사용자 승인 후
bq rm -f -t "$PROJECT_ID:feast_offline_store.data_lake_youtube_trending_kr" # 사용자 승인 후
terraform -chdir=terraform/envs/dev apply                                    # 사용자 승인 후, 2 to add
# 이후 앱 저장소에서 재적재:
# python scripts/load_raw_to_bigquery.py --tables action_log,youtube_trending_kr
```

## Task 5: 운영 문서 갱신

**Files:**
- Modify: `docs/TERRAFORM_DEV.md` — "dev BigQuery (#20)" 섹션
- Modify: `docs/CHANGE_HISTORY.md` — 변경 이력 추가

- [x] **Step 1: `docs/TERRAFORM_DEV.md`의 dev BigQuery 섹션에 테이블 관리
  경계를 추가한다.** "GCS와 BigQuery 역할" 표 아래에 다음 내용을 반영한다:

```markdown
### data lake 테이블 dt 파티션 (#199)

`feast_offline_store` dataset의 `data_lake_action_log`,
`data_lake_youtube_trending_kr`는 Terraform이 존재와 `dt` 일 단위 파티셔닝을
보장한다 (`google_bigquery_table`, `deletion_protection = true`).

| 소유권 | 주체 | 내용 |
| --- | --- | --- |
| 구조 | 이 저장소 (Terraform) | 테이블 존재, `time_partitioning(DAY, dt)`, labels |
| 스키마/데이터 | `SKYAHO/Autoresearch` | `scripts/load_raw_to_bigquery.py`가 autodetect + WRITE_TRUNCATE로 관리, Terraform은 `ignore_changes = [schema]` |

파티셔닝 변경은 테이블 교체를 유발하므로 `deletion_protection` 해제와 재적재
계획 없이는 수행하지 않는다.
```

`data_lake/action_log`를 "BigQuery partitioned table 후보"로 적어 둔 기존
행(275행 부근)은 "dt 일 단위 partitioned table (#199)"로 현행화한다.

- [x] **Step 2: `docs/CHANGE_HISTORY.md`에 요약을 추가한다.** 기존 항목 형식을
  따라 작성한다. 포함 내용: 목적(재생성 시 파티셔닝 보장), 비용 영향 없음,
  리전 변화 없음(`asia-northeast3`), 롤백(`terraform state rm` 후 코드 revert,
  테이블/데이터 유지).

- [x] **Step 3: 커밋한다.**

```bash
git add docs/TERRAFORM_DEV.md docs/CHANGE_HISTORY.md
git commit -m "docs: data lake 테이블 dt 파티션 IaC 소유권 경계 기록 (#199)"
```

## Task 6: spec/plan 문서 포함 및 최종 검증

- [x] **Step 1: 이 계획과 spec 문서를 같은 브랜치에 커밋한다.**

```bash
git add docs/superpowers/specs/2026-07-15-bigquery-dt-partition-tables-design.md \
        docs/superpowers/plans/2026-07-15-bigquery-dt-partition-tables.md
git commit -m "docs: BigQuery dt 파티션 테이블 spec/plan 추가 (#199)"
```

- [x] **Step 2: 최종 검증을 실행한다.**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
git diff origin/main --stat
```

기대: fmt/validate 통과, diff에 secret/state/tfvars 없음, 변경 파일이
`bigquery.tf` + 문서 4종뿐임을 확인한다.

## Task 7: Draft PR 생성 및 전달

- [x] `.github/PULL_REQUEST_TEMPLATE.md` 구조를 그대로 따라 Draft PR을
  생성한다(GitHub 원격 작업이므로 사용자 확인 후 push/PR). PR 본문에 반드시
  포함할 사항:
  - CI plan 기대치: 테이블 미존재 시 `2 to add, 0 to change, 0 to destroy`,
    import 완료 시 `0 to add` (기존 리소스 change/destroy 없음)
  - Task 4의 import(또는 apply) 절차가 merge 후 별도 승인 하에 수행됨
  - 비용 영향 없음, 리전 변화 없음, 롤백 = `terraform state rm` + revert
- [ ] squash merge 후 사용자 승인 하에 import/apply를 수행하고, 적재 스크립트
  재실행 후 `terraform plan`이 no-op(스키마 드리프트 없음)인지 확인한다.
