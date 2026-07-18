# Autoresearch Kubernetes 경계

이 admin Terraform root는 dev GKE의 일반 애플리케이션 워크로드에 필요한
Kubernetes 측 경계를 별도 state로 관리합니다.

- `autoresearch` namespace
- app GCP service account와 연결된 `autoresearch-app` KSA
- DNS, Cloud SQL, Redis Cluster PSC, Workload Identity, HTTPS만 허용하는 egress
  NetworkPolicy

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

Redis Cluster client는 discovery endpoint에서 topology를 받은 뒤 node endpoint로
직접 연결합니다. 따라서 TCP 6379만 열면 연결이 완료되지 않으며 11000-13047도
같은 전용 PSC `/29` 안에서 허용해야 합니다. 앱이 다른 포트를 사용한다면 배포 전
최소 CIDR/port 규칙을 별도로 검토합니다.

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

## 팀원 접근 (#252)

`autoresearch` 네임스페이스에는 기본 RBAC가 없어 팀원이 앱/모델 파드를
`kubectl`로 조회하거나 `port-forward`로 검증하지 못했다(`airflow`·`mlflow`·
`monitoring`에는 팀 접근이 있음). `mlflow-k8s`(#236)와 동일하게 최소 권한을 준다.

- 부여: built-in ClusterRole `view`(secret 제외 read) namespace RoleBinding +
  `pods/portforward` create 전용 Role `autoresearch-portforward`.
- 제외: `pods/exec`·write·cluster-admin은 부여하지 않는다.
- 대상은 `autoresearch_viewer_user_emails`(로컬 tfvars). 저장소엔 placeholder만.

```bash
# 로컬 terraform.tfvars에 대상 계정 추가 후
terraform -chdir=terraform/admin/autoresearch-k8s apply
```

plan은 대상 계정 수에 따라 `kubernetes_role_v1.autoresearch_portforward` 1개 +
계정별 RoleBinding 2개(view, portforward)만 add로 보여야 한다.

검증(대상 계정 자격으로):

```bash
kubectl auth can-i get pods                              -n autoresearch --as=<계정>  # → yes
kubectl auth can-i create pods --subresource=portforward -n autoresearch --as=<계정>  # → yes
kubectl auth can-i create pods --subresource=exec        -n autoresearch --as=<계정>  # → no
kubectl auth can-i get secrets                           -n autoresearch --as=<계정>  # → no
```

롤백: 대상 계정을 `autoresearch_viewer_user_emails`에서 제거하고 다시 apply하면
해당 RoleBinding이 삭제된다.

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
