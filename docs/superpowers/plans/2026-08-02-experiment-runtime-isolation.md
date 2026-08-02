# 실험 runtime 격리 실행 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** paired Feast 실험 전용 runtime identity·Kubernetes 격리·최소 IAM·운영 계약을 만들고 Job 생성 권한은 fail-closed로 유지한다.

**Architecture:** dev root는 GSA·Workload Identity·조건부 GCS IAM·dev BigQuery read를, admin root는 namespace/KSA·observer RBAC·default-deny network·quota를 관리한다.

**Tech Stack:** Terraform, GCP IAM/GCS/BigQuery, GKE Workload Identity, Kubernetes NetworkPolicy/ResourceQuota/LimitRange.

## Global Constraints

- prod Feast registry·`feast_offline_store`·Redis·CA Secret·Cloud SQL·MLflow·외부 HTTPS egress를 추가하지 않는다.
- runtime GSA에 broad IAM, `objectAdmin`, 프로젝트 수준 BigQuery data role을 부여하지 않는다.
- IAM은 `experiments/`와 `code/` root까지만 강제하며, comparison/source SHA 검증은 후속 Airflow 템플릿 계약이다.
- Airflow와 runtime KSA 모두 `jobs.create` 권한이 없고 output은 `job_creation_enabled=false`를 반환한다.
- apply/destroy, state 조작, schema migration, backfill은 수행하지 않는다.

### Task 1: dev root runtime GSA와 최소 IAM

**Files:** Create `terraform/envs/dev/experiment_runtime.tf`; modify `terraform/envs/dev/locals.tf`, `variables.tf`, `terraform.tfvars.example`, `outputs.tf`, `README.md`.

- [ ] `locals.tf`에 `${local.resource_prefix}-exp-runtime`, `experiments/`, `code/`, `${var.project_id}.svc.id.goog[${var.experiment_runtime_k8s_namespace}/${var.experiment_runtime_k8s_service_account}]`를 정의하고, namespace/KSA 입력 기본값과 Kubernetes 이름 검증을 추가한다.
- [ ] `experiment_runtime.tf`에 `google_service_account.experiment_runtime`과 `google_service_account_iam_member.experiment_runtime_wi`를 만들고 WI member를 위 principal 하나로 한정한다.
- [ ] dev registry/staging·MLflow artifact에는 `experiments/` object prefix IAM condition을, code artifacts에는 `code/` prefix viewer condition을 둔다. staging/artifact는 creator+viewer, registry/code는 viewer만 둔다. dataset 수준 dataViewer와 프로젝트 수준 jobUser/readSessionUser만 추가한다.
- [ ] `experiment_runtime_contract` output에 GSA, WI principal, registry/staging/artifact/code URI root, dev dataset, `job_creation_enabled=false`만 넣고 README에 production/Redis/Secret Manager 권한 부재와 prefix 한계를 기록한다.
- [ ] `terraform -chdir=terraform/envs/dev fmt -check -recursive`, `init -backend=false -input=false`, `validate` 성공 후 `feat: 실험 runtime dev IAM 경계 추가`로 커밋한다.

### Task 2: admin root Kubernetes 격리 경계

**Files:** Create `terraform/admin/autoresearch-k8s/experiment_runtime.tf`; modify `terraform/admin/autoresearch-k8s/locals.tf`, `variables.tf`, `terraform.tfvars.example`, `outputs.tf`, `README.md`.

- [ ] `experiment-runtime` namespace에 PSA `restricted` enforce/audit/warn을 적용하고 KSA annotation으로 `${resource_prefix}-exp-runtime` GSA를 연결한다. runtime/Airflow GSA override와 `private_googleapis_cidr=199.36.153.8/30`에 형식 검증을 둔다.
- [ ] ResourceQuota에는 jobs/pods 4, requests CPU/memory 4/8Gi, limits CPU/memory 8/16Gi를 둔다. LimitRange의 request는 1 CPU/2Gi, default/max는 2 CPU/4Gi다.
- [ ] Airflow GSA observer Role은 jobs/pods get/list/watch와 pods/log get만 가진다. `create`, `delete`, `patch`, `update`, secrets, exec, attach, port-forward를 넣지 않으며 runtime KSA에는 RoleBinding을 만들지 않는다.
- [ ] ingress는 전면 차단하고 egress는 DNS, metadata `169.254.169.254:80`·`169.254.169.252:987/988`, `199.36.153.8/30:443`만 허용한다. `0.0.0.0/0`, Redis, Cloud SQL, MLflow는 넣지 않는다.
- [ ] `experiment_runtime_kubernetes_contract`에 namespace/KSA/GSA, observer role, policies, quota/limit, CIDR, `job_creation_enabled=false`만 넣는다. README에는 quota가 node capacity를 보장하지 않고 ValidatingAdmissionPolicy 전에는 create를 켜지 않는다고 기록한다.
- [ ] `terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive`, `init -backend=false -input=false`, `validate` 성공 후 `feat: 실험 runtime Kubernetes 격리 추가`로 커밋한다.

### Task 3: 운영 문서와 음성 검증 계약

**Files:** Create `docs/runbooks/2026-08-02-paired-feast-experiment-runtime.md`; modify `docs/TERRAFORM_DEV.md`, `docs/INFRASTRUCTURE_SUMMARY.md`, `docs/CHANGE_HISTORY.md`.

- [ ] Airflow에 전달할 namespace/KSA, dev URI root, dataset, `CODE_ARCHIVE_SHA`, comparison prefix를 기록하고 `job_creation_enabled=false`이면 Job 생성 시도를 중단해야 한다고 명시한다.
- [ ] prod registry/BQ/Redis CA 403, external HTTPS 부재, GKE allocatable/autoscaler, BigQuery maximum bytes billed와 partition filter를 apply gate로 문서화한다.
- [ ] TTL·deadline·rollback은 후속 활성화 조건으로 분리하고, rollback은 Airflow trigger 중지 후 approved apply로 새 IAM/KSA/namespace만 제거한다고 기록한다.
- [ ] `git diff --check` 통과 후 `docs: 실험 runtime 운영 계약 추가`로 커밋한다.

### Task 4: 전체 보안 검토와 Draft PR 준비

**Files:** Review Tasks 1-3과 `.github/PULL_REQUEST_TEMPLATE.md`.

- [ ] 두 Terraform root의 `fmt -check`, `init -backend=false -input=false`, `validate`와 `git diff --check`를 실행한다.
- [ ] `git diff origin/main...HEAD -- terraform/envs/dev terraform/admin/autoresearch-k8s`에서 `roles/owner`, `roles/editor`, `objectAdmin`, `0.0.0.0/0`, `secretAccessor`, `jobs.create`가 새로 생기지 않았는지 확인한다.
- [ ] PR 템플릿 모든 section에 `Closes #485`, dev/`asia-northeast3`, direct resource cost 없음, Job create disabled, apply 미실행, IAM·rollback 검토 결과를 채운다. push와 Draft PR 생성은 사용자 확인 뒤에만 수행한다.
