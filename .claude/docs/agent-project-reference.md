# 에이전트 프로젝트 참조

> Last Updated: 2026-07-08

프로젝트 구조, 폴더 책임, 팀 소유권을 빠르게 찾기 위한 문서입니다.
"X는 어디에 있는가?", "Y는 누가 소유하는가?" 질문에 답합니다.

## 이 문서를 볼 때

- 저장소 레이아웃과 폴더별 책임을 파악해야 할 때
- 새 Terraform 리소스나 workflow를 추가할 위치를 정해야 할 때
- 팀 도메인 경계와 소유권을 확인해야 할 때

## 프로젝트 구조

현재 저장소의 실제 구조입니다:

```
terraform/
├── bootstrap/               # 원격 state bucket, WIF pool/provider, CI SA
├── admin/
│   ├── autoresearch-k8s/     # 앱 namespace/KSA/NetworkPolicy (separate state)
│   ├── airflow-k8s/          # Airflow namespace/RBAC/NetworkPolicy (separate state)
│   ├── gke-team-access/      # 팀원 GKE container.viewer IAM (전역 k8s 읽기, secrets 제외 — 의도된 방침) + bastion 접속 IAM (separate state)
│   ├── monitoring-k8s/       # Prometheus/Grafana monitoring namespace + Helm values (separate state)
│   └── argocd-k8s/           # ArgoCD namespace + Helm values scaffold (separate state)
├── envs/
│   └── dev/                 # dev 환경 root module
│       ├── versions.tf      # Terraform/provider 버전, provider 설정
│       ├── variables.tf     # 입력 변수
│       ├── locals.tf        # 공통 locals (이름 prefix, 기본 label)
│       ├── outputs.tf       # 다른 시스템이 소비하는 출력
│       ├── vpc.tf           # custom VPC, subnet, firewall, PGA
│       ├── nat.tf           # Cloud Router + Cloud NAT
│       ├── artifact_registry.tf  # Docker 저장소
│       ├── cloud_sql.tf     # PostgreSQL dev 인스턴스 (private IP)
│       ├── redis.tf         # Feast Online Store Redis (private IP, AUTH/TLS)
│       ├── gke.tf           # dev GKE 클러스터
│       ├── storage.tf       # raw data, Feast, Airflow DAG/log GCS bucket
│       ├── bigquery.tf      # analytics / Feast offline store dataset
│       ├── cloud_run.tf     # dev proxy Cloud Run
│       ├── airflow.tf       # Airflow GCP SA/WI/DB/GCS/IAM
│       ├── cloud_build.tf   # Autoresearch-airflow image build/push IAM
│       ├── secret_manager.tf     # Secret Manager
│       ├── bastion.tf       # IAP 전용 bastion host (#47)
│       ├── dns.tf           # Airflow ILB 고정 IP + private DNS zone (#48)
│       └── terraform.tfvars.example  # 변수 예시 (실값 커밋 금지)
└── modules/                 # 재사용 module (예정)

.github/
├── ISSUE_TEMPLATE/          # Issue Forms (feature/bug/experiment)
├── workflows/
│   ├── lint.yml             # actionlint (required check)
│   ├── terraform-plan.yml   # PR Terraform plan (OIDC/WIF + PR comment)
│   └── claude.yml           # Claude Code PR 리뷰
└── PULL_REQUEST_TEMPLATE.md

docs/
├── README.md                # 운영 문서 진입점
├── TEAM_OPERATIONS_RUNBOOK.md  # 팀원 GKE/Bastion/Airflow UI 접근 절차와 권한 기록
├── TERRAFORM_DEV.md         # dev 환경 구성과 필요 GCP API
├── TERRAFORM_BOOTSTRAP.md   # bootstrap root (state bucket/WIF/CI SA) 절차
├── CHANGE_HISTORY.md        # 완료된 주요 인프라 변경 결정 요약
├── BRANCH_RULESET_MAIN.md   # main ruleset 설명
├── GITHUB_LABELS_AND_PROJECT.md  # label/Project 운영 기준
└── superpowers/
    └── README.md            # 작업 중 spec/plan 사용 기준

CONTRIBUTING.md              # 사람용 협업 규칙 (워크플로우 전체)
branch_ruleset_main.json     # main branch ruleset 정의
```

로컬 전용(커밋하지 않음): `agent.local.md`, `docs/NOTION_PROGRESS_TIMELINE.md`,
`.claude/settings.local.json`

에이전트 호환 진입점으로 `AGENTS.md -> CLAUDE.md`,
`.agents -> .claude` symlink를 둔다.

## Team Ownership & Domains

