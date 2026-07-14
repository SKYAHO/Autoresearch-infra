# monitoring 스택 ArgoCD 이관 설계 (GitOps 파일럿)

> 작성: 2026-07-14 | 성격: 아키텍처 변경 — 실행 중 스택 인수(adopt) 리스크 있음
> 목적: Terraform `helm_release`(kube-prometheus-stack)를 ArgoCD Application으로 이관하는
>       **파일럿**. GITOPS_STRATEGY의 "Terraform=경로, ArgoCD=앱" 책임 분리를 실제로 구현.
> 범위: monitoring 한정. **vault는 제외**(stateful secret store — 첫 이관 대상으로 고위험).

## 결정 요약

| 항목 | 결정 | 근거 |
|---|---|---|
| Git source | infra repo `deploy/monitoring/` umbrella chart | #17 airflow 제안과 동일 패턴. infra repo **public**이라 ArgoCD repo 자격증명 불필요(실측) |
| chart | kube-prometheus-stack **87.12.1** dependency + values | 현재 pin 버전 그대로. ArgoCD가 `helm dependency build` 자동 수행 |
| sync 정책 | **manual**(auto-sync/prune 없음) | GITOPS_STRATEGY 초기 원칙. adopt는 diff 검토 후 수동 |
| 책임 분리 | namespace·port-forward RBAC = **Terraform 유지**, 앱(chart) = ArgoCD | GITOPS_STRATEGY: TF는 플랫폼 경계, ArgoCD는 앱 |
| adopt 방식 | `state rm`(destroy 아님) → ArgoCD가 실행 중 리소스 인수 | 무중단. 실패 시 import로 롤백 |
| operator 주입 secret | grafana-admin-credentials, grafana-google-oauth = **손대지 않음** | chart 밖 리소스라 ArgoCD가 관리·prune하지 않음. values는 이름만 참조 |

## 현재 상태 (실측)

- `terraform/admin/monitoring-k8s`: namespace `monitoring`, `helm_release.kube_prometheus_stack`(87.12.1),
  port-forward Role/RoleBinding.
- AppProject `autoresearch-dev`: sourceRepos=샘플 repo만, destinations=argocd-sample만,
  cluster-wide 리소스 기본 거부.
- kube-prometheus-stack cluster-wide 리소스: CRD 10종(monitoring.coreos.com), ClusterRole 4 +
  ClusterRoleBinding, ValidatingWebhookConfiguration(admission).
- ArgoCD 정상(sample-guestbook Synced/Healthy).

## 구현 단계

### 1. umbrella chart `deploy/monitoring/` (infra repo)

- `Chart.yaml`: dependency `kube-prometheus-stack` 87.12.1 (prometheus-community repo).
- `values.yaml`: 현재 `terraform/admin/monitoring-k8s/helm-values/kube-prometheus-stack.values.yaml`
  내용을 **`kube-prometheus-stack:` 키 아래로 중첩**(subchart이므로). nodeSelector/requests/OAuth
  등 모든 커스터마이즈 보존. grafana existingSecret·envFromSecret 참조 그대로.
- `charts/`는 vendor하지 않음 — ArgoCD가 dependency build.

### 2. AppProject 확장 (argocd-k8s root, kubernetes_manifest)

- `sourceRepos`에 `https://github.com/SKYAHO/Autoresearch-infra.git` 추가.
- `destinations`에 monitoring namespace 추가.
- `clusterResourceWhitelist` 추가(kube-prometheus-stack 필요분만 — 최소 허용):
  - `apiextensions.k8s.io/CustomResourceDefinition`
  - `rbac.authorization.k8s.io/ClusterRole`, `ClusterRoleBinding`
  - `admissionregistration.k8s.io/ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`
- namespaceResourceWhitelist는 미지정(모든 namespaced kind 허용) — 파일럿 후 하드닝 검토.

### 3. ArgoCD Application `monitoring` (argocd-k8s root)

