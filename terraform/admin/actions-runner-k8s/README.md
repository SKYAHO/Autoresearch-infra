# terraform/admin/actions-runner-k8s

GitHub Actions 셀프 호스티드 러너(ARC, Actions Runner Controller)의 Kubernetes
경계(별도 state). #533 설계, PoC.

- namespace `actions-runner` (PSA `baseline`)
- KSA `actions-runner-controller`(Workload Identity → GSA
  `autoresearch-dev-runner`, automount 기본값 유지 — 컨트롤러가 K8s API를 직접
  관리해야 하므로 이 root의 "automount=false 기본" 원칙에 대한 의도적 예외)
- KSA `actions-runner-listener`(automount=false, GCP API 미사용 — PoC
  워크플로우가 이 KSA로 실행됨)
- ResourceQuota `pods=4`(scale-set chart `maxRunners`와 짝) + LimitRange
- ingress 전면 차단 + egress deny-by-default(DNS, GKE/WI metadata, Private
  Google Access, K8s API 서버 443, GitHub 443 예외)

chart(ARC 컨트롤러/러너)는 이 root가 아니라 **ArgoCD Application**
(`deploy/actions-runner-controller`, `deploy/actions-runner-scale-set`)이
배포한다. 이 root는 플랫폼 경계만 소유한다("Terraform=경로, ArgoCD=앱").

## 범위 밖 (#533 설계 문서 참고)

- feast apply GKE-Job을 이 러너로 이관하는 작업
- 프로덕션 배포 전용 러너 분리(Environment gate)
- 다른 워크플로우로의 확장
- GitHub IP 대역 기반 egress 강화(현재는 포트 443만 제한한 이름 있는 예외)

## apply

```bash
scripts/terraform-env --environment dev --root terraform/admin/actions-runner-k8s init
scripts/terraform-env --environment dev --root terraform/admin/actions-runner-k8s apply \
  -var project_id=<PROJECT_ID> -var cluster_services_cidr=<GKE_SERVICES_CIDR> \
  -var private_googleapis_cidr=<PGA_CIDR>
```

## operator secret 주입 (ARC 설치 전 필수)

GitHub App은 조직 GitHub UI에서 수동으로 먼저 생성해야 한다. Secret Manager
컨테이너(`terraform/envs/dev/actions_runner.tf`)에 값을 채우고 네이티브 K8s
Secret을 만드는 절차는
`docs/runbooks/2026-08-05-actions-runner-github-app-secret.md`를 따른다
(`--from-literal` 금지, `--from-env-file` 사용, #213 컨벤션).

## 정리/롤백

```bash
terraform -chdir=terraform/admin/actions-runner-k8s destroy # 경계 제거(ArgoCD Application 먼저 제거)
```