| 도메인 | 팀원 | 책임 | 주요 경로 |
|---|---|---|---|
| **GCP Infrastructure** | hyeongyu-data | Terraform/IaC, 네트워크, IAM, 시크릿, 배포 자동화 | `terraform/`, `.github/workflows/`, `docs/` |
| **Model Training** | waieiches, hyochangsung | 모델·학습 파이프라인 (앱 저장소) | `SKYAHO/Autoresearch` |
| **Airflow Orchestration** | bbungjun | DAG·오케스트레이션, Helm values, Airflow image | `SKYAHO/Autoresearch-airflow` |

이 저장소의 주 담당은 GCP Infrastructure 도메인입니다. 인프라 변경이
애플리케이션(수집 파이프라인, DAG, 모델 서빙)에 영향을 주면 해당 도메인
담당자를 리뷰어로 포함합니다.

- PR Assignee 기본값: `hyeongyu-data`
- 머지에는 팀원 2명의 approve가 필요합니다.

## Ownership Boundaries

### `terraform/envs/dev/`
- **책임:** dev 환경의 모든 GCP 리소스 정의
- **패턴:** 리소스 종류별로 `.tf` 파일을 분리합니다. 공통 값은
  `locals.tf`, 입력은 `variables.tf`, 외부 소비 값은 `outputs.tf`에
  둡니다. 다른 환경(staging/prod)이 생기면 `envs/` 아래 디렉터리를
  추가하고 공통 부분은 `modules/`로 추출합니다.

### `terraform/admin/autoresearch-k8s/`
- **책임:** 일반 앱의 Kubernetes namespace, Workload Identity KSA,
  NetworkPolicy를 별도 state로 관리합니다.
- **주의:** GKE API 접근이 필요하며 dev root보다 뒤에 plan/apply합니다.

### `.github/workflows/`
- **책임:** 검증(lint, Terraform plan)과 리뷰 자동화만 담습니다.
- **주의:** workflow `permissions`는 최소 권한으로 유지하고, GCP 인증은
  service account key 대신 OIDC/WIF를 우선합니다.

### `docs/`
- **책임:** 운영 문서와 spec/plan. 인프라 동작·명령어·정책이 바뀌면
  같은 PR에서 관련 문서를 갱신합니다.

## Technical Stack

- **IaC:** Terraform >= 1.6, hashicorp/google + google-beta (>= 5.0, < 8.0),
  random provider
- **GCP:** 리전 `asia-northeast3`(서울), dev 환경 — VPC, Cloud NAT,
  Artifact Registry, Cloud SQL(PostgreSQL 15, private IP), GKE,
  Secret Manager, GCS, BigQuery, Cloud Run(내부 proxy),
  Cloud DNS(private zone `dev.autoresearch.internal`), bastion host(IAP 전용)
- **State:** GCS remote backend(`autoresearch-dev-tfstate`)
- **CI:** GitHub Actions — `lint`(actionlint, required check),
  Terraform plan(OIDC/WIF, PR 댓글 게시), Claude Code PR Review
- **정책:** GCP API는 수동 활성화 (`google_project_service` 미사용),
  GCR 대신 Artifact Registry 사용

## Key Extension Rules

1. **환경 확인:** 변경이 dev 환경 한정인지, 공통 module로 갈 것인지 먼저
   판단합니다.
2. **올바른 파일에 배치:** 기존 리소스 종류별 파일 분리를 따르고, 새
   리소스 종류면 새 `.tf` 파일을 만듭니다.
3. **변수·출력 갱신:** 새 변수는 `variables.tf`와
   `terraform.tfvars.example`에, 외부에서 소비할 값은 `outputs.tf`에
   함께 추가합니다.
4. **검증:** `fmt -check`, `validate`를 통과시키고, 리소스 변경이면
   `plan` 결과를 PR에 요약합니다.
5. **설계 결정 기록:** 아키텍처에 영향이 있으면 작업 중 `docs/superpowers/`에
   spec/plan을 남기고, 완료 후 핵심 결정은 `docs/CHANGE_HISTORY.md`에 요약하거나
   관련 `.claude/docs/` 가이드를 갱신합니다.

## Verification Checklist

- [ ] 리소스가 올바른 환경·파일에 정의되어 있다.
- [ ] 새 변수가 `terraform.tfvars.example`에 반영되어 있다.
- [ ] `fmt -check`, `validate`, `git diff --check`를 통과했다.
- [ ] 비용·리전·IAM 영향이 PR에 설명되어 있다.
- [ ] 동작·설정이 바뀌었으면 문서를 갱신했다.
