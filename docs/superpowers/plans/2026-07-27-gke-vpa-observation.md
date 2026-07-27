# GKE VPA 관측 도입 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GKE dev 클러스터에 VPA 애드온을 활성화해 Airflow scheduler VPA recommendation을 수집할 API와 controller를 준비한다.

**Architecture:** GKE cluster platform capability는 infra Terraform이 소유한다. scheduler VPA CR은 Helm release lifecycle에 속하므로 Autoresearch-airflow#159가 배포하며, 이 계획은 그 CR의 선행 조건만 제공한다. 애드온 활성화는 workload resource나 Pod를 변경하지 않는다.

**Tech Stack:** Terraform >= 1.6, hashicorp/google >= 7.39.0 < 8.0, GKE Standard, kubectl

## Global Constraints

- `google_container_cluster.dev.vertical_pod_autoscaling.enabled`는 정확히 `true`여야 한다.
- VPA `Auto` 또는 `Recreate` mode, scheduler request/limit, node pool, GCP IAM, network, Secret은 변경하지 않는다.
- VPA CR lifecycle에는 `airflow` namespace의 `autoscaling.k8s.io/verticalpodautoscalers` 최소 RBAC만 추가한다. GKE managed addon의 내부 RBAC 또는 `admin` ClusterRole aggregation에 의존하지 않는다.
- `terraform apply`는 사용자가 명시적으로 승인한 경우에만 실행한다.
- Airflow VPA CR 배포는 Autoresearch-airflow#159가 담당하며, 이 변경의 apply 후에만 진행한다.
- 롤백 시 Airflow VPA CR을 먼저 삭제하고, 그 뒤에만 애드온 비활성화를 검토한다.

---

## File Structure

- Modify: `terraform/envs/dev/gke.tf` - dev GKE cluster addon configuration
- Modify: `docs/TERRAFORM_DEV.md` - dev cluster VPA addon, 적용 순서, Terraform 검증과 롤백의 정본
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md` - 운영자가 CRD/controller readiness를 확인하는 명령

### Task 1: GKE VPA 애드온 선언

**Files:**
- Modify: `terraform/envs/dev/gke.tf:84-88`
- Test: `terraform/envs/dev/gke.tf`의 rendered Terraform configuration

**Interfaces:**
- Consumes: `google_container_cluster.dev`의 기존 `addons_config`와 `network_policy_config` block
- Produces: GKE API가 `verticalpodautoscalers.autoscaling.k8s.io` CRD와 VPA controller/recommender를 제공하는 cluster configuration

- [ ] **Step 1: 변경 전 구조 검사를 실행한다**

Run:

```bash
rg -n -A5 'addons_config' terraform/envs/dev/gke.tf
rg -n 'vertical_pod_autoscaling' terraform/envs/dev/gke.tf
```

Expected: 첫 명령은 `network_policy_config`만 표시하고, 두 번째 명령은 결과가 없어 VPA addon 선언이 아직 없음을 확인한다.

- [ ] **Step 2: cluster 최상위에 최소 VPA block을 추가한다**

`terraform/envs/dev/gke.tf`에서 기존 `addons_config`는 변경하지 않고, 그 직후에
다음 최상위 block을 추가한다. google provider v7.39.0은
`addons_config.vertical_pod_autoscaling`을 지원하지 않는다.

```hcl
  vertical_pod_autoscaling {
    enabled = true
  }
```

- [ ] **Step 3: 포맷과 offline Terraform 검증을 실행한다**

Run:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

Expected: 세 명령 모두 exit code 0; `validate`는 `Success! The configuration is valid.`를 출력한다.

- [ ] **Step 4: 인증 가능한 운영자 환경에서 plan을 검토한다**

Run:

```bash
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

Expected: `google_container_cluster.dev`의 in-place VPA 변경만 나타나며 destroy/replace, IAM, node pool, network, Secret 변경이 없다. plan 출력의 add/change/destroy 수와 VPA block diff를 PR 본문에 기록한다.

- [ ] **Step 5: 인프라 선언만 커밋한다**

```bash
git add terraform/envs/dev/gke.tf
git commit -m "feat: GKE VPA 애드온 활성화"
```

### Task 2: VPA 운영 절차 문서화

**Files:**
- Modify: `docs/TERRAFORM_DEV.md`
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- Test: markdown command and link review

**Interfaces:**
- Consumes: Task 1의 GKE VPA addon과 Autoresearch-airflow#159의 `airflow-scheduler` VPA CR
- Produces: VPA 적용 순서, observation-only 제약, 운영 확인 및 rollback을 설명하는 문서

