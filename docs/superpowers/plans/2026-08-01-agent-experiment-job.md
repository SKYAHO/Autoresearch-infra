# Auto Research 실험 Job 실행 경계 구현 계획

> **에이전트 작업자 참고:** 이 계획을 실행할 때는 `superpowers:executing-plans` 또는 `superpowers:subagent-driven-development`를 사용합니다. 각 단계는 체크박스로 추적하고, 단계마다 독립적으로 검증합니다.

**목표:** Auto Research 실험을 전용 namespace의 제한된 Kubernetes Job으로 실행할 수 있는 GKE·GCP 인프라 경계를 추가합니다.

**구조:** `terraform/envs/dev`에 실험 결과 전용 GCS 버킷·Job GSA·Workload Identity를 추가하고, `terraform/admin/autoresearch-k8s`에 실험 namespace·Job KSA·RBAC·quota·limitrange·restricted Pod Security·NetworkPolicy를 추가합니다. API의 Job `create` 권한은 고정 템플릿과 admission 검증이 준비된 뒤에만 켤 수 있도록 기본값을 `false`로 둡니다.

**기술:** Terraform 1.15.x, Google provider 7.x, Kubernetes provider 3.x, GKE Standard/Calico NetworkPolicy, GKE Workload Identity Federation, GCS Uniform Bucket-Level Access

## 전역 제약

- 기존 `autoresearch` namespace의 API·Runner 권한과 NetworkPolicy를 확대하지 않습니다.
- 실험 namespace는 `pod-security.kubernetes.io/enforce=restricted`를 사용합니다.
- 실험 Job은 `backoffLimit=0`, 명시적 `activeDeadlineSeconds`, TTL, requests/limits를 사용합니다.
- 외부 인터넷 egress `0.0.0.0/0:443`를 추가하지 않고 Private Google Access `199.36.153.8/30:443`만 허용합니다.
- Job GSA에는 실험 결과 전용 버킷의 `roles/storage.objectCreator`만 부여합니다.
- API KSA의 Job `create` 권한은 `enable_experiment_job_creation=false` 기본값으로 비활성화합니다.
- 실험 Job KSA에는 Kubernetes RBAC를 부여하지 않으며, Workload Identity용 토큰만 사용합니다.
- 실제 `terraform apply`, GCP 리소스 생성·삭제, 클러스터 변경은 사용자 승인 없이는 실행하지 않습니다.
- 모든 Terraform 설명·Kubernetes 주석·운영 문서는 한글로 작성합니다.
- state, 실제 tfvars, Secret 값, 서비스 계정 키, access token은 커밋하지 않습니다.

---

### 작업 1: 실험 결과 GCS 경계와 Workload Identity 추가

**파일:**

- 생성: `terraform/envs/dev/experiment_jobs.tf`
- 수정: `terraform/envs/dev/variables.tf`
- 수정: `terraform/envs/dev/locals.tf`
- 수정: `terraform/envs/dev/outputs.tf`
- 수정: `terraform/envs/dev/README.md`

**구현 계약:**

- 버킷 이름은 `local.experiment_results_bucket_name = "${var.project_id}-${local.resource_prefix}-experiment-results"`로 파생하고 project id를 하드코딩하지 않습니다.
- 버킷은 `uniform_bucket_level_access=true`, `public_access_prevention="enforced"`, `force_destroy=false`, versioning, `prevent_destroy=true`를 사용합니다.
- GCS 객체 prefix는 `experiments/<experiment-id>/<attempt-id>/`로 문서화합니다. prefix IAM은 사용하지 않고 버킷 자체를 실험 결과 전용으로 분리합니다.
- Job GSA account id는 30자 제한을 검증하고 기본값은 `autoresearch-dev-exp-job`로 둡니다.
- Job KSA principal은 `autoresearch-experiments/experiment-job`로 고정된 기본값에서 파생합니다.
- Job GSA에는 버킷 수준 `roles/storage.objectCreator`만 부여합니다. objectViewer, objectAdmin, bucket IAM 권한은 부여하지 않습니다.
- Job KSA→GSA Workload Identity binding은 `roles/iam.workloadIdentityUser`로만 연결합니다.

