# dev Terraform State Drift Cleanup Plan

## Issue

Closes #39.

## Scope

- Decide whether the drift resources are keep/delete targets.
- Document the security and rollback reasoning.
- Apply only the drift cleanup targets.
- Verify that the full dev Terraform plan no longer contains unrelated destroy
  actions.

## Targeted Cleanup

Terraform targets:

- `google_artifact_registry_repository_iam_member.cloud_build_compute_ar_writer`
- `google_project_iam_member.cloud_build_compute_logging`
- `google_storage_bucket_iam_member.cloud_build_compute_bucket_object_viewer`
- `google_container_node_pool.airflow`
- `google_service_account_iam_member.gke_app_airflow_batch_wi`
- `google_container_cluster.dev`

Expected plan:

- `5 destroy`
- `1 update in-place`
- `0 add`

## Apply Result

- Targeted cleanup plan reviewed: `0 add`, `1 change`, `5 destroy`.
- Targeted cleanup apply completed for the drift IAM bindings, legacy
  `airflow-dev` node pool, legacy Airflow Workload Identity binding, and the
  unmanaged GKE master authorized network CIDR.
- A follow-up full apply saved only stale Terraform output changes; it reported
  `0 added`, `0 changed`, `0 destroyed`.
- Final full plan result: `No changes. Your infrastructure matches the
  configuration.`

## Verification Checklist

- [x] Targeted plan reviewed before apply
- [x] Targeted apply completed
- [x] Full `terraform -chdir=terraform/envs/dev plan -no-color -input=false`
      has no unrelated destroy/replace actions
- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive -no-color`
      passes
- [x] `git diff --check` passes
- [x] No secret, state, plan, or real tfvars values are committed
