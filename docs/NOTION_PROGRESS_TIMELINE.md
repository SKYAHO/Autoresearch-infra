# Notion Progress Timeline

이 문서는 `autoresearch-infra` 작업 진행 상황을 Notion에 옮기기 쉬운 형태로 정리한 타임라인이다.

## Notion Page Properties

| Property | Value |
|---|---|
| 문서 유형 | Work Log / Timeline |
| 프로젝트 | `autoresearch-infra` |
| 저장소 | `SKYAHO/Autoresearch-infra` |
| 상태 | In Progress |
| 담당 | Infra Maintainer |
| 태그 | GCP, Terraform, GitHub, Infra, Timeline |
| 기준 시간대 | KST |
| 마지막 업데이트 | 2026-07-01 10:59 KST |

## Milestone Timeline

| 순서 | 상태 | Issue/PR | 제목 | 산출물 | 다음 액션 |
|---:|---|---|---|---|---|
| 1 | Done | Initial setup | GCP 인프라 저장소 GitHub 초기 세팅 | README, Issue Forms, PR Template, CODEOWNERS, Claude Review workflow | 원격 저장소 push |
| 2 | Done | `#1`-`#7` | Terraform/GCP 인프라 작업 이슈 생성 | 7개 GitHub issue 생성 | label/Project 정리 |
| 3 | In Review | `#7`, `PR #8` | GitHub label 및 Project 운영값 정리 | label 생성, 이슈 label 적용, `docs/GITHUB_LABELS_AND_PROJECT.md` | PR 리뷰 및 merge |
| 4 | Todo | `#1` | Terraform dev 환경 기본 골격 구성 | `terraform/envs/dev`, provider/backend/variables 구조 | #7 merge 후 branch 생성 |
| 5 | Todo | `#2` | dev VPC 및 subnet Terraform 구성 | VPC/subnet Terraform module 또는 env 리소스 | #1 완료 후 진행 |
| 6 | Todo | `#3` | Artifact Registry Docker 저장소 기본 구성 | Docker repository, IAM/output | #1 완료 후 진행 |
| 7 | Todo | `#4` | dev Cloud SQL 최소 비용 데이터베이스 구성 | Cloud SQL dev instance/database/user | #2 완료 후 진행 |
| 8 | Todo | `#5` | dev GKE 소형 클러스터 Terraform 구성 | GKE dev cluster/node pool | #2 완료 후 진행 |
| 9 | Todo | `#6` | GitHub Actions Terraform plan 및 GCP OIDC 인증 구성 | GitHub Actions plan workflow, OIDC 문서 | #1 이후 병행 가능 |

## Work Log

| 시간 | 상태 | 작업 | 상세 | 링크 |
|---|---|---|---|---|
| 2026-07-01 10:20 KST | Done | 저장소 방향 정리 | `autoresearch-infra`를 GCP 기반 프로젝트 인프라 저장소로 정의 | `README.md` |
| 2026-07-01 10:30 KST | Done | GitHub 초기 세팅 push | remote 초기 commit 병합 후 `main` push 완료 | `main` |
| 2026-07-01 10:34 KST | Done | GCP/Terraform 작업 이슈 생성 | #1 Terraform bootstrap, #2 VPC, #3 Artifact Registry, #4 Cloud SQL, #5 GKE, #6 GitHub Actions/OIDC, #7 label/Project 이슈 생성 | GitHub Issues |
| 2026-07-01 10:45 KST | Done | #7 브랜치 생성 | `chore/7-setup-labels-project` 생성 | branch |
| 2026-07-01 10:50 KST | Done | GitHub labels 생성 | `feature`, `experiment`, `chore`, `gcp`, `terraform`, `iam`, `ci-cd`, `security`, `cost` 생성 및 기존 label 설명 정리 | GitHub Labels |
| 2026-07-01 10:52 KST | Done | 이슈 label 적용 | #1-#7에 작업 성격별 label 적용 | GitHub Issues |
| 2026-07-01 10:55 KST | Done | label/Project 문서화 | `docs/GITHUB_LABELS_AND_PROJECT.md` 추가, 운영 문서 연결 | PR #8 |
| 2026-07-01 10:57 KST | In Review | PR 생성 | `chore: GitHub label 및 Project 운영값 정리` PR 생성, `Closes #7` 포함 | PR #8 |
| 2026-07-01 10:59 KST | In Progress | Agent guide 및 timeline 작성 | `agent.md`, `docs/NOTION_PROGRESS_TIMELINE.md` 추가 | current branch |

## Decision Log

| 날짜 | 결정 | 이유 | 영향 |
|---|---|---|---|
| 2026-07-01 | GCR 대신 Artifact Registry 사용 | Container Registry는 신규 구성에 적합하지 않아 Artifact Registry 기준으로 진행 | #3에서 Artifact Registry Docker repository 구성 |
| 2026-07-01 | dev 인프라는 최소 비용 기준으로 시작 | 초기 검증 단계에서 비용을 낮추기 위함 | Cloud SQL shared-core, 작은 GKE cluster 검토 |
| 2026-07-01 | service account key보다 GitHub OIDC 우선 검토 | key 파일 유출 위험을 줄이기 위함 | #6에서 Workload Identity Federation 검토 |
| 2026-07-01 | #7을 먼저 처리 | Issue Form 자동 label이 실제 label과 맞아야 이후 이슈/PR 운영이 깔끔함 | label taxonomy 및 Project 문서 선행 |

## Blockers / Follow-ups

| 항목 | 상태 | 설명 | 해결 방법 |
|---|---|---|---|
| GitHub Project 조회 scope | Open | 현재 `gh` token에 `read:project` scope가 없어 Project 조회가 불가했음 | `gh auth refresh -s read:project` 실행 후 Project 설정 확인 |
| Project auto-add 검증 | Open | Project 접근 권한 확인 전까지 자동화 실제 동작 검증 보류 | Project 권한 갱신 후 `Auto-add to project` 필터 확인 |
| Terraform backend bucket | Todo | remote state backend용 GCS bucket이 아직 없음 | #1에서 bootstrap 방식 결정 |

## Next Action

1. PR #8 리뷰 및 merge
2. `main` 최신화
3. `feat/1-terraform-dev-bootstrap` 브랜치 생성
4. Terraform dev 환경 기본 골격 작성
5. `terraform fmt -check`, `terraform validate` 검증 흐름 추가