- [ ] **1단계: Terraform 입력 검증 조건을 먼저 정의합니다.**

  `terraform/envs/dev/variables.tf`에 `experiment_results_object_retention_days`를 추가하고, 값이 1 이상의 정수인지 validation으로 제한합니다. 버킷 이름은 입력으로 받지 않고 `locals.tf`에서 project id와 resource prefix로 파생합니다.

- [ ] **2단계: 버킷·GSA·IAM·Workload Identity 리소스를 추가합니다.**

  `experiment_jobs.tf`에 `google_storage_bucket.experiment_results`, `google_service_account.experiment_job`, `google_service_account_iam_member.experiment_job_wi`, `google_storage_bucket_iam_member.experiment_job_object_creator`를 추가합니다. 버킷 lifecycle은 기존 `storage.tf` 패턴을 따르고 `experiment_results_object_retention_days` 기본값 30일로 제한합니다.

- [ ] **3단계: 결과 버킷과 계약 좌표를 output으로 노출합니다.**

  `outputs.tf`에 `experiment_results_bucket_name`, `experiment_job_gcp_service_account_email`, `experiment_job_workload_identity_principal`을 추가합니다. 토큰·Secret payload·state backend 정보는 output하지 않습니다.

- [ ] **4단계: Terraform 포맷·검증을 실행합니다.**

  ```bash
  terraform -chdir=terraform/envs/dev fmt -check -recursive
  terraform -chdir=terraform/envs/dev init -backend=false -input=false
  terraform -chdir=terraform/envs/dev validate
  git diff --check
  ```

- [ ] **5단계: 커밋합니다.**

  ```bash
  git add terraform/envs/dev/experiment_jobs.tf terraform/envs/dev/variables.tf terraform/envs/dev/locals.tf terraform/envs/dev/outputs.tf terraform/envs/dev/README.md
  git commit -m "feat: 실험 결과 저장소와 Workload Identity 추가"
  ```

### 작업 2: 실험 전용 namespace와 실행 KSA 추가

**파일:**

- 생성: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- 수정: `terraform/admin/autoresearch-k8s/variables.tf`
- 수정: `terraform/admin/autoresearch-k8s/locals.tf`
- 수정: `terraform/admin/autoresearch-k8s/outputs.tf`
- 수정: `terraform/admin/autoresearch-k8s/README.md`

**구현 계약:**

- namespace 기본값은 `autoresearch-experiments`입니다.
- Job KSA 기본값은 `experiment-job`입니다.
- namespace에는 `app.kubernetes.io/part-of=auto-research`와 Pod Security `restricted` enforce/audit/warn 라벨을 모두 설정합니다.
- Job KSA는 `automount_service_account_token=true`로 설정해 GKE metadata server 기반 Workload Identity를 사용합니다. Kubernetes RoleBinding은 만들지 않습니다.
- namespace ResourceQuota 기본값은 `count/jobs.batch=4`, `count/pods=4`, `requests.cpu=2`, `requests.memory=4Gi`, `limits.cpu=4`, `limits.memory=8Gi`입니다.
- LimitRange 기본값은 container request `250m/256Mi`, default limit `1 CPU/2Gi`, max `2 CPU/4Gi`로 고정합니다.

- [ ] **1단계: namespace·KSA·quota·limitrange 리소스를 추가합니다.**

  `experiment_jobs.tf`에 `kubernetes_namespace_v1.experiment_jobs`, `kubernetes_service_account_v1.experiment_job`, `kubernetes_resource_quota_v1.experiment_jobs`, `kubernetes_limit_range_v1.experiment_jobs`를 추가합니다. admin root는 dev state를 직접 읽지 않으므로 KSA annotation은 `${var.resource_prefix}-exp-job@${var.project_id}.iam.gserviceaccount.com` 기본값을 locals에서 파생하며, 필요하면 검증된 GSA email만 변수 override로 받습니다.

- [ ] **2단계: namespace 출력과 운영 문서를 추가합니다.**

  admin root output에 namespace, KSA, GSA email, 결과 버킷 이름을 추가하고 README의 namespace 경계·import·rollback 절차를 갱신합니다.

