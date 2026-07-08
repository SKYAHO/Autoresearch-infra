# dev GKE Worker Node Sizing Design

## Issue

Closes #41.

## Context

The dev GKE cluster was originally created as a minimum-cost baseline with an
`e2-small` worker node pool. The next infrastructure step is to provide enough
capacity for Kubernetes workload validation and the future Airflow installation
boundary, while keeping the control plane managed by GKE.

Requested target:

- "master node": 2 vCPU / 8 GB
- worker node: 4 vCPU / 16 GB

GKE Standard does not expose a Terraform setting to choose control plane CPU or
memory. The GKE control plane is managed by Google. Therefore this issue only
changes the worker node machine type.

## Decision

Use `e2-standard-4` for the dev GKE worker node pool.

Rationale:

- `e2-standard-4` matches the requested worker capacity target: 4 vCPU and
  16 GB memory.
- The existing node pool, service accounts, Workload Identity, private nodes,
  Cloud NAT, disk size, and autoscaling boundaries stay unchanged.
- IAM does not need to expand for a machine type change.
- Keeping autoscaling at min 1 / max 2 preserves the current operational
  pattern while increasing per-node capacity.

## Impact

- Cost increases versus `e2-small`; confirm current pricing before apply.
- Terraform may replace or roll the GKE node pool depending on provider/GKE
  behavior. Review plan output before apply.
- Workloads running on the node pool can be rescheduled during the update.
- No secrets, service account keys, state files, or real tfvars values are
  required in the repository.

## Rollback

If the increased size is not needed, change `gke_machine_type` back to
`e2-small`, update docs, run plan, and apply after confirming the node pool
impact.