- [ ] **Step 1: 문서에 기존 VPA 운영 절차가 없는지 확인한다**

Run:

```bash
rg -n -i 'vertical pod autoscaling|\bvpa\b' docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md
```

Expected: 새 VPA 운영 절차가 아직 없음을 확인한다.

- [ ] **Step 2: Terraform 개발 문서에 VPA section을 추가한다**

`docs/TERRAFORM_DEV.md`의 GKE 운영 설명 뒤에 `## GKE VPA 관측 (#373)` section을 추가한다. 다음 내용을 빠짐없이 기록한다.

```markdown
`google_container_cluster.dev.vertical_pod_autoscaling`은 GKE VPA
CRD와 recommender/controller를 제공한다. scheduler VPA resource는 Helm release
소유이므로 Autoresearch-airflow#159가 배포한다.

LocalExecutor task는 scheduler Pod 안에서 실행되므로 `Auto`와 `Recreate` mode를
사용하지 않는다. 초기 VPA는 `updateMode: "Off"`로 recommendation만 수집하며,
scheduler `values.yaml` resource 변경은 recommendation, namespace quota, node
allocatable resource를 검토한 후 별도 이슈에서 수동으로 한다.
```

문서에는 Terraform validate/plan을 먼저 수행하고, apply 후 Airflow VPA CR을
배포한다는 순서와 "VPA CR 제거 후 addon 비활성화" rollback 순서도 기록한다.

- [ ] **Step 3: 팀 운영 runbook에 readiness 확인 명령을 추가한다**

`docs/TEAM_OPERATIONS_RUNBOOK.md`의 Airflow 설치 권한 확인 section 뒤에 다음
`## VPA 관측 확인 (#373)` section을 추가한다.

```bash
kubectl wait --for=condition=Established --timeout=120s crd/verticalpodautoscalers.autoscaling.k8s.io

# CRD Established 뒤 served API discovery가 반영될 때까지 최대 120초 대기한다.
deadline=$((SECONDS + 120))
while ! kubectl api-resources --request-timeout=5s --api-group=autoscaling.k8s.io \
  | awk '$1 == "verticalpodautoscalers" { found = 1 } END { exit !found }'
do
  if (( SECONDS >= deadline )); then
    printf '%s\n' 'VPA served API discovery timed out after 120 seconds.' >&2
    exit 1
  fi
  sleep 5
done

kubectl get pods --all-namespaces
kubectl get vpa airflow-scheduler --namespace airflow
kubectl describe vpa airflow-scheduler --namespace airflow
```

설명에는 CRD Established 뒤 `verticalpodautoscalers` served API discovery가 120초 안에
반영되지 않으면 실패하며, 전체 pod 목록은 내부 component Pod 이름이나 label을 가정하지
않는 진단용 보조 명령임을 적는다. 마지막 두 명령은 Autoresearch-airflow#159 배포 후
실행하고 recommendation은 실제 workload 데이터가 누적되기 전에는 비어 있을 수 있음을
적는다.

- [ ] **Step 4: 문서 diff를 검증한다**

Run:

```bash
git diff --check
git diff -- docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md
```

Expected: whitespace 오류가 없고, 문서가 `updateMode: "Off"`, Airflow#159 선행
조건, 수동 조정, rollback 순서를 모두 명시한다.

- [ ] **Step 5: 운영 문서를 별도 커밋한다**

```bash
git add docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md
git commit -m "docs: GKE VPA 관측 절차 추가"
```

### Task 3: 운영 적용 후 API readiness 확인

**Files:**
- Modify: 없음
- Test: live GKE API and VPA system components

**Interfaces:**
- Consumes: merge된 Task 1 Terraform 변경, PR의 `terraform-plan` 검토, 사용자의 명시적
  `dev-apply` workflow-dispatch 요청과 `dev-apply` Environment reviewer 승인
- Produces: Autoresearch-airflow#159의 Helm VPA 배포를 진행할 수 있는 readiness evidence

- [ ] **Step 1: PR의 dev root plan을 검토한다**

PR의 `terraform-plan` check와 상세 diff를 검토한다. 로컬 `terraform.tfvars` plan은 기본
경로가 아니다.

Expected: 변경 resource address는 `google_container_cluster.dev` 하나뿐이고, 그 resource의
in-place `vertical_pod_autoscaling` addon 변경만 나타난다. 다른 resource address, destroy,
replace, IAM, node pool, network, Secret 변경이 하나라도 있으면 merge하지 않고 plan 원인을
해결한다. plan 출력의 add/change/destroy 수와 VPA block diff를 PR 본문에 기록한다.

- [ ] **Step 2: merge 후 사용자 요청으로 `dev-apply` workflow를 dispatch한다**

