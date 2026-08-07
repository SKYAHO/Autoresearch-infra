# Agent Orchestration GKE 내부 배포 Runbook

Agent Orchestration은 FastAPI API, Codex Runner, Streamlit UI를 서로 다른 Pod와 파일
시스템으로 분리한 dev 전용 내부 서비스입니다. API만 Cloud SQL 전용 DB와 DB password
Secret Manager 접근 권한을 가지며, Runner는 Codex OAuth bootstrap 시크릿 하나만 읽고,
UI는 기존 API 요청 토큰만 환경 변수로 받으며 KSA token과 GCP IAM 권한을 갖지 않습니다.

UI는 사용자별 인증을 제공하지 않습니다. 따라서 `agent-orchestration-ui` Service에
`kubectl port-forward`할 RBAC를 가진 내부 팀원은 API 요청 토큰을 직접 알지 않아도 UI가
주입받은 토큰으로 `/chat`을 호출할 수 있습니다. 이는 Codex/OpenAI 비용 발생과
`chat_interactions` 기록을 수행할 수 있는 dev 내부 권한 경계입니다. 포트포워드 권한은
신뢰된 팀원에게만 부여하고, 외부 Ingress·LoadBalancer·공용 사용자 접근은 도입하지
않습니다.

이 문서는 `deploy/agent-orchestration/`의 immutable digest 주입, OAuth 초기 인증,
Alembic PreSync migration, ArgoCD automated sync, 내부 healthcheck, Streamlit port-forward와
PostgreSQL 저장 검증·롤백 절차를 다룹니다.
외부 Ingress, LoadBalancer, 사용자별 OAuth, 외부 공개 API는 범위가 아닙니다.

## 적용 전 조건

1. `terraform/envs/dev`와 `terraform/admin/autoresearch-k8s` 변경이 별도 승인된
   Terraform plan을 거쳐 적용되어야 합니다. `agent_orchestration` DB/user, API·Runner
   GSA/KSA, 각 Secret Manager IAM이 먼저 존재해야 합니다.
2. 앱 저장소 release workflow가 아래의 **검증된 immutable digest** 세 개를 출력해야
   합니다. tag(`:latest`, `:sha-*` 포함)만으로 배포하지 않습니다.

   - `autoresearch-agent-orchestration-api@sha256:...`
   - `autoresearch-agent-orchestration-runner@sha256:...`
   - `autoresearch-agent-orchestration-ui@sha256:...`

