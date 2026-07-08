# 기여 가이드 (Contributing Guide)

autoresearch-infra 저장소에 기여해 주셔서 감사합니다.
이 저장소는 AutoResearch 프로젝트의 GCP 기반 인프라와 GitHub 운영 자동화를 관리합니다.
원활한 협업을 위해 아래 규칙을 따라 주세요.

---

## 워크플로우

```
이슈 등록 → 작업 브랜치 생성 → 작업/검증 → Draft PR 생성 → 셀프 리뷰 및 설명 보강
       → Ready for review 전환 → 에이전트 리뷰 실행 → 이해도 체크 inline 답변
       → 팀원 리뷰 요청 → 최소 2명 승인 → Squash merge
```

1. **이슈 등록**: 작업 시작 전 반드시 이슈를 먼저 만듭니다.
   `Issues > New issue`에서 Issue Form(Feature / Bug / Experiment)을 선택해 작성해 주세요. Form을 선택하면 제목 prefix와 label이 자동으로 적용됩니다.

2. **작업 브랜치 생성**: `main`에서 분기하여 작업 브랜치를 만듭니다.
   브랜치 네이밍 규칙은 아래를 따릅니다.

3. **작업 및 검증**: 커밋 컨벤션에 따라 커밋 메시지를 작성합니다. 인프라 변경은 `git diff --check`, Terraform `fmt`/`validate`(필요 시 `plan`)를 통과시킵니다.

4. **Draft PR 생성**: 작업이 완료되면 Draft PR을 엽니다. PR 템플릿을 채우고 본문에 `Closes #이슈번호`를 포함합니다.

5. **셀프 리뷰 및 설명 보강**: 본인이 diff를 처음부터 끝까지 읽고 PR 설명, 검증 결과, 영향 범위(IAM/비용/리전/롤백)를 보강합니다.

6. **Ready for review 전환**: 설명이 충분해지면 Draft를 해제해 리뷰를 요청할 수 있는 상태로 전환합니다.

7. **에이전트 리뷰 실행**: Ready로 전환되면 Claude Code PR Review workflow가 자동 실행됩니다. (Draft에서는 실행되지 않습니다.)

8. **이해도 체크 inline 답변**: 에이전트가 남긴 `이해도 확인:` inline comment 각각에 같은 스레드에서 답변하고, 필요하면 로컬에서 검증한 뒤 resolve합니다.

9. **팀원 리뷰 요청**: 담당 팀원에게 리뷰를 요청합니다.

10. **최소 2명 승인**: 팀원 **최소 2명**의 Approve와 모든 대화 resolve가 있어야 머지할 수 있습니다.

11. **Squash merge**: 머지 방식은 **squash만 허용**합니다.
    머지 커밋 제목은 `<type>: <설명> (#PR번호)` 형식으로 작성합니다.

---

## 브랜치 네이밍 규칙

| 유형 | 패턴 | 예시 |
|------|------|------|
| 기능 개발 | `feat/이슈번호-간략한-설명` | `feat/42-add-cloud-run-job` |
| 버그 수정 | `fix/이슈번호-간략한-설명` | `fix/57-iam-permission-error` |
| 실험 | `exp/이슈번호-간략한-설명` | `exp/61-terraform-state-backend` |
| 문서 | `docs/이슈번호-간략한-설명` | `docs/30-update-readme` |
| 리팩터링 | `refactor/이슈번호-간략한-설명` | `refactor/48-split-terraform-module` |
| 기타 | `chore/이슈번호-간략한-설명` | `chore/10-setup-ci` |

- 영어 소문자와 하이픈(`-`)만 사용합니다.
- 이슈 번호를 반드시 포함합니다.

---

## 커밋 컨벤션

```
<type>: <설명>
```

### Type 목록

| type | 사용 상황 |
|------|-----------|
| `feat` | GCP 인프라 리소스, IaC, GitHub 자동화 추가 |
| `fix` | 인프라 설정, 권한, workflow, 문서 오류 수정 |
| `refactor` | 동작 변화 없는 IaC/문서/설정 구조 정리 |
| `docs` | 문서 추가·수정 |
| `chore` | 저장소 기본 설정, 관리 작업 |
| `exp` | GCP 구성, Terraform 방식, 운영 자동화 실험 |

### 예시

```
feat: Cloud Run Job 인프라 정의 추가
fix: Secret Manager 접근 권한 수정
exp: Terraform state backend 구성 비교
docs: GCP 운영 가이드 초안 작성
```

- 설명은 한국어로 작성합니다.
- 제목은 현재형 동사로 시작합니다 (추가, 수정, 삭제, ...).
- 제목은 50자 이내로 작성합니다.

---

## main 브랜치 보호 규칙

`main` 브랜치에는 아래 보호 규칙이 적용되어 있습니다.

