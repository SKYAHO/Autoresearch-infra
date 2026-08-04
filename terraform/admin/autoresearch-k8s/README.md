# Autoresearch Kubernetes 경계

이 admin Terraform root는 dev GKE의 일반 애플리케이션 워크로드에 필요한
Kubernetes 측 경계를 별도 state로 관리합니다.

- `autoresearch` namespace
- app GCP service account와 연결된 `autoresearch-app` KSA
- DNS, Cloud SQL, Redis Cluster PSC, Workload Identity, HTTPS만 허용하는 egress
  NetworkPolicy
- `feast-apply-dev`, `feast-apply-prod` namespace + 환경별 KSA + GitHub Actions용
  Job RBAC + 전용 egress/ingress NetworkPolicy (#424, `feast_apply.tf`)
- `experiment-runtime` namespace + Workload Identity KSA + observer-only Airflow RBAC +
  ResourceQuota/LimitRange + Private Google APIs 전용 NetworkPolicy (#485,
  `experiment_runtime.tf`)
- Agent Orchestration API·Codex Runner 전용 KSA. 실제 Deployment/Service/PVC와
  Agent 전용 NetworkPolicy는 `deploy/agent-orchestration/`의 ArgoCD plain manifest가
  소유하며, 이 root의 기존 namespace-wide egress 정책에서는 제외한다.
- `autoresearch-experiments` namespace, 실험 Job 전용 KSA, 제한된 API 관찰 RBAC,
  Pod Security `restricted`, quota·LimitRange, 기본 차단 NetworkPolicy (#484)

GCP Redis Cluster, PSC subnet/policy, TLS CA Secret Manager, app GSA와 Workload
Identity IAM member는 `terraform/envs/dev`에서 관리합니다. 애플리케이션
Deployment, cluster-aware client와 실제 Feature key hash tag 규칙은
`SKYAHO/Autoresearch` 저장소에서 관리합니다.

## 최초 적용 전 확인

이 root는 GKE API에 직접 접근하므로 운영자 인증과 네트워크 접근이 필요합니다.
먼저 dev root를 apply해 Redis Cluster와 CA secret을 준비하고 다음 값을 확인합니다.

```bash
scripts/terraform-env --environment dev --root terraform/envs/dev output redis_cluster_name
scripts/terraform-env --environment dev --root terraform/envs/dev output redis_discovery_address
scripts/terraform-env --environment dev --root terraform/envs/dev output redis_discovery_port
scripts/terraform-env --environment dev --root terraform/envs/dev output redis_psc_subnet_cidr
scripts/terraform-env --environment dev --root terraform/envs/dev output redis_server_ca_secret_id
```

실제 값이 든 `terraform.tfvars`는 커밋하지 않습니다. 예시 파일을 복사한 뒤 dev
output과 대조합니다.

```bash
cp terraform/admin/autoresearch-k8s/terraform.tfvars.example \
  terraform/admin/autoresearch-k8s/terraform.tfvars

scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s init
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s validate
```

live cluster에 `autoresearch` namespace나 KSA가 이미 존재하면 삭제·재생성하지
말고 초기화 후 최초 apply 전에 state로 import합니다.

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s import \
  kubernetes_namespace_v1.autoresearch autoresearch

scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s import \
  kubernetes_service_account_v1.app autoresearch/autoresearch-app
```

## Plan 및 적용

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s plan \
  -var-file=terraform.tfvars
```

`apply`는 dev Redis Cluster apply 완료, live namespace import 여부, NetworkPolicy
영향과 사용자 승인을 확인한 뒤에만 수행합니다.

## Auto Research 실험 Job 경계 (#484)

실험마다 별도 Kubernetes Job을 만들되, 일반 앱 namespace와 실행 신원을 공유하지
않습니다. 이 root는 Kubernetes 경계만, `terraform/envs/dev`는 결과 버킷과 GCP
Workload Identity IAM만 관리합니다. 애플리케이션 저장소는 고정 Job 템플릿·허용
이미지 digest 검증·상태 watcher를 담당합니다.

| 구분 | 값 | 의도 |
|---|---|---|
| namespace | `autoresearch-experiments` | 실험 Pod와 기존 앱을 분리 |
| Job KSA | `experiment-job` | 결과 버킷 쓰기 전용 Workload Identity |
| API KSA | `autoresearch/agent-orchestration-api` | Job·Pod·로그 상태와 결과의 인증된 읽기만 허용. 이 RBAC를 실제로 쓰려면 API Pod의 egress에 Kubernetes API 경로가 있어야 한다 — 해당 정책은 이 root가 아니라 `deploy/agent-orchestration/network-policy.yaml`이 소유한다(#484에서 services CIDR·control plane CIDR TCP 443 추가) |
| Pod Security | `restricted` / `v1.35` | privileged·host namespace·hostPath·root 실행 등 위험한 Pod 거부 |
| 기본 네트워크 | ingress/egress 차단 | DNS, GKE metadata, Private Google APIs HTTPS만 명시 허용 |

`experiment-job` KSA에는 Kubernetes RoleBinding을 만들지 않고, Kubernetes API 토큰
자동 마운트(`automount_service_account_token`)도 `false`로 둡니다. Workload Identity의
GCS 인증은 GKE metadata server 경로를 사용하므로 컨테이너 내부에 Kubernetes 토큰이
필요하지 않습니다.

### Job 생성 권한 활성화 조건

`enable_experiment_job_creation` 기본값은 `false`입니다. 이 상태에서 API KSA는 Job,
Pod, Pod 로그를 조회만 할 수 있고 Job을 생성·삭제·수정할 수 없습니다. 아래 조건을
모두 충족하고 별도 보안 검토·승인을 받은 경우에만 local `terraform.tfvars`에서
`true`로 변경합니다.

1. API가 사용자 입력을 Job manifest로 그대로 전달하지 않고 고정 템플릿만 사용한다.
2. 이미지가 mutable tag가 아닌 허용 목록의 digest인지 검증한다.
3. Job 이름·label·결과 GCS prefix·CPU/메모리·`backoffLimit: 0`은 API의 고정 템플릿이
   강제하고, `activeDeadlineSeconds`·TTL은 아래 4번 정책이 서버 측에서 강제한다.
   CPU/메모리는 namespace ResourceQuota·LimitRange가 함께 상한을 건다.
4. 이 root의 `autoresearch-experiment-job-contract` ValidatingAdmissionPolicy가
   ServiceAccount 변경, digest 없는 image(`initContainers` 포함), `batch-od`
   nodeSelector/toleration 계약 위반(빈 목록 포함), 승인된 Artifact Registry 밖
   이미지, `automountServiceAccountToken: true`, `activeDeadlineSeconds`·
   `ttlSecondsAfterFinished` 누락 또는 3600초 초과를 서버 측에서 거부한다. 두 시간
   필드를 정책에 둔 것은 완료 Job이 quota를 무기한 점유하는 경로를 막기 위해서다
   (API KSA에 `delete`가 없어 회수 수단이 TTL뿐이다). Pod Security `restricted`는
   privileged·host namespace 등 별도 위험 필드를 거부한다.
5. 아래 runbook의 RBAC·Pod Security·NetworkPolicy 음성 검증을 적용 cluster에서
   수행한다.
6. `batch-od`의 현재 실제 사용자를 확인한다(#523, 2026-08-04 조사). `batch-od`는
   #297 대응으로 만들어졌지만, `Autoresearch-airflow`의 `AutoresearchBatchPodOperator`는
   `node_selector`/`tolerations`를 넘기지 않으면 `batch-spot`을 기본값으로 쓰고
   실제로 이를 override하는 DAG가 없다 — Action Log KPO를 포함해 모든 KPO가 지금도
   `batch-spot`에서 돈다(#297 이후 채택된 완화책은 pool 이전이 아니라 체크포인트
   재개 + timeout 연장, #150). 즉 `batch-od`는 현재 다른 워크로드가 없는 유휴
   pool이며, 이 상태에서는 별도 경합 계획 없이 experiment Job이 그대로 써도 된다.
   이후 Airflow나 다른 컴포넌트가 `batch-od`에 실제로 스케줄되도록 바뀌면(예:
   `node_selector`를 명시적으로 override하는 DAG 변경), 그 시점에 capacity·우선순위
   경합 계획을 다시 검토한다.

권한을 활성화한 뒤 문제가 발견되면 API 배포에서 제출을 먼저 중지하고, 승인된
Terraform apply로 값을 `false`로 되돌립니다. 이 변경은 새 Job 제출만 막고 이미 실행
중인 Job·Pod·GCS 업로드를 중단하지 않습니다. 취소는 API에 `delete` 권한을 추가하지
않은 현재 MVP에서는 제공하지 않으며, 종료·quota 회수는 `activeDeadlineSeconds`와 TTL
controller에 의존합니다. namespace, KSA, 결과 버킷을 롤백 수단으로 삭제하지 않습니다.

### 네트워크와 용량 상한

실험 namespace는 외부 HTTPS, Cloud SQL, Redis, MLflow를 기본 허용하지 않습니다.
결과 업로드는 Private Google APIs VIP `199.36.153.8/30`의 TCP 443만 사용합니다.
새 목적지가 필요하면 목적지 CIDR/selector, 포트, GSA IAM, 데이터 분류를 함께
검토하는 별도 이슈가 필요합니다.

초기 dev 상한은 Job·Pod 각각 2개, 총 request/limit 2 vCPU/4 GiB입니다.
`count/jobs.batch`는 완료 Job도 TTL controller가 삭제할 때까지 계산하므로, 실제 제출
병목은 terminal Pod가 아닌 Job 객체 수입니다. 컨테이너 기본 request/limit은
500m/1 GiB이고, 단일 컨테이너는 1 vCPU/2 GiB를 넘을 수 없습니다. Job 템플릿과
admission 검증은 `batch-od` nodeSelector와 `workload=batch-od:NoSchedule` toleration을
강제해야 합니다. `batch-od`는 #297 대응으로 만든 min 0/max 2 on-demand pool이지만,
현재 `Autoresearch-airflow`의 어떤 KPO도 이 pool로 스케줄되지 않습니다(#523 —
`AutoresearchBatchPodOperator` 기본값은 `batch-spot`이고 override하는 DAG가 없음).
따라서 지금은 experiment Job이 이 pool을 사실상 독점하며, quota 상한(2 vCPU/4 GiB)은
pool 용량(e2-standard-2 2노드) 안에 들어갑니다. 다른 워크로드가 `batch-od`를 실제로
쓰기 시작하면 그 변경에서 capacity·우선순위 경합 계획을 별도로 승인해야 합니다.
운영 중에는 batch-od node/pod Pending·autoscaler·CPU/memory를 관측합니다. 운영 검증
절차와 Job manifest 계약은
[`docs/runbooks/2026-08-01-auto-research-experiment-job.md`](../../../docs/runbooks/2026-08-01-auto-research-experiment-job.md)를
따릅니다.

## NetworkPolicy

NetworkPolicy는 namespace 전체 pod를 egress isolation 대상으로 삼습니다.

| 대상 | CIDR/selector | Port |
|---|---|---|
| 같은 namespace | pod selector | 전체 |
| DNS | services CIDR, `kube-system` | UDP/TCP 53 |
| Cloud SQL | `private_services_cidr` | TCP 5432 |
| Redis discovery | `redis_psc_subnet_cidr` | TCP 6379 |
| Redis data nodes | `redis_psc_subnet_cidr` | TCP 11000-13047 |
| GKE metadata | link-local endpoint | TCP 80, 987, 988 |
| HTTPS API | `0.0.0.0/0` | TCP 443 |
| MLflow tracking (#302) | services CIDR(`cluster_services_cidr`) + `mlflow` namespace selector | TCP 5000 |

Redis Cluster client는 discovery endpoint에서 topology를 받은 뒤 node endpoint로
직접 연결합니다. 따라서 TCP 6379만 열면 연결이 완료되지 않으며 11000-13047도
같은 전용 PSC `/29` 안에서 허용해야 합니다. 앱이 다른 포트를 사용한다면 배포 전
최소 CIDR/port 규칙을 별도로 검토합니다.

MLflow tracking 규칙(#302)은 Inference Server 파드가 `RERANK_MODEL_SOURCE=registry`로
`ctr-model@champion` alias를 해석하고 모델 artifact를 내려받는 데 필요합니다.
`mlflow` namespace의 ClusterIP:5000은 DNS·Cloud SQL 등 기존 규칙 어디에도 걸리지
않아 별도로 추가했습니다. 이 클러스터의 Calico는 service 트래픽을 DNAT 이전에
평가하므로 ClusterIP VIP는 services CIDR로 열고, DNAT 이후 평가하는 dataplane을
위해 namespace selector 규칙을 함께 둡니다(기존 DNS 규칙과 동일한 이중 패턴).
모델 artifact는 `mlflow-artifacts:/` 스킴으로 MLflow 서버를 경유하므로 파드가
GCS에 직접 접근할 필요는 없습니다.

## Paired Feast experiment runtime 경계 (#485)

`experiment-runtime` namespace는 일반 앱, Airflow 일반 배치, Feast apply Job과
분리됩니다. `experiment-runtime` KSA는 dev root의
`autoresearch-dev-exp-runtime` GSA에만 연결하며, 기본값을 override하면 두 root의
output이 같은 email을 가리키는지 plan 전에 대조합니다.

namespace에는 Pod Security Admission `restricted`를 enforce/audit/warn으로 적용하고,
동시 Job/Pod 4개, requests 4 vCPU/8 GiB, limits 8 vCPU/16 GiB의 ResourceQuota를
둡니다. 컨테이너 LimitRange는 request 1 vCPU/2 GiB, default/max 2 vCPU/4 GiB입니다.
이 quota는 namespace 사용량 상한일 뿐 GKE node allocatable capacity나 autoscaler
확장을 예약·보장하지 않습니다. 실제 Job 활성화 전에는 node pool capacity를 별도로
확인해야 합니다.

`experiment-runtime-airflow-observer` Role은 실제 in-cluster Airflow
`airflow/airflow` KSA 하나에만 Job/Pod get/list/watch와 Pod log get을 허용합니다.
`autoresearch-batch` KPO KSA와 Helm chart 소유 `airflow-scheduler` KSA에는 이
RoleBinding을 추가하지 않습니다. 첫 변경에서는 Airflow observer KSA와 runtime KSA
모두 `jobs.create`를 갖지 않으며 output의 `job_creation_enabled`도 `false`입니다.
생성 Job의 KSA, immutable image digest, deadline/TTL, restricted Pod 사양을 검증하는
ValidatingAdmissionPolicy가 적용·검증되기 전에는 create 권한을 켜지 않습니다. runtime
KSA에는 RoleBinding이 없습니다.

ingress는 전면 차단합니다. egress는 kube-dns, GKE metadata
`169.254.169.254:80`·`169.254.169.252:987/988`, Private Google APIs VIP
`199.36.153.8/30:443`만 허용합니다. 외부 `0.0.0.0/0:443`, Redis PSC, Cloud SQL,
MLflow egress와 Secret 접근 경로는 포함하지 않습니다.

적용 전에는 dev/admin output의 identity 계약과 fail-closed 상태를 확인합니다.

```bash
terraform -chdir=terraform/envs/dev output experiment_runtime_contract
terraform -chdir=terraform/admin/autoresearch-k8s output \
  experiment_runtime_kubernetes_contract
```

## Cluster 및 hash tag smoke test

실제 apply 후 `autoresearch-app` KSA를 사용하는 GKE 내부 임시 pod에서 수행합니다.
IAM access token은 Workload Identity로 런타임 발급하고 파일, Secret Manager,
명령행 인수, 로그에 저장하지 않습니다. `redis-cli`에는 `REDISCLI_AUTH` 환경 변수를
사용하고 테스트가 끝나면 unset합니다.

1. Secret Manager에서 `redis_server_ca_secret_id`의 최신 CA bundle을 임시 파일로
   가져옵니다.
2. IAM access token을 발급해 `REDISCLI_AUTH`에만 설정합니다.
3. discovery endpoint에 cluster/TLS 모드로 연결합니다.

```bash
redis-cli -h "${REDIS_DISCOVERY_ADDRESS}" \
  -p "${REDIS_DISCOVERY_PORT}" \
  --tls --cacert /tmp/redis-server-ca.pem -c
```

연결 후 topology와 같은 hash tag 동작을 확인합니다.

```redis
PING
CLUSTER SHARDS
SET feature:{user:100}:age 29
SET feature:{user:100}:watch_time 120
CLUSTER KEYSLOT feature:{user:100}:age
CLUSTER KEYSLOT feature:{user:100}:watch_time
MGET feature:{user:100}:age feature:{user:100}:watch_time
SET feature:{user:200}:age 31
MGET feature:{user:100}:age feature:{user:200}:age
```

앞의 두 `CLUSTER KEYSLOT` 결과가 같고 첫 `MGET`이 `29`, `120`을 반환해야
합니다. 마지막 `MGET`은 두 key의 slot이 다르면 `CROSSSLOT`을 반환해야 합니다.
테스트 key를 삭제하고 `REDISCLI_AUTH`와 CA 임시 파일을 제거합니다.

hash tag는 함께 조회·갱신해야 하는 관련 key에만 사용합니다. 모든 key에 동일한
tag를 넣으면 하나의 shard에 부하가 집중되어 2-shard 구성의 목적을 잃습니다.

## Inference Server Redis 접속 정보 Secret (#302)

Inference Server(`deploy/serving`)가 Feast Online Store(Redis)에 접속하려면
`autoresearch-serving-redis` Secret이 `autoresearch` namespace에 있어야 합니다.
manifest에는 endpoint를 평문으로 두지 않고(공개 저장소, MLflow와 동일 원칙),
운영자가 dev root output 값을 그대로 주입합니다. Git·Terraform state 어디에도
값이 남지 않습니다.

```bash
REDIS_HOST=$(scripts/terraform-env --environment dev --root terraform/envs/dev output -raw redis_discovery_address)
REDIS_PORT=$(scripts/terraform-env --environment dev --root terraform/envs/dev output -raw redis_discovery_port)
kubectl -n autoresearch create secret generic autoresearch-serving-redis \
  --from-literal=REDIS_HOST="$REDIS_HOST" \
  --from-literal=REDIS_PORT="$REDIS_PORT"
```

값을 화면·로그·PR 본문에 출력하지 않습니다. Redis TLS CA는 이 Secret에 두지
않고, 파드가 `REDIS_CA_SECRET_ID`로 런타임에 Secret Manager에서 직접 읽습니다.

롤백은 Secret을 삭제하는 것으로 완결됩니다.

```bash
kubectl -n autoresearch delete secret autoresearch-serving-redis
```

## 팀원 접근 (#252)

`autoresearch` 네임스페이스에는 기본 RBAC가 없어 팀원이 앱/모델 파드를
`kubectl`로 조회하거나 `port-forward`로 검증하지 못했다(`airflow`·`mlflow`·
`monitoring`에는 팀 접근이 있음). `mlflow-k8s`(#236)와 동일하게 최소 권한을 준다.

- 부여: built-in ClusterRole `view`(secret 제외 read) namespace RoleBinding +
  `pods/portforward` create 전용 Role `autoresearch-portforward` +
  `pods/exec` create 전용 Role `autoresearch-exec`(#266).
- 제외: write/delete·cluster-admin은 부여하지 않는다.
- `pods/exec`(#266)는 앱 저장소의 Feast·Redis GKE 검증 runbook이 파드 안에서
  `feast apply`·materialize·조회 스크립트를 실행하는 절차라 필요하다. 다만 exec은
  파드 내부 환경변수·마운트를 볼 수 있어 `view`보다 강한 권한이므로, 대상은 앱
  namespace 검증 담당(viewer 목록)과 동일하게만 유지한다.
- 대상은 `autoresearch_viewer_user_emails`(로컬 tfvars). 저장소엔 placeholder만.

```bash
# 로컬 terraform.tfvars에 대상 계정 추가 후
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s apply
```

plan은 대상 계정 수에 따라 Role 2개(`autoresearch_portforward`,
`autoresearch_exec`) + 계정별 RoleBinding 3개(view, portforward, exec)만 add로
보여야 한다.

검증(대상 계정 자격으로):

```bash
kubectl auth can-i get pods                              -n autoresearch --as=<계정>  # → yes
kubectl auth can-i create pods --subresource=portforward -n autoresearch --as=<계정>  # → yes
kubectl auth can-i create pods --subresource=exec        -n autoresearch --as=<계정>  # → yes (#266)
kubectl auth can-i get secrets                           -n autoresearch --as=<계정>  # → no
```

> GKE에서는 Google 계정을 `--as`로 impersonate한 `can-i` 결과가 IAM 경로 때문에
> 실제 권한과 다르게 `no`로 나올 수 있다(이미 동작 중인 port-forward도 `no`로 보임).
> 확실한 확인은 `kubectl get rolebindings -n autoresearch`로 대상 계정의 binding과
> `roleRef`를 직접 대조하거나, 대상 계정 본인이 실행해 보는 것이다.

롤백: 대상 계정을 `autoresearch_viewer_user_emails`에서 제거하고 다시 apply하면
해당 RoleBinding이 삭제된다.

## Feast apply GKE Job 경계 (#424)

`feast apply`의 online store 고아 키 정리(`full_scan_for_deletion: true`)는
Redis(PSC, VPC 내부)에 직접 닿아야 하므로 실행 주체를 VPC 안 GKE Job으로 둡니다.
GHA는 환경별 Job 생성·결과 판정만 합니다. GCP IAM, WIF provider와 KSA Workload
Identity binding은 `terraform/envs/dev`가, namespace/RBAC/NetworkPolicy는 이 root가
관리합니다.

### 불변 환경 튜플

GitHub Environment → WIF provider → GSA → namespace → KSA는 하나의 신뢰 경계이며,
각 행의 값을 개별적으로 교환하거나 재사용해서는 안 됩니다. 환경을 추가하거나 값을
변경할 때는 두 Terraform root와 앱 저장소 Environment 설정을 함께 검토합니다.

| GitHub Environment | WIF provider | GSA 기본값 | namespace / KSA |
|---|---|---|---|
| `dev` | `github-feast-dev` | `autoresearch-dev-feast-dev@<project>.iam.gserviceaccount.com` | `feast-apply-dev` / `feast-apply` |
| `prod` | `github-feast-prod` | `autoresearch-dev-feast-prod@<project>.iam.gserviceaccount.com` | `feast-apply-prod` / `feast-apply` |

`terraform/envs/dev`의 `feast_apply_kubernetes_identities`와 이 root의
`feast_apply_identities`는 위 namespace/KSA를 동일하게 유지해야 합니다. admin root
기본값은 `resource_prefix`와 `project_id`로 GSA email을 파생합니다. GSA email을
override하면 dev/prod 두 키와 비어 있지 않은 유효 email을 모두 제공해야 합니다.

각 환경에는 namespace, KSA, Role, RoleBinding, ingress deny-all policy, egress policy가
각각 하나씩 생성됩니다. RoleBinding subject와 KSA annotation은 같은 환경의 GSA를
공유하므로 dev GSA는 prod namespace의 RoleBinding을 얻지 못합니다.

두 Feast apply namespace에는 `pod-security.kubernetes.io/enforce=baseline`도
설정합니다. Role이 Job 생성 권한을 가지므로, baseline이 `hostNetwork`, `hostPID`,
`hostIPC`를 거부하지 않으면 임의 Job이 host network namespace를 사용해
NetworkPolicy의 Redis PSC egress 경계를 우회할 수 있습니다.

### RBAC와 NetworkPolicy

각 Role에는 다음 동사만 있습니다.

| 리소스 | 동사 |
|---|---|
| `batch/jobs` | `get`, `list`, `watch`, `create`, `delete` |
| `pods` | `get`, `list` |
| `pods/log` | `get` |

`watch`는 `kubectl wait`가 list+watch로 동작해 필요합니다. `secrets`,
`pods/exec`, `update`, `patch`, ClusterRole과 cross-namespace RoleBinding은 부여하지
않습니다. Job 갱신은 **delete 후 create** 절차를 전제로 합니다.

두 namespace의 ingress는 전면 차단합니다. egress는 DNS(services CIDR 및
`kube-system` selector의 Calico 이중 규칙), GKE metadata(80, 987, 988), HTTPS(443)를
공통으로 허용합니다. Cloud SQL은 필요하지 않아 제외합니다.

| 환경 | Redis PSC discovery/data-node egress | 이유 |
|---|---|---|
| `dev` | 없음 | dev GSA에는 Redis와 Redis CA IAM이 없으며 Redis network path도 두지 않음 |
| `prod` | `redis_psc_subnet_cidr`, TCP 6379 및 11000-13047 | online store 고아 키 정리와 topology 연결 |

### 적용 전후 확인

`terraform-plan.yml`은 admin root를 실행하지 않으므로 PR에서는 아래 로컬 검증과
security diff 검토가 필요합니다. 실제 apply는 별도 승인 뒤 계획 결과를 검토한 후에만
수행합니다.

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s validate
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s plan -var-file=terraform.tfvars
```

적용이 승인·완료된 뒤에는 환경별 subject와 NetworkPolicy를 다음처럼 확인합니다.

```bash
for namespace in feast-apply-dev feast-apply-prod; do
  kubectl get namespace "$namespace" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}'
done

kubectl auth can-i create jobs -n feast-apply-dev \
  --as=autoresearch-dev-feast-dev@<project>.iam.gserviceaccount.com  # yes
kubectl auth can-i create jobs -n feast-apply-prod \
  --as=autoresearch-dev-feast-dev@<project>.iam.gserviceaccount.com  # no
kubectl -n feast-apply-dev get networkpolicy feast-apply-dev-egress -o yaml
kubectl -n feast-apply-prod get networkpolicy feast-apply-prod-egress -o yaml
```

첫 두 명령은 dev GSA가 prod namespace Job을 만들 수 없음을 확인합니다. dev egress
출력에는 `redis_psc_subnet_cidr`, 6379, 11000-13047 규칙이 없어야 하며 prod 출력에만
있어야 합니다. GKE의 GSA `--as` 결과는 IAM impersonation 경로 때문에 실제와 다르게
나올 수 있으므로, 최종 확인 때에는 각 namespace의 RoleBinding subject와 roleRef도
함께 대조합니다.

두 namespace label 출력은 모두 `baseline`이어야 합니다. 다음 server-side dry-run은
개발 namespace에서 `hostNetwork: true` Job을 만들려는 음성 검증이며, Pod Security
Admission에 의해 거부되어야 합니다. `--dry-run=server`를 유지해 실제 Job을 만들지
않습니다.

```bash
kubectl -n feast-apply-dev create --dry-run=server -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: feast-apply-hostnetwork-negative
spec:
  template:
    spec:
      hostNetwork: true
      restartPolicy: Never
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
EOF
```

롤백은 Feast apply 실행을 중지한 뒤 #424 이전 Terraform 구성을 복원하여 기존 공유
provider/GSA/namespace를 먼저 되살리는 절차입니다. bootstrap → dev root → admin root
순으로 plan을 검토하고 별도 승인된 apply로 반영한 뒤, 기존 공유 GSA와 namespace가
복구된 것을 확인한 경우에만 앱 저장소 GitHub Environment의 provider/GSA/namespace/KSA
값을 이전 호환 튜플로 복원합니다.

## 장애 복구와 롤백

replica 0과 persistence disabled 구성은 노드 장애 시 Online Store 데이터 복구를
보장하지 않습니다. 장애 또는 전체 flush 후에는 다음 순서를 따릅니다.

1. Online Store read/write 트래픽과 증분 materialization을 중지합니다.
2. `CLUSTER SHARDS`와 `PING`으로 두 primary shard가 ready인지 확인합니다.
3. 앱 저장소의 Feast feature repo에서 offline store 기준 전체 범위를
   `feast materialize <START_TIMESTAMP> <END_TIMESTAMP>`로 재적재합니다.
4. 대표 entity key의 online feature 조회와 동일 hash tag `MGET`을 검증한 뒤
   트래픽을 재개합니다.

인프라 롤백은 애플리케이션의 Redis 사용을 먼저 중지하고 NetworkPolicy Redis
규칙 제거 plan과 Redis Cluster/PSC 제거 plan을 각각 검토합니다. namespace나 KSA
삭제는 다른 워크로드에 영향을 줄 수 있으므로 롤백 수단으로 사용하지 않습니다.
실제 삭제와 state 조작은 별도 사용자 승인 없이는 수행하지 않습니다.
