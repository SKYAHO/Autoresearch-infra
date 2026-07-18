output "managed_member_count" {
  description = "Number of team Google accounts managed by this admin root."
  value       = length(var.team_member_emails)
}

output "training_image_ar_writer_emails" {
  description = "임시(#256) autoresearch-dev-docker 저장소 범위 AR writer를 받은 계정. 비어 있으면 부여 없음."
  value       = sort(tolist(var.training_image_ar_writer_emails))
}
