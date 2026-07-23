# admin-apply 전체 root 일괄 CI apply 설계 (#312)

## 배경·목적

#307/#308 argocd-k8s 파일럿을 **전체 9개 admin root 일괄 apply**로 확장한다. 각
root의 민감 tfvars(팀 이메일 allowlist)를 GitHub Secrets 단일 원천으로 옮겨 #305류
사고를 전 root에서 차단한다.

## 대상·순서

`gke-team-access → autoresearch-k8s → airflow-k8s → monitoring-k8s → elastic-k8s →
vault-k8s → mlflow-k8s → argo-rollouts-k8s → argocd-k8s`. namespace/IAM 소유 root를
먼저, argocd는 다른 namespace를 참조하므로 마지막.

## 결정

- **일괄 apply**: `workflow_dispatch`(입력 없음) → plan job이 전 root를 순차 plan
  (요약 STEP_SUMMARY + plan을 private GCS로, 하나라도 실패 시 fail-fast) → apply job
  이 Environment 승인 후 전 root 순차 apply. 승인 1회로 전체 적용되므로 plan 요약을
  root별로 보여 리뷰어가 전수 검토한다.
- **projectIamAdmin 추가**: `gke-team-access`가 팀원 프로젝트 IAM(container.viewer,
  bastion, BigQuery)을 관리하므로 apply SA에 `roles/resourcemanager.projectIamAdmin`
  이 필요하다. 강한 권한 → repo@ref(`admin-apply.yml@main`) + Environment 승인 +
  전용 SA 3중 제한. 하드닝(gke-team-access 실제 role 집합만 허용하는 조건부 IAM)은 후속.
- **Secrets(단일 원천)**: `ARGOCD_ADMIN_USER_EMAILS`, `AUTORESEARCH_VIEWER_USER_EMAILS`,
  `AIRFLOW_INSTALLER_USER_EMAILS`, `MONITORING_PORT_FORWARD_USER_EMAILS`,
  `MLFLOW_VIEWER_USER_EMAILS`, `GKE_TEAM_MEMBER_EMAILS`, `TRAINING_IMAGE_AR_WRITER_EMAILS`,
  `ARGOCD_READONLY_USER_EMAILS`(optional).
- **삭제-위험 allowlist는 폴백 없음**: 빈 값이면 terraform이 halt하도록 `[]` 폴백을
  두지 않고, plan job에 guard 스텝을 둔다. optional(readonly, training_image_ar_writer)만 폴백.
- **#211**: plan/apply 원문을 파일 리다이렉트, 요약만 STEP_SUMMARY, plan 바이너리는
  private GCS로 전달(apply 후 삭제), 오류는 이메일 마스킹.

## 리스크·완화

- **최대 리스크**: apply SA가 projectIamAdmin 보유 + gke-team-access가 사람 IAM을 CI로
  변경 + 일괄 apply(승인 1회로 전체). 완화: repo@ref + Environment 승인 + root별 plan
  요약 전수 검토 + guard. 하드닝은 후속.
- **데이터 정합성 주의**: `mlflow-k8s`는 로컬 tfvars가 없어 현재 default([]) 상태일 수
  있으므로, Secret에 넣는 정본 allowlist가 라이브와 일치하는지 첫 plan에서 확인한다.
  `autoresearch-k8s`/`airflow-k8s`의 `*_service_account_email = ""` override는 CI에선
  default를 쓰므로 plan에서 변화 여부를 확인한다. plan 검토 게이트가 안전망이다.

## 롤백

워크플로우를 파일럿(단일 root) 또는 로컬 apply로 되돌리고, projectIamAdmin·Secrets를 제거한다.
