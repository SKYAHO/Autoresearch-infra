# ArgoCD 임의 워크로드 실배포 검증 (2026-07-15, #208)

> 관련: ArgoCD 이관(#183), [`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md),
> [`ARGOCD_OPERATIONS_RUNBOOK.md`](ARGOCD_OPERATIONS_RUNBOOK.md)

ArgoCD가 **plain 애플리케이션 매니페스트(Deployment/Service)를 git에서 실제로
sync 배포**하는 경로를 임시 샘플로 실증한 기록이다. 기존 monitoring·argo-rollouts
Application은 실행 중 helm_release를 adopt한 사례라, "새 앱을 git에서 배포"하는
경로는 이 검증으로 처음 확인했다.

**임시 검증**으로 수행했고 검증 후 샘플 리소스는 제거했다(영구 샘플 미유지 —
최소권한 유지). 이 문서는 재현 절차와 결과만 남긴다.

## 검증 구성 (임시, 제거됨)

- `deploy/sample-app/`: nginx `Deployment` + `Service` (plain 매니페스트, helm 아님)
- AppProject `autoresearch-dev` destination에 `sample-app` namespace 임시 추가
- ArgoCD `Application` `sample-app`: source `deploy/sample-app`(infra repo, public),
  `syncPolicy.automated`(prune on, selfHeal off)

## ⚠️ 핵심 함정: CreateNamespace vs 최소권한 AppProject

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

## 실측 결과

| 항목 | 결과 |
|---|---|
| Application `sample-app` sync/health | **Synced / Healthy** (revision `6430f28`) |
| 배포 리소스 | `deployment.apps/sample-app` 1/1 Available, pod Running |
| Service 응답 | 클러스터 내 `http://sample-app.sample-app:80/` → **HTTP 200** |
| 배포 주체 | ArgoCD automated sync(수동 kubectl apply 아님) |

ArgoCD가 git 매니페스트를 desired state로 삼아 신규 앱 워크로드를 배포·Healthy까지
가져감을 확인했다.

## 정리

검증 후 Application·AppProject destination·`deploy/sample-app` 매니페스트를 제거하고
namespace를 삭제했다.

```bash
# Terraform에서 Application/destination 제거 후 apply → kubectl delete namespace sample-app
```

## 실제 앱 배포 시 참고

- namespace는 Terraform admin root가 소유(ArgoCD `CreateNamespace=false`).
- source는 infra repo(public) 또는 앱 repo. private repo면 자격증명 주입 설계 필요
  ([`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md) Secret 처리 원칙).
- 초기 sync 정책은 manual 우선(GITOPS_STRATEGY). automated는 이번처럼 adopt 대상이
  없는 검증/무상태 앱에 한해 신중히.
