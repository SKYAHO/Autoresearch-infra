# Airflow Kubernetes Targeted Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `airflow-k8s` Terraform root만 plan·승인·apply하는 workflow를 추가한다.

**Architecture:** `.github/workflows/airflow-k8s-apply.yml`이 OIDC/WIF, private GCS binary plan, summary masking, Environment approval을 단일 root에 적용한다. 기존 multi-root workflow는 변경하지 않는다.

**Tech Stack:** GitHub Actions, Terraform 1.13.5, GCP OIDC/WIF, GCS

## Global Constraints

- 대상 root는 정확히 `terraform/admin/airflow-k8s` 하나다.
- apply는 `airflow-k8s-apply` Environment 승인 뒤에만 실행한다.
- workflow dispatch 전에 required reviewers가 설정된 GitHub Environment
  `airflow-k8s-apply`가 존재해야 한다. workflow YAML의 `environment:` 선언은
  Environment 또는 protection을 생성할 수 없다.
- `AIRFLOW_INSTALLER_USER_EMAILS`만 기존 Secret에서 주입한다.
- 다른 admin root, 기존 admin apply SA 역할, Secret payload를 변경하지 않는다. 새
  workflow에는 기존 admin apply SA의 정확한 `workflow_ref` WIF member만 추가한다.

---

### Task 1: Targeted Apply Workflow

**Files:**
- Create: `.github/workflows/airflow-k8s-apply.yml`
- Test: workflow YAML and static contract checks

**Interfaces:**
- Consumes: `vars.WIF_PROVIDER_ID`, `vars.ADMIN_APPLY_SA_EMAIL`, `vars.GCP_PROJECT_ID`, `secrets.AIRFLOW_INSTALLER_USER_EMAILS`
- Produces: `workflow_dispatch` plan job and `airflow-k8s-apply` Environment-gated apply job

- [ ] **Step 1: Write a failing workflow contract check**

Run:
```bash
test -f .github/workflows/airflow-k8s-apply.yml
```
Expected: exit code 1.

- [ ] **Step 2: Create the workflow from the existing secure pattern**

Create a workflow that sets:
```yaml
name: airflow-k8s-apply
on:
  workflow_dispatch: {}
permissions:
  id-token: write
  contents: read
concurrency:
  group: airflow-k8s-apply
  cancel-in-progress: false
```

The plan job checks non-empty `AIRFLOW_INSTALLER_USER_EMAILS`, removes stale plans only from `gs://autoresearch-dev-tfstate/airflow-k8s-apply-plans/**`, runs `terraform init` and `terraform plan -out=tfplan.bin` only in `terraform/admin/airflow-k8s`, uploads `tfplan.bin` to `gs://autoresearch-dev-tfstate/airflow-k8s-apply-plans/${{ github.run_id }}.tfplan`, and publishes only masked resource headers and Plan summary. The apply job uses `environment: airflow-k8s-apply`, downloads that exact plan, applies it, and cleans it up with `if: always()`. The existing admin apply SA admits only `admin-apply.yml@refs/heads/main` and `airflow-k8s-apply.yml@refs/heads/main` through WIF principalSet members.

- [ ] **Step 3: Verify the workflow contract**

Run:
```bash
rg -n 'airflow-k8s|airflow-k8s-apply|AIRFLOW_INSTALLER_USER_EMAILS|tfplan.bin|environment:' .github/workflows/airflow-k8s-apply.yml
git diff --check
```
Expected: only `terraform/admin/airflow-k8s` appears as a Terraform root; apply has the named Environment.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/airflow-k8s-apply.yml
git commit -m "feat: Airflow Kubernetes 단일 root apply 추가"
```

### Task 2: Operations Documentation

**Files:**
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- Test: markdown command inspection

- [ ] **Step 1: Write a failing documentation check**

Run:
```bash
rg -n 'airflow-k8s-apply' docs/TEAM_OPERATIONS_RUNBOOK.md
```
Expected: exit code 1.

- [ ] **Step 2: Document the approval flow**

Add a short section stating that, after #387 merges, the first explicitly approved
`dev-apply` applies the exact `airflow-k8s-apply.yml@refs/heads/main` WIF allowlist
and observation-only VPA addon. Then `airflow-k8s-apply.yml` plans only
`terraform/admin/airflow-k8s`, requires `airflow-k8s-apply` Environment approval, and
uses the existing installer Secret to apply VPA RBAC. CRD/API/RBAC evidence is required
before Autoresearch-airflow deploys its VPA CR, and the addon does not mutate scheduler
Pods while no VPA CR exists.

- [ ] **Step 3: Verify and commit**

Run:
```bash
rg -n 'airflow-k8s-apply|airflow-k8s' docs/TEAM_OPERATIONS_RUNBOOK.md
git diff --check
```
Expected: command succeeds with no whitespace error.

```bash
git add docs/TEAM_OPERATIONS_RUNBOOK.md docs/superpowers/plans/2026-07-27-airflow-k8s-targeted-apply.md
git commit -m "docs: Airflow Kubernetes 단일 root apply 절차 추가"
```
