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
   Terraform drift만으로 자동 갱신되지 않습니다. 불일치하면 sync하지 말고 새
   manifest commit에 현재 output을 반영한 뒤 target SHA → reviewed admin apply →
   manual sync 전체 순서를 다시 수행합니다.

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
| `REPLACE_WITH_DB_NAME` | dev output `agent_orchestration_deployment_contract.database_name` |
| `REPLACE_WITH_DB_USER` | dev output `agent_orchestration_deployment_contract.database_user` |

`agent_orchestration_deployment_contract` output은 비밀번호와 OAuth payload를
출력하지 않습니다. output 값을 조회할 때도 CI log, PR 본문, 티켓에 복사하지
않습니다.

### 최초 활성화 매니페스트

최초 활성화에서는 위 자리표시자를 release workflow가 검증한 immutable digest와
적용된 dev Terraform output의 비밀이 아닌 식별자로만 바꾼 별도 manifest commit을
만듭니다. 이 commit은 Application이 아직 disabled 상태인 동안 검토·병합할 수
있습니다. 병합 뒤에만 그 정확한 main commit SHA를
`AGENT_ORCHESTRATION_TARGET_REVISION`으로 지정하고,
`AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`와 함께 reviewed admin apply를
수행합니다. mutable tag, PR head SHA, 비밀번호·OAuth payload·요청 토큰은 이
commit에 넣지 않습니다.

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
3. 그 commit의 main SHA를 target revision Variable에 지정하고 reviewed admin apply 뒤
   ArgoCD manual sync를 수행합니다. `kubectl rollout restart`로 ArgoCD 관리
   manifest를 직접 변경하지 않습니다.
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
3. 그 manifest commit의 정확한 소문자 40자리 SHA를
   non-secret GitHub Actions Variable `AGENT_ORCHESTRATION_TARGET_REVISION`에 설정하고,
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 함께 설정합니다. 재사용 Terraform
   plan/apply workflow는 이 두 Variables를 각각
   `TF_VAR_agent_orchestration_target_revision`과
   `TF_VAR_agent_orchestration_deployment_enabled`로 같은 값으로 주입합니다. 그 뒤
   reviewed Terraform plan을 확인한 뒤 Terraform apply로 ArgoCD Application의
   `targetRevision`을 갱신합니다.
   **manifest commit만 만들거나 ArgoCD sync만 실행해서는 안 됩니다.** Application은
   고정 SHA를 추적하므로 target revision이 새 SHA가 아니면 새 init 인자를 읽지
   않습니다.
