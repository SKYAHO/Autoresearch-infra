# autoresearch-infra

`autoresearch-infra`는 AutoResearch 프로젝트의 GCP 기반 인프라를 관리하는 저장소입니다.

현재 단계에서는 실제 GCP 리소스 코드보다 먼저 GitHub 협업 초기 세팅을 정리합니다. 이후 Terraform/IaC, GitHub Actions, GCP 배포 자동화, 권한/시크릿/모니터링 설정을 이 저장소에서 관리합니다.

## 저장소 목적

- GCP 프로젝트 인프라 구조 관리
- Terraform 또는 IaC 기반 리소스 정의 관리
- GitHub Actions 기반 검증/배포 자동화 관리
- IAM, Secret Manager, Artifact Registry, Cloud Run, Cloud Scheduler, GCS, BigQuery 등 운영 리소스 관리
- 인프라 변경 이력, 리뷰, 승인 흐름 표준화

## 현재 포함된 초기 세팅

- Issue Forms: Feature, Bug, Experiment
- Pull Request template
- CODEOWNERS
- Claude Code PR Review workflow
- GitHub issue, branch, PR, project 운영 문서
- GitHub label 및 Project 초기 운영값 문서
- GCP/IaC 작업을 고려한 `.gitignore`

## 예정 구조

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/
│   ├── workflows/
│   ├── CODEOWNERS
│   └── PULL_REQUEST_TEMPLATE.md
├── terraform/              # Terraform root/modules/envs 예정
├── gcp/                    # GCP 운영 스크립트/설정 예정
├── docs/                   # 인프라/GitHub 운영 문서
├── scripts/                # 검증/배포 보조 스크립트 예정
├── CONTRIBUTING.md
├── GITHUB_WORKFLOW.md
├── NOTION_GITHUB_WORKFLOW.md
└── README.md
```

## 협업 흐름

```text
Issue 생성 -> Branch 생성 -> 작업 -> PR 생성 -> Review -> Squash Merge
```

인프라 변경은 권한, 비용, 리전, 롤백 가능성, secret 노출 여부를 반드시 함께 검토합니다. 자세한 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md), GitHub 운영 문서는 [GITHUB_WORKFLOW.md](GITHUB_WORKFLOW.md), label/Project 규칙은 [docs/GITHUB_LABELS_AND_PROJECT.md](docs/GITHUB_LABELS_AND_PROJECT.md)를 참고합니다.
