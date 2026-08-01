# GCP 프로젝트 이전 재구축 설계 (ar-infra-501607 → autoresearch-503903)

> Status: Draft | Created: 2026-07-29

## 1. 목표와 방식 결정

- 기존 dev 인프라 전체를 새 GCP 프로젝트 `autoresearch-503903`
  (project number `611398460162`)에 재구축한다.
- GCP는 프로젝트 간 리소스 이동을 지원하지 않으므로, 전량 IaC인 이 저장소
  특성을 활용해 **Terraform 재적용 + 데이터 복사** 방식을 택한다.
- 조직만 이전하는 대안(`gcloud beta projects move`)은 사용자 결정으로 배제
  (새 프로젝트 사용 확정, 2026-07-29).

## 2. 사전 조사 결과 (2026-07-29)

옛 프로젝트 참조 전수 조사(`ar-infra-501607`, `185508640491`):

| 위치 | 파일 수 | 성격 | 조치 |
| --- | --- | --- | --- |
| `terraform/**/*.tf` 리소스 정의 | 0 | project id는 `var.project_id`로 파라미터화됨 | 로컬 `terraform.tfvars`만 교체 (커밋 안 함) |
| backend `bucket = "autoresearch-dev-tfstate"` | 13 (전 root + workflow) | state 버킷은 옛 프로젝트 소속, 버킷명은 글로벌 유니크 | 새 버킷 생성 후 backend 버킷명 일괄 교체 PR |
| `.github/workflows/*` | 0 (하드코딩 없음) | `vars.GCP_PROJECT_ID`, `vars.WIF_PROVIDER_ID`, `vars.CI_SA_EMAIL` 등 repo variables 참조 | GitHub repo variables 값만 교체 |
| `deploy/mlflow`, `deploy/serving` deployment.yaml | 2 | Artifact Registry 이미지 경로에 프로젝트 id 포함 | 이미지 복사 후 경로 교체 PR |
| `terraform/admin/vault-k8s` helm values | 1 | Vault는 드랍 결정(2026-07-15), 샌드박스 | 이번 이전에서 제외 |
| docs (README·runbook·CHANGE_HISTORY 등) | 19 중 나머지 | 문서 | 같은 PR에서 갱신, CHANGE_HISTORY는 이력이므로 수정 금지 |

## 3. 전제 조건 (Phase 0 진입 전, 사용자 액션)

1. **권한**: `autoresearch-503903`에 `sk.yaho2026@gmail.com` owner 부여
   (현재 접근 불가 확인됨 — 새 조직 관리자 계정에서 부여).
2. **결제**: 새 프로젝트에 결제 계정 연결.
3. **Quota**: E2_CPUS 등 GKE 노드풀 소요 quota 선신청.
   근거: 옛 프로젝트에서 E2_CPUS 부족으로 노드 증설 실패 실측(#388).
   새 프로젝트는 quota가 기본값으로 리셋된다.
4. **API enable**: compute, container, sqladmin, redis, artifactregistry,
   secretmanager, servicenetworking, iam, iamcredentials, sts, cloudbuild,
   bigquery, dns, cloudkms (TERRAFORM_BOOTSTRAP.md 목록 기준).

## 4. 실행 순서

- **Phase 0 — 부트스트랩(로컬)**: 새 state 버킷 생성(예:
  `autoresearch2-dev-tfstate`, versioning on) → WIF pool/provider + CI SA를
  만드는 bootstrap 절차 로컬 1회 apply (`docs/TERRAFORM_BOOTSTRAP.md` 재사용).
  닭-달걀: CI 인증(WIF)을 만드는 apply는 CI로 할 수 없다.
- **Phase 1 — 코드 PR**: backend 버킷명 13개 파일 교체 + deploy 이미지 경로
  교체 + 문서 갱신. 같은 PR에서 GitHub repo variables(GCP_PROJECT_ID,
  WIF_PROVIDER_ID, CI_SA_EMAIL) 교체 시점을 본문에 명시.
  주의: variables를 먼저 바꾸면 옛 프로젝트 대상 PR plan이 깨진다 —
  **머지 직후 교체**가 순서다(환경 먼저 릴리즈 교훈, app#393).
- **Phase 2 — dev root CI apply**: VPC→NAT→AR→SQL→Redis→GKE→...
  (단일 root라 terraform 의존성 순서는 자동). plan 리뷰 후 dev-apply 승인.
- **Phase 3 — admin roots 순차 apply**: GKE 가동 후
  `airflow-k8s` → `argocd-k8s` → `monitoring-k8s` → `elastic-k8s` →
  `autoresearch-k8s` → `argo-rollouts-k8s` → `gke-team-access`.
  (`vault-k8s` 제외.)
- **Phase 4 — 수동 재구성**: operator 주입 Secret 재주입(Airflow/Grafana/
  MLflow/Kibana oauth2-proxy client-secret·cookie-secret, DB 비밀번호 —
  runbook의 `--from-env-file` 절차), Google OAuth client는 프로젝트 종속이라
  콘솔에서 재발급, ArgoCD 앱 등록, Kibana saved objects는
  `kibana_saved_objects` Job replace로 자동 복원.
- **Phase 5 — 데이터 복사(선별)**: GCS `gcloud storage rsync`(raw data,
  feast registry, code artifacts, ES snapshot), BigQuery `bq cp`
  (cross-project 지원), AR 이미지 `crane copy` 또는 CI 재빌드.
  Cloud SQL·Redis·ES 인덱스는 dev 데이터 가치 평가 후 재적재 우선.
- **Phase 6 — 검증·전환·정리**: TEAM_OPERATIONS_RUNBOOK 스모크(IAP SSH,
  Airflow/Grafana/Kibana/MLflow UI, 야간 DAG 1회) → 팀원 IAM 확인 →
  옛 프로젝트 shutdown 예약(30일 유예 = 롤백 창구).

## 5. 리스크와 롤백

- **이중 비용**: 두 프로젝트 병행 기간 동안 비용 2배. Phase 2~6을 짧게
  묶어 진행하고, 검증 완료 즉시 옛 프로젝트 리소스를 내린다.
- **롤백**: Phase 6 전까지 옛 프로젝트가 원본 그대로 살아 있다. repo
  variables·backend를 되돌리면 즉시 복귀 가능. shutdown 후에도 30일 복구
  가능.
- **팀 영향**: 팀원 kubeconfig·터널 스크립트의 프로젝트 참조 갱신 필요 —
  runbook 갱신과 함께 공지.

## 6. 남는 결정

- 새 state 버킷 이름 (전역 유니크, 제안: `autoresearch2-dev-tfstate`)
- Cloud SQL 데이터 이전 여부 (dev DB 가치 판단)
- 옛 프로젝트 shutdown 시점
