# Terraform

이 디렉터리는 `autoresearch-infra`의 Terraform 코드를 관리합니다.

현재 구성:

```text
terraform/
├── admin/          # 운영자 전용 별도 state root(IAM 및 Kubernetes 경계)
├── bootstrap/      # GCS backend + GitHub WIF/CI SA 1회성 bootstrap
├── envs/
│   └── dev/        # dev 환경 root module(GCS backend)
└── modules/        # 재사용 module(현재 미사용, staging/prod 분리 시 추출)
```

## 환경

| 환경 | 경로 | 용도 |
|---|---|---|
| dev | `terraform/envs/dev` | AutoResearch dev 인프라 검증 및 초기 운영 |
| admin | `terraform/admin/gke-team-access` | 팀원 Google 계정의 GKE `container.viewer` + bastion 접속 IAM |
| admin | `terraform/admin/autoresearch-k8s` | 앱 namespace/KSA와 Cloud SQL/Redis Cluster 최소 egress NetworkPolicy |
| admin | `terraform/admin/airflow-k8s` | Airflow Kubernetes namespace/RBAC/NetworkPolicy |
| admin | `terraform/admin/monitoring-k8s` | monitoring namespace와 port-forward RBAC 경계(chart는 ArgoCD Application이 관리, #183) |
| admin | `terraform/admin/argocd-k8s` | ArgoCD namespace와 Helm 설치, AppProject/Application(monitoring·argo-rollouts·mlflow·serving·agent-orchestration) |
| admin | `terraform/admin/argo-rollouts-k8s` | Argo Rollouts namespace/NetworkPolicy 경계(chart는 ArgoCD Application이 관리, #186) |
| admin | `terraform/admin/elastic-k8s` | ECK/Elasticsearch namespace와 네트워크 경계 (#97) |
| admin | `terraform/admin/vault-k8s` | retired: #412 운영 제외, root/state 제거는 #478 |

## 기본 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
scripts/terraform-env --environment dev --root terraform/envs/dev init
scripts/terraform-env --environment dev --root terraform/envs/dev validate
```

실제 plan/apply를 실행할 때는 `terraform/envs/dev/terraform.tfvars.example`을 참고해 로컬 전용 `terraform.tfvars`를 만들고 사용합니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
scripts/terraform-env --environment dev --root terraform/envs/dev plan
scripts/terraform-env --environment dev --root terraform/envs/dev apply
```

`terraform.tfvars`, state, plan 파일은 커밋하지 않습니다.

**중요 — `terraform.tfvars`와 카탈로그의 우선순위**: 래퍼가 생성하는
`.environment.auto.tfvars.json`은 파일명이 `*.auto.tfvars.json` 규칙이라
`terraform.tfvars`보다 **나중에, 더 강하게** 적용됩니다. 따라서 카탈로그가
공급하는 좌표(`project_id`, `region`, `zone`, `name_prefix`, `resource_prefix`,
GKE cluster, 각 CIDR)를 로컬 `terraform.tfvars`에 적어도 **조용히 무시됩니다.**
예시 파일에 그 값들이 남아 있는 것은 카탈로그 도입 이전의 잔재이며, 이제
`terraform.tfvars`에는 카탈로그가 공급하지 않는 값(허용 이메일 목록,
`labels`, `master_authorized_networks` 등)만 두는 것이 맞습니다.

이 우선순위는 과거 "로컬 tfvars가 default를 덮어써 의도와 다른 값이 적용된"
함정과 방향이 반대입니다 — 이제는 카탈로그가 이깁니다. 좌표를 바꾸려면
`terraform.tfvars`가 아니라 `config/environments/dev/environment.yaml`을
수정해야 합니다.

`scripts/terraform-env`는 `config/environments/dev/environment.yaml`을 검증한 뒤
각 Terraform root에 gitignored `.environment.auto.tfvars.json`과 backend 입력을
생성합니다. 좌표를 바꿀 때는 개별 root의 `versions.tf`나 실제 `terraform.tfvars`가
아니라 이 카탈로그를 수정합니다. 다만 프로젝트·리전 변경은 리소스 이동이 아니라
별도 migration 절차이므로, 카탈로그 변경만으로 apply하지 않습니다.

## Backend 구성

dev 및 admin root는 GCS backend를 사용합니다. bucket과 root별 prefix의 정본은
`config/environments/dev/environment.yaml`의 `state`입니다. backend는 일반 Terraform
변수로 참조할 수 없으므로 래퍼가 `terraform init`에만 `-backend-config`로 전달합니다.
`init -backend=false`에서는 backend 입력을 전달하지 않으며, backend 좌표를 바꾼 뒤에는
반드시 `scripts/terraform-env ... init -reconfigure`를 실행합니다.

backend bucket과 GitHub Actions plan용 WIF/CI SA는 `terraform/bootstrap`에서 1회성으로 관리합니다. 자세한 내용은 [../docs/TERRAFORM_BOOTSTRAP.md](../docs/TERRAFORM_BOOTSTRAP.md)를 참고합니다.