- [ ] **3단계: Terraform 검증을 실행합니다.**

  ```bash
  terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
  terraform -chdir=terraform/admin/autoresearch-k8s init -backend=false -input=false
  terraform -chdir=terraform/admin/autoresearch-k8s validate
  git diff --check
  ```

- [ ] **4단계: 커밋합니다.**

  ```bash
  git add terraform/admin/autoresearch-k8s/experiment_jobs.tf terraform/admin/autoresearch-k8s/variables.tf terraform/admin/autoresearch-k8s/locals.tf terraform/admin/autoresearch-k8s/outputs.tf terraform/admin/autoresearch-k8s/README.md
  git commit -m "feat: 실험 Job 전용 namespace 경계 추가"
  ```

### 작업 3: API 읽기 권한과 조건부 Job 생성 RBAC 추가

**파일:**

- 수정: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- 수정: `terraform/admin/autoresearch-k8s/variables.tf`
- 수정: `terraform/admin/autoresearch-k8s/README.md`
- 생성: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`

**구현 계약:**

- API KSA는 `autoresearch` namespace의 `agent-orchestration-api`입니다.
- 기본 상태에서 API KSA는 실험 namespace의 `jobs`, `pods`, `pods/log`에 대해 `get/list/watch`만 수행합니다.
- `enable_experiment_job_creation=false`이면 `create`가 절대 생성되지 않습니다.
- 이 변수를 `true`로 설정하는 조건은 문서에 명시된 고정 Job 템플릿·허용 digest 검증·admission 검증 완료입니다.
- API KSA에는 `secrets`, `pods/exec`, `pods/attach`, `roles`, `rolebindings`, `serviceaccounts`, 다른 namespace 권한을 부여하지 않습니다.

- [ ] **1단계: API 읽기 Role과 RoleBinding을 추가합니다.**

  `kubernetes_role_v1.experiment_job_observer`와 `kubernetes_role_binding_v1.experiment_job_observer`를 추가합니다. subject는 기존 `kubernetes_service_account_v1.agent_orchestration_api`를 사용하고 `jobs`, `pods`, `pods/log`에 필요한 최소 read 동사만 둡니다.

- [ ] **2단계: 조건부 create Role을 추가합니다.**

  `var.enable_experiment_job_creation ? { enabled = true } : {}` 방식으로 `kubernetes_role_v1.experiment_job_creator`와 binding을 조건부 생성합니다. `jobs.create` 외 동사는 추가하지 않습니다. Job API create가 임의 Pod 사양을 허용할 수 있다는 위험과 활성화 전제조건을 README와 runbook에 기록합니다.

- [ ] **3단계: API 권한 음성 검증을 문서화합니다.**

  ```bash
  kubectl auth can-i get jobs -n autoresearch-experiments --as=system:serviceaccount:autoresearch:agent-orchestration-api
  kubectl auth can-i create jobs -n autoresearch-experiments --as=system:serviceaccount:autoresearch:agent-orchestration-api
  kubectl auth can-i get secrets -n autoresearch-experiments --as=system:serviceaccount:autoresearch:agent-orchestration-api
  kubectl auth can-i create pods/exec -n autoresearch-experiments --as=system:serviceaccount:autoresearch:agent-orchestration-api
  ```

  기본값에서 예상 결과는 `get=yes`, `create=no`, `secrets=no`, `pods/exec=no`입니다.

- [ ] **4단계: 검증 후 커밋합니다.**

  ```bash
  terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
  terraform -chdir=terraform/admin/autoresearch-k8s validate
  git diff --check
  git add terraform/admin/autoresearch-k8s/experiment_jobs.tf terraform/admin/autoresearch-k8s/variables.tf terraform/admin/autoresearch-k8s/README.md docs/runbooks/2026-08-01-auto-research-experiment-job.md
  git commit -m "feat: 실험 Job API 권한 경계 추가"
  ```

### 작업 4: 실험 namespace NetworkPolicy와 운영 계약 문서 완성

**파일:**

- 수정: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- 수정: `terraform/admin/autoresearch-k8s/README.md`
- 수정: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- 수정: `docs/INFRASTRUCTURE_SUMMARY.md`
- 수정: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- 수정: `docs/CHANGE_HISTORY.md`

**구현 계약:**

- Ingress는 전면 차단합니다.
- Egress는 kube-dns Service ClusterIP와 `kube-system` DNS selector, GKE metadata endpoint(`169.254.169.254:80`, `169.254.169.252:987/988`), Private Google Access `199.36.153.8/30:443`만 허용합니다.
- Redis, Cloud SQL, MLflow, 외부 API는 이번 기본 정책에 포함하지 않습니다.
- NetworkPolicy는 기존 `autoresearch` 정책에 추가하지 않고 실험 namespace에서 별도로 관리합니다.

- [ ] **1단계: deny-all ingress/egress 정책을 추가합니다.**

  `kubernetes_network_policy_v1.experiment_jobs_ingress`는 빈 pod selector와 `policy_types=["Ingress"]`로 구성합니다. egress는 services CIDR DNS와 kube-system DNS selector를 함께 사용해 Calico DNAT 전후를 커버하고, metadata와 Private Google Access만 추가합니다.

- [ ] **2단계: restricted 음성 테스트 manifest와 Job 계약을 문서화합니다.**

  runbook에 `hostNetwork: true`, `hostPath`, `runAsUser: 0`, `privileged: true`, `capabilities.add`를 포함한 server-side dry-run 음성 검증을 추가합니다. 정상 Job 계약에는 `backoffLimit: 0`, `activeDeadlineSeconds: 3600`, `ttlSecondsAfterFinished: 86400`, 고정 digest, `experiment-id`·`source-revision`·`result-uri` metadata, 명시적 requests/limits를 기록합니다.

- [ ] **3단계: 운영 문서를 갱신합니다.**

  `docs/INFRASTRUCTURE_SUMMARY.md`에 실험 namespace·GCS·IAM을 추가하고, `docs/TEAM_OPERATIONS_RUNBOOK.md`에는 apply 전 확인·읽기 전용 권한 확인·실패 원인 분류·롤백을 추가합니다. `CHANGE_HISTORY.md`에는 설계 결정과 API create 기본 비활성 상태를 짧게 기록합니다.

- [ ] **4단계: 검증 후 커밋합니다.**

  ```bash
  terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
  terraform -chdir=terraform/admin/autoresearch-k8s validate
  git diff --check
  git add terraform/admin/autoresearch-k8s/experiment_jobs.tf terraform/admin/autoresearch-k8s/README.md docs/runbooks/2026-08-01-auto-research-experiment-job.md docs/INFRASTRUCTURE_SUMMARY.md docs/TEAM_OPERATIONS_RUNBOOK.md docs/CHANGE_HISTORY.md
  git commit -m "docs: 실험 Job 운영 경계와 롤백 절차 기록"
  ```

### 작업 5: 최종 정적 검증과 보안 셀프 리뷰

**파일:**

- 검토: `terraform/envs/dev/experiment_jobs.tf`
- 검토: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- 검토: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- 검토: `.github/PULL_REQUEST_TEMPLATE.md`

- [ ] `terraform -chdir=terraform/envs/dev fmt -check -recursive` 통과
- [ ] `terraform -chdir=terraform/envs/dev validate` 통과
- [ ] `terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive` 통과
- [ ] `terraform -chdir=terraform/admin/autoresearch-k8s validate` 통과
- [ ] YAML 중복 키·구문 검증 통과
- [ ] `git diff --check` 통과
- [ ] `rg`로 Secret 값·실제 tfvars·state·서비스 계정 키·토큰 유입 여부 확인
- [ ] IAM diff에 `roles/owner`, `roles/editor`, 프로젝트 전체 objectAdmin, Secret Manager 전체 accessor가 없는지 확인
- [ ] NetworkPolicy diff에 `0.0.0.0/0:443`, Redis·Cloud SQL·외부 API 신규 허용이 없는지 확인
- [ ] `deletion_protection` 해제, `prevent_destroy` 제거, 기존 리소스 교체가 없는지 확인
- [ ] PR 템플릿의 IAM·비용·리전·롤백·문서·검증 체크리스트를 모두 채울 수 있는지 확인

최종 검증 명령:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
terraform -chdir=terraform/admin/autoresearch-k8s validate
git diff --check
```
