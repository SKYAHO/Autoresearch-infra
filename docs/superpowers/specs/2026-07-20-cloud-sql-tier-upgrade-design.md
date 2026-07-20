# dev Cloud SQL shared-core tier 상향 설계

> 관련 이슈: #273

## 목적

여러 애플리케이션이 같은 dev PostgreSQL 인스턴스에 동시 연결할 때의 여유를
확보하도록 기본 Cloud SQL tier를 `db-f1-micro`에서 `db-g1-small`으로 상향한다.

## 변경 결정

- `var.db_tier` 기본값과 `terraform.tfvars.example`을 `db-g1-small`으로 통일한다.
- `google_sql_database_instance.dev`는 기존처럼 `var.db_tier`를 참조하므로,
  인스턴스 이름·엔진·private IP·디스크·백업·PITR·사용자·database는 변경하지 않는다.
- 비공개 `terraform.tfvars`가 `db_tier`를 명시한 apply 환경에서는 해당 값을
  `db-g1-small`으로 갱신해야 한다. 이 파일은 저장소에 커밋하지 않는다.
- 운영 문서에 tier 변경의 재시작 영향, 적용 전후 확인, 롤백 방법과 비용 영향을 기록한다.

## 영향 및 제외 범위

- Terraform apply 시 Cloud SQL 인스턴스 재시작이 발생하므로 짧은 DB 연결 중단이
  가능하다. 배치 작업이 없는 시간에 적용한다.
- 기본 shared-core tier는 계속 Cloud SQL SLA 대상이 아니므로, 이번 변경은 고가용성
  전환이 아니다.
- 애플리케이션 connection pool 정책, HA 전환, 신규 인스턴스 생성과 DB 스키마 변경은
  후속 작업 범위다.

## 롤백

`db_tier`를 `db-f1-micro`로 되돌린 뒤 별도 `terraform apply`를 수행한다. 롤백에도
인스턴스 재시작이 발생하므로 같은 운영 창을 확보한다.
