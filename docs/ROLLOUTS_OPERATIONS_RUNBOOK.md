# Argo Rollouts 운영 Runbook (dev)

dev GKE의 Argo Rollouts(#88 설치, `argo-rollouts` namespace) 운영 절차.
모든 명령은 #89 샘플 검증에서 실행해 확인한 것을 기준으로 한다.
적용 범위·책임 경계는 #87 설계
(`superpowers/specs/2026-07-13-argo-rollouts-scope-design.md`) 참조.

전제:

```bash
# kubectl plugin (1회 설치)
brew install argoproj/tap/kubectl-argo-rollouts
```

## 상태 확인

```bash
# 목록/개요
kubectl argo rollouts -n <namespace> list rollouts

# 상세 (revision 트리, SetWeight, stable/canary 이미지)
kubectl argo rollouts -n <namespace> get rollout <name>

# 실시간 관찰
kubectl argo rollouts -n <namespace> get rollout <name> --watch

# 스크립트용 phase 조회
kubectl -n <namespace> get rollout <name> -o jsonpath='{.status.phase}'
```

phase 의미: `Healthy`(전환 완료) / `Progressing`(전환 중) /
`Paused`(canary 정지 — promote 대기) / `Degraded`(abort됨 또는 실패).

## canary 진행과 수동 promote (1단계 표준)

이미지 변경(Git 또는 CLI)이 반영되면 canary가 시작되고 `pause` step에서
`Paused`로 멈춘다. **promote 전 Grafana에서 canary pod의 오류율/지연을
확인**하고 진행한다(#87 — metric 자동 판단은 2단계).

```bash
# 다음 step으로 진행 (pause 해제)
kubectl argo rollouts -n <namespace> promote <name>

# 모든 step을 건너뛰고 즉시 100% 전환
kubectl argo rollouts -n <namespace> promote <name> --full
```

## abort와 rollback

```bash
# canary 중단 — 트래픽을 stable로 되돌린다
kubectl argo rollouts -n <namespace> abort <name>
```

**주의: abort는 rollback이 아니다.** abort 후 Rollout은 `Degraded`로
남는다 — desired spec에 새 이미지가 그대로 있기 때문이다. Healthy로
복귀하려면 spec을 stable revision으로 되돌려야 한다:

- **ArgoCD로 관리되는 Rollout(실제 앱)**: 이미지 tag를 되돌리는 **Git
  revert → sync**가 원칙이다. 아래 CLI undo를 쓰면 Git과 어긋나
  OutOfSync가 된다.
- **ArgoCD 밖 검증용**: `kubectl argo rollouts -n <ns> undo <name>`
  (#89에서 검증 — undo 후 Healthy 복귀 확인).

## 실패 시 확인 순서

| 순서 | 확인 | 명령/포인트 |
|---|---|---|
| 1 | Rollout phase와 message | `get rollout <name>` — Degraded 사유, 어느 step에서 멈췄는지 |
| 2 | canary pod 상태 | `kubectl -n <ns> get pods` — ImagePullBackOff/CrashLoop 여부 |
| 3 | controller 로그 | `kubectl -n argo-rollouts logs deploy/argo-rollouts` |
| 4 | controller 자체 상태 | `kubectl -n argo-rollouts get pods` — controller가 죽어 있으면 전환이 진행되지 않고 정지 상태로 유지된다(기존 pod는 영향 없음) |
| 5 | ArgoCD 상태 (연결된 경우) | Application이 OutOfSync면 Git과 spec 불일치 — CLI 조작 흔적인지 확인 |

## ArgoCD와 함께 볼 지점 (#87 책임 경계)

| 상황 | ArgoCD | Rollouts |
|---|---|---|
| 새 버전 배포 | Git 변경 sync (manual sync 1단계) | sync된 spec으로 canary 시작 |
| 전환 진행/완료 | Application health가 Progressing/Healthy로 반영 (빌트인 health check) | promote는 항상 plugin으로 별도 수행 |
| 되돌리기 | **Git revert 후 sync** | abort는 임시 정지일 뿐 — Git이 진실 |
| 보이는 곳 | Application 트리에서 Rollout 리소스/health | `get rollout`의 revision 트리·weight |

## 검증용 재현 manifest (#89)

실제 앱 적용 전 흐름을 재현할 때 사용한다. 검증 후 반드시 폐기한다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: sample-canary
  namespace: argo-rollouts
spec:
  replicas: 2   # 50% step의 전제 (#87 — stable >= 2 replica)
  strategy:
    canary:
      steps:
      - setWeight: 50
      - pause: {}
  selector:
    matchLabels:
      app: sample-canary
  template:
    metadata:
      labels:
        app: sample-canary
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            memory: 64Mi
```

재현 절차(#89 실측 순서): `kubectl apply` → Healthy 확인 →
`set image ... web=nginx:1.28-alpine` → Paused(50%) 확인 → `promote` →
Healthy → `set image ... web=nginx:1.29-alpine` → `abort` → Degraded(트래픽
stable 복귀) → `undo` → Healthy → `kubectl -n argo-rollouts delete rollout
sample-canary`로 폐기.

## 폐기/롤백 (controller 수준)

controller 제거·CRD 취급 주의사항은
`terraform/admin/argo-rollouts-k8s/README.md`의 롤백 절을 따른다
(요지: release 제거는 controller만 삭제, CRD는 keep — CRD를 지우면 전
namespace Rollout 연쇄 삭제로 서비스 중단).
