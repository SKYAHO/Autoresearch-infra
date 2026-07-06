# GitHub Actions Terraform plan + GCP OIDC 인증 설계 (#6)

- **이슈**: [#6 [FEAT] GitHub Actions Terraform plan 및 GCP OIDC 인증 구성](https://github.com/SKYAHO/Autoresearch-infra/issues/6)
- **날짜**: 2026-07-06
- **상태**: 설계 확정(사용자 승인) → 구현 계획 대기
- **선행**: #1 ~ #5 (main 머지 완료, **GCP apply 전 상태**)

---

## 1. 목표

PR이 열릴 때마다 GitHub Actions가 Terraform `fmt / validate / plan`을 자동 실행하고, 결과를 PR 댓글로 게시한다. GCP 인증은 **service account key 파일 없이** GitHub OIDC + Workload Identity Federation(WIF)로 처리한다.

> **비전문가용 한 줄 요약**: PR을 올리면 봇이 알아서 "이 변경이 인프라에 어떤 영향을 주는지" 검사하고 결과를 댓글로 달아준다. 비밀번호(key) 파일 없이도 봇이 GCP에 안전하게 로그인한다.

## 2. 배경 및 현재 상태

| 항목 | 상태 |
|---|---|
| Terraform backend | **local** (`versions.tf`에 backend 블록 없음) → CI에서 공유 state 참조 불가 |
| `.github/` 디렉토리 | **없음** (workflow/CODEOWNERS 전무, 처음 생성) |
| repo 가시성 | **PUBLIC** (GitHub Actions 무료 한도 영향 없음) |
| `#1~#5` 코드 | main에 머지됨(최신 `e5ea31a`) |
| GCP apply | **아직 안 함** (코드만 병합) |
| 프로젝트 | `ar-infra-501108` |

**핵심 제약**: local backend로는 CI 머신이 state에 접근할 수 없다. 그래서 **GCS 원격 backend**가 본 이슈의 전제다. GCS 버킷과 WIF/CI SA는 Terraform 자체로 관리하되, dev 루트 모듈과 **분리된 `terraform/bootstrap/`** 디렉토리에 둔다(부트스트랩은 1회성, local state 유지).

## 3. 아키텍처 개요

```
┌────────────────────────────────────────────────────────────────┐
│  GitHub (PR 생성/갱신)                                            │
│     │ issues pull_request trigger                                │
│     ▼                                                            │
│  GitHub Actions Runner                                           │
│     │ 1. OIDC 토큰 발급(GitHub 내장, id-token: write)              │
│     │ 2. google-github-actions/auth@v2 → WIF로 GCP 인증            │
│     │ 3. setup-terraform → init(fmt/validate/plan)                 │
│     │ 4. plan 결과 → PR 댓글                                       │
│     ▼                                                            │
│  GCP (ar-infra-501108)                                           │
│   - WIF Pool/Provider가 GitHub OIDC 토큰 검증                     │
│   - CI SA(terraform-ci) 권한으로 dev 리소스 read/plan               │
│   - GCS 버킷(autoresearch-dev-tfstate)에서 state read/write        │
└────────────────────────────────────────────────────────────────┘

관심사 분리:
- terraform/bootstrap/  (local state) → GCS 버킷·WIF·CI SA 관리
- terraform/envs/dev/   (GCS backend) → 실제 dev 인프라 관리
```

**왜 분리하나?** backend 리소스(GCS 버킷) 자체도 Terraform으로 관리하고 싶지만, 그 버킷에 state를 저장하면 순환(닭이 먼저냐 알이 먼저냐)이 된다. 그래서 backend 인프라는 별도 디렉토리에서 local state로 관리하고, dev 본루트만 그 버킷을 backend로 쓴다. 업계 표준 패턴이다.

## 4. 구성 요소

### 4.1 `terraform/bootstrap/` (신규, local state)

부트스트랩은 1회성 수동 apply 대상. dev 루트와 별도 tfstate(로컬 파일)를 쓴다.

**리소스**:

| 리소스 | 용도 |
|---|---|
| `google_storage_bucket.tfstate` | 원격 state 저장. `autoresearch-dev-tfstate`. UBLA(true), 버전관리 On, public access 차단 |
| `google_iam_workload_identity_pool.github` | WIF 풀. `autoresearch-github` |
| `google_iam_workload_identity_pool_provider.github` | GitHub OIDC provider. issuer=`https://token.actions.githubusercontent.com`, attribute_mapping 기본 세트(repository, repository_owner, sub 등), **attribute_condition** `repository == "SKYAHO/Autoresearch-infra"` |
| `google_service_account.terraform_ci` | CI용 SA. `terraform-ci@ar-infra-501108.iam.gserviceaccount.com` |
| `google_project_iam_member.ci_viewer` | `roles/viewer` (project 한정) — plan용 read |
| `google_project_iam_member.ci_secret_accessor` | `roles/secretmanager.secretAccessor` (project 한정) — plan 시 secret data 소스 접근 |
| `google_service_account_iam_member.ci_wi` | CI SA에 `roles/iam.workloadIdentityUser`. member = `principalSet://iam.googleapis.com/<pool>/attribute.repository/SKYAHO/Autoresearch-infra` |

> **attribute_condition이 뭔가요?** GitHub에서 발급한 OIDC 토큰이 "이 저장소에서 왔다"고 검증하는 조건문이다. `repository == "SKYAHO/Autoresearch-infra"`면 다른 저장소의 PR/워크플로가 아무리 토큰을 제출해도 이 풀에 인증 불가. 브랜치 제한은 워크플로의 `if:`로 별도 처리한다.

**variables** (bootstrap):
- `project_id` (필수)
- `github_repository` (기본값 `"SKYAHO/Autoresearch-infra"` — `owner/name` 형식)

**outputs**:
- `tf_state_bucket_name`
- `tf_state_bucket_self_link`
- `wif_pool_name` (full: `projects/.../locations/global/workloadIdentityPools/autoresearch-github`)
- `wif_provider_name` (full: `.../providers/github`)
- `ci_service_account_email`

### 4.2 `terraform/envs/dev/versions.tf` (수정)

`backend "gcs"` 블록 추가. **버킷명은 dev 고정값이므로 리터럴로 지정**한다 — `terraform` 블록은 variable/local을 참조할 수 없다(초기화 시점에 평가되므로). bootstrap에서 같은 버킷명(`autoresearch-dev-tfstate`)을 생성하므로 두 곳이 일치해야 한다.

```hcl
terraform {
  required_version = ">= 1.6"
  # ... 기존 required_providers ...

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "dev/"
  }
}
```

> **왜 변수화하지 않나?** dev 환경은 단일 버킷이며, 버킷명을 바꿀 일이 없다. 변수화하려면 `terraform init -backend-config=` partial config로 주입해야 하는데, 복잡도만 늘고 이득이 없다(YAGNI).

> **state가 비어있으면 마이그레이션은?** dev는 아직 apply 전이라 state가 비어있다. 그래서 `terraform init -migrate-state`는 즉시 완료된다(옮길 게 없음). 이후 plan/apply부터 GCS를 사용.

### 4.3 `.github/workflows/terraform-plan.yml` (신규)

```yaml
name: Terraform Plan

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  id-token: write        # GitHub OIDC 토큰 발급 (GCP WIF 인증에 필수)
  contents: read         # 코드 체크아웃
  pull-requests: write   # PR 댓글 게시

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER_ID }}
          service_account: ${{ vars.CI_SA_EMAIL }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ">=1.6"
      # backend 없이 init (fmt/validate용)
      - run: terraform -chdir=terraform/envs/dev init -backend=false
      - run: terraform -chdir=terraform/envs/dev fmt -recursive -check -no-color
      - run: terraform -chdir=terraform/envs/dev validate -no-color
      # backend 포함 init (plan용, state 참조)
      - run: terraform -chdir=terraform/envs/dev init -no-color
      - run: terraform -chdir=terraform/envs/dev plan -no-color
        id: plan
        continue-on-error: true
      # plan 결과를 PR 댓글로 게시
      - uses: actions/github-script@v7
        with:
          script: |
            const out = `${{ steps.plan.outputs.stdout || '' }}`;
            // 결과 요약(길면 잘라서) 코멘트 게시
            await github.rest.issues.createComment({
              ...context.repo,
              issue_number: context.issue.number,
              body: `### Terraform Plan\n\n\`\`\`\n${out.slice(0, 60000)}\n\`\`\``,
            });
