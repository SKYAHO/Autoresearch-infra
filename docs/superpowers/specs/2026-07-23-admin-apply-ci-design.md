# admin root CI apply (gated) 설계 (#307)

## 배경·목적

admin root(`terraform/admin/*-k8s`) apply가 각 운영자의 **로컬 gitignored
tfvars**에 의존한다. 팀원마다 값이 달라 사고가 난다 — #305: `argocd-k8s`를
`argocd_admin_user_emails` 없이 apply하면 `policy.csv`가 삭제되고 `policy.default=""`
와 결합해 **전원 접근 불가**. 민감 tfvars를 GitHub Secrets 단일 원천으로 옮기고
apply를 gated 워크플로우로 이관해 누가 하든 동일 결과를 보장한다. `argocd-k8s`
파일럿.

## 결정

- **트리거**: `workflow_dispatch`(수동) + `root` 입력. 자동-on-merge는 cluster
  변경 자동화라 dev엔 과감 → 수동.
- **승인 게이트**: plan job(즉시) → apply job(`environment: admin-apply`,
  required reviewers 승인). 리뷰어가 plan 출력을 보고 승인 → apply. CLAUDE.md
  "apply는 사람이 확인" 원칙 유지.
- **민감 tfvars**: `argocd_admin_user_emails` 등을 GitHub **Secrets**(JSON 리스트)로.
  `TF_VAR_*` 주입. Secrets는 로그·설정 UI에서 마스킹. 이메일 노출 최소화.
- **인증**: 전용 apply SA(`autoresearch-dev-admin-apply`). WIF binding을
  `admin-apply.yml@main` workflow_ref로 제한(application_pusher와 동일 패턴).
- **K8s 권한**: `argocd-k8s`가 CRD/ClusterRole/ClusterRoleBinding을 설치하므로
  cluster-admin이 불가피. GKE가 `roles/container.admin`에 cluster-admin RBAC를
  자동 매핑하므로 이를 부여(별도 ClusterRoleBinding 불필요, 자기완결적).
- **K8s Secret payload는 CI 밖**: OAuth client secret(`argocd-google-oidc` 등)은
  operator가 별도 주입한다(terraform·CI가 관리 안 함). CI는 cm/RBAC/deployment만 apply.
- **로컬 apply는 break-glass**로 유지. GCS backend lock이 CI/로컬 동시성을 막는다.

## 리스크·완화

- **최대 리스크 = apply SA의 권한**(container.admin = GKE 제어 + K8s cluster-admin).
  완화 3중: (1) 전용 SA, (2) `admin-apply.yml@main` repo/workflow ref 제한(임의
  브랜치·workflow 가장 차단), (3) Environment required reviewers 승인.
- **하드닝(후속)**: `container.clusterViewer` + argocd 전용 scoped ClusterRole로
  축소. cluster-admin이 필요한 CRD 설치 범위를 정확히 좁히는 ClusterRole 설계가
  필요해 파일럿 이후로 분리.
- **정책 전환**: "apply는 운영자 로컬"에서 CI로. 승인 게이트로 사람 확인은 유지하고,
  로컬 break-glass 경로를 남긴다.
- **plan 노출**: plan 요약은 #211대로 리소스 헤더/`Plan:` 라인만 STEP_SUMMARY에.

## GitHub 준비물(apply 단계, 코드 밖)

- Secret `ARGOCD_ADMIN_USER_EMAILS`(JSON 리스트), 선택 `ARGOCD_READONLY_USER_EMAILS`.
- Variable `ADMIN_APPLY_SA_EMAIL`(apply SA 이메일), 기존 `WIF_PROVIDER_ID`·`GCP_PROJECT_ID` 재사용.
- Environment `admin-apply` + required reviewers.

## 롤백

워크플로우·apply SA·IAM을 되돌려 로컬 apply로 복귀. Secrets/Environment는 GitHub에서 제거.
