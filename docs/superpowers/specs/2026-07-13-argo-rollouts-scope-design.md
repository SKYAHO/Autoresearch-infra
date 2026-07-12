# Argo Rollouts 적용 범위 설계 (#87)

> 작성: 2026-07-13
> 전제: controller 설치와 sample 검증은 후속 이슈. 이 문서는 범위·정책 결정만.

## 필요성 검토

점진 배포(Canary/Blue-Green)의 가치는 "실 트래픽을 받는 stateless 서비스의
릴리스 위험 축소"에 있다. 현재 dev 클러스터에는 실 트래픽을 받는 앱
Deployment가 아직 없다(`autoresearch` namespace 비어 있음). 따라서:

- **결론**: Rollouts는 필요하다 — 단, 앱(SKYAHO/Autoresearch) API가 실제로
  배포되는 시점에 맞춰 도입한다. 그 전에 controller만 설치해 두는 것은
  관리 대상만 늘린다.
- 이 설계를 지금 확정해 두는 이유: 앱 배포 이슈가 열릴 때 배포 전략을
  다시 논의하지 않고 바로 적용하기 위해서다.

## 적용 / 제외 대상

| 워크로드 | 적용 | 근거 |
|---|---|---|
| Autoresearch 앱 API (stateless Deployment, `autoresearch` ns) | **적용 (유일 대상)** | 실 트래픽 수신, stateless — canary의 본래 대상 |
| Airflow 전체 (scheduler/webserver/postgresql) | 제외 | stateful + Helm chart 소유가 앱 저장소. chart upgrade 전략으로 관리 |
| KPO batch pods | 제외 | 일회성 pod — 점진 전환 개념이 성립 안 함 |
| ArgoCD / Prometheus / Grafana / Vault | 제외 | 플랫폼 컴포넌트, 관리자 트래픽만. Terraform helm_release(버전 pin)로 관리 |
| Cloud Run proxy | 제외 | Cloud Run 자체 revision traffic split이 이미 canary 역할 |

## Canary vs Blue-Green

**Canary 채택, Blue-Green 제외.**

- Blue-Green은 전환 순간까지 replica 2벌이 필요해 dev 최소 비용 원칙과 충돌.
- 이 클러스터에는 mesh/ingress 기반 트래픽 분할 장치가 없으므로
  **replica-weight 방식 canary**(trafficRouting 미설정)를 쓴다. 트래픽
  비율은 replica 수로 근사되며 추가 인프라가 필요 없다.
- 초기 step 예시: `25% → pause(무기한) → 100%` — pause 해제(promote)는
  운영자가 수행한다.

## Metric 기반 판단

**단계적 도입 — 1단계는 수동 promote.**

| 단계 | 판단 방식 | 근거 |
|---|---|---|
| 1단계 (도입 시) | AnalysisTemplate 없음. canary pause 상태에서 운영자가 Grafana(kube-prometheus-stack)로 오류율/지연 확인 후 수동 promote | GITOPS_STRATEGY의 manual-first 원칙과 정렬. 자동 판단보다 가시화 먼저 |
| 2단계 (안정화 후) | AnalysisTemplate + Prometheus provider (5xx 비율, p95 latency) 기반 자동 promote/abort | metric 신뢰도와 임계값이 실측으로 검증된 뒤 |

2단계 전제 조건: rollouts controller → `monitoring` namespace Prometheus로의
NetworkPolicy 경로 확인(현재 각 namespace deny-by-default), 앱의 request
metric이 Prometheus에 수집되고 있을 것.

## ArgoCD와의 책임 경계

| 역할 | 담당 | 설명 |
|---|---|---|
| Rollout/AnalysisTemplate manifest를 Git → cluster로 sync | ArgoCD | Rollout CR도 여느 manifest처럼 desired state의 일부 |
| Rollout CR 실행 (ReplicaSet 전환, canary step, pause) | Argo Rollouts controller | ArgoCD는 전환 과정에 개입하지 않음 |
| promote / abort | 운영자 (`kubectl argo rollouts` plugin) | ArgoCD sync와 독립된 조작. auto-sync가 켜져 있어도 promote를 대신하지 않음 |
| Rollout health 표시 | ArgoCD (빌트인 health check) | Progressing/Degraded/Healthy가 Application 상태에 반영됨 |
| controller 설치 | Terraform admin root (신설, 예: `argo-rollouts-k8s`) | argocd-k8s/vault-k8s와 동일 패턴 — namespace, NetworkPolicy, helm_release 버전 pin |

주의: ArgoCD auto-sync + Rollouts를 함께 쓸 때 Git의 이미지 tag 변경이
sync되면 Rollout이 자동으로 canary를 시작한다. 시작은 자동이어도 완료
(promote)는 1단계에서 항상 수동이다.

앱 저장소 쪽 전환 방식: 기존 Deployment를 삭제하지 않고 Rollout의
`workloadRef`로 참조하는 방식을 우선 검토한다(manifest 이중화 방지).
결정은 앱 배포 이슈에서 chart/manifest 구조와 함께 확정한다.

## 후속 이슈 입력값

| 이슈(예정) | 입력값 |
|---|---|
| Rollouts controller 설치 | admin root `argo-rollouts-k8s`, chart `argo-rollouts` 버전 pin, deny-by-default NetworkPolicy(#116/#122/#126 교훈 재사용), 트리거: 앱 첫 배포 이슈와 같은 마일스톤 |
| 앱 Rollout 전환 + sample 검증 | workloadRef 여부, canary steps, `kubectl argo rollouts` 운영 절차 runbook |
| metric 기반 analysis (2단계) | AnalysisTemplate, Prometheus 쿼리·임계값, monitoring NetworkPolicy 경로 |
