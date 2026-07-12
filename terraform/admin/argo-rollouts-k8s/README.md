# Argo Rollouts Kubernetes Admin Root

이 root는 dev GKE의 Argo Rollouts controller 설치를 별도 state로 관리한다
(#88). 적용 범위·책임 경계는 #87 설계
(`docs/superpowers/specs/2026-07-13-argo-rollouts-scope-design.md`)를 따른다.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `argo-rollouts` namespace | 예 | `prevent_destroy` |
| Rollouts controller Helm release | 예 | chart `argo-rollouts` `2.41.0` pin |
| NetworkPolicy | 예 | deny-by-default. controller는 DNS/K8s API만 필요 |
| Rollout/AnalysisTemplate CR | 아니오 | 앱 저장소 manifest → ArgoCD sync (#87 책임 경계) |
| promote/abort 조작 | 아니오 | 운영자 kubectl plugin (`docs/ROLLOUTS_OPERATIONS_RUNBOOK.md`, #90에서 제공) |
| dashboard | 미설치 | kubectl plugin으로 운영. 필요 시 별도 이슈 |

## 네트워크 경계

controller는 GCP API를 쓰지 않으므로(WI 불필요) metadata/googleapis 규칙이
없다 — vault-k8s보다 좁다.

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 namespace, kube-system | 컴포넌트/시스템 (샘플 rollout pod 포함) |
| egress | 같은 namespace | 내부 통신 |
| egress | services CIDR 53/443 | kube-dns, kubernetes.default VIP — pre-DNAT 평가(#122) |
| egress | kube-system 53 | post-DNAT dataplane 대비 |
| egress | master CIDR 443 | K8s API post-DNAT 목적지 대비(#138 패턴) |

## RBAC (#88 완료 조건)

chart upstream 기본 ClusterRole을 사용한다: Rollout CR 실행에 필요한
rollouts/replicasets/pods/services 등으로 한정되며 secret 전역 read 같은
과잉 권한이 없다. cluster-wide인 이유는 controller가 모든 namespace의
Rollout을 감시하는 upstream 설계이기 때문이다(적용 namespace 제한은
AppProject/앱 manifest 위치로 통제 — #87).

## 사용 방법

```bash
cd terraform/admin/argo-rollouts-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

운영자 환경 전용(일반 PR CI는 lint만). chart가 CRD와 ClusterRole을
포함하므로 cluster-admin 수준 Kubernetes 권한이 필요하다.

로컬 검증:

```bash
terraform -chdir=terraform/admin/argo-rollouts-k8s fmt -check -recursive
terraform -chdir=terraform/admin/argo-rollouts-k8s init -backend=false
terraform -chdir=terraform/admin/argo-rollouts-k8s validate
```

## 설치 후 확인

```bash
kubectl -n argo-rollouts get pods
kubectl get crd rollouts.argoproj.io
kubectl -n argo-rollouts get svc   # 외부 노출 리소스 없어야 함
```

운영 절차(상태 확인, promote/abort/rollback)는
[docs/ROLLOUTS_OPERATIONS_RUNBOOK.md](../../../docs/ROLLOUTS_OPERATIONS_RUNBOOK.md)
참조(#90에서 제공 — 병합 전까지는 #89 이슈 코멘트 참조).

## 실제 앱 적용 전 주의사항 (#89 샘플 검증에서 확인)

샘플 canary(2 replica, `50% → pause → 100%`)로 전 흐름을 실측 검증했다.
샘플은 검증 후 폐기했고 재현 manifest와 조작 명령은
`docs/ROLLOUTS_OPERATIONS_RUNBOOK.md`로 제공한다(#90 — 병합 전까지는
#89 이슈 코멘트의 실측 기록 참조).

- **abort는 rollback이 아니다**: abort는 트래픽만 stable로 되돌리고
  Rollout은 **Degraded로 남는다**(desired spec에 새 이미지가 남아 있기
  때문). Healthy 복귀는 spec을 stable revision으로 되돌려야 한다 —
  CLI `undo`로 검증했지만, **ArgoCD 연결 후에는 Git revert가 원칙**이다.
  CLI undo는 Git과 어긋나 OutOfSync를 만든다(#87 책임 경계).
- **pause는 무기한**: promote 전까지 구/신 버전이 혼재 상태로 유지되므로,
  적용 대상 앱은 N-1 호환(스키마·API)이 전제되어야 한다.
- **비율은 replica 근사**: 2 replica에서 50%가 최소 단위임을 재확인(#87
  spec의 stable ≥ 2 replica 전제).
- 운영 조작은 kubectl plugin이 필요하다:
  `brew install argoproj/tap/kubectl-argo-rollouts`.

## 롤백

- `helm_release.argo_rollouts` 제거 후 apply → **controller만 삭제된다.**
  CRD는 chart 기본값(`crds.keep=true`, `helm.sh/resource-policy: keep`)으로
  클러스터에 남으므로 기존 Rollout CR과 ArgoCD Application은 삭제되지 않고
  "실행자 없는 선언" 상태(전환 정지, 워크로드 pod는 유지)가 된다.
  namespace는 `prevent_destroy`로 남는다.
- **CRD까지 지우면 안 되는 이유**: CRD 삭제는 전 namespace의 Rollout CR을
  연쇄 삭제하고, Rollout이 소유한 ReplicaSet/pod까지 GC되어 서비스 중단으로
  이어진다. CRD 정리는 모든 Rollout을 Deployment로 되돌린 뒤에만 수동으로
  수행한다.
- 제거 전 진행 중인 Rollout은 모두 promote해 Healthy 상태로 만든다.
- chart 버전 롤백은 `rollouts_chart_version`을 되돌려 apply.
