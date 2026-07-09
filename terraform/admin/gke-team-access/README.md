# GKE 팀 접근 권한

이 admin Terraform root는 dev GKE 클러스터에 `kubectl`로 초기 접근해야 하는
사람 Google 계정을 관리합니다.

개인 이메일 주소가 PR plan 댓글에 노출되거나, CI가 로컬 tfvars 없이 실행될 때
사람 계정을 제거하려 시도하지 않도록 `terraform/envs/dev`와 분리되어 있습니다.

## 사용법

```bash
cd terraform/admin/gke-team-access
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 Google 계정을 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

권한은 프로젝트 수준 `roles/container.viewer`로 부여합니다(#45: DNS 엔드포인트
접속에 필요한 `container.clusters.connect` 포함). `ar-infra-501607`에 dev GKE
클러스터가 하나뿐인 동안에는 허용 가능한 범위입니다. 프로젝트에 클러스터가 더
추가되면 IAM condition으로 binding 범위를 좁히거나 클러스터 접근을 전용
프로젝트로 분리합니다.

`team_member_emails`에서 이메일을 제거하고 apply하면 해당 IAM member만 제거됩니다.
이미 발급된 access token은 만료될 때까지, 보통 최대 약 1시간 동안 유효할 수
있습니다.

팀원에게는
[`docs/TEAM_OPERATIONS_RUNBOOK.md`](../../../docs/TEAM_OPERATIONS_RUNBOOK.md)의
로컬 설정 절차를 공유합니다. 실제 공인 IP, kubeconfig 파일, service account key가
들어간 예시 파일은 공유하거나 커밋하지 않습니다.
