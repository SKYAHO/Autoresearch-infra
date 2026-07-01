# autoresearch-infra GitHub 운영 가이드

이 문서는 `autoresearch-infra` 저장소에서 GCP 인프라 변경을 issue, branch, pull request, GitHub Projects, Claude Code PR Review로 관리하는 방법을 정리합니다.

- 기준 저장소: `SKYAHO/autoresearch-infra`
- 기준 Project: `SKYAHO / autoresearch-infra`
- 확인일: 2026-07-01

## 핵심 원칙

```text
Issue 생성 -> Project Todo -> Branch 생성 -> 인프라 변경 -> PR 생성 -> Review -> Squash Merge -> Project Done
```

- **Issue는 작업의 시작점**입니다. GCP 리소스, Terraform/IaC, GitHub Actions, IAM, secret, 운영 문서 변경은 먼저 issue로 만듭니다.
- **Branch는 issue 번호를 포함**합니다. 어떤 인프라 변경을 위한 브랜치인지 추적하기 쉽게 만듭니다.
- **PR은 issue를 닫는 단위**입니다. PR 본문에 `Closes #이슈번호`를 넣습니다.
- **인프라 변경은 안전성 중심으로 리뷰**합니다. 권한, 비용, 리전, 롤백, secret 노출 여부를 확인합니다.

## 저장소 범위

이 저장소는 AutoResearch 프로젝트의 GCP 기반 인프라를 관리합니다.

현재 초기 세팅:

- `.github/ISSUE_TEMPLATE/*.yml`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/CODEOWNERS`
- `.github/workflows/claude.yml`
- `README.md`, `CONTRIBUTING.md`, 운영 문서
- `docs/GITHUB_LABELS_AND_PROJECT.md`
- GCP/IaC 작업을 고려한 `.gitignore`

추후 관리 대상:

- Terraform root/module/environment 구성
- GCP IAM, service account, Secret Manager
- Artifact Registry, Cloud Run, Cloud Scheduler
- GCS, BigQuery, Logging, Monitoring
- GitHub Actions 기반 plan/apply 또는 검증 workflow

애플리케이션 기능 구현은 이 저장소 범위가 아닙니다. 단, 애플리케이션을 실행하기 위한 GCP 인프라와 배포 자동화는 이 저장소에서 관리합니다.

## 현재 GitHub 설정

### Issue Forms

| Form 파일 | 제목 prefix | 자동 label | 사용 상황 |
|---|---|---|---|
| `feature.yml` | `[FEAT]` | `feature` | GCP 인프라, IaC, GitHub 자동화 추가/개선 |
| `bug.yml` | `[BUG]` | `bug` | 권한, workflow, 리소스 설정, 자동화 오류 |
| `experiment.yml` | `[EXP]` | `experiment` | GCP 구성, Terraform 방식, 운영 정책 실험 |

`blank_issues_enabled: false`이므로 빈 issue는 만들 수 없습니다.

### Pull Request

PR template은 다음을 확인하도록 구성합니다.

- 변경한 인프라 범위
- 관련 이슈: `Closes #`
- IAM/secret/비용/리전/롤백 영향
- 검증 결과
- 리뷰어 참고사항

### Claude Code PR Review

`.github/workflows/claude.yml`은 PR이 열리거나 Draft에서 Ready for review가 될 때 Claude Code 리뷰를 실행합니다.

필요한 GitHub secret:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

Claude 리뷰는 이해도 확인 inline comment를 남기도록 설정되어 있습니다. trivial, docs-only, formatting-only 변경에는 이해도 확인 comment를 남기지 않는 정책입니다.

## 언제 Issue를 만드는가

다음 상황에서는 issue를 먼저 만듭니다.

- GCP 리소스를 추가, 수정, 삭제할 때
- Terraform module, environment, backend 구성을 바꿀 때
- IAM 권한, service account, Secret Manager 설정을 바꿀 때
- GitHub Actions workflow, Claude Review, OIDC, 배포 자동화를 바꿀 때
- 비용, 리전, 보안, 운영 정책을 검증하는 실험을 할 때
- 운영 문서 또는 runbook을 추가하거나 수정할 때

## Issue 작성법

### Feature

제목 예시:

```text
[FEAT] Cloud Run Job 인프라 정의 추가
```

form 핵심 항목:

- 목적
- 작업 범위
- 영향받는 인프라 영역
- 완료 조건

### Bug

제목 예시:

```text
[BUG] Secret Manager 접근 권한 오류 수정
```

form 핵심 항목:

- 현상
- 재현 방법
- 기대 동작
- 실제 동작
- 영향받는 인프라 영역
- 실행 환경 또는 로그

### Experiment

제목 예시:

```text
[EXP] Terraform state backend 구성 비교
```

form 핵심 항목:

- 가설
- 실험 대상
- 판정 기준
- 실험 설정
- 결과

## Branch 컨벤션

```bash
git switch main
git pull origin main
git switch -c feat/12-add-cloud-run-job
```

| 작업 유형 | 형식 | 예시 |
|---|---|---|
| 기능 | `feat/이슈번호-간략한-설명` | `feat/12-add-cloud-run-job` |
| 버그 | `fix/이슈번호-간략한-설명` | `fix/18-fix-secret-access` |
| 실험 | `exp/이슈번호-간략한-설명` | `exp/21-terraform-state-backend` |
| 문서 | `docs/이슈번호-간략한-설명` | `docs/7-update-gcp-runbook` |
| 리팩터링 | `refactor/이슈번호-간략한-설명` | `refactor/15-split-iam-module` |
| 기타 | `chore/이슈번호-간략한-설명` | `chore/3-setup-codeowners` |

