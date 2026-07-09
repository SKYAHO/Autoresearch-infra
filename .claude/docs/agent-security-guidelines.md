# 에이전트 보안 가이드

> Last Updated: 2026-07-07

시크릿, 자격 증명, IAM, workflow 권한을 다룰 때 사용하는 문서입니다.

## Secrets

- 다음을 절대 커밋하지 않습니다:
  - `.env` (로컬 환경 변수)
  - `keys/` 하위 파일, service account key JSON
  - `*.pem`, `*.key`, `application_default_credentials.json`
  - Terraform state(`*.tfstate`)와 실값 `terraform.tfvars` — state와
    tfvars에는 비밀번호, private IP, project id가 포함될 수 있습니다.
- 시크릿 값은 코드, 로그, PR 본문, 커밋 메시지에 포함하지 않습니다.
- 애플리케이션이 소비하는 시크릿은 Secret Manager로 관리하고, Terraform
  에서는 `random_password` 생성 → Secret Manager 저장 패턴을 사용합니다.
- 새 변수가 필요하면 값이 비어 있는 항목을 `terraform.tfvars.example`에
  추가하고 용도를 주석으로 남깁니다.
- 커밋 전 `git status`와 diff에서 시크릿·자격 증명·state 파일이
  포함되지 않았는지 확인합니다.

## IAM

- 최소 권한 원칙을 적용합니다: 프로젝트 수준보다 리소스 수준(버킷,
  저장소, 인스턴스 단위) 권한을 우선합니다.
- 서비스 계정은 용도별로 분리하고, 광범위한 role(`roles/owner`,
  `roles/editor`)을 부여하지 않습니다.
- 권한 확대 변경은 PR에 사유와 롤백 방법을 명시합니다.
- 로컬 개발용 자격 증명과 CI/프로덕션 자격 증명을 분리합니다.

## GitHub Actions

- workflow의 `permissions`는 필요한 최소 권한만 부여합니다.
- 시크릿은 GitHub Secrets로 참조하고 workflow 파일에 하드코딩하지
  않습니다.
- GCP 인증은 service account key 파일 대신 OIDC 기반 Workload Identity
  Federation을 우선합니다 (`id-token: write` 필요).
- 외부에서 제어 가능한 입력(PR 제목, 코멘트 본문)을 shell에 직접
  보간하지 않습니다.
- workflow 변경 시 `git diff --check`를 실행하고, 로컬에 `actionlint`가
  있으면 함께 사용합니다.

## Network

- 데이터 저장소(Cloud SQL 등)는 private IP를 기본으로 하고, public IP
  노출은 사유 없이 추가하지 않습니다.
- 방화벽 규칙은 소스 범위를 최소화합니다. 관리 접근(SSH)은 IAP 경유를
  기본으로 합니다.
- egress가 필요한 리소스는 Cloud NAT를 사용합니다.

## Review Triggers

다음이 바뀌면 PR 리뷰에 Security 관점을 반드시 포함합니다:

- IAM binding, service account, Secret Manager
- 방화벽, 네트워크 노출 (public IP, 포트)
- GitHub Actions workflow와 `permissions`
- OIDC/WIF 설정
