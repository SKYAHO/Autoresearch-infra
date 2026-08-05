# GitHub Actions 셀프 호스티드 러너(ARC) PoC 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** ARC 전용 namespace/KSA·GSA/NetworkPolicy/Secret 경계를 만들고 ArgoCD로
ARC를 설치한 뒤, 비파괴적 워크플로우 하나로 러너의 VPC 내부망 접근을 검증한다.

**Architecture:** dev root(`terraform/envs/dev/`)는 컨트롤러 GSA·Workload Identity·
Secret Manager 컨테이너를, admin root(`terraform/admin/actions-runner-k8s/`)는
namespace/KSA/NetworkPolicy/quota를, `terraform/admin/argocd-k8s/`는 ARC 설치용
Application 2개와 AppProject 확장을 관리한다. 새 워크플로우가 검증을 수행한다.

**Tech Stack:** Terraform, GCP IAM/Secret Manager, GKE Workload Identity, ArgoCD
Application, Helm(OCI, `oci://ghcr.io/actions/actions-runner-controller-charts`),
GitHub Actions, GitHub App.

## Global Constraints

- `feast apply`, `experiment_jobs.tf`, `batch-od` node pool은 수정하지 않는다.
- 새 `0.0.0.0/0:443` egress는 `actions-runner-k8s` namespace에만 적용하고 다른
  namespace의 NetworkPolicy는 건드리지 않는다.
- ARC 컨트롤러의 ClusterRole/ClusterRoleBinding은 chart가 만들도록 두고, 이 root가
  손으로 중복 작성하지 않는다.
- GitHub App private key 등 시크릿 값은 커밋하지 않으며 Terraform도 값을 관리하지
  않는다(Secret Manager 컨테이너만 생성).
- 실제 `terraform apply`(CI `apply.yml` dispatch 포함)는 사용자 승인 후에만
  수행한다.
- 새 PoC 워크플로우는 `workflow_dispatch`로만 실행되며 다른 트리거에 얹지 않는다.

### Task 1: dev root — 컨트롤러 GSA와 Secret Manager 컨테이너

**Files:** Create `terraform/envs/dev/actions_runner.tf`; modify
`terraform/envs/dev/locals.tf`, `variables.tf`, `terraform.tfvars.example`,
`outputs.tf`, `README.md`.

- [ ] `locals.tf`에 `${local.resource_prefix}-runner`(GCP account_id 6~30자 제약
      확인) GSA 이름과 Workload Identity principal
      `${var.project_id}.svc.id.goog[${var.actions_runner_namespace}/${var.actions_runner_controller_ksa}]`을
      정의한다.
- [ ] `actions_runner.tf`에 `google_service_account.actions_runner_controller`와
      Workload Identity binding(`google_service_account_iam_member`)을 만든다.
- [x] `google_secret_manager_secret` 3개(`actions-runner-github-app-id`,
      `-installation-id`, `-private-key`)를 `replication.auto{}` +
      `lifecycle.prevent_destroy = true`로 만든다. 값은 Terraform이 관리하지
      않는다(주석으로 명시, `argocd_google_oidc_client`와 동일 패턴). ARC 러너는
      이 값을 Secret Manager API가 아니라 운영자가 만드는 네이티브 K8s Secret으로
      소비하므로(`argocd_google_oidc_client`도 동일) 컨트롤러 GSA에
      `secretmanager.secretAccessor`를 부여하지 않는다 — 계획 작성 시의 가정을
      구현 중 정정.
- [ ] `actions_runner_contract` output에 GSA email, WI principal, 3개 Secret
      Manager secret_id만 넣는다. README에 GitHub App 생성은 조직 GitHub UI에서
      수동으로 선행돼야 한다고 기록한다.
- [ ] `terraform -chdir=terraform/envs/dev fmt -check -recursive`,
      `init -backend=false -input=false`, `validate` 성공 후
      `feat: 셀프 호스티드 러너 컨트롤러 GSA·Secret Manager 컨테이너 추가`로 커밋한다.

### Task 2: admin root — 러너 namespace/KSA/quota/NetworkPolicy

**Files:** Create `terraform/admin/actions-runner-k8s/{versions,main,variables,locals,outputs,terraform.tfvars.example,README}.tf` (또는 `.md`); modify
`config/environments/dev/environment.yaml`, `scripts/environment_catalog.rb`
(카탈로그 wrapper `scripts/terraform-env`가 알려진 root만 허용하므로 신규 root는
두 파일 모두에 등록해야 `init -backend=false`가 동작한다 — 계획 작성 시 누락된
필수 단계, 구현 중 정정).

- [x] `versions.tf`: backend `gcs {}`, `google >=5,<8`, `kubernetes >=2.20` provider
      (mlflow-k8s 스캐폴드와 동일, `helm` provider 없음).
