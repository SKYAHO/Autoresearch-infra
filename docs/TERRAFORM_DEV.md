# Terraform Dev Environment

이 문서는 `#1 Terraform dev 환경 기본 골격 구성` 결과를 팀원이 빠르게 이해하도록 정리합니다.

## 구조

```text
terraform/
├── README.md
├── envs/
│   └── dev/
│       ├── README.md
│       ├── artifact_registry.tf
│       ├── backend.tf.example
│       ├── locals.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       └── versions.tf
└── modules/
    └── README.md
```

## 현재 단계에서 생성하지 않는 것

#1은 Terraform 실행 골격만 구성합니다. 아래 리소스는 생성하지 않습니다.

- VPC/subnet
- Cloud SQL instance
- GKE cluster
- GitHub OIDC IAM/service account
- Terraform remote state bucket

## Artifact Registry (#3)

| 항목 | 값 | 비고 |
|---|---|---|
| Repository id | `autoresearch-dev-docker` | `${resource_prefix}-docker` (`local.ar_repo_id`) |
| Format | `DOCKER` | 컨테이너 이미지 |
| Location | `asia-northeast3` | `var.region`, dev 기본 region |
| Labels | `default_labels` 상속 | provider `default_labels`에서 일괄 적용 |
| Image URL | `asia-northeast3-docker.pkg.dev/ar-infra-501108/autoresearch-dev-docker` | `output.artifact_registry_image_url` |
| IAM | (미구성) | push/pull 바인딩은 GitHub OIDC SA / GKE 노드 SA 이슈에서 추가 |

배포 workflow는 `output.artifact_registry_repo_id`(repo명)와 `output.artifact_registry_image_url`(이미지 base URL)을 참조한다.

### 왜 GCR이 아니라 Artifact Registry인가

- **GCR은 사실상 deprecated**: Google이 신규 기능/이미지를 Artifact Registry로 이관 중이며, 신규 프로젝트는 AR 권장.
- **IAM 정밀도**: AR은 리포 단위 IAM/labels로 세분화 가능. GCR은 프로젝트 단위(`gcr.io/<project>`)로 권한이 거침.
- **확장성**: AR은 Docker 외 npm/Maven/Python 등 멀티 포맷 + 리전/멀티리전 + 빌트인 취약점 스캔 지원.

## 필수 GCP API 후보

아래 API는 후속 이슈에서 필요한 후보입니다. #1에서는 Terraform output으로 목록만 정리하며, 실제 enable은 별도 이슈나 승인 후 진행합니다.

| API | 사용 예정 |
|---|---|
| `serviceusage.googleapis.com` | GCP API enable 관리 |
| `cloudresourcemanager.googleapis.com` | project metadata 조회 및 관리 |
| `compute.googleapis.com` | VPC/subnet, GKE 기반 네트워크 |
| `artifactregistry.googleapis.com` | Docker image repository |
| `sqladmin.googleapis.com` | Cloud SQL |
| `container.googleapis.com` | GKE |
| `iam.googleapis.com` | service account, IAM binding |
| `iamcredentials.googleapis.com` | GitHub OIDC 기반 credential 생성 |
| `sts.googleapis.com` | Workload Identity Federation token exchange |
| `secretmanager.googleapis.com` | secret 저장 및 참조 |
| `logging.googleapis.com` | 운영 로그 |
| `monitoring.googleapis.com` | 모니터링 |

## 검증 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

`terraform init`은 provider plugin을 내려받기 때문에 네트워크가 필요합니다.

