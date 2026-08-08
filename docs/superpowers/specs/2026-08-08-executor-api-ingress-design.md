# Executor의 Experiment API ingress 허용 설계

## 목표

Argo CD가 관리하는 `autoresearch/agent-orchestration-api-egress`
NetworkPolicy에 dev executor Pod의 Experiment API TCP 8000 호출 경로를 Git desired
state로 반영한다.

## 변경 범위

- `deploy/agent-orchestration/network-policy.yaml`의 API ingress에 네 번째 규칙을
  추가한다.
- source peer 하나 안에 아래 두 selector를 함께 둔다. Kubernetes NetworkPolicy는
  같은 peer 안의 `namespaceSelector`와 `podSelector`를 AND로 평가한다.
  - namespace: `app.kubernetes.io/name=autoresearch-experiments`
  - Pod: `app.kubernetes.io/component=experiment-executor`
- 목적지 포트는 `TCP/8000` 하나만 허용한다.
- API ingress는 총 4개, API egress는 기존 10개를 유지한다.
- IAM, image digest, executor egress, Kubernetes 리소스 selector는 변경하지 않는다.

## 계약 검사

`scripts/check-agent-orchestration-deployment-verification.rb`가 다음을 검증한다.

1. API ingress가 정확히 4개다.
2. executor namespace와 Pod selector가 같은 `from` 항목 안에 있다.
3. executor 규칙이 `TCP/8000`만 허용한다.
4. API egress가 기존 10개다.

`scripts/test-check-agent-orchestration-deployment-verification.rb`는 두 selector를 서로
다른 peer로 분리한 mutation을 만들고 계약 검사가 이를 거부하는지 확인한다.

## 적용 후 기대 상태

Argo CD sync 뒤 live NetworkPolicy는 ingress 4개와 egress 10개를 가지며, 이미
클러스터에서 probe로 검증한 executor-to-API 연결이 desired state와 일치한다.