- **직접 push 금지**: 모든 변경은 PR을 통해서만 반영됩니다.
- **리뷰 승인 필수**: 최소 2명의 팀원 Approve와 모든 대화 resolve가 있어야 머지할 수 있습니다.
- **PR 통과 후 머지**: 설정한 필수 체크가 모두 통과해야 머지할 수 있습니다.
- **머지 방식**: squash만 허용.

> GitHub 레포 설정 → Settings → Branches → Branch protection rules 에서 확인할 수 있습니다.

## 인프라 변경 리뷰 원칙

- GCP 리소스의 프로젝트, 리전, 이름, 비용 영향을 확인합니다.
- IAM 권한은 최소 권한 원칙을 따릅니다.
- Secret 값은 코드, 로그, PR 본문에 포함하지 않습니다.
- Terraform state, service account key, `.env` 파일은 커밋하지 않습니다.
- 삭제/교체/권한 확대 변경은 롤백 방법을 PR에 적습니다.

---

## Claude 자동 리뷰

`.github/workflows/claude.yml`은 PR이 처음 열리거나(`opened`) Draft에서 Ready for review로 전환되면(`ready_for_review`) Claude Code 리뷰를 자동 실행합니다. Draft 상태에서는 실행되지 않습니다.

- 에이전트가 남긴 `이해도 확인:` inline comment에는 같은 스레드에서 답변하고, 필요하면 로컬에서 검증한 뒤 resolve합니다.
- trivial, docs-only, formatting-only 변경에는 이해도 확인 comment를 남기지 않는 정책입니다.
- 필요한 repository secret: `CLAUDE_CODE_OAUTH_TOKEN`
- 에이전트 작업 규칙은 `CLAUDE.md`/`AGENTS.md`와 `.claude/docs/`를 기준으로 합니다.

---

## Label 및 Project 운영

label과 Project 상태는 [docs/GITHUB_LABELS_AND_PROJECT.md](docs/GITHUB_LABELS_AND_PROJECT.md)를 기준으로 관리합니다.

- 기본 label: `feature`, `bug`, `experiment`, `documentation`, `chore`, `question`
- 인프라 분류 label: `gcp`, `terraform`, `iam`, `ci-cd`, `security`, `cost`

Project 기본 상태는 `Todo`, `In Progress`, `Done`을 사용합니다.

| 상태 | 의미 | 전환 |
|------|------|------|
| `Todo` | 시작 전 | 이슈/PR 생성 시 자동 추가 |
| `In Progress` | 작업 중 | 작업 시작 시 직접 이동 |
| `Done` | 완료 | merge/close 시 자동 전환 |

권장 auto-add filter: `is:issue,pr is:open repo:SKYAHO/Autoresearch-infra`

Project의 `Add item`으로 제목만 추가하면 Issue Form을 우회하게 되므로, 새 작업은 Issues 화면에서 생성합니다.

---

## CI 및 검증

- `.github/workflows/lint.yml` — actionlint. `lint`는 required status check입니다.
- `.github/workflows/terraform-plan.yml` — 내부 브랜치 PR에서 OIDC/WIF로 dev root plan을 실행하고 PR 댓글을 게시합니다.
- `.github/workflows/claude.yml` — Claude Code PR 리뷰.
- 현재 `branch_ruleset_main.json`의 required status check는 `lint`입니다. Terraform plan은 PR check/comment로 반드시 확인하되, ruleset required check에는 포함하지 않습니다.

Terraform 변경 PR의 로컬 검증:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

`terraform plan`은 실제 GCP project id와 인증이 준비된 뒤 실행합니다. 로컬 `terraform.tfvars`와 state/plan 파일은 커밋하지 않습니다.

---

## 문제 해결

**Claude 리뷰가 실행되지 않을 때**: repository secret `CLAUDE_CODE_OAUTH_TOKEN` 등록 여부, PR의 Draft 상태, workflow event(`opened`, `ready_for_review`), GitHub Actions 권한을 확인합니다.

**GCP 인증 workflow가 실패할 때**: GitHub OIDC provider와 service account binding, workflow `permissions`의 `id-token: write`, 대상 GCP project id와 service account email, 최소 권한 IAM role을 확인합니다.

**PR이 merge되지 않을 때**: Draft 상태인지, approve 2명이 있는지, 모든 대화가 resolve되었는지, 충돌이 있는지, required check(`lint`)가 실패했는지 확인합니다.

**이슈가 자동으로 닫히지 않을 때**: PR 본문에 `Closes #이슈번호`가 있는지, PR이 `main`으로 merge되었는지, 이슈 번호가 같은 저장소의 번호인지 확인합니다.

---

## 참고 링크

- Repository: https://github.com/SKYAHO/Autoresearch-infra
- Issue Forms: `.github/ISSUE_TEMPLATE/*.yml`
- PR template: `.github/PULL_REQUEST_TEMPLATE.md`
- main ruleset: `branch_ruleset_main.json`, `docs/BRANCH_RULESET_MAIN.md`
- 에이전트 가이드: `CLAUDE.md`, `AGENTS.md`, `.claude/docs/`
