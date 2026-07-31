# Training Snapshot Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 MLflow artifact 버킷에 immutable content-addressed training snapshot 계약과 최소 IAM·운영 절차를 추가한다.

**Architecture:** MLflow artifact 버킷에 Object Versioning을 활성화하고 `training-snapshots/` prefix의 live 객체에만 선택적 age lifecycle을 적용한다. 기존 Airflow batch GSA에 prefix 조건부 objectCreator/viewer를 부여하여 앱 #423이 create-if-absent와 hash/generation 검증을 수행할 수 있게 한다.

**Tech Stack:** Terraform Google provider, GCS IAM Conditions, GCS Object Versioning/Soft Delete, Markdown runbook.

## Global Constraints

- 새 GCS 버킷은 만들지 않고 Terraform 관리 MLflow artifact 버킷을 재사용한다.
- 실제 `terraform apply`는 별도 명시 승인 전 실행하지 않는다.
- IAM은 `airflow/autoresearch-batch`의 기존 GSA와 `training-snapshots/` prefix로 제한한다.
- snapshot 기본 retention은 `0`으로 age 삭제를 비활성화한다.
- secret, state, tfvars, service-account key를 커밋하지 않는다.

### Task 1: Snapshot bucket and IAM contract

**Files:**
- Modify: `terraform/envs/dev/mlflow.tf`
- Modify: `terraform/envs/dev/airflow.tf`
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/outputs.tf`
- Modify: `terraform/envs/dev/terraform.tfvars.example`

- [ ] MLflow bucket에 `versioning { enabled = true }`와 기본 비활성 dynamic lifecycle을 추가한다.
- [ ] `mlflow_training_snapshot_retention_days` 변수를 0 이상으로 검증한다.
- [ ] Airflow batch GSA에 GCS IAM condition으로 `training-snapshots/` prefix의 objectCreator/viewer를 추가한다.
- [ ] bucket 이름과 canonical prefix를 Terraform output으로 노출한다.

### Task 2: Design and operating documentation

**Files:**
- Modify: `terraform/envs/dev/README.md`
- Modify: `docs/MLFLOW_OPERATIONS_RUNBOOK.md`
- Modify: `docs/CHANGE_HISTORY.md`

- [ ] canonical URI, manifest 필드, create-if-absent 및 hash/generation 검증 절차를 기록한다.
- [ ] versioning, soft delete, retention 기본값, 비용 기준과 이전 generation 복구 절차를 기록한다.
- [ ] Terraform plan, 권한 거부, 중복 publish 검증 명령과 실제 apply 승인 경계를 기록한다.

### Task 3: Verification

**Files:**
- Verify: `terraform/envs/dev/*.tf`
- Verify: changed Markdown files

- [ ] `terraform -chdir=terraform/envs/dev fmt -check -recursive`를 실행한다.
- [ ] `terraform -chdir=terraform/envs/dev init -backend=false`와 `validate`를 실행한다.
- [ ] `git diff --check`와 변경 diff에서 bucket replace/destroy·권한 확대·secret 노출을 확인한다.
- [ ] 인증과 실제 tfvars가 없으면 live plan/apply를 실행하지 않았음을 기록한다.
