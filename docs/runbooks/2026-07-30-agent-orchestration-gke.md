# Agent Orchestration GKE 내부 배포 Runbook

Agent Orchestration은 FastAPI API와 Codex Runner를 서로 다른 Pod, Kubernetes
ServiceAccount(KSA), GCP ServiceAccount(GSA), 파일 시스템으로 분리한 dev 전용
내부 서비스입니다. API만 Cloud SQL 전용 DB와 DB password Secret Manager 접근 권한을
가지며, Runner는 Codex OAuth bootstrap 시크릿 하나만 읽습니다.

이 문서는 `deploy/agent-orchestration/`의 immutable digest 주입, OAuth 초기 인증,
ArgoCD manual sync, 내부 healthcheck와 PostgreSQL 저장 검증·롤백 절차를 다룹니다.
외부 Ingress, LoadBalancer, 사용자별 OAuth, 외부 공개 API는 범위가 아닙니다.

## 적용 전 조건

1. `terraform/envs/dev`와 `terraform/admin/autoresearch-k8s` 변경이 별도 승인된
   Terraform plan을 거쳐 적용되어야 합니다. `agent_orchestration` DB/user, API·Runner
   GSA/KSA, 각 Secret Manager IAM이 먼저 존재해야 합니다.
2. 앱 저장소 release workflow가 아래의 **검증된 immutable digest** 두 개를 출력해야
   합니다. tag(`:latest`, `:sha-*` 포함)만으로 배포하지 않습니다.

   - `autoresearch-agent-orchestration-api@sha256:...`
   - `autoresearch-agent-orchestration-runner@sha256:...`

3. `terraform/admin/argocd-k8s`의 `agent-orchestration` Application이 먼저
   적용되어 있어야 합니다. source path는 `deploy/agent-orchestration`, destination은
   `autoresearch`, sync 정책은 `CreateNamespace=false`인 manual sync입니다. 기본값
   `agent_orchestration_deployment_enabled=false`에서는 Application이 존재하지 않는
   ref를 바라보므로 sync할 수 없습니다.

`deploy/agent-orchestration/*.yaml`의 `REPLACE_WITH_*` 문자열이 하나라도 남아
있으면 의도적으로 배포하지 않습니다. release digest와 Terraform output을 확인한
후 별도 배포 커밋에서만 다음 값을 모두 교체합니다.

| 자리표시자 | 출처 |
| --- | --- |
| `REPLACE_WITH_API_IMMUTABLE_DIGEST` | 앱 release workflow API `digest_ref` |
| `REPLACE_WITH_RUNNER_IMMUTABLE_DIGEST` | 앱 release workflow Runner `digest_ref` |
| `REPLACE_WITH_PROJECT_ID` | dev Terraform `project_id` |
| `REPLACE_WITH_DB_PASSWORD_SECRET_ID` | dev output `agent_orchestration_deployment_contract.db_password_secret_id` |
| `REPLACE_WITH_CODEX_AUTH_BOOTSTRAP_SECRET_ID` | dev output `agent_orchestration_deployment_contract.codex_auth_bootstrap_secret_id` |
| `REPLACE_WITH_CLOUD_SQL_PRIVATE_IP` | dev output `cloud_sql_private_ip_address` |

`agent_orchestration_deployment_contract` output은 비밀번호와 OAuth payload를
출력하지 않습니다. output 값을 조회할 때도 CI log, PR 본문, 티켓에 복사하지
않습니다.

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

## OAuth bootstrap 시크릿 초기 등록

Runner PVC는 Codex가 갱신한 인증 상태를 유지합니다. bootstrap 시크릿은 PVC에
`auth.json`이 없는 최초 기동 때만 읽습니다. 기존 PVC의 갱신된 `auth.json`은
덮어쓰지 않습니다.

신뢰된 운영자 로컬 환경에서 별도 `CODEX_HOME`으로 로그인합니다. 실제 `auth.json`,
access token, `codex login` 출력은 터미널 공유·Git·PR·티켓에 붙이지 않습니다.

