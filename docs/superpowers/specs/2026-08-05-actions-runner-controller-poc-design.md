# GitHub Actions 셀프 호스티드 러너(ARC) PoC 설계

> 관련 이슈: #533
> 상태: 설계 승인됨, 구현 계획 작성 완료, 구현 대기

## 목적

second-brain 18회차(2026-08-04) 멘토 피드백과 팀 결정에 따라, 발표 후 백로그로
미뤄뒀던 GitHub Actions 셀프 호스티드 러너 전환을 시작한다. 이 첫 변경은 vault의
"권장 전환 순서" 7단계 중 **1~4단계만** 다룬다: 기존 `feast apply` GKE Job 방식은
그대로 두고, 러너 전용 namespace/KSA·GSA/NetworkPolicy/Secret 경계를 설계하고,
Actions Runner Controller(ARC)를 ArgoCD Application으로 설치하고, 비파괴적 워크플로우
하나로 러너가 VPC 내부망에 실제로 접근함을 검증한다.

`feast apply` 이관(5단계), 운영 배포용 별도 러너·승인 게이트 분리(6단계),
비용·보안·장애 대응 비교 후 다른 워크플로우 확장(7단계)은 이 변경 범위 밖이다.

## 현재 문제

- GitHub-hosted 러너는 VPC 밖에서 실행돼 private Redis Cluster·GKE 등 내부망
  리소스에 직접 접근하지 못한다. 현재는 GHA → GKE 인증 → K8s Job 생성 → Job Pod가
  내부망에서 실행하는 우회 구조를 쓴다(`feast apply`, 실험 Job).
- 이 우회는 기능적으로 동작하지만 `feast apply` 전용으로 만든 구조라 다른 내부망
  워크플로우에 재사용하려면 매번 같은 우회를 새로 구현해야 한다.
- 이 저장소에는 자체 호스티드 러너 관련 Terraform·워크플로우·문서가 전혀 없다
  (`grep -rn "self-hosted\|Runner Controller\|runs-on.*self"` 결과 0건 — 완전
  greenfield).

## 결정

### 전용 Kubernetes 경계 — 새 admin root `actions-runner-k8s`

`terraform/admin/actions-runner-k8s/`를 `mlflow-k8s`와 동일한 scaffold
(`versions.tf`/`main.tf`/`variables.tf`/`outputs.tf`/`terraform.tfvars.example`/
`README.md`, backend `gcs`, `google`+`kubernetes` provider)로 새로 만든다. `helm`
provider는 두지 않는다 — ARC는 raw `helm_release`가 아니라 ArgoCD `Application`으로
설치한다(`terraform/admin/argocd-k8s/main.tf`의 `application_monitoring` 패턴, #183
GitOps 이관 이후 이 저장소의 표준).

namespace는 PSA `baseline` enforce/audit/warn을 적용한다(`restricted`는 ARC 러너
Pod 템플릿을 이 root가 소유하지 않아 실측 전 강제할 수 없다 — `feast_apply.tf`가
같은 이유로 `baseline`을 쓰는 것과 동일한 판단).

KSA는 두 개로 분리한다:
- `actions_runner_controller` — ARC 컨트롤러 매니저 Pod용. `automount_service_account_token`은
  Kubernetes 기본값(`true`)을 유지한다. 컨트롤러가 CRD(`AutoscalingRunnerSet`,
  `EphemeralRunnerSet`, `EphemeralRunner`, `AutoscalingListener`)를 watch하고
  러너 Pod/Secret/ServiceAccount를 동적으로 생성·삭제하려면 K8s API token이
  필요하다 — 이 저장소의 "K8s token 미마운트" 관행의 유일한 의도적 예외이며
  코드 주석으로 그 이유를 명시한다.
- `actions_runner_listener`(러너 pod KSA) — `automount_service_account_token = false`
  + `iam.gke.io/gcp-service-account` annotation으로 Workload Identity 연결. PoC
  워크플로우 스텝이 실행되는 신원이다.

ARC 컨트롤러 chart는 자체 ClusterRole/ClusterRoleBinding을 chart 템플릿으로 만든다
(CRD가 cluster-scoped 리소스이므로 완전한 namespace 격리는 불가능). `values.yaml`의
`flags.watchSingleNamespace`를 새 러너 namespace로 설정해 namespaced 권한(Pod/Secret/
RoleBinding 생성)만이라도 이 namespace로 좁힌다. 이 root는 컨트롤러의 RBAC 객체를
직접 손으로 작성하지 않는다 — chart 자체 reconciliation과 충돌한다. 이 root의 RBAC
책임은 KSA·Workload Identity annotation과 ArgoCD `AppProject.clusterResourceWhitelist`
확장(ARC의 CRD/ClusterRole/ClusterRoleBinding 종류 추가)에 한정한다.

