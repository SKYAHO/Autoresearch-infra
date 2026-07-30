# Terraform Bootstrap (1회성)

`terraform/bootstrap/` 은 dev 인프라의 **원격 state backend** 와 **CI 인증(WIF + SA)** 을 1회성으로 생성하는 별도 루트 모듈이다. local state 를 사용하고 dev 본루트(`terraform/envs/dev/`)와 분리된다(닭/알 순환 방지).

> **언제 실행하나?** 처음 1회 + bootstrap 구성 변경 시에만 수동 apply. dev 루트의 일반 plan/apply 와는 분리해서 운영한다.

## 전제

- GCP 인증 완료(`gcloud auth application-default login`)
- `container`/`compute`/`iam`/`cloudresourcemanager` 등 API 활성화(이슈 #5 에서 활성화 완료)
- 활성 `autoresearch-503903` 프로젝트 접근 권한

## 1. bootstrap apply

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

변수는 `terraform/bootstrap/terraform.tfvars`(비커밋, local 전용)에 기록해 두고 사용한다. 배포 저장소를 포함한 필수 운영 값:

```hcl
project_id = "autoresearch-503903"

# #121/#157: 배포 GitHub Actions의 WIF 토큰 발급 허용
allowed_github_repositories = [
  "SKYAHO/Autoresearch-infra",
  "SKYAHO/Autoresearch-airflow",
  "SKYAHO/Autoresearch",
]

# state 버킷 이름은 전역 유니크라 프로젝트를 넘나드는 안전한 기본값이 없다.
# 그래서 default 없는 필수 변수다(#413) — 부트스트랩 대상 프로젝트의 버킷명을
# 반드시 지정한다. 각 root `versions.tf`의 backend bucket과 같은 값이어야 한다.
state_bucket_name = "autoresearch-503903-dev-tfstate"
```

`project_id`와 `state_bucket_name`은 default가 없으므로 값을 주지 않으면
terraform이 실행 전에 멈춘다. 옛 프로젝트의 버킷명을 조용히 집어드는 사고를
막기 위한 의도된 설계다(#413).

다른 프로젝트를 대상으로 부트스트랩할 때는 기존 local state를 덮어쓰지 않도록
workspace를 분리한다(기존 state를 그대로 쓰면 기존 프로젝트의 bootstrap
리소스를 교체/파괴하려는 plan이 나온다):

```bash
terraform -chdir=terraform/bootstrap workspace new <새-프로젝트-id>
```

`allowed_github_repositories`의 변수 default도 위 세 저장소와 일치한다. 운영
tfvars에는 같은 목록을 명시해 의도를 남기며, 새 저장소를 추가할 때는 provider
허용 목록과 해당 SA의 별도 가장 바인딩을 함께 검토한다.

생성 대상: GCS 버킷(`var.state_bucket_name`에 지정한 이름), WIF 풀/프로바이더, CI SA(`terraform-ci`), IAM.

WIF provider의 `attribute_condition`은 토큰 발급 허용 리포만 결정하고, SA 가장은 SA별 `roles/iam.workloadIdentityUser` principalSet 바인딩이 별도로 필요하다(2단 경계). `terraform-ci` 가장은 infra 리포만 가능하다. Autoresearch-airflow는 dev root의 `gar_pusher` 또는 `airflow_deployer`, Autoresearch는 `workflow_dispatch`일 때 정확한 release `workflow_ref@main`, `release:published`일 때 `release` 이벤트와 정확한 workflow 경로를 조합한 `workflow_event_path`에서만 `application_pusher`를 가장할 수 있다(#221, `docs/TERRAFORM_DEV.md` 참조).

앱 이미지 배포 권한을 활성화할 때는 먼저 위 로컬 tfvars를 포함한 bootstrap
plan/apply로 provider 허용 목록을 갱신하고, 그 다음 dev root plan/apply로
`application_pusher` SA와 repository IAM을 생성한다. 어느 한 단계만 적용하면
Autoresearch workflow의 WIF 인증 또는 SA 가장이 실패한다.

CI SA는 dev root plan을 위해 `roles/viewer`, state bucket `roles/storage.objectAdmin`, custom role `ci_storage_bucket_iam_viewer`를 가진다. custom role은 Cloud Storage bucket IAM member refresh에 필요한 `storage.buckets.getIamPolicy`만 포함한다.

state 버킷은 `force_destroy=false`와 `prevent_destroy=true`로 보호한다. 버킷을 없애야 하는 경우에는 dev state 백업과 destroy 계획을 별도로 세운 뒤 lifecycle을 의도적으로 해제한다.

## 2. outputs 회수

```bash
terraform -chdir=terraform/bootstrap output -raw wif_pool_name
terraform -chdir=terraform/bootstrap output -raw wif_provider_name
terraform -chdir=terraform/bootstrap output -raw feast_dev_wif_provider_name
terraform -chdir=terraform/bootstrap output -raw feast_prod_wif_provider_name
terraform -chdir=terraform/bootstrap output -raw ci_service_account_email
```

## Feast apply WIF provider 경계

Feast apply는 기존 범용 `github` provider가 아니라 같은
`autoresearch-github` pool의 환경 전용 provider를 사용한다. 두 provider는
`SKYAHO/Autoresearch` 저장소 토큰만 허용하며, GitHub OIDC의 `environment`
claim이 다음 값과 정확히 일치해야 한다.

| provider ID | 필수 GitHub Environment | bootstrap output |
| --- | --- | --- |
| `github-feast-dev` | `dev` | `feast_dev_wif_provider_name` |
| `github-feast-prod` | `prod` | `feast_prod_wif_provider_name` |

앱 저장소의 `feast-apply.yml`은 GitHub Environment를 반드시 지정해야 하며,
각 Environment의 `WIF_PROVIDER_ID` 변수에는 표의 **동일한 환경** provider
이름을 설정한다. 예를 들어 `dev` Environment에는
`github-feast-dev` provider 이름만, `prod` Environment에는
`github-feast-prod` provider 이름만 설정한다. 교차 설정하면 OIDC provider
조건에서 거부된다. `workflow_ref` claim은 두 provider에 매핑되며, 정확한
`main` 브랜치 `feast-apply.yml` 제한은 Feast apply 서비스 계정 IAM binding에서
적용한다.

## 3. GitHub repo variables 등록(4개)

GitHub → Settings → Secrets and variables → Actions → **Variables** 에 추가(secret 아님):

| variable | 값 |
|---|---|
| `GCP_PROJECT_ID` | `autoresearch-503903` |
| `WIF_POOL_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github` |
| `WIF_PROVIDER_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github/providers/github` |
| `CI_SA_EMAIL` | `terraform-ci@autoresearch-503903.iam.gserviceaccount.com` |

`<N>` 은 프로젝트 번호. `gcloud projects describe autoresearch-503903 --format='value(projectNumber)'` 로 확인.

## 4. dev 루트 backend 마이그레이션

```bash
terraform -chdir=terraform/envs/dev init -migrate-state
```

현재 dev 루트는 GCS backend(`autoresearch-503903-dev-tfstate`, prefix `dev/`)를 사용한다. 새 환경에서 local state로 먼저 apply했다면 이 단계에서 state가 GCS로 이동한다.

## 롤백

- backend 되돌리기: `terraform/envs/dev/versions.tf` 에서 backend 블록 제거 → `terraform -chdir=terraform/envs/dev init -migrate-state`
- bootstrap 제거: state 버킷은 `prevent_destroy=true`로 보호되므로 일반 `terraform destroy`로 삭제되지 않는다. 삭제가 필요하면 state 백업 후 lifecycle을 명시적으로 해제한다.
- 앱 이미지 배포 허용 철회: Autoresearch release workflow를 먼저 비활성화하고 dev root에서 `application_pusher` 리소스를 제거한 뒤, bootstrap 로컬 tfvars의 `SKYAHO/Autoresearch` 항목을 제거한다.
- Airflow GKE 자동 배포 허용 철회: Airflow 배포 workflow를 먼저 비활성화하고
  admin root의 `airflow-deployer-admin` RoleBinding과 dev root의
  `airflow_deployer` 리소스를 제거한다.
- GitHub variables 는 Settings 에서 수동 삭제