```

> **왜 init을 두 번?** fmt/validate는 backend가 없어도 된다(코드만 검사). 하지만 plan은 state를 읽어야 하므로 backend 연결이 필수다. backend 연결에 실패하면(예: GitHub variable 미설정) plan 단계에서 명확히 실패시키기 위해 단계를 나눴다.

### 4.4 GitHub repository variables (4개, **secret 불필요**)

OIDC keyless 방식이라 민감값이 없다. 전부 **variables**(평문, Actions에서 `${{ vars.X }}` 참조). 버킷명은 `versions.tf`에 리터럴로 박혀있으므로 variable에서 제외:

| variable | 값 예시 | 출처 |
|---|---|---|
| `GCP_PROJECT_ID` | `ar-infra-501108` | 고정 |
| `WIF_POOL_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github` | bootstrap output |
| `WIF_PROVIDER_ID` | `projects/<N>/locations/global/workloadIdentityPools/autoresearch-github/providers/github` | bootstrap output |
| `CI_SA_EMAIL` | `terraform-ci@ar-infra-501108.iam.gserviceaccount.com` | bootstrap output |

> `<N>`은 `ar-infra-501108`의 프로젝트 번호. bootstrap apply 후 `terraform -chdir=terraform/bootstrap output`으로 회수.

## 5. 데이터 흐름 (PR 1회 실행 시퀀스)

```
1. 기여자가 PR open/edit
2. GitHub Actions 트리거(pull_request)
3. Runner가 내장 OIDC provider로 short-lived 토큰 발급 (id-token: write 권한)
4. google-github-actions/auth@v2:
   - 토큰을 WIF provider에 제출
   - provider가 attribute_condition(repository 매칭) 검증
   - 통과 시 CI SA 권한으로 GCP access token 발급
