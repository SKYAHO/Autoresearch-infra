# dev 환경 좌표 카탈로그 구현 계획

> **에이전트 작업자용:** 이 계획을 구현할 때는 `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans`를 사용하고, 체크박스 단위로 완료 상태를 갱신한다.

**목표:** dev 환경의 비밀이 아닌 GCP 좌표를 infra 저장소의 단일 카탈로그로 옮기고, Terraform·CI가 검증된 카탈로그 입력만 사용하게 만든다.

**아키텍처:** `config/environments/dev/environment.yaml`을 정본으로 두고 Ruby 표준 라이브러리 기반 검증기·래퍼가 Terraform root별 backend 인수와 비밀 없는 var-file을 생성한다. Terraform backend의 초기화 제약은 빈 backend 블록과 `-backend-config` 인수로 분리하고, GitHub Actions의 WIF bootstrap anchor는 카탈로그 project ID와 대조해 fail-closed 처리한다.

**기술 스택:** Terraform 1.6 이상, hashicorp/google provider, Ruby 표준 라이브러리(Psych·JSON·OptionParser), POSIX shell, GitHub Actions.

## 전역 제약

- 대상은 현재 dev 환경 하나이며 staging/prod 환경 생성·실제 프로젝트/리전 전환·`terraform apply`는 이 계획의 범위 밖이다.
- 카탈로그에는 project ID, region, zone, CIDR, 이름·state 좌표만 넣고 secret, state, 실제 tfvars, service account key, OAuth 값은 넣지 않는다.
- 프로젝트 번호·endpoint·예약 IP처럼 GCP가 생성하는 값은 Terraform data source 또는 output을 사용하며, region에서 임의 zone을 선택하지 않는다.
- Terraform 리소스 주소·리소스 이름·IAM 권한·네트워크 노출을 이 리팩터링에서 변경하지 않는다.
- GitHub 원격 쓰기와 실제 GCP 변경은 명시 승인을 받은 뒤에만 수행한다.
- 각 커밋에는 관련 Markdown 문서와 `../second-brain/wiki/log.md` 작업 기록을 포함하고, 주석·Markdown·커밋 메시지는 한국어로 작성한다.

---

## 파일 구조와 책임

| 경로 | 책임 |
| --- | --- |
| `config/environments/dev/environment.yaml` | dev의 비밀 없는 좌표 정본 |
| `scripts/environment_catalog.rb` | YAML 파싱, 스키마 검증, root별 Terraform JSON/backend 값 생성 |
| `scripts/test-environment-catalog.rb` | 누락·불일치 입력을 차단하는 회귀 테스트 |
| `scripts/terraform-env` | 카탈로그 검증 뒤 Terraform에 backend·var-file을 전달하는 단일 진입점 |
| `terraform/**/versions.tf` | 하드코딩 값 없는 `backend "gcs" {}` 선언 |
| `terraform/**/variables.tf` | 카탈로그가 공급하는 좌표 입력의 기본값 제거·검증 유지 |
| `.github/workflows/{terraform-plan,terraform-drift,apply}.yml` | 카탈로그 래퍼 사용과 bootstrap anchor 대조 |
| `docs/ENVIRONMENT_CATALOG.md` | 로컬/CI 초기화, migration·롤백·소비자 계약 |
| `docs/MIGRATION_RUNBOOK.md` | 정본→사본→소비자 전환 검증 순서 |

## Task 1: 환경 카탈로그 파서와 스키마 검증

**Files:**
- Create: `config/environments/dev/environment.yaml`
- Create: `scripts/environment_catalog.rb`
- Create: `scripts/test-environment-catalog.rb`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `environment.yaml`의 `schema_version`, `environment`, `gcp`, `network`, `state`, `terraform_roots` 키
- Produces: `EnvironmentCatalog.load(path) -> EnvironmentCatalog`, `validate! -> nil`, `terraform_variables(root) -> Hash<String, Object>`, `backend_config(root) -> Hash<String, String>`

- [ ] **Step 1: 실패하는 카탈로그 테스트를 작성한다.**

