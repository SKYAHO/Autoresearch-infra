# 작업 중 Spec / Plan

이 폴더는 진행 중인 비자명한 인프라 변경의 spec/plan을 임시로 두는 공간이다.

새 GCP 리소스, IAM/네트워크 변경, backend 마이그레이션, workflow 권한 변경처럼
리뷰 전에 설계와 적용 순서를 분리해야 하는 작업에서 사용한다.

권장 파일명:

- `specs/YYYY-MM-DD-<slug>-design.md`
- `plans/YYYY-MM-DD-<slug>.md`

작업이 merge되고 운영 문서가 최신화되면, 장기 보존이 필요한 핵심 결정만
[`../CHANGE_HISTORY.md`](../CHANGE_HISTORY.md)에 옮긴다. 현재 운영자가 따라야 하는
절차는 spec/plan이 아니라 [`../TEAM_OPERATIONS_RUNBOOK.md`](../TEAM_OPERATIONS_RUNBOOK.md)
또는 [`../TERRAFORM_DEV.md`](../TERRAFORM_DEV.md)에 유지한다.