PR plan 검토를 통과하고 merge된 뒤, 사용자의 명시적 요청이 있을 때만 GitHub Actions의
`dev-apply` workflow를 workflow-dispatch한다. `dev-apply` Environment reviewer가 plan을
검토하고 승인해야 apply job이 실행된다.

Expected: workflow의 plan job이 성공한 뒤 Environment 승인 게이트를 통과하면, 해당 run이
저장한 plan으로 dev root apply가 실행된다. 로컬 `terraform.tfvars` apply는 CI 경로가
사용 불가능한 break-glass 상황에서만 별도 사용자 승인으로 사용하며, 이 절차의 기본
경로가 아니다.

- [ ] **Step 3: VPA API와 controller/recommender를 확인한다**

Run:

```bash
kubectl wait --for=condition=Established --timeout=120s crd/verticalpodautoscalers.autoscaling.k8s.io

# CRD Established 뒤 served API discovery가 반영될 때까지 최대 120초 대기한다.
deadline=$((SECONDS + 120))
while ! kubectl api-resources --request-timeout=5s --api-group=autoscaling.k8s.io \
  | awk '$1 == "verticalpodautoscalers" { found = 1 } END { exit !found }'
do
  if (( SECONDS >= deadline )); then
    printf '%s\n' 'VPA served API discovery timed out after 120 seconds.' >&2
    exit 1
  fi
  sleep 5
done

kubectl get pods --all-namespaces
```

Expected: CRD가 Established이고
`kubectl api-resources --request-timeout=5s --api-group=autoscaling.k8s.io` 출력에
`verticalpodautoscalers`가 120초 안에 나타난다. 각 API 요청은 5초로 제한하므로 API
server 또는 네트워크 hang이 polling deadline을 넘기지 않는다. timeout이면 실패한다. 전체
pod 목록은 GKE managed addon의 내부 Pod 이름이나 label을 가정하지 않는 진단용 보조
증적이다. 이 증적을 #373과 Airflow#159에 남긴 뒤에만 Airflow Helm VPA 배포를 진행한다.

---

## Review Remediation Amendment

이 amendment는 Task 2의 CRD readiness snippet과 Task 3의 운영 순서를 대체한다.
VPA addon 활성화는 비동기 GKE cluster update operation이므로 DAG 실행이 없는 운영 창에서
`dev-apply`를 승인하고, 완료된 operation을 확인한다. 이 계획은 addon 내부 RBAC를 공개
계약으로 가정하지 않고 Helm deployer와 installer의 VPA CR lifecycle 권한을 namespace에
명시한다.

### Task 4: Airflow VPA lifecycle RBAC 선언

**Files:**
- Modify: `terraform/admin/airflow-k8s/main.tf:26-116`
- Test: Terraform configuration structure and `terraform/admin/airflow-k8s` validate in a GKE-authenticated operator environment

**Interfaces:**
- Consumes: `var.airflow_k8s_namespace`, `var.installer_user_emails`, `local.airflow_deployer_service_account_email`
- Produces: `airflow-vpa` Role and `airflow-vpa` RoleBinding for the Helm deployer GSA and installer Users

- [ ] **Step 1: Write the failing structural assertion**

Run:

```bash
rg -n 'autoscaling\.k8s\.io|verticalpodautoscalers|airflow-vpa' terraform/admin/airflow-k8s/main.tf
```

Expected: exit code 1 because no explicit VPA Role or RoleBinding exists.

- [ ] **Step 2: Add the namespace-scoped Role and RoleBinding**

Add the following resources after `kubernetes_role_v1.airflow_components`:

```hcl
resource "kubernetes_role_v1" "airflow_vpa" {
  metadata {
    name      = "airflow-vpa"
    namespace = var.airflow_k8s_namespace
  }

  rule {
    api_groups = ["autoscaling.k8s.io"]
    resources  = ["verticalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "airflow_vpa" {
  metadata {
    name      = "airflow-vpa"
    namespace = var.airflow_k8s_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.airflow_vpa.metadata[0].name
  }

  dynamic "subject" {
    for_each = toset(concat(
      [local.airflow_deployer_service_account_email],
      tolist(var.installer_user_emails),
    ))

    content {
      api_group = "rbac.authorization.k8s.io"
      kind      = "User"
      name      = subject.value
    }
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}
```

- [ ] **Step 3: Run the structural assertion and Terraform validation**

Run:

```bash
rg -n 'autoscaling\.k8s\.io|verticalpodautoscalers|airflow-vpa' terraform/admin/airflow-k8s/main.tf
terraform -chdir=terraform/admin/airflow-k8s fmt -check -recursive
terraform -chdir=terraform/admin/airflow-k8s validate
```

