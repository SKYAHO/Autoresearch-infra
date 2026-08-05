# ArgoCD main 변경 자동 sync 구현 계획

**Goal:** Agent Orchestration을 포함한 GKE 배포 manifest가 infra main merge 뒤 자동 sync되게 한다.

## 작업

1. `argocd-k8s` Application의 Agent Orchestration source를 enabled 시 `main`으로 고정하고 automated sync를 추가한다.
2. 고정 SHA 변수·apply workflow 검증·TF_VAR 주입을 제거하되 enabled 비상 차단 스위치는 유지한다.
3. ArgoCD README, 팀 운영 runbook, Terraform 운영 문서, 변경 이력을 새 운영 방식과 rollback으로 갱신한다.
4. `terraform fmt`, admin root `init -backend=false`·`validate`, `git diff --check`로 검증한다. 실제 apply와 sync는 승인된 별도 운영 단계다.
