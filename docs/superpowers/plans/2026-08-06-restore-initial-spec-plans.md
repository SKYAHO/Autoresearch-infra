# 초기 Spec·Plan 원문 복구 구현 계획

> **For agentic workers:** 복구 대상은 Git 이력 원문이며, 임의 편집 없이 blob 동일성을 검증합니다.

**목표:** PR #72에서 삭제된 초기 spec 10개와 plan 10개를 동일 경로·동일 내용으로 복구한다.

**아키텍처:** 삭제 merge commit의 부모를 정본으로 삼아 문서 본문만 역적용하고, 모든 복구 파일 첫 줄에 현행 정본 우선 아카이브 배너를 둔다. 현재 운영 문서와 인프라 코드는 변경하지 않는다.

**Tech Stack:** Git, Markdown

## Global Constraints

- 원본 정본은 `305c98bef9ee772f2e6e18eb0bb035ce87afba37^`다.
- 각 복구 문서는 아카이브 배너 뒤의 본문이 원본과 byte 단위로 일치해야 한다.
- 시크릿·state·tfvars·Terraform·GCP 리소스는 변경하지 않는다.
- 현행 운영 절차는 `TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다.

---

### Task 1: 삭제된 초기 문서 원문 복구

**Files:**
- Modify: `docs/superpowers/specs/2026-07-03-*` 및 `2026-07-06~08-*` 10개
- Modify: `docs/superpowers/plans/2026-07-03-*` 및 `2026-07-06~08-*` 10개

- [ ] 부모 commit과 삭제 commit의 문서 경로를 비교해 정확히 20개인지 확인한다.
- [ ] 부모 commit의 각 본문을 동일 경로로 복구하고 현행 절차 우선 아카이브 배너를 추가한다.
- [ ] 새 복구 문서와 기존 문서를 포함해 파일 목록을 검토한다.

### Task 2: 무변형·형식 검증

**Files:**
- Verify: `docs/superpowers/specs/`
- Verify: `docs/superpowers/plans/`

- [ ] 각 복구 파일에서 아카이브 배너를 제외한 본문이 부모 commit의 같은 경로와 일치하는지 비교한다.
- [ ] `git diff --check`를 실행한다.
- [ ] 변경 범위에 Terraform, state, tfvars, credential이 없는지 확인한다.
