# Terraform Bootstrap (1회성)

`terraform/bootstrap/` 은 dev 인프라의 **원격 state backend** 와 **CI 인증(WIF + SA)** 을 1회성으로 생성하는 별도 루트 모듈이다. local state 를 사용하고 dev 본루트(`terraform/envs/dev/`)와 분리된다(닭/알 순환 방지).

> **언제 실행하나?** 처음 1회 + bootstrap 구성 변경 시에만 수동 apply. dev 루트 plan/apply 와는 무관.

## 전제

- GCP 인증 완료(`gcloud auth application-default login`)
- `container`/`compute`/`iam`/`cloudresourcemanager` 등 API 활성화(이슈 #5 에서 활성화 완료)
- 활성 `ar-infra-501108` 프로젝트 접근 권한

## 1. bootstrap apply

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -var="project_id=ar-infra-501108"
```

생성 대상: GCS 버킷(`autoresearch-dev-tfstate`), WIF 풀/프로바이더, CI SA(`terraform-ci`), IAM.

## 2. outputs 회수

```bash
terraform -chdir=terraform/bootstrap output -raw wif_pool_name
terraform -chdir=terraform/bootstrap output -raw wif_provider_name
terraform -chdir=terraform/bootstrap output -raw ci_service_account_email
```

## 3. GitHub repo variables 등록(4개)

GitHub → Settings → Secrets and variables → Actions → **Variables** 에 추가(secret 아님):

| variable | 값 |
|---|---|
| `GCP_PROJECT_ID` | `ar-infra-501108` |
| `WIF_POOL_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github` |
| `WIF_PROVIDER_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github/providers/github` |
| `CI_SA_EMAIL` | `terraform-ci@ar-infra-501108.iam.gserviceaccount.com` |

`<N>` 은 프로젝트 번호. `gcloud projects describe ar-infra-501108 --format='value(projectNumber)'` 로 확인.

## 4. dev 루트 backend 마이그레이션

```bash
terraform -chdir=terraform/envs/dev init -migrate-state
```

dev 는 apply 전이라 state 가 비어있어 즉시 완료된다.

## 롤백

- backend 되돌리기: `terraform/envs/dev/versions.tf` 에서 backend 블록 제거 → `terraform -chdir=terraform/envs/dev init -migrate-state`
- bootstrap 제거: `terraform -chdir=terraform/bootstrap destroy -var="project_id=ar-infra-501108"` (버킷에 객체 남으면 `force_destroy=true` 로 자동 삭제)
- GitHub variables 는 Settings 에서 수동 삭제
