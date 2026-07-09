# Coding Guidelines for AI Coding Agents

> Version: 1.0.1 | Last Updated: 2026-07-08

이 문서는 Claude Code 등 AI 코딩 에이전트가 이 저장소에서 작업할 때의 기본
진입점입니다. 필수 규칙은 짧게 유지하고, 상세 가이드는 `.claude/docs/`를
참조합니다.

## Language Preference

에이전트 응답, PR 코멘트, 리뷰 요약, 구현 노트는 한국어 격식체를 사용합니다.
사용자가 명시적으로 요청하는 경우에만 다른 언어를 사용합니다.

## Rule Priority

규칙이 충돌하면 다음 순서로 적용합니다:

1. 사용자의 명시적 요청
2. `CLAUDE.md` 및 `AGENT.md`/`AGENTS.md` symlink
3. `.claude/docs/` 하위 가이드
4. `README.md`, `CONTRIBUTING.md`, 기타 저장소 문서

같은 수준이면 더 구체적이고 더 최근에 갱신된 규칙을 우선합니다.

## Documentation Navigation

비자명한 변경을 하기 전에 가장 관련 있는 가이드를 먼저 확인합니다:

| 요청 유형 | 먼저 볼 문서 | 다음 문서 |
| --- | --- | --- |
| 프로젝트 구조·소유권 | `.claude/docs/agent-project-reference.md` | `.claude/docs/architecture-overview.md` |
| Terraform 스타일·구성 | `.claude/docs/agent-terraform-reference.md` | `.claude/docs/architecture-overview.md` |
| 워크플로우, 커밋, PR | `.claude/docs/agent-workflow-reference.md` | `.claude/docs/agent-prohibitions.md` |
| 보안, 시크릿, IAM | `.claude/docs/agent-security-guidelines.md` | `.claude/docs/agent-prohibitions.md` |
| 코드 리뷰 | `.claude/docs/agent-peer-review.md` | `.claude/docs/agent-workflow-reference.md` |
| 계획 리뷰 | `.claude/docs/agent-plan-review.md` | `.claude/docs/agent-peer-review.md` |

각 문서는 현재 구현과 계획을 구분해 표기합니다.

## Project Context

- autoresearch-infra: AutoResearch 프로젝트의 GCP 기반 인프라를
  Terraform/IaC와 GitHub Actions로 관리하는 저장소
- Terraform dev 환경 root module은 `terraform/envs/dev/`:
  - `vpc.tf` — custom VPC, 서울(`asia-northeast3`) subnet, IAP SSH
    firewall, Private Google Access
  - `nat.tf` — Cloud Router + Cloud NAT
  - `artifact_registry.tf` — Docker 저장소 (`autoresearch-dev-docker`)
  - `cloud_sql.tf` — PostgreSQL 15 dev 인스턴스 (private IP only)
  - `gke.tf` — dev GKE 클러스터
  - `storage.tf` / `bigquery.tf` — raw data, Feast, analytics 저장소
  - `cloud_run.tf` — dev proxy Cloud Run
  - `airflow.tf` / `cloud_build.tf` — Airflow GCP 리소스와 이미지 build 경로
  - `secret_manager.tf` — Secret Manager 리소스와 resource-level IAM
  - `bastion.tf` — #47 IAP 전용 bastion host
  - `dns.tf` — #48 Airflow ILB 예약 내부 IP + private DNS zone
- Kubernetes admin root는 `terraform/admin/airflow-k8s/`, 팀원 GKE 접근 IAM은
  `terraform/admin/gke-team-access/`에서 별도 state로 관리합니다.
- 재사용 module은 `terraform/modules/` (예정)
- GitHub Actions는 `.github/workflows/`: `lint.yml`(actionlint, required
  check), `terraform-plan.yml`(OIDC/WIF 기반 PR plan 및 댓글 게시),
  `claude.yml`(Claude PR 리뷰).
- 스펙·플랜 문서는 `docs/superpowers/specs/`, `docs/superpowers/plans/`
- 팀원 로컬 GKE 접근 절차는 `docs/GKE_CLUSTER_ACCESS.md`를 기준으로 합니다.
- 애플리케이션 기능 구현은 이 저장소 범위가 아닙니다. 애플리케이션 저장소는
  `SKYAHO/Autoresearch`입니다.

## Core Rules

- 코드가 변경되는 작업은 반드시 이슈를 먼저 발행하고, 그 이슈의
  `Create a branch`로 브랜치를 생성합니다(이슈-브랜치 자동 연결). 상세는
  `.claude/docs/agent-workflow-reference.md`를 참조합니다.
- 새 추상화보다 기존 저장소 패턴을 우선합니다 (리소스 종류별 `.tf` 파일 분리,
  `variables.tf`/`locals.tf`/`outputs.tf` 규칙).
- 구조 변경과 동작 변경(리소스 변경)은 분리합니다.
- 실제 GCP 리소스 생성/삭제(`terraform apply`/`destroy`)는 사용자가 명확히
  요청했을 때만 수행합니다.
- GitHub 원격에 영향을 주는 작업(issue/PR 생성·수정, push, label, Project,
  Ruleset)은 실행 전에 사용자에게 먼저 확인받습니다.
- Terraform state, 실제 `.tfvars`, service account key, secret 값은 커밋하지
  않습니다.
- IAM은 최소 권한 원칙을 따르고, dev 리소스는 최소 비용 기준으로 시작합니다.
- 동작, 명령어, 설정, 운영 방식이 바뀌면 문서를 갱신합니다.

## Local Development

로컬 검증 명령:

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

- `terraform plan`은 실제 GCP project id와 인증(`terraform.tfvars`)이 준비된
  뒤 실행합니다. 로컬 `terraform.tfvars`와 state/plan 파일은 커밋하지
  않습니다.
- 필요한 변수는 `terraform/envs/dev/terraform.tfvars.example`을 참조합니다.

## Spec / Plan First

비자명한 변경(신규 GCP 리소스, IAM/네트워크 변경, backend 마이그레이션,
workflow 권한 변경, 대규모 다중 파일 수정)은 구현 전에 계획을 작성합니다.

저장소 작업 문서 구조를 사용합니다:

- 요구사항, 설계 결정, 아키텍처 노트 →
  `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md`
- 구현 순서, 작업 분해, 검증 체크리스트 →
  `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`
- 새로 만들기보다 기존 관련 spec/plan 갱신을 우선합니다.

문서만 수정하거나 범위가 좁은 워크플로우 변경은 스레드 내 짧은 계획으로
진행할 수 있습니다.

## Verification

변경을 증명하는 가장 좁은 검증부터 수행하고, 공유 인프라나 운영 워크플로우에
영향이 있으면 범위를 넓힙니다.

주요 명령어:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
git diff --check
```

GitHub workflow 변경 시 로컬에 `actionlint`가 있으면 함께 사용합니다
(CI의 `lint` check와 동일).

## Review Guidance

PR 리뷰 시 심각도 순으로 구체적 발견 사항을 먼저 제시합니다. 중점 사항:

- 정확성 버그와 기존 인프라 동작의 의도치 않은 변경 (리소스 교체·삭제 유발)
- 시크릿·자격 증명·state 노출 위험
- IAM 권한 확대와 최소 권한 원칙 위반
- 비용, quota, 리전 영향
- 삭제/교체/권한 확대 변경의 롤백 방법 누락
- workflow `permissions`와 GitHub secret 처리

구체적 이슈는 인라인 코멘트로, 요약 코멘트는 짧게 유지합니다.
