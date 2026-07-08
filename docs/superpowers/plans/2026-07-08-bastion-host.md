# dev Bastion Host 구현 계획 (#47)

> Status: In Progress | Issue: #47 | Spec: `../specs/2026-07-08-bastion-host-design.md`

## 작업 순서

1. `terraform/envs/dev/bastion.tf`: `google_compute_instance` (SA attach 없음)
   (e2-micro, 외부 IP 없음, OS Login, Shielded, `ssh-iap` 태그, `bastion_enabled` count)
2. `locals.tf`(`bastion_name`), `variables.tf`(+4), `outputs.tf`(+2), `terraform.tfvars.example`
3. `terraform/admin/gke-team-access/main.tf`: 팀원 IAM 3종 추가
   (`iap.tunnelResourceAccessor`, `compute.osLogin`, `compute.viewer`)
4. 문서: `docs/TERRAFORM_DEV.md` Bastion 섹션(사용법 3종: SSH/-L/-D),
   `docs/ACCESS_STRATEGY.md` 상태 갱신
5. 검증: fmt/validate(양쪽 root), `git diff --check`, CI plan 확인
6. Draft PR → 셀프 리뷰 → Ready

## 검증 체크리스트

- [ ] fmt/validate 통과 (envs/dev + admin/gke-team-access)
- [ ] dev plan: 1 to add (instance), 기존 리소스 변경 없음
- [ ] gke-team-access plan: 팀원 수 × 3 binding 추가
- [ ] 외부 IP 미보유(access_config 없음) 확인
- [ ] 문서 갱신

## Apply 후 확인 (머지 후, 사용자 승인 하에)

1. dev root apply → bastion 생성 확인
2. gke-team-access apply → 팀원 IAM 반영
3. 팀원 1명: `gcloud compute ssh autoresearch-dev-bastion --tunnel-through-iap` 성공
4. bastion에서 VPC 내부 IP(예: Cloud SQL private IP:5432) 도달 확인 (`nc -vz`)
5. #48(ILB+DNS) 완료 후 브라우저 경로 종단 검증
