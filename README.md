# autoresearch-infra

`autoresearch-infra`는 AutoResearch 프로젝트의 GCP 기반 인프라를 관리하는 저장소입니다.

현재 dev 인프라 전반(VPC/subnet, Cloud SQL, GKE, Artifact Registry, GCS, BigQuery, Cloud Run proxy, Airflow 네트워크 경계, bastion, 내부 DNS)과 GitHub Actions(OIDC) 기반 Terraform plan 자동 검증(CI)이 구축 완료되어 apply까지 반영된 상태입니다. 이후 배포 권한, 애플리케이션 매니페스트, 모니터링 설정을 이 저장소에서 확장 관리합니다.

## 저장소 목적

- GCP 프로젝트 인프라 구조 관리
- Terraform 또는 IaC 기반 리소스 정의 관리
- GitHub Actions 기반 검증/배포 자동화 관리
- IAM, Secret Manager, Artifact Registry, Cloud Run, Cloud Scheduler, GCS, BigQuery 등 운영 리소스 관리
- 인프라 변경 이력, 리뷰, 승인 흐름 표준화

## 현재 포함된 초기 세팅

- Issue Forms: Feature, Bug, Experiment
- Pull Request template
- Claude Code PR Review workflow
- GitHub issue, branch, PR, project 운영 문서 (CONTRIBUTING.md로 통합)
- 에이전트용 문서 체계 (CLAUDE.md, AGENTS.md symlink, .claude/docs/)
- GitHub label 및 Project 초기 운영값 문서
- GCP/IaC 작업을 고려한 `.gitignore`
- Terraform dev 환경 리소스(VPC, Artifact Registry, Cloud SQL, Online Store Redis Cluster, GCS, BigQuery, GKE, Cloud Run proxy, bastion, 내부 DNS)
- GCS remote backend 및 GitHub Actions Terraform plan(OIDC/WIF)
- GCP 리소스/API 운영 문서

## 저장소 구조

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/
│   ├── workflows/
│   └── PULL_REQUEST_TEMPLATE.md
├── terraform/
│   ├── admin/              # 운영자 전용 별도 state root(IAM, 앱/Airflow/모니터링/ArgoCD Kubernetes 경계)
│   ├── bootstrap/          # 원격 state bucket, WIF, CI SA 부트스트랩
│   ├── envs/
│   │   └── dev/            # dev 환경 Terraform root module
│   └── modules/            # 재사용 module(현재 미사용, staging/prod 분리 시 추출)
├── deploy/                 # ArgoCD가 sync하는 umbrella chart(monitoring, argo-rollouts)
├── docs/                   # 인프라/GitHub 운영 문서
├── .claude/
│   └── docs/               # 에이전트 상세 가이드
├── CLAUDE.md               # AI 에이전트 진입점
├── AGENTS.md               # CLAUDE.md로 연결되는 symlink
├── .agents                 # .claude로 연결되는 symlink
├── CONTRIBUTING.md
└── README.md
```

## 협업 흐름

```text
Issue 등록 -> 작업 branch 생성 -> 작업/검증 -> Draft PR 생성 -> 셀프 리뷰 및 설명 보강
-> Ready for review 전환 -> 에이전트 리뷰 실행 -> 이해도 체크 inline 답변
-> 팀원 리뷰 요청 -> 최소 2명 승인 -> Squash merge
```

인프라 변경은 권한, 비용, 리전, 롤백 가능성, secret 노출 여부를 반드시 함께 검토합니다. 협업 규칙과 GitHub 운영 방식은 [CONTRIBUTING.md](CONTRIBUTING.md), label/Project 규칙은 [docs/GITHUB_LABELS_AND_PROJECT.md](docs/GITHUB_LABELS_AND_PROJECT.md)를 참고합니다. AI 코딩 에이전트 작업 규칙은 [CLAUDE.md](CLAUDE.md)/[AGENTS.md](AGENTS.md)와 `.claude/docs/`를 기준으로 합니다.

## Terraform

dev 환경 Terraform root module은 [terraform/envs/dev](terraform/envs/dev)에 있습니다.

기본 검증 명령:

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

운영 문서 목록은 [docs/README.md](docs/README.md)에서 시작합니다. 현재 Terraform
구성과 필요한 GCP API는 [docs/TERRAFORM_DEV.md](docs/TERRAFORM_DEV.md), 팀원 GKE /
Bastion / Airflow UI 접근 절차는
[docs/TEAM_OPERATIONS_RUNBOOK.md](docs/TEAM_OPERATIONS_RUNBOOK.md)를 참고합니다.

## 필수 Check

PR에서는 GitHub Actions의 `lint`와 Terraform `plan` status check를 사용합니다.

로컬에서 같은 검증을 실행하려면:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
```