ResourceQuota/LimitRange는 `experiment_jobs.tf`와 같은 형태로 두되 러너 Pod가
Job Pod보다 무거우므로(checkout+빌드 툴체인) 여유를 더 둔다(`pods=3~5`). 이 숫자는
scale-set chart의 `maxRunners` 값과 짝을 이뤄야 하며, `feast_apply_identities`
튜플 주석과 같은 방식으로 "함께 바꿔야 하는 값"임을 문서화한다.

NetworkPolicy ingress는 다른 namespace와 동일하게 전면 차단한다(`pod_selector{}`
+ `policy_types=["Ingress"]`). egress는 `experiment_jobs.tf`의 기존 4개 규칙
(DNS, GKE metadata `169.254.169.254/32:80`, Workload Identity metadata
`169.254.169.252/32:987,988`, PGA `var.private_googleapis_cidr:443`)을 그대로
재사용하고, 다음 두 규칙을 추가한다:

1. `var.cluster_services_cidr:443` — PoC 검증 스텝이 `kubernetes.default.svc`
   (GKE control plane in-cluster endpoint)에 접근하기 위한 규칙. 기존 DNS 규칙이
   이미 같은 CIDR을 53번 포트로 열어두고 있어 목적지를 새로 추가하는 것이 아니라
   포트만 하나 더 여는 것이다.
2. `0.0.0.0/0:443`(TCP만) — GitHub 인프라(`github.com`, `api.github.com`,
   `*.actions.githubusercontent.com`, `ghcr.io`, `pkg-containers.githubusercontent.com`)는
   GitHub의 공개 IP 대역이 넓고 수시로 바뀌어 이 저장소의 기존 "고정 CIDR
   allowlist" 패턴을 그대로 적용할 수 없다. **이 namespace만의 의도적 예외**로
   명시하고, 포트는 443만 열어 임의 아웃바운드를 허용하지 않는다. 이 예외는 PoC가
   비파괴적 워크플로우 단 하나에만 연결된다는 범위 제한으로 상쇄한다. GitHub IP
   대역 고정 allowlist는 이후 단계의 하드닝 과제로 남긴다.

### GitHub 자격 증명 — GitHub App

ARC 등록에는 GitHub App을 쓴다(GitHub 공식 권장 — 더 높은 rate limit, 설치
범위로 제한된 권한, 특정 사용자 계정에 종속되지 않음). GitHub App 생성 자체는
조직 수준 GitHub UI 작업이라 Terraform 밖에서 사용자가 1회 수행해야 한다(이
저장소 원격 영향 작업 확인 규칙과 별개로, GitHub App 생성 자체가 org owner
권한이 필요한 수동 단계).

`google_secret_manager_secret` 빈 컨테이너 3개(App id, installation id, private
key)를 Terraform으로 만들고 `roles/secretmanager.secretAccessor`를 컨트롤러
GSA에 부여한다(`argocd_google_oidc_client` 패턴과 동일 — 값은 Terraform이 관리하지
않고 운영자가 `gcloud secrets versions add`로 직접 채운다).

