# Online Store Redis Cluster 설계

> Issue: #129 | 작성일: 2026-07-11 | 요구사항 정정: 2026-07-13

## 목적

Feast Feature Store의 Online Store로 사용할 Redis를 dev GCP 프로젝트에
2-shard Memorystore for Redis Cluster로 구성한다. Cluster는 기존 dev VPC에
Private Service Connect(PSC)로만 연결하고, GKE의 `autoresearch` namespace
워크로드만 필요한 egress 경로를 사용하도록 Kubernetes NetworkPolicy를 별도
Terraform state에서 관리한다.

멘토 요구사항의 학습 목표인 Redis Cluster hash slot, key hash tag, `MGET`의
single-slot 제약을 인프라 연결 검증에 포함한다. 실제 Feature key 생성 규칙과
cluster-aware client 구현은 `SKYAHO/Autoresearch` 저장소에서 연계한다.

## 현재 상태

- dev GCP 리소스는 `terraform/envs/dev` GCS state에서 관리한다.
- custom VPC와 Cloud SQL용 Private Service Access(PSA) 연결 및
  `192.168.0.0/20` 예약 대역이 이미 구성되어 있다.
- GKE는 private node와 Calico NetworkPolicy enforcement를 사용한다.
- app GSA와 Workload Identity IAM member가 있고, 이 변경에서
  `terraform/admin/autoresearch-k8s`가 namespace, KSA, NetworkPolicy를 소유한다.
- 2026-07-11 초안의 Basic 단일 `google_redis_instance` 구현은 apply되지 않았고,
  변경된 #129 요구사항에 맞춰 이 설계에서 폐기한다.

## 결정

### 1. 2-shard Memorystore for Redis Cluster

`google_redis_cluster`를 사용하며 dev 기본 cluster shape는 다음과 같다.

- `shard_count = 2`: primary shard와 data node 2개
- `replica_count = 0`: shard당 replica 없음, 총 cluster usage unit 2
- `node_type = REDIS_SHARED_CORE_NANO`: node당 총 1.4 GB, writable 1.12 GB
- Redis 버전: 서비스가 관리하는 Redis 7.x
- persistence: `DISABLED`
- zone distribution: `MULTI_ZONE`

`REDIS_SHARED_CORE_NANO`는 개발·테스트 전용이며 SLA가 없다. replica 0 구성은
노드 장애 시 해당 shard의 가용성과 데이터 복구를 보장하지 않는다. Online Store
데이터는 offline store에서 다시 materialize할 수 있다는 전제로 persistence를
끄고 최소 비용으로 시작한다. 운영 전환 시 `REDIS_STANDARD_SMALL` 이상,
`replica_count = 1`, persistence를 별도 검토한다.

리소스 이름은 공통 prefix를 사용한 `autoresearch-dev-redis-cluster`로 한다.

### 2. Redis Cluster 전용 PSC 네트워크

Redis Cluster는 Cloud SQL의 PSA를 재사용하지 않는다. 기존 dev VPC의 서울 리전에
전용 `10.10.16.0/29` subnet과 다음 Service Connection Policy를 추가한다.

- service class: `gcp-memorystore-redis`
- connection limit: 2
- cluster의 `psc_configs.network`: 기존 dev VPC full resource path

Memorystore는 cluster당 discovery endpoint와 internal backend용 주소 두 개를 PSC
subnet에서 예약한다. `/29`는 현재 한 cluster에 필요한 두 주소와 GCP 예약 주소를
수용하며 기존 dev, GKE secondary, control plane, Cloud SQL PSA CIDR과 겹치지 않는다.

클라이언트는 discovery endpoint의 TCP 6379로 topology를 얻은 뒤 PSC subnet의
data node TCP 11000-13047로 직접 연결한다. 따라서 NetworkPolicy는 두 포트 범위를
모두 허용해야 하며 public endpoint나 Redis ingress firewall을 만들지 않는다.

필수 수동 활성 API는 다음 두 개를 기존 Redis API와 함께 관리 문서에 기록한다.

- `redis.googleapis.com`
- `networkconnectivity.googleapis.com`
- `serviceconsumermanagement.googleapis.com`

### 3. IAM 인증과 TLS

`authorization_mode = AUTH_MODE_IAM_AUTH`와
`transit_encryption_mode = TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION`을 상시
사용한다. 정적 AUTH 문자열은 생성·저장하지 않는다.

- app GSA에 `roles/redis.dbConnectionUser`를 부여한다.
- project IAM binding에는 `resource.name` 조건을 사용하여
  `autoresearch-dev-redis-cluster` 하나로 권한을 제한한다.
- pod는 Workload Identity로 단기 IAM access token을 발급받아 Redis `AUTH`에
  사용한다. token은 Secret Manager, Terraform state, output, 로그에 저장하지 않는다.
- Google-managed per-instance CA 전체 bundle은 Secret Manager에 저장하고 app GSA에
  해당 secret의 `roles/secretmanager.secretAccessor`만 부여한다.
