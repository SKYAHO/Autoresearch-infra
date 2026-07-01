# Agent Guide

이 저장소는 AutoResearch 프로젝트의 GCP 기반 인프라를 Terraform/IaC와 GitHub Actions로 관리하기 위한 `autoresearch-infra` 저장소다.

현재 단계는 실제 GCP 리소스를 만들기 전, 인프라 작업을 안전하게 진행하기 위한 GitHub 초기 운영 체계와 작업 순서를 정리하는 단계다.

## 현재 목표

1. GitHub issue, label, Project, PR review 흐름을 먼저 정리한다.
2. Terraform dev 환경 기본 골격을 만든다.
3. dev VPC/subnet을 만든다.
4. Artifact Registry Docker repository를 만든다.
5. 최소 비용 Cloud SQL dev database를 만든다.
6. 작은 GKE dev cluster를 만든다.
7. GitHub Actions에서 Terraform plan과 GCP OIDC 인증을 구성한다.

## 작업 원칙

- 모든 인프라 작업은 issue에서 시작한다.
- branch 이름에는 issue 번호를 포함한다.
- PR 본문에는 `Closes #이슈번호`를 넣는다.
- GCP 리소스 변경은 비용, 리전, 권한, secret, 롤백 가능성을 함께 검토한다.
- IAM은 최소 권한 원칙을 따른다.
- service account key, Terraform state, 실제 tfvars, secret 값은 커밋하지 않는다.
- GCR 대신 Artifact Registry를 사용한다.
- dev 리소스는 작은 비용으로 시작하되, 운영 전환 시 바꿔야 할 항목을 문서에 남긴다.
- 파괴적 변경이나 실제 GCP 리소스 생성/삭제는 사용자가 명확히 요청했을 때만 실행한다.

## 현재 GitHub 이슈 순서

| 순서 | Issue | 작업 |
|---:|---|---|
| 1 | `#7` | GitHub label 및 Project 초기 운영값 정리 |
| 2 | `#1` | Terraform dev 환경 기본 골격 구성 |
| 3 | `#2` | dev VPC 및 subnet Terraform 구성 |
| 4 | `#3` | Artifact Registry Docker 저장소 기본 구성 |
| 5 | `#4` | dev Cloud SQL 최소 비용 데이터베이스 구성 |
| 6 | `#5` | dev GKE 소형 클러스터 Terraform 구성 |
| 7 | `#6` | GitHub Actions Terraform plan 및 GCP OIDC 인증 구성 |

## 현재 브랜치/PR 상태

- 작업 브랜치: `chore/7-setup-labels-project`
- PR: `#8 chore: GitHub label 및 Project 운영값 정리`
- 관련 이슈: `#7`
- 현재 PR에는 label taxonomy 문서와 Project 운영값 문서화가 포함되어 있다.

## 검증 명령

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

## 참고 문서

- `README.md`: 저장소 목적과 예정 구조
- `CONTRIBUTING.md`: 브랜치/커밋/리뷰 원칙
- `GITHUB_WORKFLOW.md`: GitHub 운영 가이드
- `NOTION_GITHUB_WORKFLOW.md`: Notion 공유용 운영 가이드
- `docs/GITHUB_LABELS_AND_PROJECT.md`: label 및 Project 설정 기준
- `docs/NOTION_PROGRESS_TIMELINE.md`: 진행 타임라인

## 다음 작업자에게 남기는 메모

- #7은 label 생성과 문서화까지 완료했고 PR #8이 생성되어 있다.
- GitHub Project 조회에는 현재 `gh` token의 `read:project` scope가 부족했다.
- Project 설정 확인이 필요하면 아래 명령으로 scope를 갱신한다.

```bash
gh auth refresh -s read:project
gh project list --owner SKYAHO
```

- #7이 merge되면 `main`을 pull한 뒤 #1 작업 브랜치를 생성한다.

```bash
git switch main
git pull origin main
git switch -c feat/1-terraform-dev-bootstrap
```