```ruby
catalog = EnvironmentCatalog.load(valid_catalog_path)
raise "project_id 누락을 차단하지 못했습니다" unless raises_catalog_error? do
  EnvironmentCatalog.load(missing_project_id_path).validate!
end
raise "zone-region 불일치를 차단하지 못했습니다" unless raises_catalog_error? do
  EnvironmentCatalog.load(mismatched_zone_path).validate!
end
raise "backend prefix 누락을 차단하지 못했습니다" unless raises_catalog_error? do
  catalog.backend_config("terraform/admin/airflow-k8s")
end
```

- [ ] **Step 2: 테스트가 실패함을 확인한다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: FAIL, `cannot load such file` 또는 `EnvironmentCatalog` 미정의.

- [ ] **Step 3: 최소 파서와 카탈로그를 구현한다.**

`environment.yaml`에는 다음 구조를 사용한다. 값은 현재 dev의 비밀 없는 값만 넣으며 IP endpoint와 secret은 넣지 않는다.

```yaml
schema_version: 1
environment: dev
gcp:
  project_id: autoresearch-503903
  region: asia-northeast3
  zone: asia-northeast3-a
  name_prefix: autoresearch
state:
  bucket: autoresearch-503903-dev-tfstate
  roots:
    terraform/envs/dev: dev/
    terraform/admin/airflow-k8s: admin/airflow-k8s/
network:
  dev_subnet_cidr: 10.10.0.0/20
  private_services_cidr: 192.168.0.0/20
```

`EnvironmentCatalog#validate!`은 키 존재, `environment == "dev"`, project ID·bucket·prefix 형식, `zone.start_with?("#{region}-")`, CIDR 형식, 모든 Terraform root의 backend prefix 존재를 검사하고 하나라도 틀리면 `CatalogError`를 발생시킨다. 생성 경로는 `terraform/.generated/`로 한정하고 `.gitignore`에 추가한다.

- [ ] **Step 4: 테스트를 통과시킨다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: PASS, 유효 카탈로그와 세 가지 실패 mutation이 모두 기대대로 처리됨.

- [ ] **Step 5: 첫 번째 커밋을 만든다.**

```bash
git add config/environments/dev/environment.yaml scripts/environment_catalog.rb scripts/test-environment-catalog.rb .gitignore
git commit -m "feat: dev 환경 좌표 카탈로그 추가"
```

## Task 2: Terraform 초기화 래퍼와 backend 리터럴 제거

**Files:**
- Create: `scripts/terraform-env`
- Modify: `terraform/envs/dev/versions.tf`
- Modify: `terraform/admin/*/versions.tf`
- Modify: `terraform/README.md`
- Test: `scripts/test-environment-catalog.rb`

**Interfaces:**
- Consumes: `scripts/environment_catalog.rb`, `config/environments/dev/environment.yaml`, `--environment dev`, `--root <terraform root>`, Terraform 명령 인수
- Produces: `<root>/.environment.auto.tfvars.json`, `terraform init -backend-config=bucket=... -backend-config=prefix=...`

- [ ] **Step 1: backend/var-file 생성 실패 테스트를 추가한다.**

```ruby
Dir.mktmpdir do |dir|
  generated = EnvironmentCatalog.load(catalog_path).write_terraform_inputs!(
    root: "terraform/envs/dev", output_root: dir
  )
  raise "project_id가 생성되지 않았습니다" unless JSON.parse(File.read(generated[:var_file])).fetch("project_id") == "autoresearch-503903"
  raise "backend bucket이 다릅니다" unless File.read(generated[:backend_file]).include?("bucket = \"autoresearch-503903-dev-tfstate\"")
end
```

- [ ] **Step 2: 테스트가 실패함을 확인한다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: FAIL, `write_terraform_inputs!` 미정의.

- [ ] **Step 3: 생성기와 래퍼를 구현한다.**

`write_terraform_inputs!`는 root 내부의 gitignored `.environment.auto.tfvars.json`와 `.environment.backend.hcl`만 생성한다. `scripts/terraform-env`는 `--environment`을 `dev`만 허용하고 root가 카탈로그 `state.roots`에 있을 때만 backend를 초기화한다. `terraform/bootstrap`은 state bucket을 만들기 전 실행되는 backend 없는 root이므로 var-file만 생성·전달한다. `init -backend=false`가 포함되면 어떤 root에서도 backend 파일과 `-backend-config`를 넘기지 않는다.

