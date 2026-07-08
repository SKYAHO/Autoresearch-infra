# dev Terraform State Drift Cleanup Design

## Context

Issue #39 tracks unrelated Terraform plan output in `terraform/envs/dev`.
After PR #34 moved human GKE access IAM into `terraform/admin/gke-team-access`,
the dev root still planned changes that were not present in the current
configuration.

Observed drift:

- `google_artifact_registry_repository_iam_member.cloud_build_compute_ar_writer`
- `google_project_iam_member.cloud_build_compute_logging`
- `google_storage_bucket_iam_member.cloud_build_compute_bucket_object_viewer`
- `google_container_node_pool.airflow`
- `google_service_account_iam_member.gke_app_airflow_batch_wi`
- an extra GKE `master_authorized_networks` CIDR, `222.237.245.219/32`

## Decision

Treat all listed resources as cleanup targets, not resources to restore into
the dev root.

Rationale:

- No matching Terraform configuration exists on `main`.
- Git history does not show these resources as an intended merged design.
- The Cloud Build IAM bindings grant write/logging/bucket permissions to the
  default compute service account without a current workflow owner.
- The `airflow-dev` node pool creates ongoing GKE cost and is superseded by the
  #32 direction: create an Airflow installation boundary, not a dedicated legacy
  node pool.
- The `gke_app_airflow_batch_wi` binding lets an Airflow namespace principal
  impersonate the application GCP service account. #32 uses a dedicated Airflow
  service account instead.
- `MASTER_AUTHORIZED_NETWORKS` currently contains only `222.108.125.33/32`; the
  extra `222.237.245.219/32` entry is unmanaged network access.

## Security Notes

- Do not remove state only. Leaving unmanaged IAM grants or node pools in GCP
  would hide security and cost exposure from Terraform.
- Use a targeted Terraform plan/apply only for the drift cleanup. Do not mix
  this with unrelated resource changes.
- Confirm the final full `terraform/envs/dev plan` no longer contains unrelated
  destroy or replace actions.

## Rollback

If any cleanup is found to be required later:

- Cloud Build AR writer: reintroduce an explicitly scoped repository IAM member
  in Terraform and re-apply.
- Cloud Build logging: reintroduce project-level `roles/logging.logWriter` only
  if a Cloud Build workflow owner is documented.
- Cloud Build bucket viewer: reintroduce bucket-level object viewer only if the
  default Cloud Build bucket is still required.
- `airflow-dev` node pool: recreate a node pool through a dedicated Terraform
  resource or the future #32 Airflow path.
- `gke_app_airflow_batch_wi`: prefer the #32 dedicated Airflow GCP service
  account. Regrant app SA impersonation only with a documented need.
- Extra master authorized network: add the CIDR back through
  `MASTER_AUTHORIZED_NETWORKS`/local tfvars and document the owner.