3. `terraform/admin/argocd-k8s`의 `agent-orchestration` Application이 먼저
   적용되어 있어야 합니다(#526). source path는 `deploy/agent-orchestration`,
   destination은 `autoresearch`입니다. `agent_orchestration_deployment_enabled=true`이면
   `targetRevision=main`을 추적하는 automated sync(`prune=false`, `selfHeal=false`)이고,
   `false`이면 존재하지 않는 `agent-orchestration-disabled` ref를 바라보는 비상 차단
   상태라 sync할 수 없습니다. automated sync는 신규 커밋을 최대 3분 폴링으로 자동
   반영하며, 별도 `argocd app sync` 수동 트리거가 필요 없습니다.
4. NetworkPolicy의 정적 CIDR이 현재 dev Terraform 값과 일치해야 합니다. manifest에
   값을 임의로 바꾸지 말고, `terraform/envs/dev`의 `dev_subnet_cidr`(현재
   `10.10.0.0/20`), `gke_services_cidr`(현재 `172.16.128.0/24`)와
   `private_services_cidr`(현재 `192.168.0.0/20`)를 reviewed Terraform plan 또는
   승인된 변수 값으로 대조합니다. 첫 값은 node-originated kubelet probe·API
   port-forward ingress, 둘째 값은 Runner Service VIP·DNS egress, 셋째 값은 Cloud SQL
   private IP egress에 사용됩니다. CIDR 변경은 Terraform과 NetworkPolicy를 같은 배포
   변경에서 함께 갱신한 뒤 sync합니다.
5. API manifest의 `ORCH_DB_HOST`가 reviewed Terraform state의
   `cloud_sql_private_ip_address` output과 일치해야 합니다. Cloud SQL instance를
   재생성하면 private IP가 달라질 수 있고, ArgoCD plain manifest의 리터럴 값은
   Terraform drift만으로 자동 갱신되지 않습니다. 불일치하면 새 manifest commit에
   현재 output을 반영해 main에 merge합니다. `agent_orchestration_deployment_enabled`가
   이미 `true`인 정상 운영 상태에서는 automated sync가 그 commit을 자동 반영하므로
   별도 admin apply가 필요 없습니다.
6. v0.7.0 이상을 sync하기 전에 Kubernetes Secret `agent-orchestration-github-token`이
   먼저 존재해야 합니다. 아래
   [이슈 발행 GitHub 토큰 등록](#이슈-발행-github-토큰-등록-525) 절차를 따릅니다.
   API는 `load_settings()`를 uvicorn lifespan startup에서 호출하므로, 아래 필수
   환경변수 중 하나라도 비어 있으면 첫 요청 500이 아니라 **Pod 기동 자체가
   실패**합니다.

   | 환경변수 | 출처 | 현재 값 |
   | --- | --- | --- |
   | `ORCH_GITHUB_TOKEN` | Secret `agent-orchestration-github-token` | 운영자 등록 |
   | `ORCH_GITHUB_REPOSITORY` | 발행 대상 저장소 | `SKYAHO/Autoresearch` |
   | `ORCH_EXPERIMENT_DATASET_SOURCE` | Feast offline store 좌표 | `feast://feast_offline_store/training_entity` |
   | `ORCH_EXPERIMENT_TRAINING_CONFIG_REF` | 앱 저장소 학습 설정 | `src/pipeline/config.yaml@main` |

   뒤의 세 값은 시크릿이 아니라 manifest 리터럴이며, 발행되는 이슈 본문에 문자열로
   박히는 좌표입니다. 실재하지 않는 이름을 넣어도 API는 기동하므로, 값이 바뀌면
   실제 BigQuery 테이블·앱 저장소 파일과 대조합니다. 기간은 발행 시점에 서버가
   계산해 붙이므로 `ORCH_EXPERIMENT_DATASET_SOURCE`에 날짜를 넣지 않습니다.

`deploy/agent-orchestration/*.yaml`의 `REPLACE_WITH_*` 문자열이 하나라도 남아
있으면 의도적으로 배포하지 않습니다. release digest와 Terraform output을 확인한
후 별도 배포 커밋에서만 다음 값을 모두 교체합니다.

| 자리표시자 | 출처 |
| --- | --- |
| `REPLACE_WITH_API_IMMUTABLE_DIGEST` | 앱 release workflow API `digest_ref` |
| `REPLACE_WITH_RUNNER_IMMUTABLE_DIGEST` | 앱 release workflow Runner `digest_ref` |
| `REPLACE_WITH_UI_IMMUTABLE_DIGEST` | 앱 release workflow UI `digest_ref` |
| `REPLACE_WITH_PROJECT_ID` | dev Terraform `project_id` |
| `REPLACE_WITH_DB_PASSWORD_SECRET_ID` | dev output `agent_orchestration_deployment_contract.db_password_secret_id` |
| `REPLACE_WITH_CODEX_AUTH_BOOTSTRAP_SECRET_ID` | dev output `agent_orchestration_deployment_contract.codex_auth_bootstrap_secret_id` |
| `REPLACE_WITH_CLOUD_SQL_PRIVATE_IP` | dev output `cloud_sql_private_ip_address` |
| `REPLACE_WITH_DB_NAME` | dev output `agent_orchestration_deployment_contract.database_name` |
| `REPLACE_WITH_DB_USER` | dev output `agent_orchestration_deployment_contract.database_user` |

`agent_orchestration_deployment_contract` output은 비밀번호와 OAuth payload를
출력하지 않습니다. output 값을 조회할 때도 CI log, PR 본문, 티켓에 복사하지
않습니다.

### Experiment API Alembic migration

Experiment API v0를 포함한 API image는 `api-migration-job.yaml`의 ArgoCD `PreSync`
hook을 통해 API rollout 전에 `alembic upgrade head`를 실행합니다. Job은 API와 같은
immutable digest와 기존 `agent-orchestration-api` KSA의 DB bootstrap만 재사용합니다.
따라서 OAuth PVC, `ORCH_API_TOKEN`, `ORCH_RUNNER_TOKEN`, `ORCH_GITHUB_TOKEN`은 Job에
전달되지 않으며, 새 IAM·DB 권한도 추가하지 않습니다.

Job Pod는 API와 같은 label을 쓰므로 `agent-orchestration-api-egress`의 `podSelector`에
매칭되어 **API의 egress 경계를 그대로 상속합니다**. 즉 Cloud SQL·DNS·Workload
Identity·Private Google APIs뿐 아니라 Kubernetes API 443과, #525에서 추가한 공개 인터넷
443까지 함께 상속합니다. Job은 `alembic upgrade head`만 실행하므로 이 경로들을 쓰지
않지만, "Job에는 외부 egress가 없다"고 가정하지 마십시오. Job에만 더 좁은 경계를
적용하려면 별도 label과 NetworkPolicy를 같은 변경에서 추가해야 합니다.

`alembic` 실행 세부 구현은 앱 image 계약에 의존합니다. promotion 전에 대상 source의
API Dockerfile과 `bootstrap_secrets` 구현을 대조해 다음을 확인합니다.

- `bootstrap-db`는 `/runtime/db.env`에 quoting 없는 단일
  `ORCH_DATABASE_URL=<url>` 행을 기록합니다.
- orchestration runtime dependency에 Alembic이 포함되고, image `WORKDIR`(`/app`) 아래에
  `agent_orchestration/alembic.ini`와 migration 파일이 포함됩니다.
- Job command의 `alembic -c agent_orchestration/alembic.ini upgrade head`가 이 image에서
  실행됩니다. 이 계약을 바꾸는 앱 PR은 migration 전용 entrypoint를 제공하거나, 같은
  release에서 이 Job command와 runbook을 함께 갱신해야 합니다.

현재 dev DB에는 `alembic_version`이 없으므로 #483의 `down_revision = None`인 initial
revision `0001_experiment_tables`부터 적용됩니다. 이 Job은 이 클러스터에서 아직 한 번도
실행된 적이 없습니다 — `ccf90bf`에서 매니페스트가 들어왔지만, 그 뒤 ArgoCD 작업이 UI
Deployment 하나만 대상으로 한 선택 sync였고 선택 sync는 PreSync hook을 건너뜁니다.

`upgrade head`는 단일 revision이 아니라 **미적용 revision 전체를 순서대로** 적용합니다.
v0.7.0 기준 체인은 분기 없이 선형입니다.

| revision | 만드는 것 |
| --- | --- |
| `0001_experiment_tables` | `experiments`, `experiment_events`, `experiment_logs`, `experiment_metadata` |
| `0002_create_experiment_steps` | `experiment_steps` |
| `0003_experiment_issue_lineage` | `experiments`에 `issue_body`/`issue_title`/`issue_number`/`issue_branch`/`issue_published_at` 5컬럼 + index |

세 revision 모두 additive여야 하며, 기존 `chat_interactions` table·sequence는 변경해서는
안 됩니다. Experiment table schema의 source of truth는 Alembic이고, 기존 `/chat` table은
API startup의 `ensure_schema()`가 계속 담당합니다.

중간 revision에서 중단되면 DB가 부분 적용 상태로 남습니다. Alembic은 revision 단위로
`alembic_version`을 갱신하므로 다음 sync의 `upgrade head`가 남은 revision부터 이어서
적용합니다. 이때도 downgrade하지 않습니다.

`PreSync` Job이 실패하면 ArgoCD sync는 API·Runner rollout 전에 중단됩니다. 임의로
Deployment를 먼저 sync하거나 migration을 API startup에 숨기지 않습니다. Job은
`alembic upgrade head`만 수행하므로 완료 후 재실행해도 안전합니다. 반면 rollback에서
`alembic downgrade`는 자동 실행하지 않습니다. 이전 API는 추가된 experiment table을
읽지 않아 그대로 동작할 수 있고, downgrade는 데이터 손실 위험이 있으므로 별도 승인과
복구 계획을 먼저 마련해야 합니다. 성공·실패 Job은 상태와 log 확인을 위해 다음 sync 전까지
남기며, 다음 PreSync 전에 `BeforeHookCreation`이 같은 이름의 이전 Job을 삭제합니다.

`activeDeadlineSeconds=180`은 Job 전체 실행 시간에 적용되고 `backoffLimit`보다 우선합니다.
deadline에 도달하면 실행 중인 Pod는 종료되고 Job은 `Failed`/`DeadlineExceeded`가 되며,
남은 retry 횟수가 있어도 추가 Pod를 만들지 않습니다. 따라서 `DeadlineExceeded` 뒤에는
자동 재시도를 가정하지 말고 Job status·credential을 제외한 log·`alembic_version`을 먼저
확인한 뒤 원인을 고치고 새 PreSync sync를 시작합니다. #483 initial revision은 PostgreSQL
transaction으로 적용되는 additive DDL만 포함해야 하므로, commit 전 중단이면 다음
`upgrade head`가 같은 revision부터 다시 적용하고 commit 후 중단이면 version table이 이미
head를 가리켜야 합니다. 이 두 상태와 다른 partial schema가 관측되면 자동 재시도 대신
승인된 DB 복구 절차로 전환합니다.

### 최초 활성화 매니페스트

최초 활성화에서는 위 자리표시자를 release workflow가 검증한 immutable digest와
적용된 dev Terraform output의 비밀이 아닌 식별자로만 바꾼 별도 manifest commit을
만듭니다. 이 commit은 Application이 아직 disabled 상태인 동안 검토·병합할 수
있습니다(#526 기준 target은 고정 SHA가 아니라 `main`이므로, disabled 상태에서
main에 merge해도 즉시 배포되지 않습니다). 병합 뒤에는 그 merge를 포함한 main을
검토한 다음 `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 reviewed admin apply를
수행합니다. 이 apply가 `targetRevision`을 `main`으로 바꾸는 순간 automated sync가
이미 merge된 manifest를 자동 반영합니다. mutable tag, PR head SHA, 비밀번호·OAuth
payload·요청 토큰은 이 commit에 넣지 않습니다.

## DB runtime 권한 migration 선행 조건

현재 앱 소스의 `ensure_schema()`는 API 시작마다 advisory lock 뒤
`CREATE TABLE IF NOT EXISTS chat_interactions`를 실행합니다. Cloud SQL PostgreSQL의
built-in user는 기본적으로 `cloudsqlsuperuser`를 자동 부여받으므로, 단순
`google_sql_user`만으로 만든 `agent_orchestration_app`을 그대로 runtime에 쓰면
`CREATEROLE`·`CREATEDB`를 가진 과권한 계정이 됩니다.

따라서 이 Application은 DB 권한 migration 완료 전에는 절대로 enable/sync하지
않습니다. 현 API의 시작 DDL을 유지하면서 실제 최소 권한을 달성하는 초기 단계는
다음과 같습니다.

1. **migration owner**: 승인된 운영자만 사용하는 기존 Cloud SQL 관리자 경로입니다.
   Terraform apply 전 이 주체가 instance에 `agent_orchestration_runtime` custom role을
   `NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE`로 만듭니다. 이 role이 없으면
   `google_sql_user.database_roles`가 실패하므로, Terraform은
   `cloudsqlsuperuser` runtime user를 만들지 않습니다.
2. **runtime user**: Terraform은 위 custom role만 가진
   `agent_orchestration_app` built-in user를 만듭니다. Cloud SQL은 custom database
   role을 지정해 생성한 built-in user에 자동 `cloudsqlsuperuser`를 부여하지 않습니다.
   API GSA는 이 user password secret만 읽고 migration owner 자격 증명에는 접근하지
   않습니다.
3. **현 API 호환 최소 권한**: DB가 생성된 뒤 migration owner는 runtime role에 target
   DB `CONNECT`, `public` schema의 `USAGE, CREATE`를 grant합니다. API의
   `CREATE TABLE IF NOT EXISTS`와 `BIGSERIAL` sequence 생성에 필요한 최소 DDL 범위이며,
   runtime user에는 `CREATEROLE`, `CREATEDB`, instance 관리 권한이 없습니다. 이 권한은
   Agent Orchestration 전용 DB에서만 유효합니다.
4. **강화 후속 단계(권장)**: `ensure_schema()`를 전용 migration Job으로 옮기고 API를
   read-only schema verify mode로 전환합니다. 그 뒤 runtime role에서 schema `CREATE`를
   회수하고 `chat_interactions` table의 `SELECT, INSERT`, sequence의 `USAGE, SELECT`,
   schema `USAGE`만 남깁니다.

기본 변수 값을 유지하는 경우 migration owner는 다음 SQL을 **비밀 관리용 runtime
user가 아닌** 신뢰된 관리자 세션에서 순서대로 실행합니다. 변수 이름을 바꿨다면
동일한 식별자로 치환합니다. `public` schema 권한 변경은 전용
`agent_orchestration` DB에만 적용합니다.

```sql
-- Terraform apply 전에 instance의 postgres database에서 한 번 실행한다.
CREATE ROLE agent_orchestration_runtime
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

-- Terraform이 database와 agent_orchestration_app을 만든 뒤, target DB에서 실행한다.
REVOKE ALL ON DATABASE agent_orchestration FROM PUBLIC;
GRANT CONNECT ON DATABASE agent_orchestration TO agent_orchestration_runtime;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO agent_orchestration_runtime;
```

`agent_orchestration_app`은 custom role membership을 통해서만 위 권한을
상속합니다. 따라서 현재 MVP에서는 해당 전용 DB의 `public` schema에 만든 자기
table/sequence를 변경·삭제할 수 있지만, role/database/instance를 관리하거나 다른
database에 접속할 권한은 없습니다. 시작 DDL을 migration Job으로 옮긴 뒤에는
다음처럼 schema `CREATE`를 회수합니다(실제 생성된 sequence 이름은
`\d chat_interactions`로 확인 후 사용).

```sql
REVOKE CREATE ON SCHEMA public FROM agent_orchestration_runtime;
GRANT USAGE ON SCHEMA public TO agent_orchestration_runtime;
GRANT SELECT, INSERT ON TABLE public.chat_interactions
  TO agent_orchestration_runtime;
GRANT USAGE, SELECT ON SEQUENCE public.chat_interactions_id_seq
  TO agent_orchestration_runtime;
```

성공 여부는 `\du`/`\dp` 출력의 민감하지 않은 권한 메타데이터로만 확인합니다.
role을 임의로 비우거나 `cloudsqlsuperuser`를 무계획 revoke하면 현재 시작 DDL이
실패하므로 금지합니다. Cloud SQL built-in user와 custom database role 동작은
[Google Cloud 공식 사용자·역할 문서](https://cloud.google.com/sql/docs/postgres/create-manage-users)를
기준으로 합니다.

## Cloud SQL 주소·비밀번호 변경 대응

`bootstrap-db` init container는 API Pod가 생성될 때만 `ORCH_DB_HOST`와 Secret
Manager `versions/latest` 비밀번호를 `/runtime/db.env`에 기록합니다. 따라서 Cloud
SQL private IP가 manifest와 다르면 init container가 잘못된 주소로 DB URL을 만들고,
API container는 DB 연결·schema 초기화에 실패해 Ready가 되지 않습니다. Runner는
Cloud SQL을 사용하지 않으므로 별도로 Ready일 수 있습니다. ArgoCD Application의
Degraded 상태, API rollout status, `bootstrap-db`·API container의 오류를 함께 확인해
탐지합니다.

DB 비밀번호 rotation도 Secret version 변경만으로 기존 API Pod를 자동 재기동하지
않습니다. 기존 Pod는 이미 작성된 `db.env`의 이전 URL을 계속 사용합니다. 현 API는
연결 pool을 유지하지 않고 `/chat` 저장마다 새 PostgreSQL 연결을 열므로,
`/healthcheck`는 성공해도 password 교체 뒤 `/chat`은 저장 단계에서 HTTP 500이 될 수
있습니다. 새 Pod는 `versions/latest`의 새 비밀번호로 부트스트랩합니다. 다음 절차로
수렴시킵니다.

1. 승인된 절차로 Cloud SQL user password와 Secret Manager 최신 version을 함께
   갱신합니다. 둘 중 하나만 갱신하면 안 됩니다.
2. API Pod template에 비밀값·Secret payload를 넣지 않는 새
   `autoresearch.io/db-bootstrap-revision` annotation 값을 추가한 manifest commit을
   만듭니다. 이 annotation 변경은 API rollout을 유발합니다.
3. 그 manifest commit을 reviewed PR로 main에 merge합니다. `enabled=true`인 정상
   운영 상태에서는 automated sync가 최대 3분 폴링으로 자동 반영하므로 별도 admin
   apply나 수동 sync 트리거가 필요 없습니다. `kubectl rollout restart`로 ArgoCD
   관리 manifest를 직접 변경하지 않습니다.
4. API rollout과 공통 end-to-end gate가 성공했는지 확인합니다. 실패 시 단순
   manifest rollback으로는 `versions/latest`를 되돌리지 못하므로, 승인된 password와
   Secret version을 다시 일치시킨 뒤 새 restart manifest revision으로 복구합니다.

## OAuth bootstrap 시크릿 초기 등록·회전·장애 복구

Runner PVC는 Codex가 갱신한 인증 상태를 유지합니다. bootstrap 시크릿은 PVC에
`auth.json`이 없는 최초 기동 때만 읽습니다. 기존 PVC의 갱신된 `auth.json`은
덮어쓰지 않으며, 따라서 일반적인 재시작은 Codex refresh 상태를 보존합니다.

Runner의 bootstrap init container는 `bootstrap_secrets.py`를 포함하는 API 이미지를
재사용하고 `python -m agent_orchestration.bootstrap_secrets runner-codex-auth` CLI 역할만
호출합니다. 그러나 이 container도 Runner 전용 KSA와 OAuth 전용 GSA로 실행하고,
Runner PVC만 mount합니다. API Deployment는 OAuth bootstrap 시크릿과 Runner PVC를
mount하지 않으므로, 이미지 재사용이 API runtime의 OAuth 접근 권한을 뜻하지는 않습니다.

신뢰된 운영자는 승인된 비밀 관리 절차로 새 Secret Manager version을 생성합니다.
실제 `auth.json`, access token, `codex login` 출력과 임시 파일 경로는 터미널 공유,
Git, PR, 티켓에 기록하지 않습니다. PVC를 삭제하는 방식은 갱신된 인증 상태를
잃으므로 OAuth 장애 복구의 기본 절차가 아닙니다.

새 계정으로 교체하거나 Runner OAuth 장애를 복구할 때만 다음 **일회성** 절차를
사용합니다.

1. 새 Secret Manager version을 생성합니다. payload·token·임시 경로는 출력하거나
   기록하지 않습니다.
2. 새 **manifest commit 하나에만** Runner init container의
   `runner-codex-auth` command 배열 뒤에 `--replace-existing`을 추가합니다. 이 명시 opt-in은
   기존 regular `auth.json`을 새 Secret Manager 값으로 0600 원자 교체하게 합니다.
3. 그 manifest commit을 reviewed PR로 main에 merge합니다. `enabled=true`인
   정상 운영 상태에서는 Application이 `main`을 automated sync로 추적하므로
   merge만으로 반영이 시작됩니다. **manifest commit만 만들고 main에 merge하지
   않은 상태로 두면 안 됩니다.** disabled 상태(`agent_orchestration_deployment_enabled=false`)라면
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 먼저 reviewed admin apply를
   수행해야 automated sync가 시작됩니다.
4. merge된 revision이 automated sync로 반영됐는지 ArgoCD에서 확인합니다(최대
   3분 폴링, 필요하면 `argocd app get agent-orchestration`으로 즉시 확인). Runner
   rollout이 Ready이고 Runner readiness probe의 `/healthcheck`가 성공하는지 확인한
   다음, API `/healthcheck`도 확인한 뒤
   [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 수행합니다.
   이 gate는 OAuth 복구 전용 절차가 아니라 모든 배포의 공통 검증입니다.
5. 위 Runner/API readiness와 공통 post-sync end-to-end gate가 모두 성공한 경우에만
   다음 manifest commit에서 `--replace-existing`을 제거하고 reviewed PR로 main에
   merge합니다. automated sync가 이 commit도 같은 방식으로 자동 반영합니다.

하나라도 실패하면 5단계의 정상 flag 제거 commit으로 진행하지 말고, 즉시 승인된
rollback/incident handling으로 멈춥니다. force init container는 이미 PVC의 기존 인증을
새 bootstrap 값으로 덮어썼으므로, manifest rollback이나 flag 제거만으로 이전 PVC 인증을
복구할 수 없습니다. 반복 재시작을 피하고, 노출 없는 incident 기록과 승인된 OAuth 복구
절차로 다음 조치를 결정합니다.

`--replace-existing`을 남긴 상태로 Runner를 재시작하면 이후 Codex refresh 상태도
bootstrap Secret Manager 값으로 덮어쓸 수 있습니다. 따라서 이 flag는 일반 배포나
재시작에 남겨 두지 않습니다. `api-database` 역할에는 이 flag를 사용하지 않습니다.

## API·Runner 요청 토큰 등록

API는 `/chat`에 `X-Orch-Token`을 요구합니다. 이 토큰은 DB password와 OAuth
시크릿과 다른 공유 요청 토큰이며, API GSA에는 Secret Manager accessor를 추가하지
않습니다. 허가된 운영자는 임시 파일(권한 0600)에서 Kubernetes Secret
`agent-orchestration-api-token`의 `ORCH_API_TOKEN` key만 생성·갱신합니다. payload를
manifest, Git, Terraform state, shell history에 넣지 않습니다.

API가 Runner의 `/generate`를 호출할 때에는 별도의 `X-Runner-Token`을 사용합니다.
운영자는 32자 이상의 무작위 값을 0600 임시 파일에만 보관해 Kubernetes Secret
`agent-orchestration-runner-token`의 `ORCH_RUNNER_TOKEN` key로 생성·갱신합니다. 이
Secret은 API와 Runner Pod에만 mount하며, 외부 호출자·DB bootstrap·OAuth bootstrap
용으로 재사용하지 않습니다. 이 역시 GSA Secret Manager accessor를 추가하지 않는
Kubernetes Secret입니다.

`autoresearch` namespace의 `view` 권한에는 Secret read가 포함되지 않습니다. 토큰을
호출자에게 전달할 별도 보관·배포 방식은 팀의 승인된 비밀 관리 절차를 따릅니다.

## 이슈 발행 GitHub 토큰 등록 (#525)

`POST /experiments/{id}/issue`는 `gh issue create`를 subprocess로 실행하며,
`ORCH_GITHUB_TOKEN`을 `GH_TOKEN`으로 전달합니다. 이 값은 API Pod가 startup에서 읽는
필수 환경변수라, **Secret이 없으면 Pod가 기동하지 못합니다.** v0.7.0 이상을 sync하기
전에 반드시 먼저 등록합니다.

토큰은 `SKYAHO/Autoresearch` 저장소 하나에만 `Issues: Read and write` 권한을 준
fine-grained PAT입니다. `contents: write`나 `repo` 스코프 토큰을 넣지 않습니다 — 이
토큰으로 코드를 쓸 수 없어야 한다는 것이 앱 저장소 spec의 격리 전제입니다.

```bash
umask 077
token_file="$(mktemp)"
printf '%s' '<fine-grained PAT>' > "$token_file"   # 끝에 개행을 넣지 않습니다

kubectl -n autoresearch create secret generic agent-orchestration-github-token \
  --from-file=ORCH_GITHUB_TOKEN="$token_file"

rm -f "$token_file"
```

`_require_env`가 `strip()` 후 빈 문자열을 거부하므로 개행·공백만 든 값은 startup
실패로 이어집니다. `--from-literal` 대신 위처럼 개행 없는 파일을 쓰는 이유입니다.

앞의 두 요청 토큰과 마찬가지로 payload를 manifest, Git, Terraform state, shell
history에 넣지 않으며 API GSA에 Secret Manager accessor를 추가하지 않습니다. 이
Secret은 API Pod에만 mount하며 UI·Runner에는 전달하지 않습니다.

회전은 같은 명령에 `--dry-run=client -o yaml | kubectl apply -f -`를 붙여 수행하고,
API Pod를 재기동해야 새 값이 적용됩니다(startup에 1회만 읽습니다).

`gh`가 발행에 실패하면 API는 502를 반환합니다. 토큰이 잘못됐어도 startup은 통과하므로
(형식 검증이 없습니다) 등록 직후
[공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)로 실제 발행을
확인합니다.

## baseline-reader GitHub App 자격 증명 등록 (#539)

실험 이슈를 발행하기 **전에** API가 `heads/dev` SHA를 읽어
`experiments.base_dev_sha`에 봉인합니다. 그 조회에 baseline-reader GitHub App을
사용합니다. 앞 절의 `ORCH_GITHUB_TOKEN`(이슈 발행용 PAT)과는 **별개의 자격
증명**이며 서로 대체할 수 없습니다.

이 App은 `SKYAHO/Autoresearch` 저장소 **하나에만** 설치하고 권한은 `Contents:
Read-only` **하나만** 부여합니다. 브랜치를 실제로 만드는 branch-writer App
(`Contents: Read and write`)은 완전히 다른 App이며, 그쪽 절차는
[실험 Job runbook](2026-08-01-auto-research-experiment-job.md)에 있습니다. 두 App을
하나로 합치면 "SHA를 읽기만 하는 경로"가 쓰기 권한을 갖게 되므로 분리를
유지합니다.

API Pod는 세 값을 startup에서 읽으므로 **Secret이 없으면 Pod가 기동하지
못합니다.** 이 배선을 포함한 API digest를 sync하기 전에 반드시 먼저 등록합니다.

| 환경변수 | 출처 | Secret key |
|---|---|---|
| `ORCH_BASELINE_GITHUB_APP_ID` | Secret | `app-id` |
| `ORCH_BASELINE_GITHUB_APP_INSTALLATION_ID` | Secret | `installation-id` |
| `ORCH_BASELINE_GITHUB_APP_PRIVATE_KEY_PATH` | manifest 리터럴 | (없음) |
| private key 파일 | Secret volume | `private-key.pem` |

App ID와 installation ID는 비밀이 아니지만, App 생성 전에는 값을 알 수 없어
manifest에 리터럴로 박을 수 없습니다. `#533` actions-runner와 같이 private key와
한 Secret에 함께 두고 운영자가 주입합니다.

installation ID는 App 설치 후 설치 페이지 URL
(`https://github.com/settings/installations/<installation-id>`) 또는 App 관리
화면에서 확인합니다. App ID는 App 설정 페이지 상단에 있습니다.

PEM은 여러 줄이라 `--from-env-file`(한 줄 `KEY=VALUE`만 지원)로는 옮길 수
없습니다. 세 값 모두 `--from-file`로 넣습니다.

```bash
umask 077
sdir="$(mktemp -d)"          # 고정 경로 금지 — 공유 호스트 심링크/선점 위험
trap 'rm -rf "$sdir"' EXIT

printf '%s' '<App ID>'          > "$sdir/app-id"           # 끝에 개행 없음
printf '%s' '<installation ID>' > "$sdir/installation-id"  # 끝에 개행 없음
cp /path/to/downloaded.pem        "$sdir/private-key.pem"

kubectl -n autoresearch create secret generic agent-orchestration-baseline-reader-app \
  --from-file=app-id="$sdir/app-id" \
  --from-file=installation-id="$sdir/installation-id" \
  --from-file=private-key.pem="$sdir/private-key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -rf "$sdir"; trap - EXIT
shred -u /path/to/downloaded.pem    # 다운로드한 원본 즉시 파기
```

`--dry-run=client -o yaml | kubectl apply -f -`를 쓰는 이유는 키 재발급 시에도
멱등하기 위해서입니다(`create` 단독은 이미 있으면 `AlreadyExists`로 실패합니다).

두 ID는 `_required_positive_env_int`가 `strip()` 후 파싱하므로 파일 끝 개행이
섞여도 동작하지만, 다른 Secret과 표기를 맞추기 위해 개행 없이 넣습니다.

private key는 환경 변수가 아니라 `/var/run/secrets/baseline-reader/private-key.pem`
파일로만 전달합니다. 환경 변수는 하위 프로세스로 상속되고 crash dump·프로세스
목록에 노출될 수 있어 PEM을 담기에 부적절합니다. 이 Secret은 API 컨테이너에만
mount하며 DB bootstrap initContainer·UI·Runner에는 전달하지 않습니다.

volume의 `defaultMode`는 8진수 `0440`입니다. Secret 파일 소유자가 `root:fsGroup`
이라 `0400`으로 두면 `fsGroup: 10001`로 도는 API 프로세스가 읽지 못합니다.

회전은 같은 명령을 다시 실행한 뒤 API Pod를 재기동합니다(startup에 1회만
읽습니다). 키를 재발급했다면 GitHub App 쪽 이전 키도 폐기합니다.

Secret이 없는 상태로 sync하면 새 Pod가 `CreateContainerConfigError`(env) 또는
`FailedMount`(volume)로 멈춥니다. `replicas: 1`의 기본 RollingUpdate는 새 Pod가
Ready가 될 때까지 기존 Pod를 종료하지 않으므로 서비스는 유지되고 롤아웃만
정체됩니다.

## 배포 및 확인

ArgoCD에서 API/Runner manifest와 NetworkPolicy diff를 먼저 확인합니다. 이 단계 전에
`agent_orchestration_deployment_enabled=true`와 immutable deployment commit SHA가
적용돼 있어야 합니다. 다음 항목을
만족하지 않으면 sync하지 않습니다.

- API와 Runner image가 모두 `@sha256:` immutable digest입니다.
- Experiment API를 포함하는 promotion에서는 API digest가 API container, API DB
  bootstrap, Runner OAuth bootstrap, PreSync migration Job의 두 container까지 다섯 image
  reference에 모두 같은 값으로 pin돼 있습니다.
- API에는 `agent-orchestration-api` KSA, DB runtime `emptyDir`, `/tmp` `emptyDir`,
  그리고 #539에서 추가한 baseline-reader private key Secret volume만 있고 OAuth
  PVC가 없습니다. API에는 `ORCH_API_TOKEN`, `ORCH_RUNNER_TOKEN`, #525의
  `ORCH_GITHUB_TOKEN`, #539의 baseline-reader Secret 네 개만 전달되며 OAuth
  bootstrap Secret은 전달되지 않습니다. 이 네 개는 모두 API Pod에만 전달하고
  UI·Runner에는 전달하지 않습니다. baseline-reader Secret volume은 API 컨테이너
  에만 mount되고 DB bootstrap initContainer에는 없습니다.
- Runner에는 `agent-orchestration-runner` KSA와 1Gi `ReadWriteOnce` PVC만 있으며,
  DB URL·DB password·Cloud SQL secret reference가 없습니다. Runner에는
  `ORCH_RUNNER_TOKEN`만 전달되고 `ORCH_API_TOKEN`은 전달되지 않습니다.
- Runner ingress는 API pod label과 node subnet의 kubelet probe만 TCP 8080으로
  허용합니다. Runner Service는 port-forward하거나 외부 노출하지 않습니다.
- API ingress는 node subnet의 kubelet probe·초기 `kubectl port-forward`와 Streamlit UI
  Pod label만 TCP 8000으로 허용하는 default-deny입니다. 이후 in-cluster 호출자를 추가하면
  해당 caller label/port만 허용하는 ingress rule을 같은 변경에서 추가합니다.
- UI는 ClusterIP TCP 8501로만 제공하며 node subnet ingress, API TCP 8000, DNS만
  허용한다. Ingress·LoadBalancer·Cloud SQL·Runner·public HTTPS egress는 없다.
- API egress는 Runner TCP 8080, Cloud SQL TCP 5432, DNS, Workload Identity metadata,
  private Google APIs VIP(`199.36.153.8/30`) TCP 443, Kubernetes API TCP 443,
  그리고 #525에서 추가한 공개 인터넷 TCP 443이고, Runner egress에는 Cloud SQL
  TCP 5432가 없습니다. API는 Codex/OpenAI 직접 호출을 여전히 하지 않습니다.
- **#525 이전까지 API에는 public HTTPS egress가 없었습니다.** 이슈 발행이
  `gh issue create` subprocess로 `api.github.com` TCP 443에 직접 나가야 하고, `gh`가
  전달 환경변수를 화이트리스트로 제한해 `HTTPS_PROXY`를 넘기지 않으므로 proxy로
  대체할 수 없어 이 경계를 바꿨습니다. 이 클러스터의 NetworkPolicy provider는
  Calico라 FQDN 규칙을 쓸 수 없고, GitHub이 게시하는 api 대역 24개 중 20개가 /32라
  수시로 교체되므로 고정 CIDR은 예고 없이 발행을 502로 만듭니다. 그래서 공개 인터넷
  443을 열되 사설·링크로컬 대역(`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `100.64.0.0/10`, `169.254.0.0/16`, `127.0.0.0/8`)을 `except`로 제외합니다. 이 목록은
  RFC1918/RFC6598 기준이라 dev CIDR 변수가 바뀌어도 함께 고칠 필요가 없습니다.
  Runner는 Codex 호출 때문에 이미 같은 `0.0.0.0/0` TCP 443을 갖고 있습니다.
- 이 규칙이 넓히는 범위를 정확히 봐 두십시오. 사설 대역 목적지(Runner, Cloud SQL,
  in-cluster ClusterIP, private Google APIs VIP)는 `except`로 계속 차단되므로 그
  위협 모델은 유지됩니다. 다만 이 클러스터는 GKE DNS 엔드포인트가
  `allow_external_traffic = true`(`terraform/envs/dev/gke.tf:151-155`)라 공개 주소를
  가지므로, 이 규칙은 API Pod에서 그 엔드포인트로 가는 **네트워크 경로를 새로
  엽니다**. 실제 도달에는 여전히 `container.clusters.connect` IAM이 필요하고 API
  GSA에는 그 권한이 없습니다. 공개 IP 엔드포인트 쪽은 `master_authorized_networks`가
  비어 있어 별도로 막혀 있습니다. 이 두 전제가 바뀌면 이 egress 규칙을 다시
  평가해야 합니다.
- API 컨테이너는 `readOnlyRootFilesystem: true`를 유지하되 `/tmp`에 64Mi emptyDir을
  mount합니다. `gh`가 호출마다 `HOME`·`GH_CONFIG_DIR`·`TMPDIR`용과 issue body 파일용
  임시 디렉터리를 만들기 때문이며, 이것이 없으면 발행이 실패합니다.
- Runner의 `CODEX_TIMEOUT_SEC`은 110초이고, API와 Runner는
  `agent-orchestration-runner-timeout` ConfigMap의 같은 `CODEX_RUNNER_TIMEOUT_SEC` key를
  `valueFrom.configMapKeyRef`로 주입받아 모두 120초를 사용합니다. Runner는 기동 시
  `CODEX_TIMEOUT_SEC + 5 < CODEX_RUNNER_TIMEOUT_SEC`를 검증하며, 공통 key가 없으면
  startup을 fail-close합니다. macOS 기본 Ruby와 GitHub Actions의 고정 Ruby가 제공하는
  Psych만 사용하는 `ruby scripts/check-agent-orchestration-timeout-contract.rb`로 ConfigMap
  값, 양 deployment의 참조, 양 pod template의 timeout annotation을 sync 전에 검사합니다.
  ConfigMap timeout을 바꾸는 manifest commit은 같은 값을 양 annotation에도 갱신해야 합니다.
  annotation 변경은 pod template hash를 바꾸므로 API와 Runner가 함께 새 env 값으로
  rollout됩니다. ConfigMap만 갱신하면 기존 Pod는 서로 다른 env 값으로 남을 수 있으므로
  금지합니다. lint job도 같은 checker와 부정 mutation self-test를 실행하므로 timeout
  계약 위반은 CI에서 실패합니다.
  Runner의 동시 실행 한도를 초과하면 대기열에 넣지 않고 즉시 503을 반환하며 API도
  해당 상태를 503으로 보존합니다.

sync 뒤에는 다음 상태를 확인합니다.

```bash
kubectl -n autoresearch rollout status deployment/agent-orchestration-runner --timeout=5m
kubectl -n autoresearch rollout status deployment/agent-orchestration-api --timeout=5m
kubectl -n autoresearch get pod -l app.kubernetes.io/part-of=agent-orchestration
kubectl -n autoresearch get job agent-orchestration-api-migration \
  -o jsonpath='{.status.succeeded}'
```

마지막 명령의 출력은 `1`이어야 합니다. 실패한 PreSync Job은 API rollout을 막으므로
`kubectl logs`를 credential을 출력하지 않는 범위에서 확인하고 sync를 재시도하기 전에
원인을 해결합니다.

## 공통 post-sync end-to-end gate

이 gate는 최초 배포, 이미지 promotion, 이미지 rollback, OAuth force 복구 뒤의 모든
sync에 적용합니다. Runner Service를 port-forward하거나 외부 노출하지 않습니다.
권한 있는 운영자는 API Service만 port-forward합니다.

```bash
kubectl -n autoresearch port-forward service/agent-orchestration-api 8000:8000
curl --fail --silent http://127.0.0.1:8000/healthcheck
```

1. `/chat` 호출 전 `chat_interactions`의 최대 id를 비민감 메타데이터로만 기록합니다.

   ```sql
   SELECT COALESCE(MAX(id), 0) AS pre_chat_max_id
   FROM chat_interactions;
   ```

2. 승인된 `X-Orch-Token`과 승인된 비공개 요청 본문으로 API `/chat`을 실제 호출합니다.
   HTTP status **201만** 확인하고 response body는 stdout에 출력하지 않습니다. prompt,
   token, OAuth/auth 원문도 shell history, stdout, runbook, 티켓에 기록하거나 출력하지
   않습니다. 요청 본문은 승인된 비공개 stdin 경로로만 공급하고, 다음 명령은 status를
   shell 변수에서만 비교해 response·prompt·token·OAuth 값을 출력하지 않습니다. 공유
   토큰은 curl argv에 넣지 않고 0600 임시 header 파일에서만 읽으며, path·payload·token은
   출력하지 않습니다. subshell의 EXIT trap은 HTTP 201 성공·실패·중단 모두에서 header
   파일을 삭제합니다. HUP/INT/TERM handler는 즉시 `exit 1`로 종료해 signal 뒤의
   `printf`나 `curl`이 실행되어 0600 경로를 다시 만들 수 없게 하고, 그 종료가 EXIT
   cleanup을 실행합니다.

   ```bash
   (
   if [ -z "${ORCH_API_TOKEN:-}" ]; then
     echo "ORCH_API_TOKEN is required for the approved /chat smoke test." >&2
     exit 1
   fi

   chat_header_file="$(mktemp)" || exit 1
   trap 'rm -f "$chat_header_file"' EXIT
   trap 'exit 1' HUP INT TERM
   chmod 600 "$chat_header_file" || exit 1
   printf 'X-Orch-Token: %s\n' "$ORCH_API_TOKEN" > "$chat_header_file" || exit 1

   chat_status="$(
     curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}' \
       --request POST http://127.0.0.1:8000/chat \
       --header "Content-Type: application/json" \
       --header "@${chat_header_file}" \
       --data-binary @-
   )"
   test "$chat_status" = "201"
   )
   ```

3. 아래 조회가 1행을 반환해 `pre_chat_max_id`보다 큰 id의 새 저장 행을 확인하면
   end-to-end gate를 통과합니다. `id`, `model`, `latency_ms`, `created_at` 이외의 값은
   출력하지 않습니다.

   ```sql
   SELECT id, model, latency_ms, created_at
   FROM chat_interactions
   WHERE id > :pre_chat_max_id
   ORDER BY id ASC
   LIMIT 1;
   ```

HTTP 201 또는 신규 저장 행 확인에 실패하면 deployment success로 진행하지 않습니다.
승인된 incident/rollback 판단으로 멈추고, Runner를 외부 노출하거나 민감 값을 출력해
원인을 추적하지 않습니다.

### Experiment API v0 추가 gate

Experiment API promotion에서는 `/openapi.json`에 `/experiments`와
`/experiments/{experiment_id}` 경로가 있는지 먼저 확인합니다. 그 뒤 `/chat`과 같은
`X-Orch-Token`으로 비민감 test hypothesis 하나를 생성하고 목록 조회가 성공하는지를
확인합니다. 응답 본문·UUID·token은 stdout이나 티켓에 남기지 않습니다. 다음 명령은
응답 JSON을 0600 임시 파일에만 보관하고 생성·목록 HTTP status만 검증합니다.

```bash
(
if [ -z "${ORCH_API_TOKEN:-}" ]; then
  echo "ORCH_API_TOKEN is required for the approved Experiment API smoke test." >&2
  exit 1
fi

experiment_header_file="$(mktemp)" || exit 1
experiment_response_file="$(mktemp)" || exit 1
experiment_openapi_file="$(mktemp)" || exit 1
trap 'rm -f "$experiment_header_file" "$experiment_response_file" "$experiment_openapi_file"' EXIT
trap 'exit 1' HUP INT TERM
chmod 600 "$experiment_header_file" "$experiment_response_file" "$experiment_openapi_file" || exit 1
printf 'X-Orch-Token: %s\n' "$ORCH_API_TOKEN" > "$experiment_header_file" || exit 1

curl --fail --silent --output "$experiment_openapi_file" \
  http://127.0.0.1:8000/openapi.json || exit 1
python3 -c 'import json, sys; paths = json.load(open(sys.argv[1], encoding="utf-8"))["paths"]; assert "/experiments" in paths; assert "/experiments/{experiment_id}" in paths' \
  "$experiment_openapi_file" || exit 1

create_status="$(curl --fail --silent --output "$experiment_response_file" --write-out '%{http_code}' \
  --request POST http://127.0.0.1:8000/experiments \
  --header 'Content-Type: application/json' \
  --header "@${experiment_header_file}" \
  --data '{"hypothesis":"deployment smoke test","metadata":{"source":"gke-smoke"}}')"
test "$create_status" = "201" || exit 1

list_status="$(curl --fail --silent --output /dev/null --write-out '%{http_code}' \
  --header "@${experiment_header_file}" http://127.0.0.1:8000/experiments?limit=1)"
test "$list_status" = "200"
)
```

이 gate는 Experiment table 생성과 API DB session 연결을 함께 증명합니다. 더 상세한
상태 event·log·promotion 계약은 앱 저장소 OpenAPI와 #483 테스트를 기준으로 확인하며,
운영 smoke test에 실제 실험 입력·사용자 데이터·LLM prompt를 넣지 않습니다.

### 이슈 발행 gate (#525 이후 필수)

**위의 두 gate는 이슈 발행 경로를 전혀 검증하지 못합니다.** 스코프가 잘못된 PAT,
egress `except` 오설정, `/tmp` 미마운트는 셋 다 `/chat`과 `POST /experiments`를 통과한
뒤 발행 시점에만 502로 드러납니다. v0.7.0 이상을 sync한 뒤에는 아래를 반드시
수행합니다.

먼저 `/openapi.json`에 두 경로가 실제로 노출됐는지 확인합니다. 이것이 이번 롤아웃의
직접 증거입니다.

```bash
(
openapi_file="$(mktemp)" || exit 1
trap 'rm -f "$openapi_file"' EXIT
trap 'exit 1' HUP INT TERM
chmod 600 "$openapi_file" || exit 1

curl --fail --silent --output "$openapi_file" http://127.0.0.1:8000/openapi.json || exit 1
python3 -c 'import json, sys; paths = json.load(open(sys.argv[1], encoding="utf-8"))["paths"]; assert "/experiments/{experiment_id}/issue" in paths; assert "/experiments/{experiment_id}/steps" in paths' \
  "$openapi_file"
)
```

그다음 위 smoke test에서 만든 실험 id로 실제 발행을 1회 수행합니다. 발행은 대상
저장소에 실제 이슈를 만드므로, 확인 후 해당 이슈를 닫고 `auto-experiment` label이
붙었는지 함께 확인합니다. 발행 경로는 자동 재시도하지 않는 것이 앱 spec의 결정이므로
실패해도 같은 실험으로 반복 호출하지 않습니다.

| 응답 | 원인 | 확인할 곳 |
| --- | --- | --- |
| 201 | 정상 | 대상 저장소의 새 `[AR]` 이슈 |
| 502 `authentication_failed` | PAT이 잘못됐거나 만료 | Secret `agent-orchestration-github-token` |
| 502 `label_missing` | 대상 저장소에 `auto-experiment` label 없음 | `gh label list --repo <owner/repo>` |
| 502 (timeout·연결 실패) | egress 또는 `/tmp` 문제 | `agent-orchestration-api-egress`, API Pod의 `/tmp` mount |
| 429 | `ORCH_ISSUE_DAILY_LIMIT` 초과 | DB의 `issue_published_at` 24시간 내 건수 |

이 gate가 실패하면 deployment success로 진행하지 않고 incident/rollback 판단으로
멈춥니다.

## 롤백과 보안 확인

이미지 promotion은 검증된 API와 Runner immutable digest를 manifest commit에 함께
반영하는 것으로 시작합니다. Application(#526)이 `agent_orchestration_deployment_enabled=true`에서
`targetRevision=main`을 automated sync(prune·selfHeal 없음)로 추적하므로, 다음
순서를 지킵니다.

1. 배포할 digest를 포함한 manifest commit을 만들고 reviewed PR로 main에 merge합니다.
2. `enabled=true`인 정상 운영 상태라면 별도 admin apply 없이 automated sync가 최대
   3분 폴링으로 자동 반영합니다. `enabled=false`(비상 차단) 상태라면
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 reviewed admin apply를 먼저
   수행해야 sync가 시작됩니다.
3. ArgoCD에서 반영된 revision과 diff를 확인한 뒤 Runner Ready 및 API
   `/healthcheck`를 확인하고
   [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 통과합니다.

이미지 rollback도 같은 순서입니다. 이전에 검증된 API digest 다섯 container 참조와
Runner digest를 포함한 새 rollback manifest commit을 만들어 reviewed PR로 main에
merge합니다. `enabled=true`인 정상 운영 상태라면 automated sync가 이 commit도 같은
방식으로 자동 반영합니다. sync 뒤에는
[공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 통과해야 하며,
실패하면 deployment success로 진행하지 않고 incident/rollback 판단으로 멈춥니다.
OAuth 장애와 이미지 장애를 같은 롤백으로 처리하지 않습니다.

rollback manifest를 만들기 전에는 대상 Alembic revision이 `chat_interactions` table과
sequence를 변경하지 않는 additive migration인지 source diff로 다시 대조합니다. rollback
sync 뒤에는 [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 반드시
실행합니다. 이 gate는 rollback 직전의 최대 chat id보다 큰 새 저장 행과 HTTP 201을 함께
확인하므로, 이전 API digest에서도 `/chat`과 PostgreSQL 저장이 계속 동작함을 증명합니다.

### Terraform 소유 RBAC와 ArgoCD 소유 manifest가 갈리는 변경

`agent-orchestration-api` KSA의 실험 Job 상태 조회 RBAC(`terraform/admin/autoresearch-k8s`,
#484)와 그 권한을 실제로 쓰게 하는 egress(`deploy/agent-orchestration/network-policy.yaml`,
ArgoCD가 관리)처럼, 같은 기능 변경이 서로 다른 두 배포 경로를 탈 때가 있습니다(#497에서
실측).

- RBAC는 admin apply로 즉시 반영됩니다.
- `deploy/agent-orchestration/`의 NetworkPolicy 등 manifest는 **main에 merge된 뒤
  ArgoCD automated sync가 반영해야만** 실제로 적용됩니다(최대 3분 폴링). PR merge
  자체는 GitHub 저장소 상태만 바꿀 뿐, 그 순간에 클러스터가 즉시 갱신되지는
  않습니다.

두 변경을 같은 PR·같은 커밋에 묶어 머지해도, automated sync가 실제로 반영을
끝냈는지 확인하지 않으면 "권한은 있는데 실제로 호출할 경로가 아직 없는" 창이
잠시 남을 수 있습니다. `kubectl auth can-i`는 RBAC만 확인하므로 이 간극을
드러내지 않습니다 — NetworkPolicy 반영 여부는
`kubectl -n autoresearch get networkpolicy agent-orchestration-api-egress -o yaml`로 직접
대조해야 합니다.

RBAC와 NetworkPolicy를 함께 바꾸는 변경은 다음 순서를 지킵니다.

1. RBAC(Terraform)와 NetworkPolicy(manifest) 변경을 같은 PR에 포함해 머지합니다.
2. `agent_orchestration_deployment_enabled`가 이미 `true`인 정상 운영 상태라면
   RBAC 변경만 admin apply로 반영합니다. flag가 `false`(비상 차단)라면 [롤백과
   보안 확인](#롤백과-보안-확인) 절차처럼
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true` admin apply를 함께 수행해야
   Application이 `main`을 추적하기 시작합니다. `terraform/admin/argocd-k8s/main.tf`의
   `targetRevision = var.agent_orchestration_deployment_enabled ? "main" :
   "agent-orchestration-disabled"`가 이 분기를 결정합니다.
3. ArgoCD에서 automated sync가 머지 커밋을 반영했는지 확인해 NetworkPolicy를
   검증합니다.
4. live NetworkPolicy와, 권한을 실제로 쓰는 Pod에서의 연결 가능 여부를 함께 확인합니다.
   권한 확인만으로는 충분하지 않습니다.

이 순서는 권한/경로를 **확장**하는 변경 기준입니다. `enable_experiment_job_creation`을
되돌리거나 egress 규칙을 제거하는 등 **축소** 방향 변경은 반대 순서(먼저 NetworkPolicy로
경로를 막고, 그다음 RBAC를 회수)를 씁니다 — 그래야 "경로는 없는데 권한만 남아있는" 창이
아니라 "권한은 있는데 경로가 없는" 더 안전한 중간 상태만 거칩니다.

### 이미지 참조 원자성

API digest는 `api` container, API의 `bootstrap-db` init container, Runner의
`bootstrap-codex-auth` init container, PreSync migration Job의 두 container 다섯 곳을
**같은 commit에서 함께** 갱신합니다. Runner init container는 API 이미지의
`bootstrap_secrets` CLI와 OAuth 파일 형식 계약을 실행하고, migration Job은 같은 image의
Alembic migration을 실행하므로 어느 하나라도 이전 digest로 남기면 runtime·bootstrap·DB
schema 계약이 달라질 수 있습니다. CI 계약 검사는 다섯 API image reference의 동등성과 모든
image의 `@sha256` pin을 검증합니다.

Runner 본체만 promotion할 때에는 Runner container digest만 별도로 바꿀 수 있습니다.
다만 API 또는 Runner 중 한 쪽의 rollback이 필요하고 해당 release 조합의 호환성이
검증되지 않았다면, 마지막으로 end-to-end gate를 통과한 API 다섯 참조와 Runner 본체
digest의 조합 전체를 새 rollback manifest commit으로 되돌립니다.

마지막으로 다음을 확인합니다.

```bash
git grep -nE 'auth\.json|ORCH_DATABASE_URL|postgresql://|BEGIN [A-Z ]*PRIVATE KEY' -- deploy/agent-orchestration docs/runbooks/2026-07-30-agent-orchestration-gke.md
kubectl -n autoresearch get networkpolicy agent-orchestration-api-egress agent-orchestration-runner -o yaml
```

첫 명령은 실제 credential이나 완성 DB URL이 아닌 이름·검증 패턴만 보여야 합니다.
Secret payload가 출력되면 터미널 기록을 보관하지 말고 노출 범위를 평가한 뒤 즉시
회수·교체 절차를 진행합니다.

## 서비스 폐기

`agent_orchestration_app`은 custom database role membership을 가지므로 Terraform은
`google_sql_user` 삭제에 `deletion_policy = "ABANDON"`을 사용합니다. 즉 Terraform
config에서 user resource를 제거해도 Cloud SQL API로 user 삭제나 role membership
해제를 시도하지 않고 state만 정리합니다. 다음 순서를 건너뛰면 삭제 실패 또는
의도치 않은 데이터 손실이 생길 수 있습니다.

1. **서비스 중지**: ArgoCD에서 Application sync를 중단하고 API·Runner Deployment를
   `replicas: 0`으로 축소한 뒤 Ready Pod가 없는지 확인합니다. API Service의
   port-forward와 `/chat` 호출도 중지합니다.
2. **DB 정리**: 보존이 필요하면 먼저 `chat_interactions`를 승인된 저장소로 export합니다.
   그 뒤 migration owner가 전용 DB에서 보존하지 않을 table/sequence를 정리하고,
   Cloud SQL API로 runtime user의 database role membership을 revoke합니다. user/role
   삭제 전에는 실행 중인 연결이 없는지 확인합니다. 기본 식별자 기준 예시는 다음과
   같습니다.

   ```sql
   -- 이 명령은 반드시 agent_orchestration DB에 접속한 상태에서 실행한다.
   -- runtime role이 받은 public schema 및 database 권한을 모두 회수하고, role이
   -- 소유한 객체가 있으면 함께 제거해 이후 DROP ROLE이 실패하지 않게 한다.
   DROP OWNED BY agent_orchestration_runtime;
   DROP TABLE IF EXISTS public.chat_interactions CASCADE;
   ```

   ```bash
   # Cloud SQL built-in user의 database role membership과 user 삭제는 SQL DROP ROLE이
   # 아니라 Cloud SQL API로 수행한다. CLOUD_SQL_INSTANCE는 shared instance 이름이다.
   gcloud sql users assign-roles agent_orchestration_app \
     --type=BUILT_IN \
     --instance="$CLOUD_SQL_INSTANCE" \
     --database-roles= \
     --revoke-existing-roles

   gcloud sql users delete agent_orchestration_app \
     --instance="$CLOUD_SQL_INSTANCE"
   ```

   gcloud user delete가 성공한 뒤 group role을 삭제합니다. `DROP OWNED`는 target DB의
   권한만 정리하므로, 향후 이 role을 다른 DB에 재사용했다면 각 DB에서 같은 정리를
   마친 뒤에만 role을 삭제할 수 있습니다. 현재 role은 Agent Orchestration 전용이며
   다른 DB에 부여하지 않습니다.

   ```sql
   DROP ROLE agent_orchestration_runtime;
   ```

   `DROP TABLE`은 데이터와 연결된 sequence를 삭제하므로 export 확인 없이 실행하지 않습니다.
   DB 자체를 제거할지 여부는 보존 정책에 따라 별도로 결정합니다.
3. **Terraform config/state 정리**: 위 SQL 정리가 완료된 뒤에만 Agent Orchestration
   manifest와 Terraform resource를 제거합니다. reviewed plan에서 shared Cloud SQL
   instance 교체·삭제가 없고 `google_sql_user.agent_orchestration`이 API delete가 아닌
   abandon/state 제거로 표시되는지 확인한 뒤 apply합니다. OAuth bootstrap secret은
   `prevent_destroy`가 있으므로 payload 보존·삭제 여부를 별도 승인으로 결정합니다.
