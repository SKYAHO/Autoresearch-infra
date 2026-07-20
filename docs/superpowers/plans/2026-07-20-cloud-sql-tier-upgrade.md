# dev Cloud SQL shared-core tier 상향 계획

> 설계: `../specs/2026-07-20-cloud-sql-tier-upgrade-design.md`
> 관련 이슈: #273

## 구현

1. `terraform/envs/dev/variables.tf`의 `db_tier` 기본값을 `db-g1-small`으로 변경한다.
2. `terraform/envs/dev/terraform.tfvars.example`의 예시값을 같은 값으로 변경한다.
3. `docs/TERRAFORM_DEV.md`와 `docs/INFRASTRUCTURE_SUMMARY.md`에 tier, 비용 영향,
   재시작·검증·롤백 절차를 반영한다.
4. 실제 apply 환경의 비공개 `terraform.tfvars`가 `db_tier`를 명시하면, 커밋하지
   않고 해당 값을 `db-g1-small`으로 갱신한다.

## 사전 검증

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars -var='db_tier=db-g1-small'
git diff --check
```

`plan`에서는 `google_sql_database_instance.dev`의 `settings.tier` 변경만 확인하고,
database·user·private IP·백업 구성의 교체 또는 삭제가 없는지 검토한다.

## 적용 및 사후 검증

`terraform apply`는 별도 승인 후 배치 작업이 없는 시간에 수행한다.

1. 자동 백업과 PITR 상태를 확인한다.
2. apply 후 Cloud SQL 인스턴스가 `RUNNABLE` 상태인지 확인한다.
3. 애플리케이션 DB 연결과 CPU·메모리 지표를 관찰한다.
4. Airflow 수동 DAG run 1회를 성공시킨다.

## 롤백

문제가 있으면 `db_tier`를 `db-f1-micro`로 되돌린 뒤 별도 apply한다. rollback에도
인스턴스 재시작이 발생한다.