```bash
work_dir="$(mktemp -d)"
chmod 700 "$work_dir"
export CODEX_HOME="$work_dir/codex"
mkdir -m 700 "$CODEX_HOME"

codex login

# secret id는 Terraform output에서 확인한다. 값은 출력하지 않는다.
gcloud secrets versions add "$CODEX_AUTH_BOOTSTRAP_SECRET_ID" \
  --data-file="$CODEX_HOME/auth.json"
```

명령이 성공하면 민감 파일이 든 임시 디렉터리를 운영자 환경에서 제거하고
`CODEX_HOME`을 unset합니다. Runner가 OAuth 오류를 보이면 먼저 Deployment를
`replicas: 0`으로 축소한 뒤, 새 version을 추가하고 Ready 확인 후 1로 복구합니다.
PVC를 삭제하는 방식은 갱신된 인증 상태를 잃으므로 OAuth 장애 복구의 기본 절차가
아닙니다.

## API 요청 토큰 등록

API는 `/chat`에 `X-Orch-Token`을 요구합니다. 이 토큰은 DB password와 OAuth
시크릿과 다른 공유 요청 토큰이며, API GSA에는 Secret Manager accessor를 추가하지
않습니다. 허가된 운영자는 임시 파일(권한 0600)에서 Kubernetes Secret
`agent-orchestration-api-token`의 `ORCH_API_TOKEN` key만 생성·갱신합니다. payload를
manifest, Git, Terraform state, shell history에 넣지 않습니다.

`autoresearch` namespace의 `view` 권한에는 Secret read가 포함되지 않습니다. 토큰을
호출자에게 전달할 별도 보관·배포 방식은 팀의 승인된 비밀 관리 절차를 따릅니다.

## 배포 및 확인

ArgoCD에서 API/Runner manifest와 NetworkPolicy diff를 먼저 확인합니다. 이 단계 전에
`agent_orchestration_deployment_enabled=true`와 immutable deployment commit SHA가
적용돼 있어야 합니다. 다음 항목을
만족하지 않으면 sync하지 않습니다.

- API와 Runner image가 모두 `@sha256:` immutable digest입니다.
- API에는 `agent-orchestration-api` KSA와 DB runtime `emptyDir`만 있고 OAuth PVC가
  없습니다.
- Runner에는 `agent-orchestration-runner` KSA와 1Gi `ReadWriteOnce` PVC만 있으며,
  DB URL·DB password·Cloud SQL secret reference가 없습니다.
- Runner ingress source는 API pod label 하나와 TCP 8080뿐입니다.
- API egress는 Runner TCP 8080, Cloud SQL TCP 5432, DNS, Workload Identity metadata,
  HTTPS뿐이고 Runner egress에는 Cloud SQL TCP 5432가 없습니다.

sync 뒤에는 다음 상태를 확인합니다.

```bash
kubectl -n autoresearch rollout status deployment/agent-orchestration-runner --timeout=5m
kubectl -n autoresearch rollout status deployment/agent-orchestration-api --timeout=5m
kubectl -n autoresearch get pod -l app.kubernetes.io/part-of=agent-orchestration
```

초기 검증은 권한 있는 운영자의 port-forward로 제한합니다. Runner Service를
port-forward하거나 외부 노출하지 않습니다.

```bash
kubectl -n autoresearch port-forward service/agent-orchestration-api 8000:8000
curl --fail --silent http://127.0.0.1:8000/healthcheck
curl --fail --silent --request POST http://127.0.0.1:8000/chat \
  --header "Content-Type: application/json" \
  --header "X-Orch-Token: ${ORCH_API_TOKEN}" \
  --data '{"prompt":"한 문장으로 상태를 알려주세요."}'
```

Cloud SQL에서는 저장된 행의 메타데이터만 확인합니다. 프롬프트, 모델 응답, token
원문, OAuth 내용은 출력하지 않습니다.

```sql
SELECT id, model, latency_ms, created_at
FROM chat_interactions
ORDER BY id DESC
LIMIT 1;
```

## 롤백과 보안 확인

이미지 장애는 이전에 검증된 API와 Runner digest를 함께 되돌리는 배포 커밋을 만든
뒤 ArgoCD에서 diff 확인 후 manual sync합니다. OAuth 장애와 이미지 장애를 같은
롤백으로 처리하지 않습니다.

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
