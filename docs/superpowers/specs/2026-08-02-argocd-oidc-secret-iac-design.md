# ArgoCD OIDC Secret Manager 정본 IaC 편입 — 설계 노트

> Issue: #494 | Date: 2026-08-02

## 문제

`argocd-google-oidc-client-id` / `argocd-google-oidc-client-secret`은 라이브 Secret
Manager에는 존재하지만 Terraform 어디에도 정의돼 있지 않다. airflow·mlflow·grafana·
kibana 4종은 모두 코드화된 것과 대비된다. 다음 프로젝트 재구축(#404 유형 사고)에서
이 컨테이너가 누락된다.

## 이름 규칙 결정

두 가지 선택지:

1. **기존 이름 유지** (`argocd-google-oidc-client-id`, `-secret`) — `terraform import`로
   기존 라이브 secret을 그대로 state에 입양. 값·이름 변경 없음. 접두사 규칙
   (`${local.resource_prefix}-...`) 예외로 문서화.
2. **`autoresearch-dev-argocd-oauth-client-*`로 통일** — 새 secret 생성 + 값 이관 +
   README의 `gcloud secrets versions access` 대상 이름 갱신 + 기존 secret 폐기.

**선택: 1 (기존 이름 유지).** 근거:

- 이 이슈의 목적은 "값이 아니라 컨테이너를 코드로 옮기는 것"(이슈 본문 명시). 이름
  변경은 범위 밖 리스크를 추가한다.
- ArgoCD `helm-values/argo-cd.values.yaml.tftpl`이 `$argocd-google-oidc:clientId`로
  K8s Secret `argocd-google-oidc`(Terraform 밖, README 수동 절차)를 참조하는데, 그
  K8s Secret은 SM에서 `gcloud secrets versions access --secret argocd-google-oidc-client-id`로
  값을 읽는다. 이름을 바꾸면 README의 이 명령과 운영자의 기존 스크립트/기억을 함께
  갱신해야 하고, 전환 기간에 두 이름이 혼재할 위험이 생긴다.
- import는 되돌리기 쉽다(`terraform state rm`으로 분리해도 라이브 secret은 그대로
  남는다). 이름 변경(신규 생성 + 값 이관 + 폐기)은 되돌리기가 더 무겁다.
- 접두사 규칙 예외는 코드 주석으로 명시하면 충분히 추적 가능하다.

## 구현

`terraform/envs/dev/secret_manager.tf`에 `ui_oauth_clients`(grafana/kibana, prefixed
for_each)와 나란히 별도 리소스 블록을 추가한다. argocd는 접두사가 없고 값도
Terraform이 관리하지 않으므로(운영자가 gcloud로 직접 채움) `ui_oauth_clients`
for_each에 합치지 않고 `agent_orchestration_codex_auth_bootstrap`과 같은 형태
(payload 없는 컨테이너 + `prevent_destroy`)로 별도 선언한다.

```hcl
resource "google_secret_manager_secret" "argocd_google_oidc_client" {
  for_each = toset([
    "argocd-google-oidc-client-id",
    "argocd-google-oidc-client-secret",
  ])
  secret_id = each.key # 기존 라이브 이름 그대로 — resource_prefix 접두사 예외(#494)

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

accessor는 부여하지 않는다(README의 수동 `gcloud secrets versions access` 절차만
사용, 4종 UI OAuth secret과 동일).

## Import

값 변경 없이 기존 라이브 secret을 state에 입양한다.

```bash
terraform -chdir=terraform/envs/dev import \
  'google_secret_manager_secret.argocd_google_oidc_client["argocd-google-oidc-client-id"]' \
  projects/<project>/secrets/argocd-google-oidc-client-id
terraform -chdir=terraform/envs/dev import \
  'google_secret_manager_secret.argocd_google_oidc_client["argocd-google-oidc-client-secret"]' \
  projects/<project>/secrets/argocd-google-oidc-client-secret
```

import 후 `terraform plan`이 0 add / 0 change / 0 destroy로 수렴해야 한다(라이브 값·
replication 설정을 그대로 반영). 편차가 있으면 코드를 라이브에 맞춰 조정하고, 라이브
쪽을 바꾸지 않는다.

실측(2026-08-02, `gcloud secrets describe --format='value(replication)'`): 두 secret
모두 `automatic={}`로, 코드의 `replication { auto {} }`와 일치한다. `replication`은
Secret Manager에서 생성 후 변경 불가(ForceNew) 필드이지만, 값이 이미 일치하므로 import
시 교체가 발생하지 않는다.

### 머지 → import → plan 확인 순서 보장

이 import는 PR에 코드로 포함되지 않는 수동 out-of-band 절차다. `import {}` 블록
(TF >= 1.6, `versions.tf` 충족)으로 코드화하는 대신 수동 절차를 유지한 이유:
`import {}`는 참조하는 라이브 리소스가 없으면 plan이 실패한다. 이 이슈의 목적은
재구축(라이브 secret이 아직 없는 상태)에서도 이 컨테이너가 정상 생성되게 하는
것이므로, import를 코드에 고정하면 재구축 경로가 새로 깨진다. 현재 프로젝트처럼
라이브 secret이 이미 있는 경우에만 1회성으로 import가 필요하다.

머지 직후 이 PR 작업자가 즉시 import를 실행하고 `terraform plan`이 0/0/0으로
수렴하는지 확인한다. 그 사이(머지~import) `apply.yml`이 먼저 실행되면, 이
리소스 생성 API 호출만 `ALREADY_EXISTS`로 실패한다 — Terraform은 그래프상
독립적인 다른 dev root 리소스 변경까지 막지 않고, 이 리소스에 의존하지 않는
변경은 그대로 적용된다. 이후 import를 수행하면 정상 수렴한다.

## 완료 조건

- [ ] `terraform plan` 0 add / 0 change / 0 destroy (import 후)
- [ ] `scripts/verify-oauth-clients.sh` argocd 항목 WARN 없이 통과
- [ ] `terraform/admin/argocd-k8s/README.md`, `docs/MIGRATION_RUNBOOK.md`,
      `docs/OAUTH_OPERATIONS_RUNBOOK.md` Secret 인벤토리에 컨테이너 출처가
      Terraform임을 반영
- [ ] `secret_manager.tf:130` 부근 "argocd와 대칭" 주석을 실제와 맞게 정정

## 롤백

import만 수행하고 리소스 속성을 바꾸지 않으므로, 문제가 생기면
`terraform state rm 'google_secret_manager_secret.argocd_google_oidc_client["..."]'`로
state에서만 분리하면 라이브 secret은 그대로 남는다.
