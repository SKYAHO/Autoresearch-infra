# dev proxy Cloud Run 구현 계획 (#27)

> Status: In Progress | Issue: #27 | Spec: `../specs/2026-07-07-proxy-cloud-run-design.md`

## 작업 순서

1. **Terraform 코드** (`terraform/envs/dev/`)
   - `cloud_run.tf` 신설: 런타임 SA(role 없음) + `google_cloud_run_v2_service` + invoker IAM(for_each)
   - `locals.tf`: `proxy_service_name`, `proxy_sa_name`, `proxy_image` 버전 태그 기본 경로,
     `required_services`에 `run.googleapis.com` 추가
   - `variables.tf`: `proxy_image`, `proxy_ingress`, `proxy_max_instances`,
     `proxy_cpu`, `proxy_memory`, `proxy_invoker_members`, `proxy_deletion_protection`
   - `outputs.tf`: `proxy_service_name`, `proxy_service_uri`, `proxy_sa_email`
   - `terraform.tfvars.example`: proxy 변수 예시
2. **문서**
   - `docs/TERRAFORM_DEV.md`: "dev proxy Cloud Run (#27)" 섹션 + 필수 API 표에 run 추가
3. **검증**
   - `terraform fmt -check -recursive` / `init -backend=false` / `validate`
   - `git diff --check`
   - CI plan에서 추가 리소스 확인 (SA 1 + service 1, invoker는 기본 0)
4. **PR**: Draft → 셀프 리뷰 → Ready (assignee `hyeongyu-data`, label `terraform`/`gcp`/`iam`/`cost`)

## 검증 체크리스트

- [ ] fmt/validate 통과
- [ ] plan: 2 to add (SA, service), 기존 리소스 변경 없음
- [ ] 서비스 스펙: port 8080, `GET /health` probe, min 0/max 1, internal ingress
- [ ] invoker 기본 빈 목록 → 아무도 호출 불가 상태 확인
- [ ] `docs/TERRAFORM_DEV.md` 갱신

## Apply 전 선행 조건 (머지 후)

1. `gcloud services enable run.googleapis.com --project=<project>`
2. 앱 저장소에서 proxy 이미지 빌드 → AR push (`proxy:dev-YYYYMMDD-N` 또는 digest)
3. `proxy_image`를 배포할 tag/digest로 맞춘 뒤 `terraform apply` (사용자 승인 후)
4. collector SA 확정 시: `proxy_invoker_members`에 추가 → apply
