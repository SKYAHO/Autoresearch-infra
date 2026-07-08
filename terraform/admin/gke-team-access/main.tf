# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "user:${each.value}"
}
