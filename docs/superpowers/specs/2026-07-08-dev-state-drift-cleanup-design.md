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
- an extra GKE `master_authorized_networks` CIDR not present in the current
  managed input (`<unmanaged-extra-operator-ip>/32`)

## Decision

Treat all listed resources as cleanup targets, not resources to restore into
the dev root.

Rationale:

- No matching Terraform configuration exists on `main`.
- Git history does not show these resources as an intended merged design.
- The Cloud Build IAM bindings grant write/logging/bucket permissions to the
  default compute service account without a current workflow owner.
- Current owner checks before cleanup:
  - repository search found no Cloud Build trigger, Cloud Deploy pipeline, or
    default compute service account owner in `.github/`, `terraform/`, or
    `docs/`;
  - `gcloud builds triggers list --project ar-infra-501607` returned no
    triggers;
  - Cloud Deploy API is disabled in `ar-infra-501607`, so no Cloud Deploy
    delivery pipeline can currently depend on the removed default compute
    service account binding;
  - GKE nodes use the dedicated `autoresearch-dev-gke-nodes` service account,
    not the project default compute service account.
- The `airflow-dev` node pool creates ongoing GKE cost and is superseded by the
  #32 direction: create an Airflow installation boundary, not a dedicated legacy
  node pool.
- The `gke_app_airflow_batch_wi` binding lets an Airflow namespace principal
  impersonate the application GCP service account. #32 uses a dedicated Airflow
  service account instead.
- `MASTER_AUTHORIZED_NETWORKS` currently contains only the managed operator
  CIDR (`<managed-operator-ip>/32`); the extra
  `<unmanaged-extra-operator-ip>/32` entry is unmanaged network access.
- The exact source of the extra CIDR is not provable from Terraform state alone.
  It may have come from a previous local tfvars apply or a manual console edit.
  The cleanup criterion is that the CIDR is not present in the current managed
  input and has no documented owner.

## Security Notes

- Do not remove state only. Leaving unmanaged IAM grants or node pools in GCP
  would hide security and cost exposure from Terraform.
- Use a targeted Terraform plan/apply only for the drift cleanup. Do not mix
  this with unrelated resource changes.
- Do not commit real operator IPs from local tfvars or plan output. Use
  placeholders in docs and PR text.
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
