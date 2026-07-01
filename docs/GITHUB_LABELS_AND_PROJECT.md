# GitHub Labels and Project Setup

이 문서는 `autoresearch-infra` 저장소의 GitHub label과 Project 초기 운영값을 정의합니다.

## 필수 Labels

Issue Forms에서 자동으로 지정하는 label은 실제 repository에 반드시 존재해야 합니다.

| Label | Color | 용도 |
|---|---|---|
| `feature` | `1d76db` | GCP 인프라, IaC, GitHub 자동화 추가/개선 |
| `bug` | `d73a4a` | 권한, workflow, 리소스 설정, 자동화 오류 |
| `experiment` | `5319e7` | GCP 구성, Terraform 방식, 운영 정책 실험 |
| `documentation` | `0075ca` | README, runbook, 운영 문서 변경 |
| `chore` | `c2e0c6` | 저장소 설정, label, Project, CODEOWNERS 관리 |
| `question` | `d876e3` | 결정이 필요한 질문 또는 확인 요청 |

## 인프라 분류 Labels

인프라 PR이 커질수록 변경 영역을 빠르게 찾기 위해 아래 label을 추가로 사용합니다.

| Label | Color | 용도 |
|---|---|---|
| `gcp` | `4285f4` | GCP 리소스 전반 |
| `terraform` | `844fba` | Terraform/IaC 변경 |
| `iam` | `fbbc04` | IAM, service account, 권한 변경 |
| `ci-cd` | `0e8a16` | GitHub Actions, 배포/검증 자동화 |
| `security` | `b60205` | secret, 접근 제어, 보안 정책 |
| `cost` | `fbca04` | 비용, quota, 리소스 크기 조정 |

## Issue Forms 연결

현재 Issue Forms의 자동 label은 아래와 일치해야 합니다.

| Form | 자동 label |
|---|---|
| `.github/ISSUE_TEMPLATE/feature.yml` | `feature` |
| `.github/ISSUE_TEMPLATE/bug.yml` | `bug` |
| `.github/ISSUE_TEMPLATE/experiment.yml` | `experiment` |

## Project 기본 상태

권장 Project 상태 필드는 아래 3단계입니다.

| Status | 의미 |
|---|---|
| `Todo` | 아직 시작하지 않은 issue/PR |
| `In Progress` | branch를 만들고 실제 작업 중인 issue/PR |
| `Done` | merge 또는 close된 issue/PR |

## Project 자동화 권장값

GitHub Projects에서 아래 workflow를 켭니다.

| Workflow | 권장 동작 |
|---|---|
| Auto-add to project | open issue/PR 자동 추가 |
| Item added to project | 새 item의 status를 `Todo`로 설정 |
| Item closed | closed issue/PR의 status를 `Done`으로 설정 |
| Pull request merged | merged PR의 status를 `Done`으로 설정 |

권장 auto-add filter:

```text
is:issue,pr is:open repo:SKYAHO/Autoresearch-infra
```

## CLI 확인

Project 조회에는 GitHub CLI의 `read:project` scope가 필요합니다.

```bash
gh auth refresh -s read:project
gh project list --owner SKYAHO
```

Label 확인:

```bash
gh label list --repo SKYAHO/Autoresearch-infra
```
