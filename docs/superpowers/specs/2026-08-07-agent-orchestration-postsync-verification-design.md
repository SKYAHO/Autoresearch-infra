# Agent Orchestration PostSync 배포 검증 설계

infra main merge 뒤 ArgoCD가 자동 sync한 Agent Orchestration 배포를 GKE 내부 Job으로 검증한다. GitHub-hosted Runner와 ARC runner에는 private GKE 접근 또는 Kubernetes RBAC를 추가하지 않는다.

ArgoCD는 Sync 단계의 Deployment가 `Healthy`가 된 뒤에만 `PostSync` hook을 실행한다. 따라서 새 API Pod가 기동하지 못하거나 rollout이 진행되지 않으면 Job이 아니라 ArgoCD Deployment health가 sync 실패를 표시한다. verifier는 그 다음 단계에서 API Service의 OpenAPI에 candidate 보고 endpoint가 있는지를 최대 150초 재시도해 확인한다. 이는 Service가 제공하는 기능 계약 검증이며, Kubernetes API 권한 없이 개별 endpoint의 image digest 균일성까지 증명하지는 않는다.

Job의 image digest는 API Deployment의 `api` container와 CI에서 동일성을 검사한다. Job에는 ServiceAccount token, Secret, volume, Kubernetes API 권한을 부여하지 않는다. NetworkPolicy는 verifier Pod의 DNS와 API TCP 8000 egress, API Pod의 verifier TCP 8000 ingress만 허용한다. 실패 Job은 다음 PostSync 시도 전까지 남아 ArgoCD operation 실패와 기존 `KubeJobFailed` 경보가 원인을 노출한다.

롤백에서 candidate endpoint가 없는 이전 API digest를 사용할 경우 verifier도 같은 sync에서 실패한다. 따라서 긴급 롤백은 verifier Job과 전용 NetworkPolicy 규칙을 같은 revert PR에서 함께 제거하거나, endpoint 호환 이전 digest를 사용해야 한다. `BeforeHookCreation` 정책상 실패 Job은 다음 PostSync 시작 전에 자동 삭제되므로, 원인 확인은 다음 sync 전에 끝낸다. ArgoCD automated sync는 prune과 self-heal이 꺼져 있어 verifier manifest를 제거해도 기존 실패 Job을 자동 prune하지 않으며, 이 경우 운영자가 확인 뒤 별도로 정리한다.
