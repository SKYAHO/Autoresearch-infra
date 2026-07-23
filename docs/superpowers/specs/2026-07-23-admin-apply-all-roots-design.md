# admin-apply 전체 root 일괄 CI apply 설계 (#312)

## 배경·목적

#307/#308 argocd-k8s 파일럿을 **전체 9개 admin root 일괄 apply**로 확장한다. 각
root의 민감 tfvars(팀 이메일 allowlist)를 GitHub Secrets 단일 원천으로 옮겨 #305류
사고를 전 root에서 차단한다.

## 대상·순서

`autoresearch-k8s → airflow-k8s → monitoring-k8s → elastic-k8s → vault-k8s →
mlflow-k8s → argo-rollouts-k8s → argocd-k8s`(K8s admin root 8개). namespace 소유
root를 먼저, argocd는 다른 namespace를 참조하므로 마지막.

> **#314 정정**: 첫 실행에서 `gke-team-access`는 프로젝트 IAM 외에 BigQuery
> dataset·Artifact Registry repo IAM까지 관리해 apply SA에 `bigquery.admin` +
> `artifactregistry.admin`까지 필요한 과도한 escalation임이 드러났다. 사람 IAM은
> 로컬 break-glass로 유지하고 CI 대상에서 제외했다. apply SA의 projectIamAdmin도 회수.

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

## 운영 주의

- **부분 적용(fail-fast)**: apply는 root별 독립 state를 순차 적용하므로, 중간 root
  실패 시 앞 root는 반영·커밋되고 뒤 root는 미적용인 부분 상태로 종료된다. admin root는
  서로 독립(다른 namespace/IAM)이라 cross-root 비정합은 없고, 각 root state는 내부
  정합적이다(argocd는 마지막이라 앞 root 미적용 영향 없음). **복구 = 원인 수정 후
  워크플로우 재실행**(재-plan에서 이미 적용된 root는 No changes, 실패했던 root만 적용).
- **stale plan은 안전 실패**: 승인~apply 사이 라이브 state가 바뀌면 저장된
  `tfplan.bin`이 stale이 되고 `terraform apply <plan>`이 오류로 중단한다(잘못된 계획을
  적용하지 않음). 재실행 필요.
- **human-IAM(gke-team-access) 검증**: 승인자는 `GKE_TEAM_MEMBER_EMAILS` 등 Secret을
  스스로 설정하므로 의도한 대상을 안다. gke-team-access plan은 정상 상태에서 No changes여야
  하며, Secret을 방금 바꿨다면 변경 수(생성/삭제될 `google_project_iam_member` 개수)가
  의도와 일치하는지 요약으로 교차 확인한다. 예상외 변경이 보이면 승인하지 말고 로컬에서
  전체 plan을 비공개로 확인한다(#211상 이메일 원문은 공개 로그에 노출하지 않으므로).
- **plan job은 read-only**: projectIamAdmin을 가진 apply SA가 plan job(승인 게이트 없음)
  에서 실행되지만 plan은 상태를 변경하지 않는다. IAM 변경은 apply job(Environment 승인)
  에서만 일어나고, apply가 무엇을 하는지는 main의 terraform 코드(PR 리뷰)가 정한다. self-
  escalation은 악의적 코드 변경(main PR 리뷰)과 apply 승인 둘 다를 통과해야 하므로 차단된다.

## 롤백

워크플로우를 파일럿(단일 root) 또는 로컬 apply로 되돌리고, projectIamAdmin·Secrets를 제거한다.
