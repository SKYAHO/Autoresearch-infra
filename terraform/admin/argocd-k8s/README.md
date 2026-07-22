# ArgoCD Kubernetes Admin Root

이 root는 dev GKE의 ArgoCD 설치를 별도 state로 관리한다. #83에서 `argocd`
namespace와 values 위치를 준비했고, #84에서 argo-cd Helm release를, #85에서
AppProject와 샘플 Application을 추가했다.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `argocd` namespace | 예 | `prevent_destroy`로 실수 삭제 방지 |
| ArgoCD Helm release | 예 | chart `argo-cd` `10.1.3` pin (#84) |
| ArgoCD Helm values | 예 | `helm-values/argo-cd.values.yaml` |
| AppProject `autoresearch-dev` | 예 | repo/destination 허용 경계 (#85). 샘플 제거 후 infra repo Application 전용(#183). sourceRepos=infra repo, destinations=`monitoring`·`kube-system`(control-plane exporter)·`argo-rollouts`(#186), cluster-wide는 필요한 kind만 |
| Application `monitoring` | 예 (#183) | infra repo `deploy/monitoring` umbrella chart, manual sync. helm_release에서 이관 |
| Application `argo-rollouts` | 예 (#186) | infra repo `deploy/argo-rollouts` umbrella chart, manual sync. helm_release에서 이관 |
| Secret payload | 아니오 | Secret Manager 또는 운영자 주입 |

## 설치 구성 (#84)

| 항목 | 값 | 비고 |
|---|---|---|
| Chart | `argo-cd` `10.1.3` (ArgoCD v3.4.5) | `var.argo_cd_chart_version` |
| Release | `argo-cd` | `var.argo_cd_release_name` |
| server Service | `ClusterIP` | 외부 공개 금지. LoadBalancer/Ingress 없음 |
| NetworkPolicy | deny-by-default ingress/egress (#116) | 아래 네트워크 경계 참조 |
| dex (SSO) | disabled | SSO 도입 시 별도 이슈에서 활성화 |
| notifications | disabled | 알림 채널 결정 후 활성화 |
| applicationSet | replicas 0 (중지) | chart 8.0부터 enabled 키가 제거됨(#115). ApplicationSet CR 사용 시 1로 복원 |

## 네트워크 경계 (#116)

`ClusterIP`는 인터넷 노출만 막고 클러스터 내부 접근은 막지 않으므로, 다른
namespace 워크로드가 ArgoCD 제어면에 접근하지 못하도록 deny-by-default
NetworkPolicy를 둔다. enforcement는 dev root(`gke.tf`)의 Calico 활성화가 전제다.

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 namespace | 컴포넌트 간 통신 (server ↔ repo-server ↔ redis ↔ controller) |
| ingress | kube-system | 시스템 컴포넌트 |
| ingress | `var.ui_ingress_source_cidr`(dev subnet) → 8080 | `kubectl port-forward` 트래픽은 노드 IP에서 출발하므로 노드 대역 허용이 없으면 UI 접근이 차단된다 |
| egress | 같은 namespace | pod-direct 트래픽 (post-DNAT dataplane 대비 유지) |
| egress | services CIDR(`cluster_services_cidr`) 53/6379/8081 | **service VIP 경유 트래픽**(#122): kube-dns, redis, repo-server. 이 클러스터의 Calico는 egress를 DNAT 이전(VIP 기준)에 평가하므로 selector로는 매칭 불가 |
| egress | kube-system 53 (UDP/TCP) | DNS (post-DNAT dataplane 대비 유지) |
| egress | 0.0.0.0/0 443 | Git/Helm repository, Kubernetes API(VIP 443 포함). git ssh(22)는 미사용이라 미허용 |

## 사용 방법

```bash
cd terraform/admin/argocd-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

실행 환경에는 dev GKE API 접근 경로와 `argocd` namespace 및 CRD,
ClusterRole/ClusterRoleBinding을 만들 수 있는 Kubernetes 권한이 필요하다.
argo-cd chart는 CRD와 cluster-wide RBAC를 포함하므로 namespace admin만으로는
부족하다. 일반 PR CI가 아니라 운영자 환경에서만 plan/apply한다.

**완전 재구성(재해 복구) 순서**: `kubernetes_manifest`(AppProject/Application)는
plan 단계에서 ArgoCD CRD 스키마를 클러스터에서 조회하므로, CRD가 없는 빈
클러스터에서는 전체 plan이 실패한다. 이때는 chart를 먼저 targeted apply한다.

```bash
terraform apply -target=helm_release.argo_cd
terraform apply
```

로컬 검증은 원격 state에 붙지 않고 실행할 수 있다.

```bash
terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive
terraform -chdir=terraform/admin/argocd-k8s init -backend=false
terraform -chdir=terraform/admin/argocd-k8s validate
```

## 설치 후 확인

```bash
kubectl -n argocd get pods
# 외부 공개 리소스가 없는지 검증: 모든 Service가 ClusterIP여야 한다.
kubectl -n argocd get svc
kubectl -n argocd get ingress
```

## UI 접근 (내부 전용)

ArgoCD UI는 인터넷에 공개하지 않는다. 접근은 kubectl port-forward만 사용한다.

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8443:443
```

브라우저에서 `https://localhost:8443`으로 접속한다. self-signed 인증서 경고는
dev 내부 접근 경로 특성상 허용한다.

## 초기 admin credential 처리

chart가 최초 설치 시 `argocd-initial-admin-secret`에 임시 admin 비밀번호를
생성한다. 처리 절차:

```bash
# 1) 초기 비밀번호 회수 (값을 문서/PR/채팅에 남기지 않는다)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 2) UI 또는 argocd CLI로 로그인 후 즉시 비밀번호 변경
# 3) 초기 secret 삭제
kubectl -n argocd delete secret argocd-initial-admin-secret
```

변경한 admin 비밀번호는 팀 비밀번호 관리 경로로만 공유한다. Git, PR,
Terraform state, values 파일에 저장하지 않는다. 로컬 `admin` 계정은 OIDC 도입
후에도 CLI·자동화·break-glass용으로 유지한다(#289).

## Google(Gmail) OIDC 로그인 (#289)

팀원이 Gmail 계정으로 UI에 로그인하고, 이메일 기준으로 권한(admin/readonly)을
나눈다. Dex 없이 ArgoCD 내장 **직접 OIDC**로 Google을 연결한다. Airflow/MLflow와
동일하게 **client id/secret은 Git·Terraform state에 두지 않고** 별도 Secret으로
주입하며, 허용 이메일은 로컬 `terraform.tfvars`에만 둔다.

**1) Google OAuth 클라이언트 생성(콘솔 수동)**

- 유형: Web application
- redirect URI: `https://localhost:8443/auth/callback` (`argocd_server_url` +
  `/auth/callback`). port-forward → localhost 접근이라 이 값이 불변이다.
- 발급된 client id / client secret은 아래 Secret으로만 넣고 어디에도 남기지 않는다.

**2) `argocd-google-oidc` Secret 주입(Terraform 밖, Secret Manager 경유)**

`oidc.config`는 값이 아니라 `$argocd-google-oidc:<key>`를 참조하므로, 실제 값은
이 Secret에만 있다. label `app.kubernetes.io/part-of=argocd`가 있어야 ArgoCD가
`$` 참조로 읽는다. 시크릿을 명령행에 노출하지 않도록 `--from-env-file`을 쓴다(#213).

```bash
umask 077
env_file="$(mktemp)"; trap 'rm -f "$env_file"' EXIT
# client id/secret을 Secret Manager에 저장해 두고 회수(예시 secret 이름)
CID="$(gcloud secrets versions access latest --secret argocd-google-oidc-client-id --project ar-infra-501607)"
CSECRET="$(gcloud secrets versions access latest --secret argocd-google-oidc-client-secret --project ar-infra-501607)"
printf 'clientId=%s\nclientSecret=%s\n' "$CID" "$CSECRET" > "$env_file"; unset CID CSECRET
kubectl create secret generic argocd-google-oidc -n argocd --from-env-file="$env_file" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret argocd-google-oidc -n argocd app.kubernetes.io/part-of=argocd --overwrite
rm -f "$env_file"; trap - EXIT
kubectl -n argocd rollout restart deployment/argo-cd-argocd-server   # 새 oidc.config 반영
```

**3) 허용 이메일 지정(로컬 `terraform.tfvars`)**

```hcl
argocd_admin_user_emails    = ["you@gmail.com"]
argocd_readonly_user_emails = ["teammate@gmail.com"]
```

apply하면 `argocd-rbac-cm`의 `policy.csv`에 `g, <email>, role:admin|readonly`가
렌더된다. `policy.default`는 빈 값(거부)이라 목록 밖 계정은 로그인해도 권한이 없다.

**4) 로그인 확인**

port-forward 후 `https://localhost:8443`에서 **LOG IN VIA GOOGLE**로 로그인한다.
admin(내장 `role:admin`)은 app sync/rollback을 포함해 repo·project·설정·RBAC까지
전체를 관리하고, readonly는 조회만 가능하다. 로컬 `admin` 로그인도 그대로 된다.
(admin 티어를 더 좁히려면 sync/rollback만 허용하는 커스텀 role을 별도로 정의한다.)

**로테이션/회수**: client secret은 Secret Manager 새 version → 위 2)로 재주입 →
`rollout restart`. 팀원 제거는 `terraform.tfvars`에서 이메일을 빼고 apply한다.
이미 발급된 세션 토큰은 만료까지 유효하다.

## 샘플 sync/diff/rollback 검증 (#85, 완료 후 제거)

초기 검증에는 공개 샘플 repo(`argoproj/argocd-example-apps`의 `guestbook`)를
`argocd-sample` namespace에 manual sync로 연결한 `sample-guestbook`
Application을 사용했다. sync/diff/rollback 흐름 검증을 마치고, 실제 repo
(monitoring umbrella chart)를 연결하는 #183에서 샘플 리소스(Application +
`argocd-sample` namespace)를 제거했다.

제거 이유(코드 리뷰 반영): AppProject `clusterResourceWhitelist`는 프로젝트
단위 정책이라 같은 프로젝트의 모든 Application에 적용된다. 샘플을 남겨두면
CRD/ClusterRole/**ClusterRoleBinding**/webhook 등 cluster-wide 권한이
신뢰하는 Application 밖으로 확대되므로, 최소 권한 원칙에 따라 프로젝트를 infra
repo Application 전용으로 좁혔다(현재 `monitoring`·`argo-rollouts`).

## 실제 repo 연결 시 주의사항 (#85, #183 적용)

- **AppProject 허용 목록은 그때 넓힌다**: `SKYAHO/Autoresearch-airflow` 등
  실제 repo와 대상 namespace는 해당 Application을 만드는 이슈에서
  `sourceRepos`/`destinations`에 추가한다. 미리 열어두지 않는다. 이때
  namespaced 리소스 종류도 `namespaceResourceWhitelist`로 필요한 kind만
  허용하는 하드닝을 함께 검토한다(미지정 시 모든 namespaced kind 허용).
- **sync 정책은 manual부터**: auto-sync/prune/self-heal은 GITOPS_STRATEGY의
  단계 기준을 따라 안정화 후 Application별로 켠다. prune은 리소스 삭제를
  유발하므로 특히 신중히 다룬다.
- **private repo credential**: Kubernetes Secret payload로 주입하고 Git,
  Terraform 변수/state에 남기지 않는다.
- **Application 삭제 시 잔존물**: finalizer
  (`resources-finalizer.argocd.argoproj.io`) 없이 Application CR만 지우면
  배포된 리소스는 남는다(prune off일 때). 이관 롤백은 이 성질을 이용해
  Application을 제거해도 워크로드를 유지한다.
- **ApplicationSet CR을 쓰려면** controller replicas 복원이 선행돼야 한다
  (#115, 현재 0).
- **NetworkPolicy enforcement(#116)가 apply되기 전에는** argocd namespace
  경계가 선언 상태다. 실제 repo credential 도입 전에 enforcement 적용을
  권장한다.

## Secret 처리 원칙

- repo credential, admin password, webhook secret, OAuth secret payload를 Git에
  커밋하지 않는다.
- Terraform 변수와 state에도 secret payload를 저장하지 않는다.
- private repository credential이 필요하면 Kubernetes Secret payload로 주입하고,
  Terraform/Helm values에는 Secret 이름과 key만 참조한다.
- Secret Manager, External Secrets Operator, Secret Manager CSI Driver 도입은
  별도 설계 후 진행한다.

## 롤백

- `helm_release.argo_cd` 리소스를 제거하고 apply하면 release가 삭제된다.
  namespace는 `prevent_destroy`로 남는다.
- chart 버전 롤백은 `argo_cd_chart_version`을 이전 버전으로 되돌려 apply한다.
- **주의**: 이 root는 이제 `application_monitoring`(#183)·`application_argo_rollouts`
  (#186) 두 Application을 관리한다. ArgoCD를 삭제하면 이 Application들이 관리하는
  monitoring·argo-rollouts 스택이 sync/self-heal 없이 남으므로, release 삭제 전
  두 스택의 adopt 상태와 영향 범위를 먼저 확인한다(워크로드 pod 자체는 prune off라
  즉시 삭제되지 않지만 GitOps 관리가 끊긴다).
