# MLflow GKE 구현 계획

> 설계: `../specs/2026-07-14-mlflow-gke-design.md`
> 상위 기능: `SKYAHO/Autoresearch#95`

## 1. 실행 원칙

- 각 Infra 이슈는 최신 `main`에서 별도 브랜치와 PR로 진행한다.
- GCP resource와 IAM은 `terraform/envs/dev`에서 관리한다.
- Namespace/KSA/NetworkPolicy는 기존 admin root를 확장한다.
- Deployment/Service는 `SKYAHO/Autoresearch`에서 관리한다.
- secret, apply, image push와 실제 배포는 각각 사전 승인을 받는다.
- 앞 단계 PR이 merge된 뒤 다음 단계 브랜치를 만든다.

## 2. Phase 1 — Infra #91 설계

변경 파일:

- `docs/superpowers/specs/2026-07-14-mlflow-gke-design.md`
- `docs/superpowers/plans/2026-07-14-mlflow-gke.md`

검증:

```bash
git diff --check
```

검토 항목:

- caller Namespace 확인을 #94 선행 게이트로 두었는가
- Secret Manager reader와 MLflow GSA를 분리했는가
- URL-safe password와 DB encryption 미결정을 명시했는가
- node pool 값의 dev 환경 종속성을 기록했는가
- bucket IAM 축소 가능성을 열어 두었는가
- probe와 integration smoke test 역할을 분리했는가

## 3. Phase 2 — Infra #92 Artifact bucket

예상 변경:

- `terraform/envs/dev/mlflow.tf`: MLflow GSA, 전용 bucket과 bucket IAM
- `terraform/envs/dev/locals.tf`: 이름
- `terraform/envs/dev/variables.tf`: location, class, lifecycle 입력
- `terraform/envs/dev/terraform.tfvars.example`: 비민감 예시
- `terraform/envs/dev/outputs.tf`: bucket name/URI

구현 기준:

- artifact 접근 주체인 MLflow GSA를 #92에서 먼저 생성
- Uniform Bucket-Level Access
- Public Access Prevention
- `force_destroy = false`, `prevent_destroy = true`
- MLflow GSA에 bucket-scoped `roles/storage.objectAdmin`
- project-level storage role 금지
- 실제 operation 검증 뒤 role 축소를 후속 검토