5. terraform init(GCS backend) → state 읽기
6. terraform plan → diff 계산 (viewer + secretAccessor 권한)
7. plan 결과를 PR 댓글 게시
8. 토큰은 잡 종료 시 자동 만료(저장 안 됨)
```

## 6. IAM / 권한 모델

| 주체 | 권한 | 범위 |
|---|---|---|
| GitHub Actions (WIF 경유) | CI SA 가장 | repo 제한(`SKYAHO/Autoresearch-infra`) |
| CI SA (`terraform-ci`) | `roles/viewer` | `ar-infra-501108` project |
| CI SA | `roles/secretmanager.secretAccessor` | `ar-infra-501108` project |
| CI SA | GCS 버킷 객체 read/write | `autoresearch-dev-tfstate`(UBLA + IAM) |

**최소권한 원칙**: plan만 하므로 쓰기 권한(`roles/editor` 등)은 의도적으로 부여하지 않는다. apply 자동화가 필요해지면 별도 이슈에서 권한을 **추가**한다.

> **secretAccessor가 왜 필요한가?** dev 코드에 `google_secret_manager_secret_version` 데이터 소스 접근이 있으면, plan 단계에서도 secret 존재 확인/메타데이터 읽기가 필요하다. 다만 평문 secret 값을 봇이 출력하지는 않는다(plan 출력은 리소스 메타데이터 위주).

## 7. 보안 고려

- **keyless**: SA key 파일을 만들지 않는다. key 유출/회전 부담 제거.
- **OIDC 토큰 수명 단축**: 잡 종료 시 만료. 저장/재사용 불가.
- **repo 한정**: `attribute_condition`으로 다른 저장소 인증 차단.
- **최소권한**: viewer + secretAccessor. apply 권한 없음.
- **state 파일 민감**: GCS 버킷은 UBLA + IAM으로 보호. CI SA만 read/write.
- **PR 댓글 노출 주의**: plan 출력에 민감값이 찍히지 않는지 검토. `sensitive = true` 마킹된 output/state 필드는 plan에 `<sensitive>`로 마스킹된다(dev 코드의 CA certificate output 등).

## 8. 비용

| 항목 | 월 예상 |
|---|---|
| GitHub Actions | 무료(public repo) |
| WIF / OIDC | 무료 |
| GCS 버킷(state 수 GB 이하) | ~$0.1 미만 |
| CI SA | 무료 |
| **합계** | **거의 $0** |

## 9. 에러 처리 / 실패 시나리오

| 시나리오 | 동작 | 대응 |
|---|---|---|
| GitHub variable 미설정 | `terraform init`(backend) 실패 → 워크플로 red | variables 4개 등록 확인 |
| WIF 인증 실패 | auth step 실패 → red | attribute_condition, SA email, pool/provider ID 재확인 |
| plan 실패(문법/CIDR 등) | `continue-on-error`로 댓글까지는 게시, 이후 step은 중단 | 댓글의 에러 메시지로 원인 파악 |
| GCS 버킷 미생성 | init 실패 | bootstrap apply 선행 확인 |
| 임의 PR(포크 등) 인증 시도 | attribute_condition이 repo owner/name 미일치 → 거부 | 설계상 차단됨 |

## 10. 검증 / 테스트 전략

- **bootstrap**: `terraform -chdir=terraform/bootstrap validate` + 수동 `plan`/`apply`(GCP 인증 필요).
- **dev 루트**: `terraform -chdir=terraform/envs/dev fmt -recursive` + `validate`(로컬 가능). backend 포함 `init`/`plan`은 bootstrap apply 후.
- **workflow**: bootstrap 완료 후 임의 PR(예: README 1줄 변경)을 올려 Actions가 정상 실행되는지 확인. 실패 시 로그로 디버깅.
- 자동화된 단위 테스트는 도입하지 않는다(Terraform repo 관례상 plan이 곧 검증).

## 11. 롤백

- **backend 마이그레이션 되돌리기**: `versions.tf`에서 backend 블록 제거 → `terraform init -migrate-state`(GCS → local).
- **bootstrap 제거**: `terraform -chdir=terraform/bootstrap destroy` (GCS 버킷은 객체 있으면 실패 → 버킷 비우기 필요).
- **workflow 비활성화**: `.github/workflows/terraform-plan.yml` 삭제 또는 `disable` 처리.

## 12. 적용 순서 (구현 후)

1. `terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply` (수동 1회)
2. `terraform -chdir=terraform/bootstrap output` → 4개 값 회수
3. GitHub repo settings → Secrets and variables → Actions → **Variables** 4개 등록
4. dev 루트 `versions.tf`에 backend 블록 추가(이미 코드에 반영됨) → `terraform -chdir=terraform/envs/dev init -migrate-state`(state 비어 즉시 완료)
5. 임의 PR로 workflow 정상 동작 확인

## 13. 범위 밖 (별도 이슈)

- **main 브랜치 apply 자동화**: 별도 이슈에서 권한 확대(`roles/editor` 등) + 보안 강화와 함께 결정.
- **브랜치 단위 WIF 제한 강화**: 필요 시 provider attribute_condition에 branch 조건 추가.
- **멀티 환경(prod 등)**: backend 분리 정책 재검토.
- **GitHub Actions runner 보안 강화**(권한 최소화, OIDC 브랜치 필터 등): 차후 hardening 이슈.

## 14. 산출물(구현 시 생성/수정 파일)

- **신규**: `terraform/bootstrap/main.tf`, `terraform/bootstrap/variables.tf`, `terraform/bootstrap/outputs.tf`, `terraform/bootstrap/versions.tf`, `.github/workflows/terraform-plan.yml`, `docs/TERRAFORM_BOOTSTRAP.md`
- **수정**: `terraform/envs/dev/versions.tf`(backend 블록만 — 버킷명 리터럴, variables 변경 없음), `docs/TERRAFORM_DEV.md`(CI 섹션), `README.md`(진행 단계 한 줄)

## 15. 완료 조건 (이슈 #6 기준 매핑)

- [x] 설계: 본 문서
- [ ] PR에서 `terraform fmt/validate/plan` 실행 가능
- [ ] workflow `permissions`에 `id-token: write` 포함
- [ ] GCS 원격 backend 구성(CI가 동일 state 참조)
- [ ] CI SA + 최소 권한 key 없이(OIDC) 동작
- [ ] 필요 GitHub variables 문서화
- [ ] SA key 파일 미사용 확인
