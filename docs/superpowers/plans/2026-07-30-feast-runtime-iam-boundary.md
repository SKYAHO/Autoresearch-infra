# Feast Runtime IAM Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate dev and prod Feast apply identities, GCS buckets, Kubernetes execution boundaries, and GitHub OIDC WIF trust without splitting the current Terraform environment root/state.

**Architecture:** Existing Feast registry/staging buckets remain the prod targets; new dev-only buckets replace the shared `dev/` prefixes. Dedicated dev/prod Feast apply GSAs and namespaces obtain only their environment's runtime permissions. New environment-specific WIF providers in the existing pool leave existing CI/provider consumers unchanged and let the app workflow select a provider through its GitHub Environment.

**Tech Stack:** Terraform 1.6+, hashicorp/google provider, hashicorp/kubernetes provider, GCP IAM/WIF, Cloud Storage, BigQuery, Memorystore Redis Cluster, GitHub Actions OIDC.

## Global Constraints

- Keep one GCP project and the existing `terraform/envs/dev` root/state; do not run `terraform apply`, state migration, destroy, or resource import.
- Preserve existing prod Feast registry/staging bucket names and objects; create only dev-specific buckets.
- Use resource-level IAM wherever supported; dev Feast apply must receive no Redis connection or Redis CA secret access.
- Keep existing generic GitHub WIF provider unchanged; scope new providers to `SKYAHO/Autoresearch`, an exact GitHub Environment, and the exact main-branch `feast-apply.yml` workflow.
- Do not commit tfvars, Terraform state, service-account credentials, GitHub secrets, or real project identifiers.
- Document required app-repository and GitHub Environment configuration without changing the `SKYAHO/Autoresearch` repository in this issue.

---

### Task 1: Add environment-specific Feast WIF providers

**Files:**
- Modify: `terraform/bootstrap/main.tf`
- Modify: `terraform/bootstrap/variables.tf`
- Modify: `terraform/bootstrap/outputs.tf`
- Modify: `docs/TERRAFORM_BOOTSTRAP.md`

**Interfaces:**
- Consumes: `var.project_id`, `var.allowed_github_repositories`, the existing `autoresearch-github` WIF pool, GitHub OIDC `repository`, `environment`, and `workflow_ref` claims.
- Produces: `github-feast-dev` and `github-feast-prod` WIF provider resource names for application GitHub Environment configuration.

- [ ] **Step 1: Add a static contract check before implementation**

Run:

```bash
rg -n 'github-feast-dev|github-feast-prod|assertion.environment' terraform/bootstrap
```

Expected: no matches, proving environment-specific Feast providers are absent.

- [ ] **Step 2: Add provider variables and resources**

Add a `feast_apply_github_repository` variable defaulting to `SKYAHO/Autoresearch`. Add `github-feast-dev` and `github-feast-prod` providers to the existing pool. Map `google.subject`, `attribute.repository`, `attribute.environment`, and `attribute.workflow_ref`; restrict the dev/prod provider condition to the application repository and its exact environment.

- [ ] **Step 3: Export and document provider names**

Add outputs for the two provider names. Update bootstrap documentation with the provider IDs, environment claim requirement, and warning that app Environment variables must use the matching provider.

- [ ] **Step 4: Verify the static contract**

Run:

```bash
rg -n 'github-feast-dev|github-feast-prod|assertion.environment' terraform/bootstrap
```

Expected: both providers map and validate the environment claim; both outputs exist.

### Task 2: Create dev Feast storage and split Feast apply IAM

**Files:**
- Modify: `terraform/envs/dev/locals.tf`
- Modify: `terraform/envs/dev/storage.tf`
- Modify: `terraform/envs/dev/github_actions.tf`
- Modify: `terraform/envs/dev/secret_manager.tf`
- Modify: `terraform/envs/dev/redis.tf`
- Modify: `terraform/envs/dev/code_artifacts.tf`
- Modify: `terraform/envs/dev/outputs.tf`

**Interfaces:**
- Consumes: prod Feast bucket resource IDs, prod/dev BigQuery dataset resource IDs, bootstrap WIF pool project number, and existing Redis cluster/CA secret IDs.
- Produces: dev registry/staging buckets, `feast_apply_dev` and `feast_apply_prod` GSA emails, and app-consumable provider/SA/path outputs.

- [ ] **Step 1: Add a static contract check before implementation**

Run:

```bash
rg -n 'google_service_account" "feast_apply"|feast_apply_.*redis|feast_dev_registry_path' terraform/envs/dev
```

Expected: one shared Feast apply SA, its Redis binding, and a shared-bucket dev registry path are present.

- [ ] **Step 2: Add dev-only registry and staging buckets**

Keep existing registry/staging resource addresses and names as prod. Add dev registry/staging resources with project-unique `-dev` names and the existing privacy, versioning, lifecycle, and label conventions. Change dev paths from shared `dev/` prefixes to the new dev bucket roots.

- [ ] **Step 3: Replace the shared Feast apply GSA**

Replace `feast_apply` with dev/prod service accounts. Bind each to its environment-specific WIF provider and exact `feast-apply.yml@refs/heads/main` workflow ref. Grant each SA only its matching registry/staging bucket permissions and dataset `metadataViewer` binding.

- [ ] **Step 4: Restrict Redis, CA secret, code artifact, and GKE metadata access**

Move Redis `dbConnectionUser` condition and Redis CA `secretAccessor` to the prod SA only. Give both environment SA identities the required code artifact read and `container.clusterViewer` access. Remove all references to the deleted shared SA.

- [ ] **Step 5: Add explicit outputs**

Export dev/prod Feast apply GSA emails, dev/prod registry paths, dev/prod staging locations, and the environment-specific WIF provider names required by the app repository.

