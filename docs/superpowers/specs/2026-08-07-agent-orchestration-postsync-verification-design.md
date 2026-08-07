# Agent Orchestration PostSync 배포 검증 설계

infra main merge 뒤 ArgoCD가 자동 sync한 Agent Orchestration 배포를 GKE 내부 Job으로 검증한다. GitHub-hosted Runner와 ARC runner에는 private GKE 접근 또는 Kubernetes RBAC를 추가하지 않는다.

검증 Job은 ArgoCD `PostSync` hook으로 실행되며 API Service의 OpenAPI에서 candidate 보고 endpoint를 최대 150초 재시도해 확인한다. API Deployment가 Healthy여도 이전 Pod가 Service를 유지하는 경우를 이 endpoint 확인으로 탐지한다.

Job에는 ServiceAccount token, Secret, volume, Kubernetes API 권한을 부여하지 않는다. NetworkPolicy는 verifier Pod의 DNS와 API TCP 8000 egress, API Pod의 verifier TCP 8000 ingress만 허용한다. 실패 Job은 보존해 ArgoCD operation 실패와 기존 `KubeJobFailed` 경보가 원인을 노출한다.

롤백은 verifier Job과 전용 NetworkPolicy 규칙을 revert PR로 제거한다. ArgoCD automated sync는 prune과 self-heal이 꺼져 있으므로, 이미 생성된 실패 Job은 운영자가 원인 확인 뒤 별도로 정리한다.
