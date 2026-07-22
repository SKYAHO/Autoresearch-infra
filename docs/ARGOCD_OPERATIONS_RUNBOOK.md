# ArgoCD 운영 Runbook

이 문서는 Issue #86 기준으로 ArgoCD에서 배포 상태를 확인하고 sync/diff/rollback을
수행하는 절차를 정리한다. 설치와 네트워크 경계는 `terraform/admin/argocd-k8s`,
GitOps 운영 원칙은 [`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md)를 기준으로 한다.
절차의 명령은 #85 샘플 검증에서 실제 실행해 확인한 것이다.

## 접속 전 확인

ArgoCD는 현재 운영자 전용이다. `argocd` namespace에 팀원 RBAC이 없으므로
클러스터 접근 권한(kubeconfig)과 namespace 조회 권한이 있는 계정으로 작업한다.

```bash
kubectl config current-context
kubectl -n argocd get pods
```

pod 4종(server, application-controller, repo-server, redis)이 `Running`이어야
한다. applicationset-controller는 replicas 0으로 중지 상태가 정상이다(#115).

## UI 접속

ArgoCD UI는 인터넷에 공개하지 않는다. 접근은 `kubectl port-forward`만 사용한다.

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8443:443
```

브라우저에서 `https://localhost:8443`으로 접속한다. self-signed 인증서 경고는
dev 내부 경로 특성상 허용한다.

로그인은 두 가지다(#289):

- **Google(Gmail) 로그인(기본)**: **LOG IN VIA GOOGLE**. 허용 이메일만 접근하며
  admin은 sync/rollback, readonly는 조회만 가능하다. 목록 밖 계정은 로그인해도
  권한이 없다(`policy.default` 거부).
- **로컬 `admin`**: CLI·자동화·break-glass용으로 유지한다.

Google OIDC client secret 주입, redirect URI, 허용 이메일(`terraform.tfvars`) 절차와
admin credential 처리(초기 비밀번호 회수·변경·secret 삭제)는
[`terraform/admin/argocd-k8s/README.md`](../terraform/admin/argocd-k8s/README.md)를
단일 원본으로 한다. 비밀번호·client secret은 문서, PR, 채팅에 남기지 않는다.

## 상태 확인 순서

장애 알림이 없어도 운영 점검은 아래 순서로 본다.

| 순서 | 확인 | 명령/위치 |
|---|---|---|
| 1 | 컴포넌트 pod 상태 | `kubectl -n argocd get pods` |
| 2 | Application sync/health | 아래 명령 또는 UI Applications 목록 |
| 3 | 마지막 sync operation 결과 | `status.operationState` |
| 4 | 배포 이력 | `status.history[]` |

```bash
# sync 상태와 health
kubectl -n argocd get application <app> \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

# 마지막 operation 결과와 실제 배포된 revision
kubectl -n argocd get application <app> \
  -o jsonpath='{.status.operationState.phase} deployed={.status.operationState.syncResult.revision}{"\n"}'

# 배포 이력
kubectl -n argocd get application <app> \
  -o jsonpath='{range .status.history[*]}{.id}: {.revision}{"\n"}{end}'
```

> **주의**: `status.sync.revision`은 배포된 revision이 아니라 spec
> `targetRevision`과의 비교 기준값이다. 실제 배포된 revision은
> `status.operationState.syncResult.revision`과 `status.history[].revision`으로
> 확인한다(#85 검증에서 확인된 동작).

## diff 확인

Git desired state와 클러스터 live state의 차이를 확인한다.

- **UI**: Applications → 해당 Application → `APP DIFF`.
- **kubectl**: refresh를 유도한 뒤 sync 상태를 본다. `OutOfSync`면 차이가 있다.

```bash
kubectl -n argocd annotate application <app> \
  argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd get application <app> -o jsonpath='{.status.sync.status}{"\n"}'
```

`OutOfSync`의 흔한 원인: Git 커밋 반영 전, 클러스터 리소스 수동 변경(drift),
배포 revision과 spec pin 불일치.

## sync (수동)

현재 모든 Application은 manual sync만 사용한다(auto-sync/prune/self-heal 없음).
sync는 사람이 diff를 확인한 뒤 트리거한다.

- **UI**: Application 화면의 `SYNC` 버튼 (prune 체크는 기본 해제 유지).
- **kubectl**:

```bash
kubectl -n argocd patch application <app> --type merge \
  -p '{"operation":{"sync":{"revision":"<커밋 SHA 또는 spec targetRevision>"}}}'
```

sync 후 `Synced`/`Healthy` 전환과 대상 namespace의 리소스 상태를 확인한다.

## rollback

이전에 배포했던 revision으로 되돌린다.

- **UI**: Application → `HISTORY AND ROLLBACK` → 대상 revision 선택 → Rollback.
- **kubectl**: history에서 되돌릴 revision을 확인하고 그 revision으로 sync한다.

```bash
kubectl -n argocd get application <app> \
  -o jsonpath='{range .status.history[*]}{.id}: {.revision}{"\n"}{end}'

kubectl -n argocd patch application <app> --type merge \
  -p '{"operation":{"sync":{"revision":"<이전 revision SHA>"}}}'
```

rollback 후 상태가 spec `targetRevision`과 다르면 `OutOfSync`로 표시되는 것이
정상이다(배포는 이전 revision, desired는 spec). 근본 조치는 Git에서 spec 또는
소스 revision을 바로잡는 것이며, rollback은 임시 복구 수단으로 사용한다.

## secret / repo credential 주입

- private repository credential이 필요하면 Kubernetes Secret payload로 주입하고
  Git, PR, Terraform 변수/state에 남기지 않는다.
- Secret manifest에 실제 base64 payload를 커밋하지 않는다.
- Secret Manager, External Secrets Operator, CSI Driver 도입은 별도 설계 후
  진행한다(GITOPS_STRATEGY의 Secret 처리 원칙).

## 장애 시 확인 순서

1. `kubectl -n argocd get pods` — 컴포넌트 자체가 내려갔는지 확인한다.
2. Application의 `status.operationState.phase`가 `Failed`/`Error`면 message를
   읽는다: `kubectl -n argocd describe application <app>`.
3. repo 접근 오류(수신 거부, 인증 실패)는 repo-server 로그를 본다:
   `kubectl -n argocd logs deploy/argo-cd-argocd-repo-server --tail=50`.
4. sync는 됐는데 workload가 비정상이면 대상 namespace에서 pod/event를 본다.
   Grafana 점검 절차는 [`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md).
5. 조치(재sync, rollback, 리소스 조정)를 기록하고, 반복 원인은 이슈로 남긴다.

## 자주 나는 오류

| 증상 | 주된 원인 | 조치 |
|---|---|---|
| UI가 안 열림 | port-forward 터미널 종료 또는 로컬 8443 충돌 | 터널 재실행, 다른 포트 사용 |
| 로그인 실패 | admin 비밀번호 불일치 | credential 관리 경로 확인, README 절차 참조 |
| Application이 `Unknown` | repo 접근 불가(네트워크/인증) | repo-server 로그, repo URL/credential 확인 |
| sync가 `Failed` | manifest 오류 또는 대상 namespace 권한/부재 | `describe application`의 message, AppProject destination 확인 |
| 계속 `OutOfSync` | 수동 변경(drift) 또는 배포 revision ≠ spec pin | diff 확인 후 재sync 또는 Git 수정 |
| ApplicationSet CR이 무동작 | applicationset-controller replicas 0 (#115) | 사용 결정 시 replicas 복원 이슈로 진행 |

## 임의 워크로드 실배포 검증 (#208, 2026-07-15)

ArgoCD가 **plain 애플리케이션 매니페스트(Deployment/Service)를 git에서 실제로
sync 배포**하는 경로를 임시 샘플로 실증한 기록이다. monitoring·argo-rollouts
Application은 실행 중 helm_release를 adopt한 사례라, "새 앱을 git에서 배포"하는
경로는 이 검증으로 처음 확인했다. 임시 검증으로 수행했고 검증 후 샘플 리소스는
제거했다(영구 샘플 미유지 — 최소권한 유지).

### 검증 구성 (임시, 제거됨)

- `deploy/sample-app/`: nginx `Deployment` + `Service` (plain 매니페스트, helm 아님)
- AppProject `autoresearch-dev` destination에 `sample-app` namespace 임시 추가
- ArgoCD `Application` `sample-app`: source `deploy/sample-app`(infra repo, public),
  `syncPolicy.automated`(prune on, selfHeal off)

### ⚠️ 핵심 함정: CreateNamespace vs 최소권한 AppProject

`CreateNamespace=true` syncOption은 **cluster-scoped `Namespace`를 생성**하려 한다.
이 저장소의 AppProject는 최소권한으로 `clusterResourceWhitelist`에 CRD/ClusterRole/
ClusterRoleBinding/webhook만 허용하고 **`Namespace`는 허용하지 않는다**. 그래서
`CreateNamespace=true`만으로는 sync가 실패한다:

```
operationState: one or more synchronization tasks are not valid.
```

**해결**: destination namespace를 미리 생성한다(ArgoCD가 cluster 리소스를
만들 필요가 없어짐). 이 저장소 패턴상 앱 namespace는 Terraform admin root가
소유하므로(예: `autoresearch-k8s`) 실제 앱 배포 시에도 namespace는 Terraform이
만들고 ArgoCD는 namespaced 리소스만 sync한다. `clusterResourceWhitelist`에
`Namespace`를 넣어 넓히지 않는다.

```bash
kubectl create namespace sample-app   # ArgoCD sync 전에 선생성
```

### 실측 결과

| 항목 | 결과 |
|---|---|
| Application `sample-app` sync/health | **Synced / Healthy** (revision `6430f28`) |
| 배포 리소스 | `deployment.apps/sample-app` 1/1 Available, pod Running |
| Service 응답 | 클러스터 내 `http://sample-app.sample-app:80/` → **HTTP 200** |
| 배포 주체 | ArgoCD automated sync(수동 kubectl apply 아님) |

ArgoCD가 git 매니페스트를 desired state로 삼아 신규 앱 워크로드를 배포·Healthy까지
가져감을 확인했다. 검증 후 Application·AppProject destination·`deploy/sample-app`
매니페스트를 제거하고 namespace를 삭제했다.

### 실제 앱 배포 시 참고

- namespace는 Terraform admin root가 소유(ArgoCD `CreateNamespace=false`).
- source는 infra repo(public) 또는 앱 repo. private repo면 자격증명 주입 설계 필요
  ([`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md) Secret 처리 원칙).
- 초기 sync 정책은 manual 우선(GITOPS_STRATEGY). automated는 이번처럼 adopt 대상이
  없는 검증/무상태 앱에 한해 신중히.

## 변경 관리

- Application/AppProject 추가·변경은 `terraform/admin/argocd-k8s` PR로 리뷰한다.
- chart upgrade는 `argo_cd_chart_version` 변수 변경 PR로 진행하고, release
  note와 CRD 변경 여부를 먼저 확인한다.
- auto-sync/prune/self-heal 활성화는 GITOPS_STRATEGY의 단계 기준을 따라
  Application별로 결정한다.