검증:

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan
git diff --check
```

Apply는 별도 승인 후 수행한다.

## 4. Phase 3 — Infra #93 Cloud SQL와 Secret

예상 변경:

- `terraform/envs/dev/mlflow.tf`: database, user, password, Secret Manager
- `terraform/envs/dev/outputs.tf`: DB name/user와 secret ID, password 제외
- 관련 문서: 직접 연결과 state 노출 한계

구현 기준:

- 기존 PostgreSQL 15 private-IP instance 재사용
- MLflow 전용 database/user
- `random_password`: 최소 32자, `special = false`
- Secret Manager가 원본 저장소
- MLflow GSA에 Secret Manager accessor 미부여
- password와 전체 URI output 금지
- SSL/`sslmode`는 현재 instance 설정과 실제 연결을 확인한 뒤 결정
- Terraform state에 password가 남는 기존 패턴의 한계 문서화

검증:

- plan에 새 DB/user/secret만 포함되는지 확인
- 기존 Airflow/application database 교체가 없는지 확인
- password가 plan/log/output에 평문으로 노출되지 않는지 확인

## 5. Phase 4 — Autoresearch MLflow image 발행

예상 변경:

- 기존 `.github/workflows/release.yml` 재사용 가능성 우선 확인
- 독립 lifecycle이 필요할 때만 `.github/workflows/release-mlflow.yml` 추가

검증:

- `deploy/mlflow/Dockerfile` build
- MLflow `v2.22.1`
- `psycopg2`, `google.cloud.storage` import
- container start 시 install 없음
- SHA tag와 registry digest 출력
- 실제 image push는 별도 승인

## 6. Phase 5 — Infra #94 Kubernetes 권한 경계

예상 변경:

- `terraform/envs/dev/mlflow.tf`: 기존 MLflow GSA에 대한 KSA WI binding
- `terraform/envs/dev/locals.tf`, `variables.tf`, `outputs.tf`: WI principal
- `terraform/admin/autoresearch-k8s/main.tf`: MLflow KSA
- `terraform/admin/autoresearch-k8s/locals.tf`, `variables.tf`, `outputs.tf`
- caller가 `airflow`일 때만 `terraform/admin/airflow-k8s/main.tf`
- 필요하면 `terraform/admin/airflow-k8s/variables.tf`와 example

구현 전 게이트:

1. 실제 Scheduler/Worker/KPO 설정에서 MLflow client Pod Namespace를 확인한다.
2. caller가 `autoresearch`뿐이면 기존 same-namespace rule을 재사용한다.
3. caller가 `airflow`이면 다음을 함께 추가한다.
   - `cluster_services_cidr` TCP 5000
   - `autoresearch` Namespace + MLflow Pod selector TCP 5000
4. 일반 node pool 이름 `dev-default`를 output으로 노출할 필요를 확인한다.

IAM 기준:

- KSA `autoresearch/mlflow`만 MLflow GSA impersonation 가능
- GSA는 artifact bucket role만 보유
- `cloudsql.client`, `secretmanager.secretAccessor`와 project storage role 없음

검증:

- 두 Terraform root의 fmt/validate/plan
- 기존 Namespace와 NetworkPolicy 중복 생성 없음
- 불필요한 Airflow egress 변경 없음
- IAM member principal과 KSA annotation 일치

## 7. Phase 6 — Autoresearch #95 Deployment/Service

예상 변경:

```text
deploy/mlflow/kubernetes/
├── deployment.yaml
├── service.yaml
└── README.md
```

Deployment 계약:

- digest-pinned image
- `serviceAccountName: mlflow`
- replica 1
- dev manifest의 `cloud.google.com/gke-nodepool: dev-default`
- 다른 환경에서 node pool 값을 바꿔야 함을 README에 명시
- port 5000과 resources requests/limits
- `MLFLOW_BACKEND_STORE_URI`는 `mlflow-db` Secret 참조
- `MLFLOW_ARTIFACT_DESTINATION`과 `GOOGLE_CLOUD_PROJECT`
- `GOOGLE_APPLICATION_CREDENTIALS` 없음
- exec 형식 `args`에서는 Kubernetes `$(VAR)` 치환만 사용하고 `${VAR}`와
  혼용하지 않음
- startup/readiness/liveness probe

Probe 확정 절차:

1. `v2.22.1` 파생 image를 로컬 실행한다.
2. `/health` 응답과 startup 시간을 확인한다.
3. DB/GCS 일시 장애가 liveness restart loop를 만들지 확인한다.
4. probe는 process/HTTP 준비 상태만 판단한다.
5. DB metadata와 GCS artifact는 smoke test로 별도 검증한다.

Service는 ClusterIP 5000만 노출하고 Ingress는 추가하지 않는다.

## 8. Phase 7 — Apply와 통합 검증

Apply, Kubernetes secret 생성과 배포는 변경 요약 후 각각 승인을 받는다.

Secret 주입 절차는 다음을 만족해야 한다.

- `umask 077`
- mode 600 임시 env file 또는 표준 입력
- password를 process argument에 넣지 않음
- `kubectl --from-env-file --dry-run=client -o yaml | kubectl apply -f -`
- output/log에 secret 값 없음
- `trap`을 사용해 임시 file 삭제

검증 순서:

1. MLflow Pod가 `dev-default`에 배치됐는지 확인
2. KSA와 예상 GSA identity 확인, key JSON 없음 확인
3. Cloud SQL metadata 생성과 Run 재조회
4. GCS artifact upload/download
5. port-forward UI
6. 실제 caller Namespace에서 Service FQDN TCP 5000 접근
7. `scripts/mlflow_smoke_test.py` 전체 통과

## 9. Phase 8 — Infra #95 Runbook

포함 내용:

- 안전한 Secret 생성과 rotation
- UI port-forward
- Airflow/training `MLFLOW_TRACKING_URI`
- Pod, logs, probes와 node placement 확인
- DB 연결과 SSL 설정 진단
- Workload Identity와 GCS IAM 진단
- image digest 확인, redeploy와 rollback
- GCS role 축소 검토 기록

## 10. PR 분리와 연결

| PR | 연결 문구 |
| --- | --- |
| Infra #91 | `Closes #91`, `Part of SKYAHO/Autoresearch#95` |
| Infra #92 | `Closes #92`, `Part of SKYAHO/Autoresearch#95` |
| Infra #93 | `Closes #93`, `Part of SKYAHO/Autoresearch#95` |
| Infra #94 | `Closes #94`, `Part of SKYAHO/Autoresearch#95` |
| Infra #95 | `Closes #95`, `Part of SKYAHO/Autoresearch#95` |

Autoresearch #95는 image, Infra, Deployment와 실제 통합 검증이 모두 끝나는
마지막 PR에서만 close한다.

## 11. 승인 게이트

다음 작업은 각 단계에서 명시적으로 승인받는다.

- Issue 본문/assignee 변경
- Terraform apply 또는 state 작업
- Kubernetes Secret 생성과 manifest apply
- image push
- Git push와 PR 생성
- issue close
