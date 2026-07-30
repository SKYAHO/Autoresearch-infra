# Autoresearch Kubernetes 경계

이 admin Terraform root는 dev GKE의 일반 애플리케이션 워크로드에 필요한
Kubernetes 측 경계를 별도 state로 관리합니다.

- `autoresearch` namespace
- app GCP service account와 연결된 `autoresearch-app` KSA
- DNS, Cloud SQL, Redis Cluster PSC, Workload Identity, HTTPS만 허용하는 egress
  NetworkPolicy
- `feast-apply-dev`, `feast-apply-prod` namespace + 환경별 KSA + GitHub Actions용
  Job RBAC + 전용 egress/ingress NetworkPolicy (#424, `feast_apply.tf`)

GCP Redis Cluster, PSC subnet/policy, TLS CA Secret Manager, app GSA와 Workload
Identity IAM member는 `terraform/envs/dev`에서 관리합니다. 애플리케이션
Deployment, cluster-aware client와 실제 Feature key hash tag 규칙은
`SKYAHO/Autoresearch` 저장소에서 관리합니다.

## 최초 적용 전 확인

이 root는 GKE API에 직접 접근하므로 운영자 인증과 네트워크 접근이 필요합니다.
먼저 dev root를 apply해 Redis Cluster와 CA secret을 준비하고 다음 값을 확인합니다.

```bash
terraform -chdir=terraform/envs/dev output redis_cluster_name
terraform -chdir=terraform/envs/dev output redis_discovery_address
terraform -chdir=terraform/envs/dev output redis_discovery_port
terraform -chdir=terraform/envs/dev output redis_psc_subnet_cidr
terraform -chdir=terraform/envs/dev output redis_server_ca_secret_id
```

실제 값이 든 `terraform.tfvars`는 커밋하지 않습니다. 예시 파일을 복사한 뒤 dev
output과 대조합니다.

```bash
cp terraform/admin/autoresearch-k8s/terraform.tfvars.example \
  terraform/admin/autoresearch-k8s/terraform.tfvars

terraform -chdir=terraform/admin/autoresearch-k8s init
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check
terraform -chdir=terraform/admin/autoresearch-k8s validate
```

live cluster에 `autoresearch` namespace나 KSA가 이미 존재하면 삭제·재생성하지
말고 초기화 후 최초 apply 전에 state로 import합니다.

```bash
terraform -chdir=terraform/admin/autoresearch-k8s import \
  kubernetes_namespace_v1.autoresearch autoresearch

terraform -chdir=terraform/admin/autoresearch-k8s import \
  kubernetes_service_account_v1.app autoresearch/autoresearch-app
```

## Plan 및 적용

```bash
terraform -chdir=terraform/admin/autoresearch-k8s plan \
  -var-file=terraform.tfvars
```

`apply`는 dev Redis Cluster apply 완료, live namespace import 여부, NetworkPolicy
영향과 사용자 승인을 확인한 뒤에만 수행합니다.

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
REDIS_HOST=$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_address)
REDIS_PORT=$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_port)
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
terraform -chdir=terraform/admin/autoresearch-k8s apply
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
| `dev` | `github-feast-dev` | `autoresearch-dev-feast-apply-dev@<project>.iam.gserviceaccount.com` | `feast-apply-dev` / `feast-apply` |
| `prod` | `github-feast-prod` | `autoresearch-dev-feast-apply-prod@<project>.iam.gserviceaccount.com` | `feast-apply-prod` / `feast-apply` |

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
terraform -chdir=terraform/admin/autoresearch-k8s validate
terraform -chdir=terraform/admin/autoresearch-k8s plan -var-file=terraform.tfvars
```

적용이 승인·완료된 뒤에는 환경별 subject와 NetworkPolicy를 다음처럼 확인합니다.

```bash
for namespace in feast-apply-dev feast-apply-prod; do
  kubectl get namespace "$namespace" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}'
done

kubectl auth can-i create jobs -n feast-apply-dev \
  --as=autoresearch-dev-feast-apply-dev@<project>.iam.gserviceaccount.com  # yes
kubectl auth can-i create jobs -n feast-apply-prod \
  --as=autoresearch-dev-feast-apply-dev@<project>.iam.gserviceaccount.com  # no
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
kubectl -n feast-apply-dev create job feast-apply-hostnetwork-negative \
  --image=busybox:1.36 \
  --dry-run=server \
  --overrides='{"apiVersion":"batch/v1","spec":{"template":{"spec":{"hostNetwork":true}}}}' \
  -- sh -c 'true'
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
