# Autoresearch Kubernetes 경계

이 admin Terraform root는 dev GKE의 일반 애플리케이션 워크로드에 필요한
Kubernetes 측 경계를 별도 state로 관리합니다.

- `autoresearch` namespace
- app GCP service account와 연결된 `autoresearch-app` KSA
- DNS, Cloud SQL, Redis TLS, Workload Identity, HTTPS만 허용하는 egress
  NetworkPolicy

GCP Redis, Secret Manager, app GSA와 Workload Identity IAM member는
`terraform/envs/dev`에서 관리합니다. 애플리케이션 Deployment와 Feast
`feature_store.yaml`은 `SKYAHO/Autoresearch` 저장소에서 관리합니다.

## 최초 적용 전 확인

이 root는 GKE API에 직접 접근하므로 운영자 인증과 네트워크 접근이 필요합니다.
먼저 dev root를 apply해 Redis와 Secret을 준비하고 다음 값을 확인합니다.

```bash
terraform -chdir=terraform/envs/dev output redis_port
terraform -chdir=terraform/envs/dev output redis_auth_secret_id
terraform -chdir=terraform/envs/dev output redis_server_ca_secret_id
```

`redis_port`를 이 root의 로컬 `terraform.tfvars`에 반영합니다. 실제 project id와
값이 든 `terraform.tfvars`는 커밋하지 않습니다.

live cluster에 `autoresearch` namespace나 KSA가 이미 존재하면 삭제·재생성하지
말고 최초 apply 전에 state로 import합니다.

```bash
terraform -chdir=terraform/admin/autoresearch-k8s import \
  kubernetes_namespace_v1.autoresearch autoresearch

terraform -chdir=terraform/admin/autoresearch-k8s import \
  kubernetes_service_account_v1.app autoresearch/autoresearch-app
```

## 검증 및 적용

```bash
cp terraform/admin/autoresearch-k8s/terraform.tfvars.example \
  terraform/admin/autoresearch-k8s/terraform.tfvars

terraform -chdir=terraform/admin/autoresearch-k8s init
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check
terraform -chdir=terraform/admin/autoresearch-k8s validate
terraform -chdir=terraform/admin/autoresearch-k8s plan \
  -var-file=terraform.tfvars
```

`apply`는 dev Redis apply 완료, live namespace import 여부, NetworkPolicy 영향과
사용자 승인을 확인한 뒤에만 수행합니다.

## NetworkPolicy와 smoke test

NetworkPolicy는 namespace 전체 pod를 egress isolation 대상으로 삼습니다. 앱이
추가 포트를 사용한다면 배포 전에 최소 CIDR/port 규칙을 별도 검토해야 합니다.

Redis 연결은 public endpoint가 아니라 private services CIDR의 TLS endpoint로만
허용됩니다. apply 후 앱 GSA를 사용하는 pod에서 Secret Manager의 AUTH token과
CA를 주입하고 TLS `PING`이 `PONG`을 반환하는지 확인합니다. AUTH token은 명령행,
로그, PR 또는 shell history에 남기지 않습니다.

## 롤백

문제가 생기면 애플리케이션의 Redis 사용을 먼저 중지하고, NetworkPolicy에서
Redis port 규칙을 제거한 plan을 검토한 뒤 admin root를 apply합니다. namespace나
KSA를 삭제하는 롤백은 다른 워크로드에 영향을 줄 수 있으므로 수행하지 않습니다.
