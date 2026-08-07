# Agent Orchestration PostSync 배포 검증 설계

infra main merge 뒤 ArgoCD가 자동 sync한 Agent Orchestration 배포를 GKE 내부 Job으로 검증한다. GitHub-hosted Runner와 ARC runner에는 private GKE 접근 또는 Kubernetes RBAC를 추가하지 않는다.

ArgoCD는 Sync 단계의 Deployment가 `Healthy`가 된 뒤에만 `PostSync` hook을 실행한다. 따라서 새 API Pod가 기동하지 못하거나 rollout이 진행되지 않으면 Job이 아니라 ArgoCD Deployment health가 sync 실패를 표시한다. verifier는 그 다음 단계에서 API Service의 OpenAPI에 candidate 보고 endpoint가 있는지를 최대 150초 재시도해 확인한다. 이는 Service가 제공하는 기능 계약 검증이며, Kubernetes API 권한 없이 개별 endpoint의 image digest 균일성까지 증명하지는 않는다.

Job의 image digest는 API Deployment의 `api` container와 CI에서 동일성을 검사한다. Job에는 ServiceAccount token, Secret, volume, Kubernetes API 권한을 부여하지 않는다. Job Pod label·API ingress selector·verifier NetworkPolicy selector는 CI에서 같은 값인지 검사하고, verifier egress는 환경 카탈로그의 services CIDR 기반 API TCP 8000과 DNS만 허용한다. `backoffLimit=1`로 image pull·eviction 같은 Pod 단위 일시 실패를 한 번 흡수하되, 300초 전체 deadline을 넘기면 즉시 실패한다. 실패 Job은 다음 PostSync 시도 전까지 남아 ArgoCD operation 실패와 기존 `KubeJobFailed` 경보가 원인을 노출한다.

롤백에서 candidate endpoint가 없는 이전 API digest를 사용할 경우 verifier도 같은 sync에서 실패한다. Sync 단계에서 Deployment는 먼저 롤백 digest로 적용되지만, PostSync 실패가 이를 자동으로 되돌리지는 않는다. 따라서 긴급 롤백은 verifier Job과 전용 NetworkPolicy 규칙을 같은 revert PR에서 함께 제거하거나, endpoint 호환 이전 digest를 사용해야 한다. Application에는 retry·self-heal이 없으므로 같은 Git revision의 실패를 자동 반복하지 않는다. `BeforeHookCreation` 정책상 새 revision 또는 수동 sync가 다음 PostSync를 시작할 때 직전 실패 Job을 삭제하므로, 원인 확인은 그 전에 끝낸다. ArgoCD automated sync는 prune도 꺼져 있어 verifier manifest를 제거해도 기존 실패 Job을 자동 prune하지 않으며, 이 경우 운영자가 확인 뒤 별도로 정리한다.
