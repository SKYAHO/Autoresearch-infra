# data_lake_raw 가상 유저 raw 테이블 Terraform 관리 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans 또는
> superpowers:subagent-driven-development로 task 단위 실행. 체크박스로 진행을
> 추적한다.
>
> 설계: `docs/superpowers/specs/2026-07-22-virtual-user-raw-table-design.md`
> Issue: #300

**목표:** `asset_virtual_user_vu_1000` BigQuery 테이블을 `google_bigquery_table`
리소스로 편입해, 재생성 시에도 삭제 보호·관리 라벨·dataset 소속이 항상
보장되게 한다.

**아키텍처:** 구조(존재·라벨·deletion_protection)는 Terraform이, 스키마/데이터는
앱 적재 스크립트(`SKYAHO/Autoresearch` `scripts/load_raw_to_bigquery.py`)가
소유한다. Terraform은 최소 seed 스키마(`user_id STRING`)와
`ignore_changes = [schema]`로 경계를 지킨다.

---

## Task 1: 작업 경계 확인 및 브랜치 생성

- [x] `main`이 `origin/main`과 동기화되고 clean인지 확인한다.

```bash
git fetch origin
git status
```

- [x] 이슈 #300의 `Create a branch`로 브랜치를 생성한다(이슈-브랜치 자동 연결).
  GitHub 원격 작업이므로 실행 전 사용자 확인을 받는다.

```bash
gh api repos/SKYAHO/Autoresearch-infra/issues/300 --jq .title
# 브랜치 생성은 GitHub UI의 "Create a branch" 또는 로컬:
git switch -c feat/300-virtual-user-raw-table origin/main
```

## Task 2: Terraform 테이블 리소스 추가

**Files:**
- Modify: `terraform/envs/dev/bigquery.tf` (raw 테이블 블록 뒤에 추가)

- [ ] **Step 1: 테이블 리소스를 추가한다.** `data_lake_youtube_trending_kr`
  리소스 뒤에 위치시킨다.

```hcl
# #300 가상 유저 raw 테이블 (정적 자산, 비 hive-partition)
# 스키마/데이터는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유하고
# (parquet autodetect + WRITE_TRUNCATE, hive_partitioned=False), Terraform은 존재와
# 삭제 보호, 관리 라벨만 보장한다.
#
# parquet의 LIST<string> 필드는 BigQuery load 시 wrapper record로 적재된다:
#   <field> RECORD NULLABLE { list: RECORD REPEATED { element: STRING NULLABLE } }
# feature_materialize.py의 _string_array()가 UNNEST(<col>.list)로 언래핑한다.
# Terraform은 스키마를 소유하지 않고 ignore_changes = [schema]로 둔다.
resource "google_bigquery_table" "asset_virtual_user_vu_1000" {
  dataset_id          = google_bigquery_dataset.data_lake_raw.dataset_id
  table_id            = "asset_virtual_user_vu_1000"
  description         = "가상 유저 페르소나 원본 parquet(vu_1000) raw 적재 테이블. 정적 자산이라 파티션 없음. 스키마는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유(WRITE_TRUNCATE)한다."
  deletion_protection = true

  # 적재 스크립트가 전체 스키마를 소유한다. 존재 보장용 최소 seed 컬럼만 둔다.
  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
    managed_by = "terraform"
    owner      = "infra"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}
```

- [ ] **Step 2: 로컬 검증을 실행한다.**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

기대: `Success! The configuration is valid.`

- [ ] **Step 3: 커밋한다.**

```bash
git add terraform/envs/dev/bigquery.tf
git commit -m "feat: 가상 유저 raw BigQuery 테이블 IaC 편입 (#300)"
```

## Task 3: 운영 문서 갱신

**Files:**
- Modify: `docs/TERRAFORM_DEV.md` — raw/feature layer 분리 섹션의 테이블 표
- Modify: `docs/INFRASTRUCTURE_SUMMARY.md` — 가상 유저 raw 행
- Modify: `docs/CHANGE_HISTORY.md` — 변경 이력 추가

- [ ] **Step 1: `docs/TERRAFORM_DEV.md`의 raw/feature layer 분리 표에서
  `data_lake_raw` 행에 새 테이블을 추가한다.**

```markdown
| `data_lake_raw` | raw | `data_lake_action_log`, `data_lake_youtube_trending_kr`, `asset_virtual_user_vu_1000` |
```

같은 섹션의 GCS ↔ BigQuery 매핑 표에서 "가상 유저" 행을 갱신한다: feature/user
dimension 후보 → `data_lake_raw.asset_virtual_user_vu_1000` raw 테이블 (#300).

- [ ] **Step 2: `docs/INFRASTRUCTURE_SUMMARY.md`의 데이터 저장 위치 표에서
  "Virtual user raw" 행의 비고를 갱신한다.** BigQuery 테이블 참조를 추가한다.

- [ ] **Step 3: `docs/CHANGE_HISTORY.md`에 요약을 추가한다.** 기존 항목 형식을
  따른다. 포함 내용: 목적(정적 자산 raw 테이블의 IaC 편입, 관리 라벨 부여),
  스키마 소유권 경계(앱 소유, Terraform은 존재·라벨·deletion_protection),
  IAM 영향 없음(dataset 레벨 dataEditor로 이미 충족), 비용 영향 없음,
  리전 변화 없음(`asia-northeast3`), 롤백(`terraform state rm` 후 코드 revert,
  테이블/데이터 유지).

- [ ] **Step 4: 커밋한다.**

```bash
git add docs/TERRAFORM_DEV.md docs/INFRASTRUCTURE_SUMMARY.md docs/CHANGE_HISTORY.md
git commit -m "docs: 가상 유저 raw 테이블 IaC 편입 기록 (#300)"
```

## Task 4: spec/plan 문서 포함 및 최종 검증

- [ ] **Step 1: 이 계획과 spec 문서를 같은 브랜치에 커밋한다.**

```bash
git add docs/superpowers/specs/2026-07-22-virtual-user-raw-table-design.md \
        docs/superpowers/plans/2026-07-22-virtual-user-raw-table.md
git commit -m "docs: 가상 유저 raw 테이블 spec/plan 추가 (#300)"
```

- [ ] **Step 2: 최종 검증을 실행한다.**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
git diff origin/main --stat
```

기대: fmt/validate 통과, diff에 secret/state/tfvars 없음, 변경 파일이
`bigquery.tf` + 문서 5종뿐임을 확인한다.

## Task 5: Draft PR 생성 및 전달

- [ ] `.github/PULL_REQUEST_TEMPLATE.md` 구조를 그대로 따라 Draft PR을
  생성한다(GitHub 원격 작업이므로 사용자 확인 후 push/PR). PR 본문에 반드시
  포함할 사항:
  - CI plan 기대치: 테이블 미존재 시 `1 to add, 0 to change, 0 to destroy`,
    기존 테이블 import 후 no-op
  - IAM 변경 없음(dataset 레벨 dataEditor로 이미 충족)
  - 비용 영향 없음, 리전 변화 없음, 롤백 = `terraform state rm` + revert
- [ ] squash merge 후 사용자 승인 하에 apply(또는 기존 테이블 import)를
  수행하고, 적재 스크립트 재실행 후 `terraform plan`이 no-op인지 확인한다.