## Commit 컨벤션

```text
<type>: <한국어 설명>
```

| type | 의미 |
|---|---|
| `feat` | GCP 인프라 리소스, IaC, GitHub 자동화 추가 |
| `fix` | 인프라 설정, 권한, workflow, 문서 오류 수정 |
| `exp` | GCP 구성, Terraform 방식, 운영 자동화 실험 |
| `docs` | 운영 문서 추가 또는 수정 |
| `refactor` | 동작 변화 없는 IaC/문서/설정 구조 정리 |
| `chore` | 저장소 기본 설정, CODEOWNERS, 관리 작업 |

예시:

```text
feat: Cloud Run Job 인프라 정의 추가
fix: Secret Manager 접근 권한 수정
docs: GCP 운영 가이드 업데이트
chore: CODEOWNERS 담당 영역 정리
```

## PR 리뷰 기준

리뷰어는 다음을 확인합니다.

- 변경 목적과 issue가 일치하는가
- 대상 GCP 프로젝트, 리전, 리소스 이름이 명확한가
- IAM 권한이 최소 권한 원칙을 따르는가
- secret 값, service account key, Terraform state가 포함되지 않았는가
- 비용 영향과 quota 영향이 설명되어 있는가
- 삭제/교체/권한 확대 변경의 롤백 방법이 있는가
- workflow 권한과 GitHub secret 이름이 적절한가

## 기본 검증

현재 GitHub 초기 세팅 단계의 기본 검증:

```bash
git diff --check
```

Terraform/IaC 파일이 추가된 뒤에는 아래 검증을 PR template에 포함합니다.

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

`terraform plan`은 실제 GCP project id와 인증이 준비된 뒤 실행합니다. 로컬 `terraform.tfvars`와 state/plan 파일은 커밋하지 않습니다.

## Label 및 Project 운영

label과 Project 상태는 [docs/GITHUB_LABELS_AND_PROJECT.md](docs/GITHUB_LABELS_AND_PROJECT.md)를 기준으로 관리합니다.

필수 label:

| label | 사용 기준 |
|---|---|
| `feature` | GCP 인프라, IaC, GitHub 자동화 추가/개선 |
| `bug` | 권한, workflow, 리소스 설정, 자동화 오류 |
| `experiment` | GCP 구성, Terraform 방식, 운영 정책 실험 |
| `documentation` | 운영 문서 변경 |
| `chore` | 저장소 설정, label, Project, CODEOWNERS 관리 |
| `question` | 결정이 필요한 질문 또는 확인 요청 |

인프라 분류 label:

| label | 사용 기준 |
|---|---|
| `gcp` | GCP 리소스 전반 |
| `terraform` | Terraform/IaC 변경 |
| `iam` | IAM, service account, 권한 변경 |
| `ci-cd` | GitHub Actions, 배포/검증 자동화 |
| `security` | secret, 접근 제어, 보안 정책 |
| `cost` | 비용, quota, 리소스 크기 조정 |

Project 기본 상태는 `Todo`, `In Progress`, `Done`을 사용합니다. 권장 auto-add filter는 아래와 같습니다.

```text
is:issue,pr is:open repo:SKYAHO/Autoresearch-infra
```

## 추천 GitHub 저장소 설정

### Merge 설정

- `Allow squash merging`: 켜기
- `Allow merge commits`: 끄기
- `Allow rebase merging`: 끄기
- `Automatically delete head branches`: 켜기

### Branch protection 또는 ruleset

`main` 브랜치에는 다음 규칙을 권장합니다.

- 직접 push 금지
- PR을 통한 변경만 허용
- 최소 1명 approve 필요
- conversation resolved 필요
- Claude Code PR Review workflow가 안정화되면 required check로 지정
- Terraform plan workflow가 생기면 required check로 지정

### GitHub Secrets

초기 단계에서 필요한 secret:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

GCP 배포 자동화 단계에서는 service account key 파일보다 GitHub OIDC 기반 Workload Identity Federation을 우선 검토합니다.

### CODEOWNERS

현재 `.github/CODEOWNERS`는 placeholder 상태입니다. 실제 팀원 계정이나 GitHub team으로 교체해야 자동 reviewer 지정이 의미 있게 동작합니다.

예:

```text
/.github/   @SKYAHO/infra-maintainers
/terraform/ @SKYAHO/platform
/gcp/       @SKYAHO/platform
/*.md       @SKYAHO/infra-docs
```

## 자주 생기는 문제

### Claude 리뷰가 실행되지 않는 경우

- repository secret `CLAUDE_CODE_OAUTH_TOKEN`이 등록되어 있는지 확인합니다.
- PR이 Draft 상태인지 확인합니다.
- workflow event가 `opened`, `ready_for_review`인지 확인합니다.
- GitHub Actions 권한이 workflow 실행을 허용하는지 확인합니다.

### GCP 인증 workflow가 실패하는 경우

- GitHub OIDC provider와 service account binding을 확인합니다.
- workflow `permissions`에 `id-token: write`가 있는지 확인합니다.
- 대상 GCP project id와 service account email이 맞는지 확인합니다.
- 필요한 IAM role이 최소 권한으로 부여되어 있는지 확인합니다.

### Issue가 자동으로 닫히지 않는 경우

- PR 본문에 `Closes #이슈번호`가 있는지 확인합니다.
- PR이 default branch인 `main`으로 merge되었는지 확인합니다.
- issue 번호가 같은 repository의 번호인지 확인합니다.
