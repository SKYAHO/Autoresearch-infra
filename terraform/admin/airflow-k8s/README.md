# Airflow Kubernetes Boundary

This admin Terraform root manages the Kubernetes-side Airflow installation
boundary in the dev GKE cluster:

- `airflow` namespace
- Airflow Kubernetes service account with Workload Identity annotation
- namespace-scoped Role/RoleBinding for Airflow components
- optional namespace-scoped installer admin RoleBindings
- ResourceQuota, LimitRange, and NetworkPolicy

It is separated from `terraform/envs/dev` because the GitHub Actions Terraform
plan runner is not in `master_authorized_networks`. Keeping Kubernetes resources
out of the dev root prevents routine PR plans from needing direct access to the
GKE API server.

## Usage

```bash
cd terraform/admin/airflow-k8s
cp terraform.tfvars.example terraform.tfvars
# Fill terraform.tfvars with real values. Do not commit it.

terraform init
terraform plan
terraform apply
```

Run this from an operator network already allowed by the GKE
`master_authorized_networks` setting. The active Google account also needs
Kubernetes authorization to create namespace-scoped resources.

`installer_user_emails` grants each listed Google account the Kubernetes
`admin` ClusterRole within only the `airflow` namespace. Removing an email and
applying removes that RoleBinding.

The matching Google Cloud resources, including the Airflow GCP service account
and IAM binding for Workload Identity, are managed by `terraform/envs/dev`.

## Initial Apply Note

On 2026-07-08 the `airflow` namespace already existed in the cluster. It was
imported into this root instead of being deleted and recreated:

```bash
terraform import kubernetes_namespace_v1.airflow airflow
```

After the import, the admin root applied the remaining service account, RBAC,
quota, limit range, and network policy resources. The final plan reported no
changes.
