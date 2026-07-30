# Task 3 보고 — environment-scoped Feast apply Kubernetes 경계

## 변경 파일

- `terraform/envs/dev/variables.tf`
- `terraform/envs/dev/terraform.tfvars.example`
- `terraform/admin/autoresearch-k8s/variables.tf`
- `terraform/admin/autoresearch-k8s/locals.tf`
- `terraform/admin/autoresearch-k8s/feast_apply.tf`
- `terraform/admin/autoresearch-k8s/outputs.tf`
- `terraform/admin/autoresearch-k8s/terraform.tfvars.example`
- `terraform/admin/autoresearch-k8s/README.md`

## 검증 결과

- `terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive` 및
  `fmt -check -recursive` 성공.
- `git diff --check` 성공.
- `rg`로 dev/prod namespace, 모든 Feast resource의 `for_each`, KSA annotation과
  RoleBinding의 같은 환경 GSA 참조, `each.key == "prod"` Redis PSC 동적 블록을 확인.
- 첫 sandbox `init -backend=false`는
  `lookup registry.terraform.io: no such host` DNS 오류로 실패했다. 승인된 실행
  환경에서 재시도한 `init -backend=false`와 `validate`는 성공했다. 이후 sandbox의
  provider schema 로드는 차단됐으나 승인된 실행 환경의 최종 `validate`는 성공했다.

## 결정

- Task 2의 고정 WI subject와 일치하도록 dev/prod namespace/KSA 기본값을
  `feast-apply-dev|prod` / `feast-apply`로 고정했다.
- admin override는 정확히 `dev`, `prod` 두 키와 유효한 비어 있지 않은 GSA email을
  요구한다. null 기본값에서만 resource prefix/project id 기반 GSA를 파생한다.
- Redis PSC discovery/data-node egress는 prod 정책에만 렌더되며 dev에는 포함하지
  않는다.

## 구현 커밋

- `8f98f08a262eb44d20669a6fdc3fe25d2c6e05cf` — `feat: Feast apply Kubernetes 환경 경계 분리`