ARC의 `gha-runner-scale-set` chart가 실제로 소비하는 네이티브 `kubernetes_secret_v1`은
Terraform이 만들지 않는다. chart의 `githubConfigSecret` 값에 기존 Secret 이름을
참조하는 모드를 우선 사용해 Helm/Terraform이 평문을 보지 않게 한다. 그 Secret은
운영자가 런북에 따라 `kubectl create secret generic ... --from-env-file`로 수동
생성한다(`--from-literal` 금지 — 이 저장소의 기존 시크릿 주입 컨벤션, #213).

### ArgoCD Application 2개

컨트롤러와 scale-set은 독립된 lifecycle을 가지므로(컨트롤러 업그레이드는 드물고
cluster-scoped 리스크가 있는 반면, scale-set 설정은 향후 오토스케일링 튜닝 단계에서
자주 바뀔 것으로 예상) 하나의 umbrella chart로 묶지 않고 별도 Application 2개로
분리한다:

- `deploy/actions-runner-controller/Chart.yaml` — `oci://ghcr.io/actions/actions-runner-controller-charts`
  저장소의 `gha-runner-scale-set-controller`를 dependency로 감싼다. Helm은 v3.8+부터
  OCI 저장소를 `dependencies[].repository`에 직접 쓸 수 있다.
- `deploy/actions-runner-scale-set/Chart.yaml` — 같은 저장소의 `gha-runner-scale-set`을
  감싼다.

두 `kubernetes_manifest` Application 리소스는 `terraform/admin/argocd-k8s/main.tf`의
`application_monitoring` 구조를 그대로 따른다: `spec.source.helm.releaseName`을
반드시 명시적으로 고정하고(비워두면 Application 이름이 release 이름이 되어 기존
리소스 입양이 깨지는 과거 사고 재발), `syncPolicy.automated = {prune=false,
selfHeal=false}`(#460), retry 지수 백오프, `syncOptions = ["ServerSideApply=true",
"CreateNamespace=false"]`(namespace 소유권은 Terraform 유지). scale-set
Application은 컨트롤러의 CRD가 먼저 존재해야 하므로 컨트롤러 Application에
`depends_on`(또는 sync-wave)으로 순서를 강제한다.

`AppProject.clusterResourceWhitelist`에 ARC CRD 4종과 컨트롤러 매니저
ClusterRole/ClusterRoleBinding 종류를 추가한다.

### PoC 검증 워크플로우 — K8s API 서버 접근 확인

새 워크플로우 `.github/workflows/actions-runner-poc.yml`(`workflow_dispatch`
전용, 다른 트리거에 얹지 않음)을 만든다. `runs-on: [self-hosted, ...]`로 새
러너를 선택하고, 러너 pod KSA로 `kubernetes.default.svc`의 in-cluster 엔드포인트에
읽기 전용 요청(`kubectl get --raw /healthz` 또는 동등한 호출)을 보낸다. 성공은
VPC 내부망 접근이 실제로 동작함을, 실패(connection timeout)는 NetworkPolicy 누락을
바로 알려주는 자기진단적 테스트다. 클러스터 상태 변경은 없다.

Redis Cluster PSC PING(대안 B)은 `feast_apply.tf`의 prod 전용 Redis egress
변수와 결합돼 이 PoC 범위에는 과하다 — 향후 `feast apply` 이관 단계(5단계)의
검증으로 남긴다.

### GKE node pool — 기존 `dev`(general) pool 재사용

새 전용 pool을 만들지 않는다. `batch-od`는 실험 Job 전용 단일 소비자 가정이
문서화돼 있어(#523) 러너를 얹으면 그 가정이 깨진다. `dev` pool은 이미 Workload
Identity가 설정돼 있고 오토스케일링 여유가 있어 PoC 단계의 격리 요구가 없는
현재로선 충분하다.

### CI apply 배선

`.github/workflows/apply.yml`의 `ADMIN_ROOTS`에 `terraform/admin/actions-runner-k8s`를
`argocd-k8s` 앞에 추가한다(namespace 소유 root 먼저, argocd-k8s 마지막이라는
기존 규칙 유지). 주석의 "admin K8s root 7개"를 8개로 갱신하고 이 이슈 번호를
남긴다.

## 범위 밖(명시)

- `feast apply`를 셀프 호스티드 러너로 이관하는 것(vault 5단계)
- Terraform apply/운영 배포용 별도 러너·승인 게이트 분리(vault 6단계)
- PoC 외 다른 내부망 워크플로우로 확장(vault 7단계)
- 오토스케일링 min/max 튜닝, GKE Job 방식과의 운영 비용·장애 대응 비교
- GitHub IP 대역 고정 allowlist로 `0.0.0.0/0:443` 예외를 좁히는 후속 하드닝

## 검증

- `terraform -chdir=terraform/admin/actions-runner-k8s fmt -check -recursive`,
  `init -backend=false`, `validate`
- `terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive`, `validate`
  (Application 리소스 추가분)
- `actionlint`로 새 PoC 워크플로우 검사
- CI apply(`scope: admin`) 실행 후 ArgoCD UI에서 두 Application이 `Synced`/`Healthy`인지,
  컨트롤러 Pod가 뜨는지 확인
- GitHub App 자격 증명을 런북대로 수동 주입한 뒤 `actions-runner-poc.yml`을
  `workflow_dispatch`로 실행해 성공(K8s API 200)과 실패(NetworkPolicy 일부러
  제거 후 timeout) 양쪽을 한 번씩 확인