- discovery address, port, PSC subnet CIDR, CA secret ID만 output한다.

IAM token은 만료되므로 애플리케이션 cluster client는 token 재발급과 새 connection
인증, topology refresh, `MOVED` redirection을 지원해야 한다. Feast 0.64.0의 실제
호환성 및 adapter 구현은 앱 저장소 후속 작업의 merge 전제 조건으로 남긴다.

### 4. Kubernetes 경계는 별도 admin state

`terraform/admin/autoresearch-k8s` root는 다음을 관리한다.

- `autoresearch` namespace
- app GSA annotation이 붙은 `autoresearch-app` KSA
- namespace 전체 pod에 적용되는 egress NetworkPolicy

egress 정책은 다음 최소 경로를 허용한다.

- 같은 namespace pod 간 통신
- kube-dns UDP/TCP 53과 GKE services CIDR의 DNS VIP
- Cloud SQL PSA CIDR TCP 5432
- Redis PSC subnet TCP 6379, TCP 11000-13047
- GKE metadata server의 Workload Identity TCP 80, 987, 988
- 외부 API와 Google APIs의 HTTPS TCP 443

Cloud SQL PSA CIDR과 Redis PSC CIDR을 서로 다른 변수와 egress rule로 분리한다.
namespace가 live cluster에 이미 존재하면 최초 apply 전에 import한다. apply는
운영자 네트워크와 명시적 사용자 승인 후에만 수행한다.

### 5. hash tag와 MGET 검증

Redis Cluster는 key 전체를 CRC16으로 계산해 16,384개 hash slot 중 하나에
배치한다. key에 첫 번째 유효한 `{...}` 구간이 있으면 해당 문자열만 slot 계산에
사용한다.

예시:

```text
feature:{user:100}:age
feature:{user:100}:watch_time
```

두 key는 `{user:100}`을 공유하므로 `CLUSTER KEYSLOT` 결과가 같고 단일 `MGET`이
성공해야 한다. `{user:100}`과 `{user:200}`처럼 tag가 다르고 slot도 다른 key를
한 `MGET`으로 요청하면 `CROSSSLOT`을 확인한다.

hash tag는 multi-key 원자 연산이 필요한 관련 key에만 사용한다. 너무 많은 key를
같은 tag에 집중시키면 특정 shard에 데이터와 트래픽이 몰리므로 모든 Feature에
고정 tag 하나를 공통 적용하지 않는다.

인프라 apply 후 GKE 내부 임시 검증 pod에서 IAM token과 CA를 사용해 위 동작을
검증한다. 실제 Feature key schema와 회귀 테스트는 앱 저장소 후속 작업으로 둔다.

## 보안·비용·롤백

- public endpoint와 `0.0.0.0/0` Redis ingress를 만들지 않는다.
- IAM 인증 token은 런타임에서만 사용하고 저장하지 않는다.
- CA payload는 Terraform state에 포함되므로 기존 GCS backend IAM으로 보호한다.
- nano 2노드는 SLA와 replica가 없으며 총 writable keyspace는 약 2.24 GB다.
- `redis_cluster_deletion_protection=false`는 dev 기본값이지만 삭제·교체 plan은 별도 승인한다.
- 롤백 시 앱의 Redis 사용을 중지하고 offline store에서 재-materialize할 수 있는지
  확인한 뒤 NetworkPolicy와 Cluster/PSC 제거 plan을 각각 검토한다.
- 이미 단일 Redis를 apply한 환경이 생긴 경우 in-place 전환으로 보지 않고 데이터
  재-materialize를 전제로 별도 migration과 destroy 승인을 받는다.

## 검증

- dev root와 admin root 각각 `fmt -check`, `init -backend=false`, `validate`
- 실제 인증 환경에서 dev plan의 add/change/delete/replace 확인
- admin plan에서 namespace 존재 시 import 필요 여부 확인
- apply 후 GKE pod에서 TLS + IAM 인증 `PING`/`PONG`, `CLUSTER SHARDS` 확인
- `CLUSTER KEYSLOT` 동일성, 동일 tag `MGET` 성공, 다른 slot `CROSSSLOT` 재현
- public IP 부재, IAM condition, PSC CIDR/port 최소 범위, 예상 비용 확인

## 참고 자료

- [Google Cloud Redis Cluster networking](https://docs.cloud.google.com/memorystore/docs/cluster/networking)
- [Google Cloud Redis Cluster IAM authentication](https://docs.cloud.google.com/memorystore/docs/cluster/about-iam-auth)
- [Google Cloud Redis Cluster in-transit encryption](https://docs.cloud.google.com/memorystore/docs/cluster/about-in-transit-encryption)
- [Redis key hash tags](https://redis.io/docs/latest/develop/using-commands/keyspace/#hashtags)
- [Redis multi-key operations](https://redis.io/docs/latest/develop/using-commands/multi-key-operations/)