- source: infra repo, path `deploy/monitoring`, targetRevision = **커밋 SHA pin**(재현성).
- destination: monitoring namespace.
- syncPolicy: 미지정(manual). `ServerSideApply=true`, prune off(초기).

### 4. 무중단 adopt (핵심 위험 단계 — apply 시)

1. `terraform -chdir=terraform/admin/monitoring-k8s state rm helm_release.kube_prometheus_stack`
   (release는 계속 실행, TF 관리만 해제)
2. monitoring-k8s `main.tf`에서 `helm_release` 리소스 제거(namespace·RBAC는 유지),
   `terraform apply` → 그 결과 helm_release가 **destroy되지 않는지 plan으로 반드시 확인**
   (state에 없으므로 apply 대상 아님).
3. argocd-k8s apply → AppProject 확장 + Application 생성.
4. **sync 전에 diff 검토**: `argocd app diff monitoring` 또는 UI. 예상 churn 원인은 helm
   `app.kubernetes.io/managed-by: Helm` 라벨 vs ArgoCD. ServerSideApply로 흡수.
5. **수동 sync**(prune off) → pod 재시작 폭풍 없는지, Grafana/Prometheus 정상, secret 보존 확인.

## 검증 기준

- adopt 후: monitoring pod 전부 Ready 유지(재시작 카운트 급증 없음), PVC 그대로.
- Grafana 접속·OAuth 정상, Prometheus 지표 수집 연속성.
- Application **Synced/Healthy**, ComparisonError 없음.
- grafana-admin-credentials·grafana-google-oauth secret 그대로 존재.
- monitoring-k8s 최종 plan No changes(helm_release 제거 반영), argocd-k8s No changes.

## 롤백

adopt가 churn/장애를 유발하면:
1. ArgoCD Application 제거(argocd-k8s에서 리소스 삭제 apply) — prune off라 실제 워크로드는 유지.
2. monitoring-k8s에 `helm_release` 리소스 복원 + `terraform import`(release가 살아 있으므로 재인수).
3. AppProject 확장 되돌림(선택).

`state rm`은 리소스를 삭제하지 않으므로, 롤백은 "TF가 다시 관리하게" 하는 것이며 무중단이다.

## 파일럿 후 (이 spec 범위 밖)

- 성공 시 GITOPS_STRATEGY에 이관 로드맵 반영(리마인드 ②), airflow(#17)·vault 순으로 확장 검토.
- namespaceResourceWhitelist 하드닝, auto-sync 도입 여부.

## 3종 병렬 어드버서리 리뷰 반영 (codex/claude/opencode, 2026-07-14)

3개 모델 병렬 검토에서 claude가 무중단 adopt를 깨뜨리는 리스크 3건을 지적, 전부 실측 확인 후 수정:

1. **[치명] release 이름 불일치 → 데이터 손실** — Application 이름(`monitoring`) 기반 release name이면
   subchart 리소스가 `monitoring-*`로 개명되어 기존 `kube-prometheus-stack-*`를 인수하지 못하고 빈 PVC로
   새 스택을 나란히 생성. **수정**: Application source에 `helm.releaseName = "kube-prometheus-stack"`.
   실측: 렌더 이름이 live와 정확히 일치 확인.
2. **[높음] Chart.lock 부재 → ArgoCD `helm dependency build` 실패** — build는 lock을 요구. **수정**:
   Chart.lock을 커밋(gitignore에서 제외), charts/ tgz만 무시.
3. **[중] helm_release 코드 선삭제 → apply 순서 사고 시 destroy** — **수정**: 수동 state rm 대신
   Terraform `removed { lifecycle { destroy = false } }` 블록으로 "state에서만 제거, release 유지"를
   기계적으로 강제(helm provider 유지, required_version 1.7+).

교훈: 실행 중 스택 adopt는 "렌더 리소스 이름이 기존과 byte 단위로 일치"가 무중단의 필수 전제다.
