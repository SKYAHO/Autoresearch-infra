# Agent Project Reference

> Last Updated: 2026-07-07

프로젝트 구조, 폴더 책임, 팀 소유권을 빠르게 찾기 위한 문서입니다.
"X는 어디에 있는가?", "Y는 누가 소유하는가?" 질문에 답합니다.

## When To Use This Doc

- 저장소 레이아웃과 폴더별 책임을 파악해야 할 때
- 새 Terraform 리소스나 workflow를 추가할 위치를 정해야 할 때
- 팀 도메인 경계와 소유권을 확인해야 할 때

## Project Layout

현재 저장소의 실제 구조입니다:

```
terraform/
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
│       ├── gke.tf           # dev GKE 클러스터
│       ├── secret_manager.tf     # Secret Manager
│       └── terraform.tfvars.example  # 변수 예시 (실값 커밋 금지)
└── modules/                 # 재사용 module (예정)

.github/
├── ISSUE_TEMPLATE/          # Issue Forms (feature/bug/experiment)
├── workflows/
│   ├── lint.yml             # actionlint (required check)
│   └── claude.yml           # Claude Code PR 리뷰
├── CODEOWNERS
└── PULL_REQUEST_TEMPLATE.md

docs/
├── TERRAFORM_DEV.md         # dev 환경 구성과 필요 GCP API
├── BRANCH_RULESET_MAIN.md   # main ruleset 설명
├── GITHUB_LABELS_AND_PROJECT.md  # label/Project 운영 기준
└── superpowers/
    ├── specs/               # 설계 문서 (YYYY-MM-DD-<slug>-design.md)
    └── plans/               # 구현 계획 (YYYY-MM-DD-<slug>.md)

CONTRIBUTING.md              # 사람용 협업 규칙 (워크플로우 전체)
branch_ruleset_main.json     # main branch ruleset 정의
```

진행 중(별도 브랜치, main 미반영):

```
.github/workflows/terraform-plan.yml   # Terraform plan OIDC workflow (#6)
terraform/envs/dev/backend.tf          # GCS remote backend (#6)
```

로컬 전용(커밋하지 않음): `agent.md`, `docs/NOTION_PROGRESS_TIMELINE.md`,
`.claude/settings.local.json`

## Team Ownership & Domains

| 도메인 | 팀원 | 책임 | 주요 경로 |
|---|---|---|---|
| **GCP Infrastructure** | hyeongyu-data | Terraform/IaC, 네트워크, IAM, 시크릿, 배포 자동화 | `terraform/`, `.github/workflows/`, `docs/` |
| **Model Training** | waieiches, hyochangsung | 모델·학습 파이프라인 (앱 저장소) | `SKYAHO/Autoresearch` |
| **Airflow Orchestration** | bbungjun | DAG·오케스트레이션 (앱 저장소) | `SKYAHO/Autoresearch` |

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
  Secret Manager
- **State:** 로컬 state (GCS remote backend는 #6에서 진행 중)
- **CI:** GitHub Actions — `lint`(actionlint, required check),
  Claude Code PR Review. Terraform plan workflow는 #6에서 진행 중
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
5. **설계 결정 기록:** 아키텍처에 영향이 있으면 `docs/superpowers/specs/`에
   spec을 남기거나 관련 `.claude/docs/` 가이드를 갱신합니다.

## Verification Checklist

- [ ] 리소스가 올바른 환경·파일에 정의되어 있다.
- [ ] 새 변수가 `terraform.tfvars.example`에 반영되어 있다.
- [ ] `fmt -check`, `validate`, `git diff --check`를 통과했다.
- [ ] 비용·리전·IAM 영향이 PR에 설명되어 있다.
- [ ] 동작·설정이 바뀌었으면 문서를 갱신했다.