```sh
terraform -chdir="$ROOT" init -backend-config="$BACKEND_FILE" "$@" # backend 사용 root이며 -backend=false가 아닐 때만
terraform -chdir="$ROOT" "$COMMAND" "$@"
```

`versions.tf`의 모든 GCS backend는 다음처럼 비워 둔다. bucket/prefix 문자열은 남기지 않는다.

```hcl
backend "gcs" {}
```

`terraform/README.md`에는 직접 `terraform init` 대신 래퍼를 쓰는 명령, 생성 파일의 비커밋 원칙, backend 변경 뒤 `-reconfigure`가 필요한 이유를 기록한다.

- [ ] **Step 4: 모든 root에서 정적 초기화·검증을 통과시킨다.**

Run: `scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false -input=false && scripts/terraform-env --environment dev --root terraform/envs/dev validate`
Expected: PASS.

Run: `for root in terraform/admin/*; do scripts/terraform-env --environment dev --root "$root" init -backend=false -input=false && scripts/terraform-env --environment dev --root "$root" validate; done`
Expected: 모든 admin root PASS. 실제 backend 접근·plan·apply는 수행하지 않음.

- [ ] **Step 5: 두 번째 커밋을 만든다.**

```bash
git add scripts/terraform-env terraform terraform/README.md
git commit -m "refactor: Terraform backend 좌표를 카탈로그로 분리"
```

## Task 3: Terraform root 좌표 입력을 카탈로그로 수렴

**Files:**
- Modify: `terraform/envs/dev/variables.tf`, `terraform/envs/dev/terraform.tfvars.example`, `terraform/envs/dev/locals.tf`
- Modify: `terraform/bootstrap/{variables.tf,README.md}`
- Modify: `terraform/admin/*/{variables.tf,terraform.tfvars.example,README.md}`
- Modify: `docs/TERRAFORM_DEV.md`, `docs/TERRAFORM_BOOTSTRAP.md`
- Test: `scripts/test-environment-catalog.rb`

**Interfaces:**
- Consumes: Task 2가 생성한 `.environment.auto.tfvars.json`
- Produces: 모든 root에서 동일한 `project_id`, `region`, `zone`, `name_prefix`, GKE cluster, CIDR, state 좌표 계약

- [ ] **Step 1: 좌표 기본값 재발을 잡는 정적 테스트를 작성한다.**

```ruby
forbidden = ["autoresearch-503903", "asia-northeast3", "asia-northeast3-a"]
terraform_files.each do |path|
  next if path.include?("terraform.tfvars.example")
  forbidden.each do |value|
    raise "#{path}에 좌표 리터럴이 남았습니다: #{value}" if File.read(path).include?(value)
  end
end
```

과거 사실을 보존해야 하는 migration spec·change history와 예시 파일은 이 검사에서 제외하고, 현재 실행되는 `.tf`·workflow·deploy 파일만 검사한다.

- [ ] **Step 2: 테스트가 현재 코드에서 실패함을 확인한다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: FAIL, `versions.tf` 또는 admin `variables.tf`의 기존 project/region/zone 리터럴을 보고.

- [ ] **Step 3: root별 입력을 전환한다.**

각 root에서 `project_id`, `region`, `zone`, GKE cluster 이름, 공통 CIDR, 환경 prefix의 실행 기본값을 제거하고 카탈로그 생성 var-file에서 받는다. 비밀값과 사람 이메일 변수의 빈 기본값은 유지한다. bootstrap은 backend 자체를 만들기 전 실행되므로 `scripts/terraform-env bootstrap`이 카탈로그의 project·region·bucket을 `-var`로 전달하게 하고, `state_bucket_name`을 카탈로그와 다른 값으로 넘기면 검증 실패시킨다.

기존 이름 조립은 `var.name_prefix`, `var.environment`, `data.google_project.current.number`을 유지해 현 dev 카탈로그에서는 plan상 리소스 주소·이름이 바뀌지 않게 한다. defaults 제거가 신규 환경의 값 누락을 조기에 실패시키는지 각 variable validation으로 확인한다.

