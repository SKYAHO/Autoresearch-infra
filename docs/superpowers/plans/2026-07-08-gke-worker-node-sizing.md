# dev GKE Worker Node Sizing Plan

## Issue

Closes #41.

## Scope

- Update the dev GKE worker node machine type from `e2-small` to
  `e2-standard-4`.
- Keep GKE control plane sizing out of scope because GKE manages it.
- Keep node autoscaling min/max, disk, IAM, network, and Workload Identity
  unchanged.
- Update current operating docs and historical #5 notes so the new baseline is
  visible.

## Implementation

- `terraform/envs/dev/variables.tf`
  - Change `gke_machine_type` default to `e2-standard-4`.
  - Update the variable description to document the 4 vCPU / 16 GB target.
- `terraform/envs/dev/terraform.tfvars.example`
  - Change the example value to `e2-standard-4`.
- Local only: `terraform/envs/dev/terraform.tfvars`
  - Change the ignored local value to `e2-standard-4` for plan/apply
    verification.
- Docs
  - Update `docs/TERRAFORM_DEV.md`.
  - Add this plan and the matching design spec.
  - Mark the old #5 GKE design/plan as superseded for machine sizing.

## Verification Checklist

- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive -no-color`
      passes
- [x] `terraform -chdir=terraform/envs/dev validate -no-color` passes
- [x] `terraform -chdir=terraform/envs/dev plan -no-color -input=false`
      reviewed for node pool replacement or update impact
- [x] `git diff --check` passes
- [x] No secret, state, plan, service account key, or real tfvars values are
      committed

## Apply Notes

Apply only after reviewing the plan output with the user because a node pool
machine type change can disrupt running workloads.

Latest reviewed plan:

- `0 to add`, `1 to change`, `0 to destroy`
- plan refreshed the already-applied remote `dev-default` node pool state
- `google_container_node_pool.dev` updates in-place at the Terraform resource
  level
- `node_config.machine_type`: `e2-small` -> `e2-standard-4`

Operational impact:

- GKE may recreate or roll the underlying node VM even though Terraform reports
  no node pool resource destroy.
- With a single node pool and min 1 node, Pods can be evicted and rescheduled;
  if no suitable node is temporarily available, Pods can remain Pending or
  become unavailable.
- Apply before Airflow is installed when possible. If workloads already run on
  the cluster, coordinate a maintenance window or add spare capacity before the
  change.