- [x] `main.tf`: `kubernetes_namespace_v1.actions_runner`(PSA `baseline`
      enforce/audit/warn); `kubernetes_service_account_v1.actions_runner_controller`
      (automount 기본값 유지, 이유 주석); `kubernetes_service_account_v1.actions_runner_listener`
      (`automount_service_account_token=false`, WI annotation 없음 — 러너 Pod는
      GCP API를 직접 호출하지 않으므로 GSA를 공유하지 않는다, Task 1과 동일 정정).
- [x] `kubernetes_resource_quota_v1`/`kubernetes_limit_range_v1`을
      `experiment_jobs.tf` 형태로 추가하되 `pods=4`로 여유를 두고, scale-set
      chart의 `maxRunners`와 짝을 이뤄야 한다는 주석을 남긴다.
- [x] ingress NetworkPolicy(전면 차단) + egress NetworkPolicy(`experiment_jobs.tf`
      4규칙 재사용 + 같은 namespace 통신(mlflow-k8s 패턴) +
      `var.cluster_services_cidr:443` + `0.0.0.0/0:443` 예외, 각각 이유 주석 포함).
- [x] `outputs.tf`에 namespace/KSA 2종/NetworkPolicy 이름을 하나의 named contract
      output으로 공개한다(`feast_apply_environments` 스타일).
- [x] `terraform.tfvars.example`, `README.md`(경계 설명 + "5~7단계는 범위 밖" 명시)
      작성.
- [x] `terraform -chdir=terraform/admin/actions-runner-k8s fmt -check -recursive`,
      `init -backend=false -input=false`, `validate` 성공 후
      `feat: 셀프 호스티드 러너 Kubernetes 격리 경계 추가`로 커밋한다.

### Task 3: deploy umbrella chart 2개

**Files:** Create `deploy/actions-runner-controller/Chart.yaml` (+`values.yaml`),
`deploy/actions-runner-scale-set/Chart.yaml` (+`values.yaml`).

- [x] `deploy/actions-runner-controller/Chart.yaml`: `dependencies`에
      `repository: oci://ghcr.io/actions/actions-runner-controller-charts`,
      `name: gha-runner-scale-set-controller`, `version: 0.14.2` 고정. `values.yaml`에
      `flags.watchSingleNamespace = actions-runner`.
- [x] `deploy/actions-runner-scale-set/Chart.yaml`: 같은 저장소의
      `gha-runner-scale-set` dependency. `values.yaml`에 `githubConfigUrl`(이 저장소
      URL, repo 범위), `githubConfigSecret: actions-runner-github-app`(Task 6
      런북이 만들 기존 Secret 이름), `controllerServiceAccount`(Task 2 KSA 참조),
      `maxRunners: 4`(Task 2 quota와 일치), `runnerScaleSetName:
      actions-runner-poc`(Task 5 PoC 워크플로우의 `runs-on:` 단일 문자열과 일치
      — array 형태 `[self-hosted, ...]`가 아니라 scale set 이름 그대로임을 chart
      실측으로 확인, 계획 작성 시의 가정을 구현 중 정정).
- [x] `deploy/monitoring/Chart.lock`처럼 `Chart.lock`은 `helm dependency update`로
      생성해 커밋하고 `charts/*.tgz`는 `.gitignore` 규칙(`deploy/*/charts/`)에
      맡긴다(`git add -n`으로 제외 확인).
- [x] `docs: 셀프 호스티드 러너 ARC umbrella chart 추가`로 커밋한다(코드 변경
      없음 — chart 정의만이므로 fmt/validate 대상 아님, YAML lint만 확인).

### Task 4: argocd-k8s — Application 2개 + AppProject 확장

**Files:** modify `terraform/admin/argocd-k8s/{main,variables,outputs,README}.md/.tf`.

- [x] `appproject_autoresearch_dev`의 `destinations`에 새 러너 namespace 추가,
      `clusterResourceWhitelist`에 ARC CRD 4종
      (`AutoscalingRunnerSet`/`EphemeralRunnerSet`/`EphemeralRunner`/`AutoscalingListener`,
      `actions.github.com` apiGroup) 추가. ClusterRole/ClusterRoleBinding kind는
      이미 whitelist에 있어 재추가 불필요(컨트롤러 chart RBAC도 커버).
- [x] `kubernetes_manifest "application_actions_runner_controller"`:
      `application_monitoring`과 동일 구조, `spec.source.path =
      "deploy/actions-runner-controller"`, `helm.releaseName` 명시 고정,
      `syncPolicy.automated = {prune=false, selfHeal=false}`, retry 백오프,
      `syncOptions = ["ServerSideApply=true", "CreateNamespace=false"]`,
      `depends_on = [helm_release.argo_cd]`.