- [ ] **Step 6: Verify the static contract**

Run:

```bash
rg -n 'feast_apply.*redis|feast_apply.*redis_server_ca|feast_apply_offline_store' terraform/envs/dev
```

Expected: only prod SA references appear for Redis and CA; each dataset IAM binding references exactly its matching environment SA.

### Task 3: Isolate Kubernetes Job namespaces and network paths

**Files:**
- Modify: `terraform/envs/dev/locals.tf`
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/admin/autoresearch-k8s/variables.tf`
- Modify: `terraform/admin/autoresearch-k8s/locals.tf`
- Modify: `terraform/admin/autoresearch-k8s/feast_apply.tf`
- Modify: `terraform/admin/autoresearch-k8s/outputs.tf`
- Modify: `terraform/admin/autoresearch-k8s/README.md`

**Interfaces:**
- Consumes: dev/prod Feast apply GSA email outputs, shared GKE cluster/Redis network inputs, and app workflow Job namespace/KSA values.
- Produces: `feast-apply-dev` and `feast-apply-prod` namespaces with environment-specific KSA annotations, RoleBindings, and egress policies.

- [ ] **Step 1: Add a static contract check before implementation**

Run:

```bash
rg -n 'feast_apply_k8s_namespace|feast_apply_gcp_service_account_email|redis_psc_subnet_cidr' terraform/admin/autoresearch-k8s
```

Expected: one shared namespace/GSA contract and one Feast apply Redis egress rule are present.

- [ ] **Step 2: Replace the singular namespace variables and locals with environment maps**

Define validated dev/prod namespace, KSA, and GSA email inputs. Derive an environment-keyed local map so the Kubernetes resources use `for_each` and no name is duplicated.

- [ ] **Step 3: Create environment-scoped namespace/KSA/RBAC resources**

Create one namespace and KSA per environment; each KSA annotation references only its matching GSA. Create a namespace-scoped Role and RoleBinding per environment so a dev GSA cannot create Jobs in the prod namespace.

- [ ] **Step 4: Split egress policies**

Keep DNS, GKE metadata, and HTTPS egress for both environments. Add Redis PSC discovery/data-node egress only when `each.key == "prod"`.

- [ ] **Step 5: Export and document the app Job contract**

Export the dev/prod namespace and KSA names. Update the admin README with the immutable rule that the GitHub Environment selects matching WIF provider, GSA, namespace, and KSA together.

- [ ] **Step 6: Verify the static contract**

Run:

```bash
rg -n 'feast-apply-dev|feast-apply-prod|Redis Cluster PSC' terraform/admin/autoresearch-k8s
```

Expected: both namespaces are defined and only the prod policy contains Redis PSC egress.

### Task 4: Update operational documentation and migration procedure

**Files:**
- Modify: `terraform/envs/dev/README.md`
- Modify: `docs/TERRAFORM_DEV.md`
- Modify: `docs/INFRASTRUCTURE_SUMMARY.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**
- Consumes: provider, GSA, bucket, dataset, namespace, and KSA outputs from Tasks 1–3.
- Produces: an ordered non-destructive rollout, GitHub Environment variable contract, verification checks, and rollback procedure.

- [ ] **Step 1: Add the GitHub Environment configuration contract**

Document `dev` and `prod` values for WIF provider, Feast apply SA, registry path, staging location, dataset, namespace, and KSA. Specify that production required reviewers and branch restrictions remain enabled.

- [ ] **Step 2: Add non-destructive rollout and rollback steps**

Document Terraform apply order, dev first-run verification, prod cutover without moving its registry object, IAM grant/revoke order, and rollback by restoring the prior app Environment values before deleting new dev-only resources.

- [ ] **Step 3: Record the durable architectural decision**

Add a concise CHANGE_HISTORY entry that records the environment-specific buckets, identities, and WIF boundary; explicitly state that Terraform root/state separation remains deferred.

- [ ] **Step 4: Verify documentation references**

Run:

```bash
rg -n 'feast-apply-dev|feast-apply-prod|github-feast-dev|github-feast-prod' terraform/envs/dev/README.md docs
```

Expected: all new identity, provider, bucket, and GitHub Environment contracts are documented.

### Task 5: Format, validate, and review the security diff

**Files:**
- Verify: `terraform/bootstrap/`
- Verify: `terraform/envs/dev/`
- Verify: `terraform/admin/autoresearch-k8s/`
- Verify: repository diff

**Interfaces:**
- Consumes: all implementation and documentation changes from Tasks 1–4.
- Produces: reproducible local validation evidence and an IAM-focused peer-review report.

- [ ] **Step 1: Format Terraform**

Run:

```bash
terraform -chdir=terraform/bootstrap fmt -check -recursive
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
```

Expected: all commands exit 0 without formatting diffs.

- [ ] **Step 2: Initialize and validate each Terraform root without a backend**

Run:

```bash
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/admin/autoresearch-k8s init -backend=false
terraform -chdir=terraform/admin/autoresearch-k8s validate
```

Expected: all roots initialize and validate successfully. If Terraform is unavailable, record that environmental blocker and do not claim validation passed.

- [ ] **Step 3: Inspect diff safety**

Run:

```bash
git diff --check
git diff -- terraform/bootstrap terraform/envs/dev terraform/admin/autoresearch-k8s docs
```

Expected: no whitespace errors, no secret/state/tfvars files, no prod bucket replacement or deletion, and no dev SA Redis/CA IAM binding.

- [ ] **Step 4: Request an independent IAM peer review**

Give a reviewer the issue requirements, the design document, the diff, and the validation output. Resolve all Critical and Important findings before handoff.
