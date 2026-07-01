# autoresearch-infra GitHub 협업 운영 가이드

## Notion 속성 추천

| Property | Value |
|---|---|
| 문서 유형 | Team Wiki / How-to |
| 상태 | Active |
| 담당 | Repository Maintainer |
| 태그 | GCP, Infrastructure, GitHub, Pull Request, Projects, Workflow, Claude Review |
| 기준 저장소 | `SKYAHO/autoresearch-infra` |
| 기준 Project | `SKYAHO / autoresearch-infra` |
| 마지막 업데이트 | 2026-07-01 |

## 한 줄 요약

`autoresearch-infra`는 **AutoResearch 프로젝트의 GCP 인프라 변경을 issue로 정의하고, branch에서 수정하고, PR로 리뷰/병합하며, GitHub Projects로 상태를 추적**한다.

```text
Issue 생성 -> Project Todo -> Branch 생성 -> 인프라 변경 -> PR 생성 -> Review -> Squash Merge -> Project Done
```

## 저장소 범위

현재는 GitHub 초기 세팅 단계이며, 이후 GCP 인프라 코드를 이 저장소에서 관리한다.

현재 포함:

- Issue Forms
- Pull Request template
- CODEOWNERS
- Claude Code PR Review workflow
- GitHub 운영 문서
- GCP/IaC 작업을 고려한 `.gitignore`

추후 포함:

- Terraform root/module/environment 구성
- GCP IAM, service account, Secret Manager
- Artifact Registry, Cloud Run, Cloud Scheduler
- GCS, BigQuery, Logging, Monitoring
- GitHub Actions 기반 plan/apply 또는 검증 workflow

## 현재 운영 상태

### Issue Forms

| Form 파일 | 제목 prefix | 자동 label | 사용 상황 |
|---|---|---|---|
| `feature.yml` | `[FEAT]` | `feature` | GCP 인프라, IaC, GitHub 자동화 추가/개선 |
| `bug.yml` | `[BUG]` | `bug` | 권한, workflow, 리소스 설정, 자동화 오류 |
| `experiment.yml` | `[EXP]` | `experiment` | GCP 구성, Terraform 방식, 운영 정책 실험 |

### Claude Code PR Review

`.github/workflows/claude.yml`은 PR이 열리거나 Draft에서 Ready for review가 될 때 Claude Code 리뷰를 실행한다.

필수 secret:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

### Project 자동화

권장 자동 추가 필터:

```text
is:issue,pr is:open repo:SKYAHO/autoresearch-infra
```

권장 상태:

- `Todo`: 아직 시작하지 않은 작업
- `In Progress`: branch를 만들고 진행 중인 작업
- `Done`: merge 또는 close된 작업

## 팀 작업 원칙

1. GCP 인프라 변경은 가능한 한 issue에서 시작한다.
2. branch 이름에는 issue 번호를 포함한다.
3. PR 본문에는 `Closes #이슈번호`를 넣는다.
4. PR은 작게 유지한다.
5. 권한, 비용, 리전, secret, 롤백 가능성을 반드시 확인한다.
6. merge는 Squash and merge를 기본으로 한다.
7. Project는 현재 상태를 보여주는 보드로 사용한다.

## 언제 Issue를 만드는가

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

form 필수 내용:

- 목적
- 작업 범위
- 영향받는 인프라 영역
- 완료 조건

### Bug

제목 예시:

```text
[BUG] Secret Manager 접근 권한 오류 수정
```

form 필수 내용:

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

form 필수 내용:

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

예시:

```text
feat: Cloud Run Job 인프라 정의 추가
fix: Secret Manager 접근 권한 수정
docs: GCP 운영 가이드 업데이트
chore: CODEOWNERS 담당 영역 정리
```

## PR 리뷰 체크

- 대상 GCP 프로젝트, 리전, 리소스 이름이 명확한가
- IAM 권한이 최소 권한 원칙을 따르는가
- secret 값, service account key, Terraform state가 포함되지 않았는가
- 비용 영향과 quota 영향이 설명되어 있는가
- 삭제/교체/권한 확대 변경의 롤백 방법이 있는가
- workflow 권한과 GitHub secret 이름이 적절한가

## 기본 검증

현재 GitHub 초기 세팅 단계:

```bash
git diff --check
```

Terraform/IaC 추가 이후:

```bash
terraform fmt -check
terraform validate
terraform plan
```

## 추천 GitHub 저장소 설정

- Squash merge만 허용
- head branch 자동 삭제
- `main` 직접 push 금지
- 최소 1명 approve 필요
- conversation resolved 필요
- Claude Code PR Review 안정화 후 required check 지정
- Terraform plan workflow 추가 후 required check 지정

## GitHub Secrets

초기 단계:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

GCP 배포 자동화 단계에서는 service account key 파일보다 GitHub OIDC 기반 Workload Identity Federation을 우선 검토한다.

## CODEOWNERS 예시

```text
/.github/   @SKYAHO/infra-maintainers
/terraform/ @SKYAHO/platform
/gcp/       @SKYAHO/platform
/*.md       @SKYAHO/infra-docs
```