- [x] `kubernetes_manifest "application_actions_runner_scale_set"`: 동일 구조 +
      `depends_on`에 컨트롤러 Application을 추가해 Terraform 생성 순서를
      보장한다. sync-wave annotation은 채택하지 않음 — 이 root의 다른
      `kubernetes_manifest`도 `wait_for`를 쓰지 않아 Terraform이 실제 ArgoCD
      sync 완료까지 기다리는 보장은 어차피 없으므로, CRD 설치 완료 확인은
      Task 7에서 ArgoCD UI로 사람이 확인하는 절차로 남긴다.
- [x] `terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive`,
      `validate` 성공 후 `feat: ArgoCD에 셀프 호스티드 러너 ARC Application 추가`로
      커밋한다.

### Task 5: CI apply 배선과 PoC 워크플로우

**Files:** modify `.github/workflows/apply.yml`,
`scripts/test-environment-catalog.rb`; create
`.github/workflows/actions-runner-poc.yml`, `.github/actionlint.yaml`.

- [x] `apply.yml`의 `ADMIN_ROOTS`에 `terraform/admin/actions-runner-k8s`를
      `argocd-k8s` 앞에 추가하고 주석 3곳("admin K8s root 7개"류)을 8개로,
      이슈 번호(#533)를 갱신한다.
- [x] `test-environment-catalog.rb`의 fixture `state.roots`에도
      `actions-runner-k8s` 항목을 추가한다 — 실제 카탈로그는 Task 2에서 이미
      갱신했지만 이 테스트는 별도 fixture를 쓰므로 누락 시
      `validate_state!`가 실패한다(Task 5 착수 중 발견, 구현 중 정정).
- [x] `actions-runner-poc.yml`: `on: workflow_dispatch`만, `runs-on:
      actions-runner-poc`(scale set 이름 단일 문자열 — array 형태
      `[self-hosted, ...]`가 아님, Task 3에서 확인한 실제 ARC 컨벤션). 단일
      job·단일 step으로 `kubernetes.default.svc/healthz`를 인증 없이 `curl`로
      호출한다(기본 러너 이미지에 `kubectl`이 없어 `curl`로 정정). 401/403도
      "연결 성공"으로 판단하고, timeout/connection refused만 실패로 처리한다.
      결과를 `$GITHUB_STEP_SUMMARY`에 출력한다.
- [x] `.github/actionlint.yaml`에 `self-hosted-runner.labels`로
      `actions-runner-poc`를 등록한다 — 없으면 CI의 `lint`(raven-actions/
      actionlint) required check가 알 수 없는 라벨로 실패한다.
- [x] 로컬 `actionlint`로 두 워크플로우 파일 검증(exit 0 확인).
- [x] `feat: CI apply에 러너 root 추가 및 PoC 워크플로우 작성`으로 커밋한다.

### Task 6: 런북·문서 갱신

**Files:** Create `docs/runbooks/2026-08-05-actions-runner-github-app-secret.md`;
modify `terraform/README.md`(admin root 목록에 `terraform/admin/README.md`가
없어 대상 변경 — 실제 admin root 목록은 `terraform/README.md`와 `CLAUDE.md`가
관리), `CLAUDE.md`, `docs/CHANGE_HISTORY.md`.

- [x] 런북에 GitHub App 생성(조직 UI, 수동) → Secret Manager 값 채우기
      (`gcloud secrets versions add`) → K8s Secret 생성 순서를 기록한다.
      private key가 여러 줄 PEM이라 `--from-env-file`(#213, 한 줄 KEY=VALUE만
      지원)로는 옮길 수 없어, agent-orchestration #525 런북과 같은
      `--from-file` 패턴(key별 임시 파일)을 쓴다 — `--from-literal`은 여전히
      금지.
- [x] admin root 목록 문서(`terraform/README.md`, `CLAUDE.md`)에
      `actions-runner-k8s` 추가. `terraform/admin/README.md`는 애초에 존재하지
      않아 계획 작성 시의 경로 가정을 정정한다.
- [x] `docs: 셀프 호스티드 러너 ARC PoC 런북 추가`로 커밋한다.

### Task 7: Draft PR과 검증

- [ ] 이슈에서 만든 브랜치로 Draft PR을 생성한다(PR 템플릿 준수, 범위 밖 항목
      명시).
- [ ] `lint`(actionlint) CI 통과 확인.
- [ ] 사용자 승인 후 `apply.yml`(`scope: admin`) dispatch → ArgoCD UI에서 두
      Application `Synced`/`Healthy` 확인 → 런북대로 GitHub App/Secret 수동 주입 →
      `actions-runner-poc.yml` 실행해 성공 확인 → NetworkPolicy 임시 제거 후
      재실행해 timeout(실패) 확인 → 원복.
- [ ] 리뷰 반영 후 squash merge, 이슈 자동 close 확인.
