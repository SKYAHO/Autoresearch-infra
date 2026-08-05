# 초기 Spec·Plan 원문 복구 설계

## 목적

PR #72에서 압축·삭제된 초기 인프라 설계와 구현 계획 20개를 Git 이력의 원문 그대로
복구한다. 과거 의사결정의 상세 근거를 다시 탐색 가능하게 하되, 현재 운영 절차와
Terraform 동작은 바꾸지 않는다.

## 범위와 비범위

- 범위: merge commit `305c98bef9ee772f2e6e18eb0bb035ce87afba37`의 부모 commit에 있던
  `docs/superpowers/specs/` 10개와 `docs/superpowers/plans/` 10개를 같은 경로로 복구한다.
- 범위: 복구 방법·검증·현행 운영 문서 우선 원칙을 이 spec과 plan에 기록한다.
- 비범위: Terraform, GCP 리소스, IAM, workflow, 현재 runbook과 `CHANGE_HISTORY.md`의
  내용 변경 및 과거 설계의 최신화.

## 설계 결정

원본을 해석하거나 현재 값에 맞게 고치지 않고 Git blob을 byte 단위로 복구한다. 과거
문서에는 당시의 리소스명·가정이 남아 있을 수 있으므로, 현행 작업은
`TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다. 이는 저장소의
`docs/superpowers/README.md` 정책과 양립한다.

## 검증과 롤백

복구 후 각 파일의 blob SHA를 삭제 직전 부모 commit과 비교하고 `git diff --check`를
실행한다. 롤백은 이 복구 PR의 문서 파일만 revert하면 되며, 인프라 상태나 시크릿에는
영향이 없다.
