# admin-apply 전체 root 일괄 apply 구현 계획 (#312)

설계: `../specs/2026-07-23-admin-apply-all-roots-design.md`

## 변경 (코드, 이 PR)

1. `terraform/envs/dev/github_actions.tf`: apply SA에 `roles/resourcemanager.projectIamAdmin`
   추가(gke-team-access 프로젝트 IAM apply용).
2. `.github/workflows/admin-apply.yml`: `root` 입력 제거, 전 9개 root를 순차 plan
   (fail-fast, private GCS 저장) → Environment 승인 → 순차 apply. allowlist Secret
   guard 스텝, 삭제-위험 allowlist는 폴백 없음.
3. 문서: `TERRAFORM_DEV.md`, `argocd-k8s/README.md`(일괄로 갱신), spec/plan.

## 운영 적용 (apply 단계, 이 PR 이후 · 순서 중요)

1. **먼저 dev root apply**: apply SA projectIamAdmin 부여.
2. GitHub Secrets 설정(각 root allowlist 정본 값): `AUTORESEARCH_VIEWER_USER_EMAILS`,
   `AIRFLOW_INSTALLER_USER_EMAILS`, `MONITORING_PORT_FORWARD_USER_EMAILS`,
   `MLFLOW_VIEWER_USER_EMAILS`, `GKE_TEAM_MEMBER_EMAILS`, `TRAINING_IMAGE_AR_WRITER_EMAILS`
   (기존 `ARGOCD_ADMIN_USER_EMAILS`).
3. `admin-apply` 실행 → 전 root plan 요약 검토(특히 mlflow/SA-email override로 인한
   예상외 변화 없는지) → 승인 → apply.

## 검증 체크리스트

- [ ] `fmt/validate`(dev root), `actionlint` 통과
- [ ] (실행 후) 9개 root plan 요약이 root별로 노출, 하나 실패 시 전체 게이트
- [ ] (apply 후) 각 root 로컬 plan `No changes`(정본 일치)
- [ ] allowlist Secret 미설정 시 guard로 halt
- [ ] 이메일이 공개 로그·artifact에 미노출, GCS plan 정리

## 롤백

워크플로우를 단일 root/로컬 apply로 되돌리고 projectIamAdmin·Secrets 제거.
