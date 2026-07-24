# AI 코딩 에이전트 작업 지침

> Version: 1.1.1 | Last Updated: 2026-07-13

이 문서는 Claude Code 등 AI 코딩 에이전트가 이 저장소에서 작업할 때의 기본
진입점입니다. 필수 규칙은 짧게 유지하고, 상세 가이드는 `.claude/docs/`를
참조합니다.

## 언어 원칙

에이전트 응답, PR 코멘트, 리뷰 요약, 구현 노트는 한국어 격식체를 사용합니다.
사용자가 명시적으로 요청하는 경우에만 다른 언어를 사용합니다.

## 규칙 우선순위

규칙이 충돌하면 다음 순서로 적용합니다:

1. 사용자의 명시적 요청
2. `CLAUDE.md` 및 `AGENTS.md` symlink
3. `.claude/docs/` 하위 가이드
4. `README.md`, `CONTRIBUTING.md`, 기타 저장소 문서

같은 수준이면 더 구체적이고 더 최근에 갱신된 규칙을 우선합니다.

## 문서 탐색 기준

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

## 프로젝트 맥락

- autoresearch-infra: AutoResearch 프로젝트의 GCP 기반 인프라를
  Terraform/IaC와 GitHub Actions로 관리하는 저장소
- Terraform dev 환경 root module은 `terraform/envs/dev/`:
  - `vpc.tf` — custom VPC, 서울(`asia-northeast3`) subnet, IAP SSH
    firewall, Private Google Access
  - `nat.tf` — Cloud Router + Cloud NAT
  - `artifact_registry.tf` — Docker 저장소 (`autoresearch-dev-docker`)
  - `cloud_sql.tf` — PostgreSQL 15 dev 인스턴스 (private IP only)
  - `redis.tf` — Feast Online Store 2-shard Redis Cluster (PSC, IAM auth/TLS)
  - `gke.tf` — dev GKE 클러스터
  - `storage.tf` / `bigquery.tf` — raw data, Feast, analytics 저장소
  - `cloud_run.tf` — dev proxy Cloud Run
  - `airflow.tf` / `cloud_build.tf` — Airflow GCP 리소스와 이미지 build 경로
  - `secret_manager.tf` — Secret Manager 리소스와 resource-level IAM
  - `bastion.tf` — #47 IAP 전용 bastion host
  - `dns.tf` — #48 Airflow ILB 예약 내부 IP + private DNS zone
  - `vault.tf` — #132 Vault auto-unseal용 KMS key/GSA/WI
  - `elastic.tf` — #102 Elasticsearch GCS snapshot bucket/GSA
  - `github_actions.tf` — WIF pusher SA 4종(각각 최소권한·repo@ref 제한): GAR
    pusher, app image pusher, Airflow deployer(container.clusterViewer),
    feast apply SA(#332, feast_registry 버킷 objectAdmin + feast_offline_store
    dataset metadataViewer)
  - `code_artifacts.tf` — #238 코드 아카이브 배포 GCS 버킷 + 업로더 SA(WIF,
    `code-archive.yml@main` workflow_ref 제한, 버킷 objectAdmin) + 파드 read IAM
- Kubernetes admin root는 `terraform/admin/` 하위에서 별도 state로 관리합니다:
  `airflow-k8s`(Airflow 경계), `argocd-k8s`(ArgoCD), `monitoring-k8s`(모니터링),
  `vault-k8s`(#134 Vault), `argo-rollouts-k8s`(#88 Rollouts), `elastic-k8s`(#97 ECK/ELK),
  `autoresearch-k8s`(앱 namespace/KSA 경계), 팀원 GKE 접근 IAM은 `gke-team-access`.
- 재사용 module은 `terraform/modules/` (현재 미사용, staging/prod 분리 시 추출)
- GitHub Actions는 `.github/workflows/`: `lint.yml`(actionlint, required
  check), `terraform-plan.yml`(OIDC/WIF 기반 PR plan 및 댓글 게시),
  `claude.yml`(Claude PR 리뷰), `terraform-drift.yml`(dev root state drift 주기 감지).
- 작업 중 스펙·플랜 문서는 `docs/superpowers/` 기준을 따르고, 완료된 핵심
  결정은 `docs/CHANGE_HISTORY.md`에 요약합니다.
- 팀원 로컬 GKE/Bastion/Airflow UI 접근 절차는
  `docs/TEAM_OPERATIONS_RUNBOOK.md`를 기준으로 합니다.
- 애플리케이션 기능 구현은 이 저장소 범위가 아닙니다. 일반 애플리케이션 저장소는
  `SKYAHO/Autoresearch`, Airflow DAG/Helm/image 저장소는
  `SKYAHO/Autoresearch-airflow`입니다.

## 핵심 규칙

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
- 커밋 메시지, PR 본문, 이슈 본문은 작성 전에 반드시 `.github/`의 템플릿
  (`PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/*.yml`)과
  `CONTRIBUTING.md`의 컨벤션을 읽고 그 구조를 그대로 따릅니다. 임의 형식을
  사용하지 않습니다.
- 모든 작업은 관련 `.md` 문서(README, runbook, 운영 문서) 갱신을 같은
  변경(PR)에 포함합니다.
- 보안을 항상 최우선으로 검토합니다: secret/state/tfvars 노출, IAM 권한 확대,
  외부 노출 리소스(public IP/LB/Ingress) 생성 여부를 커밋 전에 diff에서
  확인합니다.
- 학습용 dev 환경이라도 실제 회사 운영 기준으로 작업합니다: 이슈→브랜치→
  Draft PR→리뷰→squash merge 워크플로우를 생략하지 않고, 변경마다 검증·롤백
  방법·비용 영향을 기록합니다.

## 로컬 개발

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

## Spec / Plan 우선

비자명한 변경(신규 GCP 리소스, IAM/네트워크 변경, backend 마이그레이션,
workflow 권한 변경, 대규모 다중 파일 수정)은 구현 전에 계획을 작성합니다.

저장소 작업 문서 구조를 사용합니다:

- 요구사항, 설계 결정, 아키텍처 노트 →
  `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md`
- 구현 순서, 작업 분해, 검증 체크리스트 →
  `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`
- 새로 만들기보다 기존 관련 spec/plan 갱신을 우선합니다.
- 작업 완료 후 현재 운영 절차는 runbook/Terraform 문서에 반영하고, 장기 보존이
  필요한 결정만 `docs/CHANGE_HISTORY.md`에 요약합니다.

문서만 수정하거나 범위가 좁은 워크플로우 변경은 스레드 내 짧은 계획으로
진행할 수 있습니다.

## 검증

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

## 리뷰 기준

PR 리뷰 시 심각도 순으로 구체적 발견 사항을 먼저 제시합니다. 중점 사항:

- 정확성 버그와 기존 인프라 동작의 의도치 않은 변경 (리소스 교체·삭제 유발)
- 시크릿·자격 증명·state 노출 위험
- IAM 권한 확대와 최소 권한 원칙 위반
- 비용, quota, 리전 영향
- 삭제/교체/권한 확대 변경의 롤백 방법 누락
- workflow `permissions`와 GitHub secret 처리

구체적 이슈는 인라인 코멘트로, 요약 코멘트는 짧게 유지합니다.