Expected: the search shows the Role and binding, formatting exits 0, and authenticated validation reports a valid configuration. Do not run `plan` or `apply` without explicit user approval.

- [ ] **Step 4: Commit the RBAC change**

```bash
git add terraform/admin/airflow-k8s/main.tf
git commit -m "feat: Airflow VPA lifecycle 권한 추가"
```

### Task 5: Apply safety and readiness runbook remediation

**Files:**
- Modify: `docs/TERRAFORM_DEV.md:1069-1090`
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md:154-178`
- Test: markdown command inspection and `bash -n` of the embedded polling snippet

**Interfaces:**
- Consumes: Task 4 namespace RBAC and `dev-apply`/`admin-apply` approval workflows
- Produces: a safe, ordered procedure for addon update, CRD readiness, and RBAC verification

- [ ] **Step 1: Write the failing command-structure assertion**

Run:

```bash
rg -n 'for=create|airflow-vpa|auth can-i.*verticalpodautoscalers|bash -c' docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md
```

Expected: required readiness and RBAC terms are absent or the old direct `kubectl wait` command remains.

- [ ] **Step 2: Document the exact safe procedure**

Replace direct CRD condition waiting with this subshell in the runbook and plan:

```bash
bash -c '
  kubectl wait --for=create --timeout=120s \
    crd/verticalpodautoscalers.autoscaling.k8s.io
  kubectl wait --for=condition=Established --timeout=120s \
    crd/verticalpodautoscalers.autoscaling.k8s.io
  deadline=$((SECONDS + 120))
  while ! kubectl api-resources --request-timeout=5s \
    --api-group=autoscaling.k8s.io \
    | awk "\$1 == \"verticalpodautoscalers\" { found = 1 } END { exit !found }"
  do
    if (( SECONDS >= deadline )); then
      printf "%s\\n" "VPA served API discovery timed out after 120 seconds." >&2
      exit 1
    fi
    sleep 5
  done
'
```

Document that `dev-apply` runs only in a DAG-idle operating window and its GKE operation must complete before readiness checks. Document that `admin-apply` applies Task 4 first, then verify the actual Helm deployer identity with `kubectl auth can-i` for all lifecycle verbs before Airflow#159 is merged. State that a failed permission check blocks the Helm deployment and must not be worked around with cluster-wide RBAC.

- [ ] **Step 3: Verify the documentation contract**

Run:

```bash
rg -n 'for=create|condition=Established|airflow-vpa|auth can-i.*verticalpodautoscalers|DAG.*운영 창|GKE operation' docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md
git diff --check
```

Expected: all required terms are present and no whitespace error is reported.

- [ ] **Step 4: Commit the runbook remediation**

```bash
git add docs/TERRAFORM_DEV.md docs/TEAM_OPERATIONS_RUNBOOK.md docs/superpowers/plans/2026-07-27-gke-vpa-observation.md
git commit -m "docs: VPA 운영 안전 절차 보완"
```

### Task 6: Approved live rollout evidence

**Files:**
- Modify: 없음
- Test: GitHub `admin-apply` and `dev-apply` runs plus live Kubernetes readiness/RBAC checks

**Interfaces:**
- Consumes: merged Tasks 1, 4, and 5 plus explicit user approval
- Produces: evidence that Airflow#159 can be safely merged and deployed

- [ ] **Step 1: Apply VPA RBAC through the approved admin root workflow**

Run after merge and explicit approval: dispatch `.github/workflows/admin-apply.yml`, select the `airflow-k8s` root, and wait for the required Environment reviewer approval.

Expected: the applied Role and RoleBinding exist only in namespace `airflow`.

- [ ] **Step 2: Apply the GKE addon during a DAG-idle operating window**

Run after explicit approval: dispatch `.github/workflows/dev-apply.yml`, review the plan summary, approve the `dev-apply` Environment, and record the completed GKE operation.

Expected: the plan has only the in-place `google_container_cluster.dev` addon change and the workflow apply succeeds.

- [ ] **Step 3: Collect readiness and permission evidence**

Run the Task 5 CRD/API subshell, then authenticate as the deployer and run:

```bash
kubectl auth can-i get verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i list verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i watch verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i create verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i update verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i patch verticalpodautoscalers.autoscaling.k8s.io -n airflow
kubectl auth can-i delete verticalpodautoscalers.autoscaling.k8s.io -n airflow
```

Expected: every command prints `yes`. Record the GKE operation and checks in #373 and Airflow#159 before merging Airflow#160.
