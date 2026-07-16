# 팀원 BigQuery 분석 권한 설계

> Issue: #215
> 계획: `docs/superpowers/plans/2026-07-16-team-bigquery-access.md`
> 상태: 구현 완료, apply 대기

## 배경

dev 환경에서 팀원은 GKE·Bastion 접근을 위해
`terraform/admin/gke-team-access`의 로컬 `terraform.tfvars`로 관리한다. 같은 팀원이
BigQuery 분석·Feast offline store 작업을 수행하려면 job 실행 권한과 대상 dataset의
데이터 편집 권한이 필요하다.

사람 계정의 실제 이메일을 일반 dev root, GitHub PR plan, 문서에 넣으면 공개
노출과 off-boarding churn 범위가 커진다. 따라서 기존 admin root와 별도 state라는
경계를 유지한다.

## 결정 사항

### 1. 기존 팀원 목록을 단일 입력으로 재사용

`team_member_emails`의 각 계정에 기존 GKE·Bastion 권한과 함께 BigQuery 권한을
부여한다. 실제 값은 로컬 `terraform.tfvars`에만 존재하며 Git, 이슈, PR, 문서에는
넣지 않는다.

### 2. job 실행은 프로젝트, 데이터 편집은 두 dataset으로 제한

| 범위 | 역할 | 필요 이유 |
| --- | --- | --- |
| 프로젝트 | `roles/bigquery.jobUser` | query/load/export job 생성 |
| `autoresearch_dev_analytics` | `roles/bigquery.dataEditor` | 분석 테이블 작업 |
| `feast_offline_store` | `roles/bigquery.dataEditor` | Feast/data lake 테이블 작업 |

`roles/bigquery.dataEditor`는 두 dataset의 IAM member로만 관리한다. 프로젝트 수준
Data Editor, Editor, Owner 같은 넓은 역할은 부여하지 않는다.

### 3. dataset ID는 admin root의 비밀 없는 입력으로 고정

admin root가 dev root state를 직접 참조하면 사람 IAM 분리 경계가 약해진다. 두
dataset ID는 기본값이 있는 변수로 둬 dev 이름을 명시하고, 필요 시 실제 이메일과
무관하게 override할 수 있게 한다.

### 4. 비용과 롤백

`jobUser`는 프로젝트 범위의 job 생성 권한이므로 팀원 쿼리와 load job은
`maximum_bytes_billed` 같은 job 수준 비용 제한을 사용한다. IAM binding 자체의
비용과 리전 영향은 없다.

퇴사/롤백 시 로컬 `team_member_emails`에서 계정을 제거하고 apply한다. 해당 계정의
GKE·Bastion·BigQuery IAM member만 non-authoritative하게 제거되며, 기존 데이터와
dataset은 변경되지 않는다. 이미 발급된 access token은 최대 약 1시간까지 남을 수
있으므로 긴급 차단은 GCP 세션 종료를 병행한다.
