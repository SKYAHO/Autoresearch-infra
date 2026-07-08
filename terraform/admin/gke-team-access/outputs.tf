output "managed_member_count" {
  description = "Number of team Google accounts managed by this admin root."
  value       = length(var.team_member_emails)
}