- [ ] **Step 4: 정적 검사와 Terraform 검증을 통과시킨다.**

Run: `ruby scripts/test-environment-catalog.rb && terraform -chdir=terraform/envs/dev fmt -check -recursive && git diff --check`
Expected: PASS.

Run: `scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false -input=false && scripts/terraform-env --environment dev --root terraform/envs/dev validate`
Expected: PASS.

- [ ] **Step 5: 세 번째 커밋을 만든다.**

```bash
git add terraform docs/TERRAFORM_DEV.md docs/TERRAFORM_BOOTSTRAP.md
git commit -m "refactor: dev Terraform 좌표 입력을 카탈로그로 통합"
```

## Task 4: infra CI·배포 소비자의 fail-closed 전환

**Files:**
- Modify: `.github/workflows/terraform-plan.yml`
- Modify: `.github/workflows/terraform-drift.yml`
- Modify: `.github/workflows/apply.yml`
- Modify: `scripts/environment_catalog.rb`, `scripts/test-environment-catalog.rb`
- Modify: `deploy/{mlflow,serving,agent-orchestration}/**/*.yaml`
- Modify: `docs/ENVIRONMENT_CATALOG.md`, `docs/MIGRATION_RUNBOOK.md`

**Interfaces:**
- Consumes: 카탈로그 project ID와 기존 GitHub Environment 변수 `GCP_PROJECT_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`, `DEV_APPLY_SA_EMAIL`, `ADMIN_APPLY_SA_EMAIL`
- Produces: project ID 불일치 시 Terraform plan/apply 이전에 실패하는 CI, Terraform output 또는 렌더 입력만 사용하는 deploy 좌표

- [ ] **Step 1: bootstrap anchor 불일치 테스트를 추가한다.**

```ruby
result = EnvironmentCatalog.compare_bootstrap_anchor!(
  catalog: valid_catalog,
  project_id: "other-project"
)
raise "불일치 project ID를 허용했습니다" unless result.is_a?(EnvironmentCatalog::CatalogError)
```

- [ ] **Step 2: 테스트가 실패함을 확인한다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: FAIL, `compare_bootstrap_anchor!` 미정의 또는 불일치 허용.

- [ ] **Step 3: workflow와 매니페스트 소비 경로를 구현한다.**

workflow는 checkout 후 카탈로그 검증과 `GCP_PROJECT_ID` 비교를 먼저 실행하고, 같을 때만 OIDC 인증과 `scripts/terraform-env`를 실행한다. 기존 WIF/SA 변수는 삭제하지 않으며, 카탈로그가 이를 대체하지 않는 bootstrap anchor임을 주석과 문서에 명시한다. plan 원문·state·secret은 기존처럼 로그/댓글에 게시하지 않는다.

매니페스트의 project ID, region, bucket, ILB IP 리터럴은 직접 치환하지 않는다. ArgoCD가 렌더할 수 있는 Kustomize overlay 또는 Terraform templatefile 중 하나를 선택한 별도 변경으로 전환해야 하므로, 이 PR에서는 리터럴 전체 목록·소유자·소비 경로를 `docs/ENVIRONMENT_CATALOG.md`에 등록하고 실행 경로가 없는 값은 변경하지 않는다. `loadBalancerIP`는 Terraform output 정본이며 app/airflow PR 전환 전까지 migration runbook의 세 값 일치 검사로 보호한다.

- [ ] **Step 4: workflow 정적 검사와 음성 테스트를 통과시킨다.**

Run: `ruby scripts/test-environment-catalog.rb && actionlint .github/workflows/terraform-plan.yml .github/workflows/terraform-drift.yml .github/workflows/apply.yml && git diff --check`
Expected: PASS. `actionlint`가 설치되지 않았으면 CI `lint`에서 확인할 항목으로 PR 본문에 기록한다.

- [ ] **Step 5: 네 번째 커밋을 만든다.**

```bash
git add .github scripts deploy docs
git commit -m "feat: infra CI에 환경 좌표 검증 추가"
```

## Task 5: 세 저장소 소비자 전환의 이슈·문서 경계 확정

