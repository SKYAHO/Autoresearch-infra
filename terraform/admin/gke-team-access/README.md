# GKE Team Access

This admin Terraform root manages human Google accounts that need `kubectl`
bootstrap access to the dev GKE cluster.

It is separated from `terraform/envs/dev` so pull request plans do not expose
personal email addresses or try to remove people when CI runs without local
tfvars.

## Usage

```bash
cd terraform/admin/gke-team-access
cp terraform.tfvars.example terraform.tfvars
# Fill terraform.tfvars with real Google accounts. Do not commit it.

terraform init
terraform plan
terraform apply
```

The role is granted at project level with `roles/container.clusterViewer`.
That is acceptable while `ar-infra-501607` has a single dev GKE cluster. If more
clusters are added to the project, narrow the binding with an IAM condition or
move cluster access into a dedicated project.

Removing an email from `team_member_emails` and applying removes only that IAM
member. Existing access tokens can remain valid until they expire, usually up to
about one hour.

Share the teammate-facing local setup steps from
[`docs/GKE_CLUSTER_ACCESS.md`](../../../docs/GKE_CLUSTER_ACCESS.md). Do not share
committed examples with real personal emails, public IPs, kubeconfig files, or
service account keys.
