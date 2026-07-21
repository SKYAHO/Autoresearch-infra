# Feast 피처 테이블 IaC 편입 + BigQuery ↔ Vertex AI connection 계획

> 설계: `../specs/2026-07-21-feast-feature-tables-vertex-connection-design.md`
> 관련 이슈: #280

## 구현

1. `terraform/envs/dev/vertex_ai.tf`를 신규 작성한다.
   - `google_bigquery_connection.vertex_ai` (`cloud_resource {}`,
     `location = var.bigquery_location`)
   - connection service agent에 `roles/aiplatform.user`
   - `airflow`·`airflow_batch` GSA에 `roles/aiplatform.user`
2. `terraform/envs/dev/bigquery.tf`에 Feast 피처 테이블 4종을 추가한다.
   스키마를 Terraform이 소유하고 `deletion_protection = true`를 둔다.
3. `terraform/envs/dev/locals.tf`의 `required_services`에
   `aiplatform.googleapis.com`, `bigqueryconnection.googleapis.com`을 추가한다.
4. `terraform/envs/dev/outputs.tf`에 `vertex_ai_connection_id`,
   `vertex_ai_connection_service_account` output을 추가한다.
5. `terraform/envs/dev/README.md`, `docs/TERRAFORM_DEV.md`를 갱신한다.

## 사전 검증

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

## 적용 (별도 승인 필요)

`terraform apply`는 프로젝트 owner 계정(`sk.yaho2026@gmail.com`)으로 수행한다.
팀원 계정은 `roles/viewer` 수준이라 API 활성화와 IAM 부여 권한이 없다.

### 1. API 활성화와 리전 판정

```bash
gcloud services enable aiplatform.googleapis.com --project=ar-infra-501607
```

`asia-northeast3`에서 `text-multilingual-embedding-002` 제공 여부를 실호출로
판정한다. 미지원이면 설계 문서의 대안 2가지 중 하나를 선택하고 이슈에 기록한다.

### 2. 기존 더미 테이블 drop

```bash
for t in user_static_feature user_dynamic_feature video_feature user_category_similarity; do
  bq --project_id=ar-infra-501607 rm -f -t feast_offline_store.$t
done
```

drop 전에 `bq show`로 행 수가 더미 규모(100~300행)인지 재확인한다.

### 3. plan 검토와 apply

```bash
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

`plan`에서 아래를 확인한다.

- 신규 리소스는 connection 1개, project IAM member 3개, BigQuery table 4개뿐이다.
- 기존 `data_lake_*` 테이블, dataset, GKE/Cloud SQL/Redis 등에 교체·삭제가 없다.
- IAM 변경이 `roles/aiplatform.user` 3건 외에 없다.

## 사후 검증

1. `bq show --schema` 4개 테이블이 Feast `FeatureView` 선언과 컬럼명·타입·mode가
   일치하는지 확인한다.
2. `terraform output vertex_ai_connection_id`로 배치 팀에 전달할 값을 확인한다.
3. connection 경유 임베딩 호출을 1건 실행해 권한 오류가 없는지 확인한다.
4. 배치 job 1회 실행 후 `terraform plan`을 다시 돌려 스키마 drift가 없는지
   확인한다. drift가 나오면 설계 문서의 `WRITE_TRUNCATE` 리스크 항목에 따라 배치
   팀과 적재 방식을 합의한다.

## 롤백

- 테이블: `deletion_protection = false`로 변경 후 apply, 이어서
  `terraform destroy -target=google_bigquery_table.<name>`.
- connection·IAM: 리소스 정의를 되돌리고 apply한다. 배치 측 remote model이 남아
  있으면 참조가 끊기므로 함께 정리한다.