4. ArgoCD에서 해당 revision의 diff를 확인한 뒤 manual sync합니다. Runner rollout이
   Ready이고 Runner readiness probe의 `/healthcheck`가 성공하는지 확인한 다음, API
   `/healthcheck`도 확인한 뒤 [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를
   수행합니다. 이 gate는 OAuth 복구 전용 절차가 아니라 모든 배포의 공통 검증입니다.
5. 위 Runner/API readiness와 공통 post-sync end-to-end gate가 모두 성공한 경우에만
   다음 manifest commit에서 `--replace-existing`을 제거합니다. 그 다음 commit의
   정확한 40자리 SHA로 `AGENT_ORCHESTRATION_TARGET_REVISION`을 다시 갱신하고,
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 설정합니다. reviewed Terraform
   plan/apply와 ArgoCD manual sync를 같은 순서로 수행합니다.

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

## 배포 및 확인

ArgoCD에서 API/Runner manifest와 NetworkPolicy diff를 먼저 확인합니다. 이 단계 전에
`agent_orchestration_deployment_enabled=true`와 immutable deployment commit SHA가
적용돼 있어야 합니다. 다음 항목을
만족하지 않으면 sync하지 않습니다.

- API와 Runner image가 모두 `@sha256:` immutable digest입니다.
- API에는 `agent-orchestration-api` KSA와 DB runtime `emptyDir`만 있고 OAuth PVC가
  없습니다. API에는 `ORCH_API_TOKEN`과 `ORCH_RUNNER_TOKEN`만 전달되며 OAuth
  bootstrap Secret은 전달되지 않습니다.
- Runner에는 `agent-orchestration-runner` KSA와 1Gi `ReadWriteOnce` PVC만 있으며,
  DB URL·DB password·Cloud SQL secret reference가 없습니다. Runner에는
  `ORCH_RUNNER_TOKEN`만 전달되고 `ORCH_API_TOKEN`은 전달되지 않습니다.
- Runner ingress는 API pod label과 node subnet의 kubelet probe만 TCP 8080으로
  허용합니다. Runner Service는 port-forward하거나 외부 노출하지 않습니다.
- API ingress는 node subnet의 kubelet probe·초기 `kubectl port-forward`만 TCP 8000으로
  허용하는 default-deny입니다. 이후 in-cluster 호출자를 추가하면 해당 caller
  label/port만 허용하는 ingress rule을 같은 변경에서 추가합니다.
- API egress는 Runner TCP 8080, Cloud SQL TCP 5432, DNS, Workload Identity metadata,
  private Google APIs VIP(`199.36.153.8/30`) TCP 443뿐이고 Runner egress에는 Cloud SQL
  TCP 5432가 없습니다. API는 Codex/OpenAI 직접 호출을 하지 않으므로 전체 인터넷
  HTTPS egress를 열지 않습니다.
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
```

## 공통 post-sync end-to-end gate

이 gate는 최초 배포, 이미지 promotion, 이미지 rollback, OAuth force 복구 뒤의 모든
manual sync에 적용합니다. Runner Service를 port-forward하거나 외부 노출하지 않습니다.
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

## 롤백과 보안 확인

이미지 promotion은 검증된 API와 Runner immutable digest를 manifest commit에 함께
반영하는 것으로 시작합니다. 그러나 manifest commit만 만들고 ArgoCD sync하는 것은
충분하지 않습니다. Application은 고정된
`agent_orchestration_target_revision`만 읽으므로, 다음 순서를 지킵니다.

1. 배포할 digest를 포함한 manifest commit을 만들고 정확한 소문자 40자리 SHA를
   확인합니다.
2. 그 SHA로 non-secret GitHub Actions Variable
   `AGENT_ORCHESTRATION_TARGET_REVISION`을 갱신하고,
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 함께 설정합니다. 이 Variables가
   `TF_VAR_agent_orchestration_target_revision` 및
   `TF_VAR_agent_orchestration_deployment_enabled`로 주입된 Terraform 변경의 reviewed
   plan을 확인하고 apply합니다.
3. ArgoCD에서 갱신된 Application target revision과 diff를 확인한 뒤 manual sync하고,
   Runner Ready 및 API `/healthcheck`를 확인한 뒤
   [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 통과합니다.

이미지 rollback도 같은 순서입니다. 이전에 검증된 두 digest를 포함한 새 rollback
manifest commit을 만들고, 그 commit의 정확한 40자리 SHA로
`AGENT_ORCHESTRATION_TARGET_REVISION`을 갱신하며
`AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`로 함께 설정합니다. 두 Variables가 주입된
Terraform Application을 reviewed plan/apply로 갱신한 뒤에만 ArgoCD manual sync합니다.
sync 뒤에는 [공통 post-sync end-to-end gate](#공통-post-sync-end-to-end-gate)를 통과해야
하며, 실패하면 deployment success로 진행하지 않고 incident/rollback 판단으로 멈춥니다.
OAuth 장애와 이미지 장애를 같은 롤백으로 처리하지 않습니다.

### 이미지 참조 원자성

API digest는 `api` container, API의 `bootstrap-db` init container, Runner의
`bootstrap-codex-auth` init container 세 곳을 **같은 commit에서 함께** 갱신합니다.
세 번째 init container도 API 이미지의 `bootstrap_secrets` CLI와 OAuth 파일 형식 계약을
실행하므로, 이 참조만 이전 digest로 남기면 API runtime과 Runner bootstrap의 인자·파일
형식이 달라질 수 있습니다. CI 계약 검사는 세 API image reference의 동등성과 모든
image의 `@sha256` pin을 검증합니다.

Runner 본체만 promotion할 때에는 Runner container digest만 별도로 바꿀 수 있습니다.
다만 API 또는 Runner 중 한 쪽의 rollback이 필요하고 해당 release 조합의 호환성이
검증되지 않았다면, 마지막으로 end-to-end gate를 통과한 API 세 참조와 Runner 본체
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
