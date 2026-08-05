# GKE DNS 기반 엔드포인트 구현 계획 (#45)

> Status: Done (PR #46 merged, 2026-07-08 apply 완료) | Issue: #45 | Spec: `../specs/2026-07-08-gke-dns-endpoint-design.md`

## 작업 순서

1. `terraform/envs/dev/gke.tf`: `control_plane_endpoints_config` 블록 추가
2. `terraform/envs/dev/outputs.tf`: `gke_dns_endpoint` output 추가
3. `terraform/admin/gke-team-access`: role `clusterViewer` → `container.viewer`
   (main.tf, variables.tf 설명, README)
4. 문서: `docs/GKE_CLUSTER_ACCESS.md`(접속 절차 `--dns-endpoint` 기본),
   `docs/ACCESS_STRATEGY.md`(1차 권장안 갱신), `docs/TERRAFORM_DEV.md`(GKE 표·kubectl 절차)
5. 검증: fmt / validate / `git diff --check`, CI plan 확인
6. Draft PR → 셀프 리뷰 → Ready

## 검증 체크리스트

- [x] fmt/validate 통과
- [x] dev plan: `google_container_cluster.dev` **in-place update 1건**(destroy/replace 없음)
- [x] gke-team-access plan: 팀원 수만큼 IAM binding 교체(clusterViewer 제거 + viewer 추가)
- [x] 문서 3종 + spec/plan 반영

## Apply 후 확인 (머지 후, 사용자 승인 하에)

1. `terraform -chdir=terraform/envs/dev apply` → `gke_dns_endpoint` output 확인
2. `terraform -chdir=terraform/admin/gke-team-access apply`
3. 팀원 1명이 IP 미등록 상태에서:
   `gcloud container clusters get-credentials ... --dns-endpoint` → `kubectl get nodes` 성공
4. IAM 없는 계정으로 접근 불가 확인
