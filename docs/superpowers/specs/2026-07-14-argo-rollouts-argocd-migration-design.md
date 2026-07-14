# argo-rollouts ArgoCD 이관 설계 (GitOps 파일럿 확장)

> 작성: 2026-07-14 | 성격: 아키텍처 변경(실행 중 컨트롤러 인수) | 이슈: #186
> 목적: Terraform `helm_release.argo_rollouts`를 ArgoCD Application으로 이관.
>       monitoring(#183) 파일럿과 동일 패턴을 두 번째 스택에 적용.

## 결정 요약

| 항목 | 결정 | 근거 |
|---|---|---|
| Git source | infra repo `deploy/argo-rollouts/` umbrella chart | monitoring과 동일. dependency `argo-rollouts` 2.41.0 + values |
| chart 버전 | 2.41.0 (현재 pin 그대로) | ArgoCD가 `helm dependency build` 자동 수행. Chart.lock 커밋 |
| releaseName | **`argo-rollouts`** 고정 | 기존 helm_release 이름과 일치해야 CRD/ClusterRole/ClusterRoleBinding을 adopt(개명 시 병렬 재생성) |
| sync 정책 | manual(auto-sync/prune 없음) | 초기 원칙. adopt는 diff 검토 후 수동 |
| 책임 분리 | namespace·NetworkPolicy = Terraform 유지, chart = ArgoCD | GITOPS_STRATEGY. NetworkPolicy는 플랫폼 경계 |
| adopt 방식 | `removed { destroy=false }` → ArgoCD 인수 | 무중단. helm_release를 state에서만 제거 |

## 현재 상태 (실측)

- `terraform/admin/argo-rollouts-k8s`: namespace `argo-rollouts`(prevent_destroy),
  NetworkPolicy 2개(ingress/egress), `helm_release.argo_rollouts`(chart 2.41.0, rev1).
- live: controller pod 1개 Running(36h, restart 0). CRD 5종(rollouts/analysisruns/
  analysistemplates/clusteranalysistemplates/experiments.argoproj.io), ClusterRole 4
  (argo-rollouts + aggregate-to-admin/edit/view) + ClusterRoleBinding argo-rollouts.
- **실행 중 Rollout/Experiment/Analysis CR: 0개** → 컨트롤러 adopt·재시작이 어떤
  워크로드에도 영향 없음.

## monitoring(#183)과 다른 점 — 전부 더 단순/안전

- **PVC·stateful 데이터 없음** → 데이터 손실 벡터 자체가 없다.
- **kube-system 등 부수 namespace 리소스 없음** → AppProject destinations는
  `argo-rollouts` 하나만 추가(monitoring은 kube-system도 필요했음).
- **admission webhook 없음** → AppProject `clusterResourceWhitelist` **무변경**
  (CRD/ClusterRole/ClusterRoleBinding은 monitoring이 이미 허용, webhook 불요).
- **ServiceMonitor·cross-namespace 없음**(values는 controller/dashboard만).
- 실행 중 Rollout CR 0개라 releaseName 불일치 시에도 blast radius 최소 — 그래도
  CRD/ClusterRole adopt를 위해 이름은 일치시킨다.

## 구현 단계

1. `deploy/argo-rollouts/`: `Chart.yaml`(dep argo-rollouts 2.41.0) +
   `values.yaml`(현 helm-values를 `argo-rollouts:` 키 아래 중첩) + `Chart.lock`(커밋).
2. `argocd-k8s`: AppProject destinations에 `argo-rollouts` 추가(whitelist 무변경),
   `application_argo_rollouts`(releaseName `argo-rollouts`, path `deploy/argo-rollouts`,
   manual sync, ServerSideApply). 변수 `rollouts_namespace`/`rollouts_target_revision`.
3. `argo-rollouts-k8s`: `helm_release` 제거 + `removed { destroy=false }`,
   namespace·NetworkPolicy 유지, versions `>= 1.7.0`, helm-values 파일 삭제(이관),
   미사용 output/변수 정리.

## 무중단 adopt (apply 시)

1. `argo-rollouts-k8s` apply → helm_release를 state에서 forget(release 유지, plan 0 destroy 확인).
2. `argocd-k8s` apply(`-var rollouts_target_revision=<병합 SHA>`) → AppProject 확장 + Application 생성.
3. `argocd app diff argo-rollouts --core` → tracking-id annotation 외 spec 변경 없어야 함.
4. 수동 sync(prune off, ServerSideApply) → controller pod 재시작/CRD·ClusterRole 보존 확인.
5. adopt 후 `rollouts_target_revision`을 `main`으로 정렬해 plan No changes.

## 검증 기준

- Application `argo-rollouts` Synced/Healthy, 리소스 adopt(재생성 없음).
- controller pod restart 없음, CRD 5종·ClusterRole 4·CRB 보존.
- `argo-rollouts-k8s`·`argocd-k8s` plan No changes.
- helm bookkeeping secret 정리(`helm list -n argo-rollouts` 비움) — monitoring과 동일.

## 롤백

adopt가 문제를 유발하면: ArgoCD Application 제거(prune off라 워크로드 유지) →
`argo-rollouts-k8s`에 `helm_release` 복원 + `terraform import`로 재인수. `removed`는
삭제가 아니므로 무중단.