**Files:**
- Modify: `docs/ENVIRONMENT_CATALOG.md`
- Modify: `docs/MIGRATION_RUNBOOK.md`
- Modify: `docs/CHANGE_HISTORY.md`
- Modify: `../second-brain/wiki/topics/Autoresearch-infra-작업-컨텍스트-2026-08-01.md`
- Modify: `../second-brain/wiki/log.md`

**Interfaces:**
- Consumes: infra 카탈로그 스키마와 CI 검증 계약
- Produces: `Autoresearch`·`Autoresearch-airflow`가 참조할 path·신뢰된 ref·bootstrap 검증·PR 순서·롤백 순서를 명시한 소비자 계약

- [ ] **Step 1: 소비자 계약 누락 검사를 작성한다.**

```ruby
required = ["SKYAHO/Autoresearch", "SKYAHO/Autoresearch-airflow", "config/environments/dev/environment.yaml", "GCP_PROJECT_ID", "롤백"]
document = File.read("docs/ENVIRONMENT_CATALOG.md")
missing = required.reject { |term| document.include?(term) }
raise "소비자 계약 누락: #{missing.join(', ')}" unless missing.empty?
```

- [ ] **Step 2: 문서가 현재 상태에서 실패함을 확인한다.**

Run: `ruby scripts/test-environment-catalog.rb`
Expected: FAIL, `docs/ENVIRONMENT_CATALOG.md` 부재 또는 필수 계약 누락.

- [ ] **Step 3: 후속 저장소 작업을 문서와 이슈로 분리한다.**

문서에 다음을 고정한다.

1. `Autoresearch` 이슈: release·feast apply·code archive workflow가 보호된 infra `main`의 카탈로그를 checkout하고 project/AR/GCS/BigQuery 좌표 불일치를 배포 전에 차단한다.
2. `Autoresearch-airflow` 이슈: build-and-push·deploy-gke-dev workflow와 Helm values가 같은 카탈로그를 검증하고 GKE·Cloud SQL·GCS 좌표를 렌더 입력으로 받는다.
3. 각 저장소는 해당 Issue Form으로 이슈를 만들고, 이슈의 Create a branch로 브랜치를 생성하며, infra 카탈로그 commit SHA와 검증 결과를 PR 본문에 기록한다.
4. 실제 migration은 infra → 이미지/데이터/시크릿 복사 → app → Airflow → e2e 검증 순서다. 이전 프로젝트 삭제·DNS 전환·apply는 별도 승인 이슈다.

`CHANGE_HISTORY.md`에는 카탈로그 도입의 장기 결정만 한 단락으로 남기고, second-brain에는 구현 상태·미전환 소비자·실제 apply 미수행을 기록한다.

- [ ] **Step 4: 문서 계약 검사와 전체 검증을 통과시킨다.**

Run: `ruby scripts/test-environment-catalog.rb && terraform -chdir=terraform/envs/dev fmt -check -recursive && terraform -chdir=terraform/envs/dev validate && git diff --check`
Expected: PASS. 실제 GCP 인증, `terraform plan`, state migration, secret copy, apply는 실행하지 않음.

- [ ] **Step 5: 다섯 번째 커밋을 만든다.**

```bash
git add docs/ENVIRONMENT_CATALOG.md docs/MIGRATION_RUNBOOK.md docs/CHANGE_HISTORY.md
git commit -m "docs: 환경 좌표 소비자 전환 절차 기록"
```

`../second-brain/wiki/` 변경은 infra 저장소 커밋에 포함하지 않는다. 해당 볼트의
`wiki/log.md` append-only 규칙에 따라 별도 작업 기록으로 저장한다.

## PR 전 최종 검증

- [ ] `ruby scripts/test-environment-catalog.rb`
- [ ] `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- [ ] `scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false -input=false`
- [ ] `scripts/terraform-env --environment dev --root terraform/envs/dev validate`
- [ ] 모든 admin root의 `scripts/terraform-env ... init -backend=false` 및 `validate`
- [ ] `git diff --check`
- [ ] `git status`에서 state, `.terraform/`, `.environment.*`, 실제 tfvars, secret, key가 없음을 확인
- [ ] PR 본문에 `Closes #491`, 카탈로그 schema version, IAM·비용·리전·롤백 영향, `plan` 미실행 또는 결과를 기록
